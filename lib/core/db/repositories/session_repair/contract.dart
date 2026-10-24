part of '../session_repair_repo.dart';

final class SessionRepairInspection {
  const SessionRepairInspection._(this.targets, this.issues, this.complete);
  final List<SessionRepairTarget> targets;
  final List<SessionRepairIssue> issues;
  final bool complete;
  Map<String, Object?> toMetadata() => {
    'complete': complete,
    'count': targets.length,
    'issues': issues.map((i) => i.name).toList(),
    'records': targets.map((t) => t.toMetadata()).toList(),
  };
  @override
  String toString() =>
      'SessionRepairInspection(${targets.length}, complete=$complete)';
}

/// Native opaque observation. No public constructor, serialization importer,
/// model string lookup, generic key/ref or restoration of executable authority.
final class SessionRepairTarget {
  const SessionRepairTarget._(
    this._owner,
    this._image,
    this._setIndex,
    this._row,
    this.kind,
    this.opaqueId,
    this.issues,
    this.availability,
    this._current,
  );
  final SessionRepairRepo _owner;
  final _RepairImage _image;
  final int _setIndex;
  final Map<String, Object?> _row;
  final bool Function() _current;
  final SessionRepairTargetKind kind;
  final String opaqueId;
  final List<SessionRepairIssue> issues;
  final SessionRepairAvailability availability;
  Map<String, Object?> toMetadata() => {
    'id': opaqueId,
    'kind': kind.name,
    'issues': issues.map((i) => i.name).toList(),
    'availability': availability.name,
  };
  @override
  String toString() => 'SessionRepairTarget(${kind.name}, protected)';
}

final class SessionRepairPreparation {
  const SessionRepairPreparation._(this.plan, this.issue);
  final SessionRepairPlan? plan;
  final SessionRepairIssue? issue;
  @override
  String toString() => 'SessionRepairPreparation(${issue?.name ?? 'prepared'})';
}

final class SessionRepairPlan {
  const SessionRepairPlan._(
    this._owner,
    this._target,
    this._before,
    this._after,
    this.operationId,
    this.previewIdentity,
    this._createdAt,
    this._current,
  );
  final SessionRepairRepo _owner;
  final SessionRepairTarget _target;
  final _RepairImage _before, _after;
  final int _createdAt;
  final bool Function() _current;
  final String operationId, previewIdentity;
  SessionRepairTargetKind get kind => _target.kind;
  int get affectedRecords => 1;
  int get collateralManualRevisionBumps =>
      kind == SessionRepairTargetKind.liveLedger ? 1 : 0;
  bool get requiresNativeConfirmation => true;
  @override
  String toString() => 'SessionRepairPlan(${kind.name}, oneRecord)';
}

final class SessionRepairReceipt {
  const SessionRepairReceipt._(
    this._plan,
    this._journal,
    this._durable,
    this.outcome,
  );
  final SessionRepairPlan _plan;
  final SupportMutationReservation _journal;
  final _RepairImage _durable;
  final SessionRepairOutcome outcome;
  String get operationId => _plan.operationId;
  String get previewIdentity => _plan.previewIdentity;
  int get affectedRecords =>
      outcome == SessionRepairOutcome.undoConflict ? 0 : 1;
  @override
  String toString() => 'SessionRepairReceipt(${outcome.name})';
}

/// This is private-source native UI material, NOT safe model metadata. It can
/// only be obtained under a separate exact body-source lease above.
final class SessionRepairNativePreview {
  const SessionRepairNativePreview._(this._plan);
  final SessionRepairPlan _plan;
  Map<String, Object?> get before => Map.unmodifiable(_plan._target._row);
  Map<String, Object?>? get after =>
      _RepairMutationStore.targetRow(_plan, after: true);
  int get collateralManualRevisionBumps => _plan.collateralManualRevisionBumps;
  bool get preservesSnapshotsAndImmutableHistory => true;
  @override
  String toString() => 'SessionRepairNativePreview(protected)';
}

final class _RepairRefused implements Exception {
  const _RepairRefused([this.issue = SessionRepairIssue.staleSource]);
  final SessionRepairIssue issue;
}

void _repairRequire(
  bool value, [
  SessionRepairIssue issue = SessionRepairIssue.staleSource,
]) {
  if (!value) throw _RepairRefused(issue);
}

String _repairHash(Object? value) =>
    sha256.convert(utf8.encode(jsonEncode(value))).toString();
bool _repairId(String value) =>
    RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$').hasMatch(value) &&
    !RegExp(
      r'(^sk[-_:]|bearer|api[-_]?key|password|secret|token|credential)',
      caseSensitive: false,
    ).hasMatch(value);

Future<T?> _repairTransaction<T>(
  AppDatabase db,
  bool Function() current,
  Future<T> Function() work,
) async {
  try {
    _repairRequire(current(), SessionRepairIssue.authorityDenied);
    _repairRequire(
      db.resolvedEngine.executor is! TransactionExecutor,
      SessionRepairIssue.authorityDenied,
    );
    // Return actual owner commit custody. Do not test cancelled UI admission
    // after this await and relabel an already committed effect as no-effect.
    return await db.transaction(() async {
      _repairRequire(current());
      final result = await work();
      _repairRequire(current());
      return result;
    });
  } on _RepairRefused {
    rethrow;
  } catch (_) {
    throw const SessionRepairStorageException();
  }
}
