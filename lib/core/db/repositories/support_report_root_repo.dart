import 'dart:async';

import '../../support_report/support_report_error.dart';
import '../app_db.dart';
import '../database_transaction_guard.dart';
import 'support_text_context_repo.dart';

/// Scoped evidence issued ONLY inside the existing audited native writer ROOT.
/// No public constructor or foreign implementation can mint this proof. Neither
/// a caller's transaction nor a matching SQLite stamp establishes admission.
final class NativeReportRootScope {
  NativeReportRootScope._(this._owner, this._zone, this._checkpoint);

  final SupportReportRootRepo _owner;
  final Zone _zone;
  final void Function() _checkpoint;
  bool _active = true;

  bool belongsTo(AppDatabase database) =>
      _active &&
      identical(_zone, Zone.current) &&
      identical(_owner.database, database) &&
      identical(_owner.currentScope, this) &&
      _owner._current();

  void check(AppDatabase database) {
    if (!belongsTo(database)) _changed();
    _checkpoint();
    if (!belongsTo(database)) _changed();
  }

  Never _changed() =>
      throw const SupportReportException(SupportReportFailure.changed);
}

/// Original native report admission, not a general transaction utility.
/// Reuses the existing audited single-connection/no-busy-handler ROOT: its first
/// main-data statement obtains the writer WITHOUT changing rows or counters.
/// All reads are joined to that transaction, never a detached WAL snapshot.
final class SupportReportRootRepo {
  SupportReportRootRepo({
    required this.database,
    required this.nativeSource,
    required this.history,
    required bool Function() isCurrent,
  }) : _isCurrent = isCurrent;

  final AppDatabase database;
  final NativeDataSourceIdentity nativeSource;
  final SupportTextContextRepo history;
  final bool Function() _isCurrent;
  NativeReportRootScope? _scope;
  bool _entering = false;

  NativeReportRootScope? get currentScope => _scope;

  bool _current() {
    try {
      return _isCurrent() &&
          database.hasCompletedOpening &&
          !database.isClosing &&
          nativeSource.belongsTo(database) &&
          identical(database.nativeDataSourceIdentity, nativeSource) &&
          history.retainsNativeDataSource(nativeSource);
    } catch (_) {
      return false;
    }
  }

  /// Bounded DB/pure-crypto reads only. Never wait for UI, a picker or OS I/O.
  Future<T> read<T>(Future<T> Function(NativeReportRootScope scope) work) {
    late T value;
    return admit<T>(
      validate: (scope) async {
        value = await work(scope);
        scope.check(database);
      },
      dispatch: (_) => value,
    );
  }

  /// Validate under the actual original ROOT, then synchronously DISPATCH with
  /// no intervening await. Return a private capsule containing the admitted I/O
  /// Future, not that Future itself: ROOT release precedes awaiting its result.
  Future<T> admit<T>({
    required Future<void> Function(NativeReportRootScope scope) validate,
    required T Function(NativeReportRootScope scope) dispatch,
  }) async {
    if (_entering || !_current()) _changed();
    _entering = true;
    Object? failure;
    var dispatched = false;
    late T value;
    try {
      final admitted = await nativeSource.withBorrowedLifetime(
        () => outsideDatabaseTransaction(
          database,
          () => history.admitDispatch(
            snapshots: const [],
            isCurrent: _current,
            checkReadOnly: (checkpoint) async {
              checkpoint();
              final scope = NativeReportRootScope._(
                this,
                Zone.current,
                checkpoint,
              );
              _scope = scope;
              try {
                scope.check(database);
                await validate(scope);
                scope.check(database);
                return true;
              } catch (error) {
                failure = error;
                rethrow;
              }
            },
            dispatch: () {
              final scope = _scope;
              if (scope == null) _changed();
              scope.check(database);
              // Existing admission also checked counted writes/stamps after the
              // joined read and before this exact synchronous native handoff.
              value = dispatch(scope);
              dispatched = true;
            },
          ),
          onRejected: () => const SupportReportException(
            SupportReportFailure.changed,
          ),
        ),
      );
      if (!admitted || !dispatched) {
        if (failure case final SupportReportException reportFailure) {
          throw reportFailure;
        }
        _changed();
      }
      return value;
    } finally {
      _scope?._active = false;
      _scope = null;
      _entering = false;
    }
  }

  Never _changed() =>
      throw const SupportReportException(SupportReportFailure.changed);
}
