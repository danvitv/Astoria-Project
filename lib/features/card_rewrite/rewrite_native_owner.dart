import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/db/repositories/manual_rewrite_job_repo.dart';
import '../../core/db/repositories/support_repo.dart';

/// One queue owned by the original review controller. Admission is synchronous,
/// including writes queued behind a native effect; neither value ABA nor a late
/// ordinary writer can issue a native successor ticket.
final class RewriteReviewWriteQueue {
  RewriteReviewWriteQueue(this.onBusy);
  final void Function(bool) onBusy;
  Future<void> _tail = Future<void>.value();
  int _revision = 0, _pending = 0;
  bool _exhausted = false;
  int get revision => _revision;
  bool get idle => !_exhausted && _pending == 0;
  void _advance() {
    if (_revision >= 9007199254740991) {
      _exhausted = true;
    } else {
      _revision++;
    }
  }

  Future<T> ordinary<T>(Future<T> Function() effect) => _enqueue(effect);
  Future<T> _enqueue<T>(Future<T> Function() effect) {
    _advance();
    _pending++;
    onBusy(true);
    final previous = _tail;
    final next = () async {
      await previous;
      try {
        return await effect();
      } finally {
        _pending--;
        _advance();
        onBusy(_pending != 0);
      }
    }();
    _tail = next.then<void>((_) {}, onError: (_, _) {});
    return next;
  }

  Future<T?> native<T>(
    int expected,
    Future<T?> Function(bool Function()) effect,
    void Function(T, RewriteReviewQueueTicket?) issue,
  ) async {
    if (!idle || revision != expected) return null;
    T? result;
    final admittedRevision = expected + 1;
    bool current() =>
        !_exhausted && _pending == 1 && revision == admittedRevision;
    var retained = false;
    try {
      await _enqueue(() async {
        if (current()) result = await effect(current);
        retained = current();
      });
      return result;
    } finally {
      if (result != null) {
        final ticket = retained && idle && revision == admittedRevision + 1
            ? RewriteReviewQueueTicket._(this, admittedRevision + 1)
            : null;
        issue(result as T, ticket);
      }
    }
  }
}

final class RewriteReviewQueueTicket {
  RewriteReviewQueueTicket._(this._queue, this._revision);
  final RewriteReviewWriteQueue _queue;
  final int _revision;
  bool _retired = false;
  bool get current {
    if (!_queue.idle || _queue.revision != _revision) _retired = true;
    return !_retired;
  }
}

final class RewriteNativeRejectCommit {
  RewriteNativeRejectCommit._(this.receipt);
  final ManualRewriteNativeRejectReceipt receipt;
  RewriteReviewQueueTicket? _queueTicket;
  bool get current => _queueTicket?.current == true && receipt.current;
}

final class RewriteNativeRejectUndoCommit {
  RewriteNativeRejectUndoCommit._(this.commit);
  final ManualRewriteNativeUndoCommit commit;
  RewriteReviewQueueTicket? _queueTicket;
  bool get current => _queueTicket?.current == true && commit.current;
}

/// Only the real mounted review route registers this owner, after its ordinary
/// load. Explicit selection is mandatory: desktop fallback-first is display only.
final class RewriteNativeReviewOwner {
  RewriteNativeReviewOwner({
    required this.originContainer,
    required this.jobId,
    required this.repo,
    required this.queue,
    required this.readLoaded,
    required this.readSelectedId,
    required this.isOriginalMounted,
  });
  final ProviderContainer originContainer;
  final String jobId;
  final ManualRewriteJobRepo repo;
  final RewriteReviewWriteQueue queue;
  final ManualRewriteJobSnapshot? Function() readLoaded;
  final String? Function() readSelectedId;
  final bool Function() isOriginalMounted;
  Object _selection = Object();
  bool _retired = false;
  bool get current {
    if (!_retired) {
      try {
        if (!isOriginalMounted()) _retired = true;
      } catch (_) {
        _retired = true;
      }
    }
    return !_retired;
  }

  void selectionChanged() => _selection = Object();
  bool Function() captureNativeGuard() {
    final selection = _selection;
    return () => current && identical(selection, _selection);
  }

  ManualRewriteOperationView? selected() {
    if (!current) return null;
    final snap = readLoaded(), id = readSelectedId();
    if (snap == null || snap.job.id != jobId || id == null) return null;
    final matches = snap.operations.where((v) => v.operation.id == id).toList();
    return matches.length == 1 ? matches.single : null;
  }

  void ordinaryAccepted() => repo.retireNativeReview(jobId);
  void retire() {
    _retired = true;
    selectionChanged();
  }

