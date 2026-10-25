part of '../database_restore_repo.dart';

enum DatabaseRestoreCode {
  unavailable,
  unsupported,
  invalidCandidate,
  tooLarge,
  stale,
  cancelled,
  busy,
  bootstrapUnknown,
  accepted,
  originalRestored,
  recoveryRequired,
  interruptedRequiresFreshConfirmation,
  closed,
}

/// No public exception cause, paths, SQLite body, hashes, schema or row data.
final class DatabaseRestoreException implements Exception {
  const DatabaseRestoreException(this.code);
  final DatabaseRestoreCode code;
  @override
  String toString() => 'DatabaseRestoreException(${code.name})';
}

final class DatabaseRestoreProposal {
  DatabaseRestoreProposal._(this._owner, this._candidate);
  final NativeDatabaseRestoreOwner _owner;
  final _RestoreCandidate _candidate;
  bool _retired = false;
  bool _confirmed = false;
  @override
  String toString() => 'DatabaseRestoreProposal(opaque)';
}

final class DatabaseRestoreConfirmation {
  DatabaseRestoreConfirmation._(this._proposal);
  final DatabaseRestoreProposal _proposal;
  bool _used = false;
  @override
  String toString() => 'DatabaseRestoreConfirmation(opaque)';
}

final class DatabaseRestoreResult {
  const DatabaseRestoreResult._(this.code, {this.accepted});
  final DatabaseRestoreCode code;
  final AcceptedDatabaseRestore? accepted;

  /// RW bootstrap may recover a journal even if SQLite subsequently refuses.
  bool get bootstrapMayHaveTouched =>
      code == DatabaseRestoreCode.accepted ||
      code == DatabaseRestoreCode.originalRestored ||
      code == DatabaseRestoreCode.bootstrapUnknown ||
      code == DatabaseRestoreCode.busy ||
      code == DatabaseRestoreCode.recoveryRequired;
  @override
  String toString() => 'DatabaseRestoreResult(${code.name})';
}

/// The actual accepted Drift wrapper and its SAME raw/native lifetime owner.
/// Do not also construct AppDatabase() when handing this to future startup.
final class AcceptedDatabaseRestore {
  AcceptedDatabaseRestore._(this._owner, this._database) {
    // Only the accepted target receives borrowed snapshot authority. Candidate
    // wrappers retain no proof. Bind once to the exact already-open raw; no
    // engine connection replacement or second openedNative wrapper is needed.
    _database.nativeDataSourceIdentity!.retainSnapshotSource(
      source: _owner._target!.database,
      checkSource: _owner._checkSnapshotSource,
    );
    _owner._startup?._accepted = true;
  }
  final NativeDatabaseRestoreOwner _owner;
  final AppDatabase _database;
  AppDatabase get database {
    if (_owner._state != _RestoreState.accepted || _owner._retired) {
      throw const DatabaseRestoreException(DatabaseRestoreCode.closed);
    }
    return _database;
  }

  /// Explicit successful-handoff retention policy; never automatic on failure.
  Future<void> releaseOriginalsAfterAcceptedHandoff() =>
      _owner._releaseOriginals();
  Future<void> close() => _owner.close();
  @override
  String toString() => 'AcceptedDatabaseRestore(opaque)';
}

enum _RestoreState {
  idle,
  preparing,
  prepared,
  admitted,
  accepted,
  settled,
  blocked,
  closed,
}

/// Narrow test-only faults at real boundaries, not an acceptance predicate.
enum DatabaseRestoreTestBoundary {
  beforeBootstrap,
  originalVerified,
  candidateCopy,
  acceptance,
  reverseCopy,
  wrapperClose,
  rawClose,
}

final class _RestoreLimits {
  static const maxBytes = 256 * 1024 * 1024;
  static const maxPages = 65536;
  static const maxRows = 100000;
  static const maxTables = 128;
  static const maxEntities = 1024;
  static const maxSchemaBytes = 2 * 1024 * 1024;
  static const maxCellBytes = 4 * 1024 * 1024;
  static const maxColumns = 256;
  static const chunk = 64 * 1024;
  static const stepPages = 32;
  static const workDeadline = Duration(seconds: 5);
}

void _refuse(DatabaseRestoreCode code) => throw DatabaseRestoreException(code);

/// Retain original async errors immediately. Timeout never authorizes closing
/// or reversing a connection with unsettled executor work.
final class _RestoreWork {
  int pending = 0;
  final _schemaMemory = <_RestoreSchemaMemory>[];
  Object? first;
  StackTrace? firstStack;
  void remember(Object error, StackTrace stack) {
    first ??= error;
    firstStack ??= stack;
  }

  Future<T> run<T>(Future<T> future) {
    pending++;
    final observed = future.then<T>(
      (value) {
        pending--;
        return value;
      },
      onError: (Object error, StackTrace stack) {
        pending--;
        remember(error, stack);
        Error.throwWithStackTrace(error, stack);
      },
    );
    return observed.timeout(
      _RestoreLimits.workDeadline,
      onTimeout: () {
        _refuse(DatabaseRestoreCode.recoveryRequired);
        throw StateError('Unreachable');
      },
    );
  }
}
