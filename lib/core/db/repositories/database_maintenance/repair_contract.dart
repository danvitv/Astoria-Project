part of '../database_maintenance_repo.dart';

/// Opaque native preview, NOT deserializable, consent or restoration evidence.
/// The caller confirms this identity, kind and single-row effect natively.
final class DatabaseMaintenancePlan {
  const DatabaseMaintenancePlan._(
    this._owner,
    this._target,
    this._guards,
    this._parentGuard,
    this.operationId,
    this._sessionId,
    this._createdAt,
    this._current,
    this.previewIdentity,
  );
  final DatabaseMaintenanceRepo _owner;
  final DatabaseMaintenanceTarget _target;
  final List<_MaintenanceRawGuard> _guards;
  final _MaintenanceRawGuard _parentGuard;
  final String operationId;
  final String _sessionId;
  final int _createdAt;
  final bool Function() _current;
  final String previewIdentity;
  DatabaseMaintenanceRepairKind get kind => _target.kind;
  int get affectedRows => 1;
  bool get requiresNativeConfirmation => true;
  @override
  String toString() => 'DatabaseMaintenancePlan(${kind.name}, oneRow)';
}

/// Actual outer-transaction completion with original encrypted journal custody.
/// No public constructor/copyWith/JSON import can manufacture execution or Undo.
final class DatabaseMaintenanceReceipt {
  const DatabaseMaintenanceReceipt._(this._plan, this._journal, this.outcome);
  final DatabaseMaintenancePlan _plan;
  final SupportMutationReservation _journal;
  final DatabaseMaintenanceMutationOutcome outcome;
  String get operationId => _plan.operationId;
  String get previewIdentity => _plan.previewIdentity;
  DatabaseMaintenanceRepairKind get kind => _plan.kind;
  @override
  String toString() => 'DatabaseMaintenanceReceipt(${outcome.name})';
}

final class _MaintenanceRawGuard {
  _MaintenanceRawGuard(
    this.table,
    Map<String, Object?> keys,
    Map<String, Object?>? row,
  ) : keys = Map.unmodifiable(keys),
      row = row == null ? null : Map.unmodifiable(row);
  final TableInfo<Table, dynamic> table;
  final Map<String, Object?> keys;
  // Bounded raw bytes used ONLY privately for exact CAS; never journaled or
  // returned. No decoder, tolerant canonicalizer or full-row replacement.
  final Map<String, Object?>? row;
  @override
  String toString() => '_MaintenanceRawGuard(protected)';
}

bool _maintenanceSafeId(String value) {
  if (!RegExp(r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$').hasMatch(value)) {
    return false;
  }
  // Fail closed on credential-looking identities instead of smuggling them
  // through the native evidence scalar allowlist. No key/endpoint decoding.
  return !RegExp(
    r'(^sk[-_:]|bearer|api[-_]?key|password|secret|token|credential)',
    caseSensitive: false,
  ).hasMatch(value);
}

String _maintenanceEvidence(
  DatabaseMaintenancePlan plan, {
  required bool after,
}) {
  final target = plan._target;
  final row = plan._guards.first.row!;
  final native = jsonEncode({
    'v': 1,
    'kind': target.kind.name,
    'id': target.id,
    if (target.folderId != null) 'folderId': target.folderId,
    if (target.presetKind != null) 'presetKind': target.presetKind!.name,
    'present':
        !after ||
        target.kind ==
            DatabaseMaintenanceRepairKind.normalizeEmptyCharacterGroup,
    if (target.kind ==
        DatabaseMaintenanceRepairKind.normalizeEmptyCharacterGroup)
      'groupId': after ? target.id : '',
    if (target.kind !=
        DatabaseMaintenanceRepairKind.normalizeEmptyCharacterGroup)
      'addedAt': row['added_at'],
  });
  return SupportMutationEvidence.encode(native);
}

Variable _maintenanceVariable(Object? value) {
  if (value == null) return const Variable<String>(null);
  if (value is String) return Variable<String>(value);
  if (value is int) return Variable<int>(value);
  if (value is double && value.isFinite) return Variable<double>(value);
  throw const _MaintenanceRefused();
}
