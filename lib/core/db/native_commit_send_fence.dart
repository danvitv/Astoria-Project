part of 'app_db.dart';

/// No positive delivery fact was received from the original executor. Callers
/// must not turn this into a refusal/rollback claim or automatically retry it.
final class NativeCommitDeliveryUnknown implements Exception {
  const NativeCommitDeliveryUnknown();
}

extension AppDatabaseNativeReviewTransaction on AppDatabase {
  /// Owns one review transaction, not an attestation of a caller's executor.
  /// Its private binding exists ONLY during synchronous beginTransaction, never
  /// across an await or an entire operation zone. Other root writers cannot
  /// borrow its callback. Nested savepoints belong to the bound outer writer.
  Future<T> nativeReviewTransaction<T>(
    Future<T> Function() body, {
    required bool Function() isCurrent,
    required Object Function() onRefused,
  }) async {
    final fence = _commitSendFence;
    if (fence == null || fence.retired || !isCurrent()) throw onRefused();
    final run = _NativeCommitRun(fence, isCurrent, onRefused);
    try {
      final result = await runWithInterceptor(
        () => transaction(() {
          if (!run.bound || !run.current) throw onRefused();
          return body();
        }),
        interceptor: _NativeCommitBinding(run),
      );
      if (!run.delivered) {
        if (run.attempted) throw const NativeCommitDeliveryUnknown();
        throw onRefused();
      }
      return result;
    } catch (_) {
      // An awaited OUTER interceptor can fail after physical delivery. That is
      // not a rollback/refusal, even if its exception has the refusal type.
      // Retain the conservative unknown outcome; never retry or issue a receipt
      // from a transaction whose complete result did not reach its caller.
      if (run.delivered) throw const NativeCommitDeliveryUnknown();
      if (run.denied) {
        // A refused COMMIT says nothing about Drift's subsequent ROLLBACK.
        // An outer observer can fail before delegating it, and a background
        // rollback request can fail without reaching SQLite.
        if (!run.bound || run.rolledBack) throw onRefused();
        throw const NativeCommitDeliveryUnknown();
      }
      if (run.attempted) throw const NativeCommitDeliveryUnknown();
      rethrow;
    } finally {
      run.closed = true;
    }
  }
}

final _nativeCommitBindingKey = Object();

final class _NativeCommitRun {
  _NativeCommitRun(this.owner, this.isCurrent, this.onRefused);
  final _NativeCommitSendFence owner;
  final bool Function() isCurrent;
  final Object Function() onRefused;
  bool bound = false, closed = false, attempted = false;
  bool delivered = false, denied = false;
  bool rolledBack = false, localVeto = false;
  bool get current =>
      !closed && !owner.retired && isCurrent() && !closed && !owner.retired;
  void check() {
    if (!current) {
      denied = true;
      throw onRefused();
    }
  }
}

final class _NativeCommitBinding extends QueryInterceptor {
  _NativeCommitBinding(this.run);
  final _NativeCommitRun run;
  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    if (parent is TransactionExecutor) return parent.beginTransaction();
    if (run.bound) throw run.onRefused();
    return runZoned(
      parent.beginTransaction,
      zoneValues: {_nativeCommitBindingKey: run},
    );
  }
}

final class _NativeCommitTransaction {
  _NativeCommitTransaction(this.parent, this.run);
  final _NativeCommitTransaction? parent;
  final _NativeCommitRun? run;
  int children = 0;
  bool finished = false;
}

/// Installed by original AppDatabase constructors BEFORE any outside observer.
/// There is deliberately no constructor accepting an arbitrary QueryExecutor,
/// public trust boolean, unwrap, receipt, or FILE-identity-based send authority.
final class _NativeCommitSendFence extends QueryInterceptor {
  _NativeCommitSendFence.background() : _local = false;
  _NativeCommitSendFence.local() : _local = true;
  final bool _local;
  bool retired = false;
  final _transactions = Expando<_NativeCommitTransaction>();
  sqlite.Database? _raw;
  bool Function()? _previousFilter, _installedFilter;
  _NativeCommitRun? _sending;

  void installLocal(sqlite.Database raw) {
    _raw = raw;
    final previous = _previousFilter = raw.commitFilter;
    final filter = _installedFilter = () {
      // Preserve the caller's veto and let it run BEFORE our final check. Do
      // not replace authorizer/update/rollback hooks or commit stream listeners.
      final allowed = previous?.call() ?? true;
      final run = _sending;
      if (run == null) return allowed;
      if (!run.current) {
        run.denied = true;
        run.localVeto = true;
        return false; // SQLite itself converts COMMIT into a rollback.
      }
      return allowed;
    };
    raw.commitFilter = filter;
  }

  void retire() => retired = true;