  Future<ManualRewriteNativeObservation?> observeReject(
    String operationId,
    bool Function() sourceCurrent,
  ) async {
    final snap = readLoaded(), view = selected(), revision = queue.revision;
    final native = captureNativeGuard();
    bool current() =>
        this.current &&
        native() &&
        sourceCurrent() &&
        queue.idle &&
        queue.revision == revision &&
        identical(readLoaded(), snap) &&
        identical(selected(), view);
    if (snap == null ||
        view == null ||
        view.operation.id != operationId ||
        !current())
      return null;
    final ticket = repo.bindNativeLoadedReview(snap);
    final observed = await repo.observeNativeReject(
      loaded: snap,
      selected: view,
      ticket: ticket,
      isCurrent: current,
    );
    return current() && observed?.current == true ? observed : null;
  }

  Future<ManualRewriteNativeUndoObservation?> observeUndo(
    RewriteNativeRejectCommit saved,
    bool Function() sourceCurrent,
  ) async {
    final snap = readLoaded(), view = selected(), revision = queue.revision;
    final native = captureNativeGuard();
    bool current() =>
        this.current &&
        native() &&
        sourceCurrent() &&
        saved.current &&
        queue.idle &&
        queue.revision == revision &&
        identical(readLoaded(), snap) &&
        identical(selected(), view);
    if (snap == null || view == null || !current()) return null;
    final observed = await repo.observeNativeRejectUndo(
      receipt: saved.receipt,
      loaded: snap,
      selected: view,
      isCurrent: current,
    );
    return current() && observed?.current == true ? observed : null;
  }

  Future<RewriteNativeRejectCommit?> reject({
    required ManualRewriteNativeObservation observed,
    required int queueRevision,
    required SupportRepo support,
    required String parentSession,
    required String journalId,
    required bool Function() sourceCurrent,
  }) {
    final native = captureNativeGuard();
    return queue.native<RewriteNativeRejectCommit>(
      queueRevision,
      (queueCurrent) async {
        bool current() =>
            this.current && native() && sourceCurrent() && queueCurrent();
        if (!current()) return null;
        final receipt = await repo.rejectNativeReview(
          observed: observed,
          support: support,
          parentSession: parentSession,
          journalId: journalId,
          isCurrent: current,
        );
        // Durable facts are retained even on retirement. No manual cache write:
        // the original durable watcher publishes its CURRENT aggregate instead.
        return receipt == null ? null : RewriteNativeRejectCommit._(receipt);
      },
      (result, ticket) {
        result._queueTicket = ticket;
      },
    );
  }

  Future<RewriteNativeRejectUndoCommit?> undo({
    required RewriteNativeRejectCommit saved,
    required ManualRewriteNativeUndoObservation observed,
    required int queueRevision,
    required SupportRepo support,
    required String parentSession,
    required bool Function() sourceCurrent,
  }) {
    final native = captureNativeGuard();
    return queue.native<RewriteNativeRejectUndoCommit>(
      queueRevision,
      (queueCurrent) async {
        bool current() =>
            this.current && native() && sourceCurrent() && queueCurrent();
        if (!current()) return null;
        final result = await repo.undoNativeReject(
          receipt: saved.receipt,
          observed: observed,
          support: support,
          parentSession: parentSession,
          isCurrent: current,
        );
        return result == null ? null : RewriteNativeRejectUndoCommit._(result);
      },
      (result, ticket) {
        result._queueTicket = ticket;
      },
    );
  }
}

final class RewriteNativeReviewOwnerRegistry {
  final _owners = <RewriteNativeReviewOwner>{};
  bool _disposed = false;
  int _revision = 0;
  int get revision => _revision;
  bool get current => !_disposed;
  void Function() register(RewriteNativeReviewOwner owner) {
    if (_disposed) {
      owner.retire();
      return () {};
    }
    _owners.add(owner);
    _revision++;
    return () {
      owner.retire();
      if (_owners.remove(owner)) _revision++;
    };
  }

  List<RewriteNativeReviewOwner> loaded(ProviderContainer container) =>
      _disposed
      ? const []
      : List.unmodifiable(
          _owners.where(
            (owner) =>
                identical(owner.originContainer, container) && owner.current,
          ),
        );
  RewriteNativeReviewOwner? existing(
    String jobId,
    ProviderContainer container,
  ) {
    final found = loaded(container).where((o) => o.jobId == jobId).toList();
    return found.length == 1 ? found.single : null;
  }

  void dispose() {
    _disposed = true;
    _revision++;
    for (final owner in _owners) {
      owner.retire();
    }
    _owners.clear();
  }
}

final rewriteNativeReviewOwnerRegistryProvider = Provider((ref) {
  final registry = RewriteNativeReviewOwnerRegistry();
  ref.onDispose(registry.dispose);
  return registry;
});
