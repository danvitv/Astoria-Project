part of 'api_config_repo.dart';

/// Root bridge to the native per-connection credential/mutation owner. It must
/// revoke native handles before admission and keep its lease through DB commit.
/// Unknown/conflicting credential ownership or retired mutation state must deny.
/// Neither this port nor the repository reads/writes a credential.
abstract interface class KeylessNativeMutationPort {
  Object? revisionFor(String connectionId);
  Future<KeylessNativeMutationLease?> acquire({
    required String connectionId,
    required bool Function() isCurrent,
  });
}

abstract interface class KeylessNativeMutationLease {
  Object get priorRevision;
  bool get isCurrent;

  /// Guarded actual protected native record, not an ID/name/history heuristic.
  bool get nativeOwned;

  /// Positive verified absence permits model changes; unavailable != absent.
  bool get allowsModelChange;
  Future<T> runObservedMutation<T>(Future<T> Function() operation);

  /// Await the original native owner's finally/settlement. Called exactly once.
  Future<void> release();

  /// Original settlement only; null on competition/disposal/uncertain settlement.
  /// Never substitute a freshly observed stamp from a replacement operation.
  Object? get settlementRevision;
}

/// Optional native-only ordinary editor/import guard. No credential dependency
/// enters this library. The root owns native reads/denial/disable, not SQL.
abstract interface class ApiConfigOrdinaryMutationGuard {
  /// connectionId is a scheduling label ONLY, possibly empty for malformed maps.
  /// Do not infer authority/native ownership/absence from it. beforePut receives
  /// the actual decoded ID plus repository-owned fresh row/normalized bytes.
  Future<T> run<T>({
    required String connectionId,
    required Future<T> Function() operation,
  });
  Future<void> beforePut({
    required ApiConfig? existing,
    required ApiConfig proposed,
  });
  Future<void> beforeDelete(String id);
}

/// All consumer owners AND native credential absence must be held, not guessed
/// from a null/error. Includes implicit first-row roleplay fallback, Studio slots
/// and overrides, pipeline, encrypted Astoria settings and embedding links.
abstract interface class KeylessCreateUndoProofPort {
  Future<KeylessCreateUndoProofLease?> acquire({
    required String connectionId,
    required bool Function() isCurrent,
  });
}

abstract interface class KeylessCreateUndoProofLease {
  bool get isCurrent;
  bool get credentialAbsent;
  bool get referencesAbsent;
  void release();
}

final class KeylessApiConfigObservation {
  const KeylessApiConfigObservation._(
    this.view,
    this._row,
    this._owner,
    this._stamp,
    this._nativeRevision,
    this._creation,
  );
  final KeylessApiConfigView view;
  final ApiConfigRow _row;
  final ApiConfigRepo _owner;
  final int _stamp;
  final Object? _nativeRevision;
  final Object? _creation;
  bool get nativeOwned => _creation != null;
}

enum KeylessApiConfigAction { create, update, restoreUpdate, undoCreate }

/// Once-only same-process custody. No raw ApiConfig, key fields, serializer or
/// public construction. This is NOT native review/approval or restart authority.
final class KeylessApiConfigReceipt {
  KeylessApiConfigReceipt._(
    this.action,
    this.before,
    this.after,
    this._beforeRow,
    this._afterRow,
    this._owner,
    this._stamp,
    this._creation,
  );
  final KeylessApiConfigAction action;
  final KeylessApiConfigView? before;
  final KeylessApiConfigView? after;
  String get connectionId => (after ?? before)!.connectionId;
  final ApiConfigRow? _beforeRow;
  final ApiConfigRow? _afterRow;
  final ApiConfigRepo _owner;
  final Object _creation;
  final int _stamp;
  Object? _nativeRevision;
  bool _consumed = false;
}

final class KeylessApiConfigException implements Exception {
  const KeylessApiConfigException();
  @override
  String toString() => 'KeylessApiConfigException(storageUncertain)';
}

final class _KeylessRefused implements Exception {
  const _KeylessRefused();
}

final class _KeylessUndoConflict implements Exception {
  const _KeylessUndoConflict();
}

final class _KeylessOperation {
  _KeylessOperation(this.native);
  final KeylessNativeMutationLease native;
  KeylessCreateUndoProofLease? proof;
  bool get proofCurrent =>
      proof == null ||
      (proof!.isCurrent && proof!.credentialAbsent && proof!.referencesAbsent);
}

/// Conservative all-row same-process revision. Ordinary writes, even identical
/// content/failed attempts, retire receipts and pre-key native ownership.
final class _KeylessRevisionState {
  int stamp = 0;
  int pending = 0;
  final creations = <String, Object>{};
  void Function() start(
    void Function() Function()? hook, {
    bool native = false,
  }) {
    stamp++;
    pending++;
    if (!native) creations.clear();
    void Function()? finish;
    try {
      finish = hook?.call();
    } catch (_) {
      pending--;
      stamp++;
      rethrow;
    }
    var done = false;
    return () {
      if (done) return;
      done = true;
      try {
        finish?.call();
      } finally {
        pending--;
        stamp++;
      }
    };
  }
}
