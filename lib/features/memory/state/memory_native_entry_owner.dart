import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/memory_book_repo.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/models/memory_book.dart';
import '../controllers/memory_book_write_queue.dart';

part 'memory_native_draft_owner.dart';
part 'memory_native_draft_removal_owner.dart';

/// The ORIGINAL controller pins its actual container synchronously before load,
/// then registers this owner after its ordinary load. Lookup cannot load a book,
/// create a widget/controller or dispatch embeddings.
final class MemoryNativeEntryOwner {
  MemoryNativeEntryOwner({
    required this.originContainer,
    required this.sessionId,
    required this.characterId,
    required this.repo,
    required this.queue,
    required this.readBook,
    required this.isNativeCurrent,
    required this.captureNativeGuard,
    required this.publish,
    required this.publishDraft,
    this.publishDraftList,
  });
  final String sessionId, characterId;
  final ProviderContainer originContainer;
  final MemoryBookRepo repo;
  final MemoryBookWriteQueue queue;
  final MemoryBook? Function() readBook;
  final bool Function() isNativeCurrent;
  final bool Function() Function() captureNativeGuard;
  final void Function(MemoryEntry) publish;
  final void Function(MemoryDraft) publishDraft;
  final void Function(List<MemoryDraft>)? publishDraftList;
  bool _retired = false;
  bool get current {
    if (_retired) return false;
    try {
      if (!isNativeCurrent()) _retired = true;
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }

  MemoryEntry? cached(String id) {
    if (!current) return null;
    final book = readBook();
    if (book == null ||
        book.sessionId != sessionId ||
        book.entries.length > 128 ||
        book.settings.vectorSearchEnabled)
      return null;
    final matches = book.entries.where((e) => e.id == id).toList();
    return matches.length == 1 ? matches.single : null;
  }

  Future<MemoryNativeEntryObservation?> observe(
    String id,
    bool Function() sourceCurrent,
  ) async {
    final entry = cached(id), revision = queue.revision;
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queue.idle &&
        queue.revision == revision &&
        identical(cached(id), entry);
    if (entry == null || !current()) return null;
    final observation = await repo.observeNativeEntry(
      sessionId: sessionId,
      entryId: id,
      isCurrent: current,
    );
    return current() && observation?.entry == entry ? observation : null;
  }

  Future<MemoryNativeEntryReceipt?> revise({
    required MemoryNativeEntryObservation observed,
    required int queueRevision,
    required String content,
    required SupportRepo support,
    required String parentSession,
    required String operationId,
    required bool Function() sourceCurrent,
  }) => queue.runNative<MemoryNativeEntryReceipt>(queueRevision, (
    queueCurrent,
  ) async {
    final cachedBefore = cached(observed.entry.id);
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queueCurrent() &&
        cachedBefore == observed.entry &&
        identical(cached(observed.entry.id), cachedBefore);
    if (!current()) return null;
    final receipt = await repo.reviseNativeEntry(
      observed: observed,
      content: content,
      support: support,
      parentSession: parentSession,
      operationId: operationId,
      isCurrent: current,
    );
    if (receipt != null && current()) publish(receipt.after);
    return receipt;
  });
  Future<MemoryEntry?> undo({
    required MemoryNativeEntryReceipt receipt,
    required MemoryNativeEntryObservation observed,
    required int queueRevision,
    required SupportRepo support,
    required String parentSession,
    required bool Function() sourceCurrent,
  }) => queue.runNative<MemoryEntry>(queueRevision, (queueCurrent) async {
    final cachedBefore = cached(observed.entry.id);
    bool current() =>
        this.current &&
        sourceCurrent() &&
        queueCurrent() &&
        cachedBefore == observed.entry &&
        identical(cached(observed.entry.id), cachedBefore);
    if (!current()) return null;
    final restored = await repo.undoNativeEntry(
      receipt: receipt,
      observed: observed,
      support: support,
      parentSession: parentSession,
      isCurrent: current,
    );
    if (restored != null && current()) publish(restored);
    return restored;
  });
  void retire() => _retired = true;
}

final class MemoryNativeEntryOwnerRegistry {
  final _owners = <MemoryNativeEntryOwner>{};
  bool _disposed = false;
  bool _exhausted = false;
  int _revision = 0;
  int get revision => _revision;
  bool get current => !_disposed && !_exhausted;
  void _advance() {
    if (_revision >= 9007199254740991) {
      _exhausted = true;
    } else {
      _revision++;
    }
  }

  void Function() register(MemoryNativeEntryOwner owner) {
    if (!current) {
      owner.retire();
      return () {};
    }
    _owners.add(owner);
    _advance();
    return () {
      owner.retire();
      if (_owners.remove(owner)) _advance();
    };
  }

  MemoryNativeEntryOwner? existing(
    String session, {
    required ProviderContainer originContainer,
  }) {
    if (!current) return null;
    final matches = _owners
        .where(
          (o) =>
              o.sessionId == session &&
              identical(o.originContainer, originContainer) &&
              o.current,
        )
        .toList();
    return matches.length == 1 ? matches.single : null;
  }

  void dispose() {
    _disposed = true;
    _advance();
    for (final owner in _owners) {
      owner.retire();
    }
    _owners.clear();
  }
}

final memoryNativeEntryOwnerRegistryProvider = Provider((ref) {
  final registry = MemoryNativeEntryOwnerRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});
