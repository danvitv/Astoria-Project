import 'package:drift/drift.dart';

/// Rejects a caller-owned transaction before entering a native owner's work.
/// The public interceptor API resolves the actual executor, including DAO and
/// intercepted scopes; the database's root executor alone cannot prove this.
/// Callers requiring no opening must first prove their database is already open.
Future<T> outsideDatabaseTransaction<T>(
  DatabaseConnectionUser database,
  Future<T> Function() work, {
  required Object Function() onRejected,
}) {
  final guard = _AmbientTransactionGuard(onRejected);
  // The second scope's opening invokes the first scope's interceptor BEFORE
  // work, even for zero-query work. Neither scope begins a transaction or lock.
  return database.runWithInterceptor(
    () => database.runWithInterceptor(work, interceptor: guard),
    interceptor: guard,
  );
}

final class _AmbientTransactionGuard extends QueryInterceptor {
  _AmbientTransactionGuard(this.onRejected);
  final Object Function() onRejected;
  bool _checked = false;

  @override
  Future<bool> ensureOpen(QueryExecutor executor, QueryExecutorUser user) {
    if (!_checked) {
      if (executor is TransactionExecutor) throw onRejected();
      _checked = true;
    }
    // The owner's own later transactions are allowed. This original one-use
    // entry proof is never reused for another operation.
    return executor.ensureOpen(user);
  }
}
