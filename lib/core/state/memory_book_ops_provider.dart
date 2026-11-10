import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/memory_book.dart';
import '../../features/memory/state/memory_book_revision_provider.dart';
import '../../features/memory/state/memory_consolidation_worker_provider.dart';
import 'db_provider.dart';

class _MemoryBookOps {
  final Ref ref;
  _MemoryBookOps(this.ref);

  Future<MemoryBook> ensureForSession(String sessionId) async {
    return ref.read(memoryBookRepoProvider).ensureForSession(sessionId);
  }

  Future<void> saveMemoryBook(MemoryBook book) async {
    await ref.read(memoryBookRepoProvider).put(book);
    ref.read(memoryBookRevisionProvider.notifier).state++;
    ref
        .read(memoryConsolidationWorkerProvider)
        .bookContextChanged(book.sessionId);
  }

  Future<MemoryBook?> approveDraft(
    String sessionId,
    String draftId,
    MemoryDraft expected,
  ) async {
    final repo = ref.read(memoryBookRepoProvider);
    final approved = await repo.approveDraft(sessionId, draftId, expected);
    if (approved == null) return null;
    // Publish only the latest durable row. Approval may have raced another
    // repository-owned mutation while the sheet held an older snapshot.
    final persisted = await repo.getBySessionId(sessionId);
    if (persisted == null) return null;
    ref.read(memoryConsolidationWorkerProvider).notifyApproval(sessionId);
    return persisted;
  }

  Future<MemoryEntry?> reviseEntry({
    required String sessionId,
    required MemoryEntry expected,
    required MemoryEntry proposed,
    String reason = 'manual_edit',
  }) async {
    final revised = await ref
        .read(memoryBookRepoProvider)
        .reviseEntry(
          sessionId: sessionId,
          expected: expected,
          proposed: proposed,
          reason: reason,
        );
    if (revised != null) {
      ref.read(memoryBookRevisionProvider.notifier).state++;
      ref.read(memoryConsolidationWorkerProvider).bookContextChanged(sessionId);
    }
    return revised;
  }

  Future<MemoryEntry?> restoreEntryRevision({
    required String sessionId,
    required MemoryEntry expected,
    required String revisionId,
  }) async {
    final restored = await ref
        .read(memoryBookRepoProvider)
        .restoreEntryRevision(
          sessionId: sessionId,
          expected: expected,
          revisionId: revisionId,
        );
    if (restored != null) {
      ref.read(memoryBookRevisionProvider.notifier).state++;
      ref.read(memoryConsolidationWorkerProvider).bookContextChanged(sessionId);
    }
    return restored;
  }

  Future<void> updateSettings(
    String sessionId,
    MemoryBookSettings settings,
  ) async {
    await ref.read(memoryBookRepoProvider).updateSettings(sessionId, settings);
    ref.read(memoryBookRevisionProvider.notifier).state++;
    ref.read(memoryConsolidationWorkerProvider).bookContextChanged(sessionId);
  }

  Future<void> deleteEmbeddingEntry(String entryId) async {
    await ref.read(embeddingRepoProvider).deleteByEntryId(entryId);
  }
}

final memoryBookOpsProvider = Provider((ref) => _MemoryBookOps(ref));