  @override
  Future<void> close(QueryExecutor inner) {
    final raw = _raw;
    // Restore only OUR installation; never undo a later caller hook change.
    if (raw != null && identical(raw.commitFilter, _installedFilter)) {
      raw.commitFilter = _previousFilter;
    }
    return inner.close();
  }

  @override
  TransactionExecutor beginTransaction(QueryExecutor parent) {
    final enclosing = parent is TransactionExecutor
        ? _transactions[parent]
        : null;
    final candidate = Zone.current[_nativeCommitBindingKey];
    final run = enclosing == null &&
            candidate is _NativeCommitRun &&
            identical(candidate.owner, this)
        ? candidate
        : null;
    if (run != null) {
      run.check();
      if (run.bound) throw run.onRefused();
    }
    final inner = parent.beginTransaction();
    if (enclosing != null) enclosing.children++;
    _transactions[inner] = _NativeCommitTransaction(enclosing, run);
    if (run != null) run.bound = true;
    return inner;
  }

  void _finished(TransactionExecutor inner) {
    final transaction = _transactions[inner];
    if (transaction == null || transaction.finished) return;
    transaction.finished = true;
    // Keep a guarded executor's one-use binding for its own lifetime. A later
    // wrapper retry cannot become an unguarded send after we received its ack.
    // Expando does not keep completed executors/runs alive.
    if (transaction.run == null) _transactions[inner] = null;
    final parent = transaction.parent;
    if (parent != null) parent.children--;
  }

  @override
  Future<void> rollbackTransaction(TransactionExecutor inner) {
    final run = _transactions[inner]?.run;
    return inner.rollback().then<void>((_) {
      // Only the original executor's successful result is a rollback fact,
      // including the server acknowledgement for a background transaction.
      if (run != null) run.rolledBack = true;
    }).whenComplete(() => _finished(inner));
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) {
    final transaction = _transactions[inner];
    final run = transaction?.run;
    if (run == null) {
      return inner.send().then((_) => _finished(inner));
    }
    if (run.attempted) throw const NativeCommitDeliveryUnknown();
    run.check();
    // A live child could make NativeDatabase's runCustom queue on its lock.
    // No awaited child/queue is allowed between our check and the native send.
    if (transaction!.children != 0 ||
        (_local && !identical(_raw?.commitFilter, _installedFilter))) {
      run.denied = true;
      throw run.onRefused();
    }
    run.attempted = true;
    final raw = _local ? _raw : null;
    Future<void> sent;
    if (_local) {
      // Drift 2.33 NativeDatabase is non-sequential. With no child executor,
      // send -> runCustom -> Future.sync -> raw.execute is synchronous. The
      // commitFilter above checks at execution, NOT prepared-statement caching.
      // This pointer lives only on that synchronous stack, never over an await.
      _sending = run;
      try {
        sent = inner.send();
      } finally {
        _sending = null;
      }
    } else {
      // Drift 2.33, stock readPool:0: LazyDatabase.beginTransaction delegates
      // synchronously to _RemoteTransactionExecutor. Its send checks whether it
      // opened, then _sendAction -> channel.request -> _send -> sink.add, ALL
      // before the first await. This is the actual commit MESSAGE send, not an
      // early outer interceptor check and not a claim that a reply is durable.
      sent = inner.send();
    }
    return sent.then<void>(
      (_) {
        run.delivered = true;
        _finished(inner);
      },
      onError: (Object error, StackTrace trace) {
        // Inspect OUR raw connection at the settled failed send, before Drift
        // tries its redundant ROLLBACK. NativeDatabase keeps the transaction
        // lock on failed COMMIT. A hook invocation/denial alone is not proof:
        // require SQLite's commit-hook error AND its actual transaction state.
        if (run.localVeto &&
            error is sqlite.SqliteException &&
            error.extendedResultCode ==
                sqlite.SqlExtendedError.SQLITE_CONSTRAINT_COMMITHOOK &&
            raw?.autocommit == true) {
          run.rolledBack = true;
        }
        Error.throwWithStackTrace(error, trace);
      },
    );
  }
}

QueryExecutor _nativeMemoryExecutor(
  _NativeCommitSendFence fence,
  QueryInterceptor? observer,
) {
  final original = NativeDatabase.memory(
    setup: fence.installLocal,
  ).interceptWith(fence);
  return observer == null ? original : original.interceptWith(observer);
}

QueryExecutor _retainedNativeExecutor(
  sqlite.Database raw,
  _NativeCommitSendFence fence, {
  required bool closeUnderlyingOnClose,
  QueryInterceptor? observer,
}) {
  NativeHistoryIndexWorker.install(raw);
  fence.installLocal(raw);
  final original = NativeDatabase.opened(
    raw,
    closeUnderlyingOnClose: closeUnderlyingOnClose,
  ).interceptWith(fence);
  return observer == null ? original : original.interceptWith(observer);
}
