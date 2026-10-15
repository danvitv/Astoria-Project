import 'sync_conflict_diagnostics_schema.dart';

enum SyncDiagnosticType {
  character,
  characterKnowledge,
  memoryGraph,
  unsupported,
}

enum SyncDiagnosticStatus {
  compared,
  unsupported,
  invalidIdentity,
  missingLocal,
  localReadFailed,
  cloudMissing,
  cloudReadFailed,
  authUnavailable,
  oversized,
  invalidJson,
  unknownRoot,
  changedDuringRead,
  inspectionLimited,
  unavailable,
}

enum SyncDiagnosticDifference {
  value,
  presence,
  shape,
  size,
  order,
  unknownSchema,
  omitted,
}

enum SyncDiagnosticTimestampUnit {
  zero,
  secondsLikely,
  millisecondsLikely,
  unknown,
}

SyncDiagnosticTimestampUnit diagnosticTimestampUnit(int value) {
  if (value == 0) return SyncDiagnosticTimestampUnit.zero;
  if (value >= 1000000000 && value < 10000000000) {
    return SyncDiagnosticTimestampUnit.secondsLikely;
  }
  if (value >= 1000000000000 && value < 10000000000000) {
    return SyncDiagnosticTimestampUnit.millisecondsLikely;
  }
  return SyncDiagnosticTimestampUnit.unknown;
}

class SyncDiagnosticPath {
  final String path;
  final SyncDiagnosticDifference difference;
  final bool localOnlyMetadata;

  SyncDiagnosticPath(String path, this.difference)
    : path = isDiagnosticPath(path) ? path : r'$',
      localOnlyMetadata = diagnosticLocalMetadata.contains(path);

  @override
  String toString() =>
      '$path: ${difference.name}'
      '${localOnlyMetadata ? ' (local-only metadata)' : ''}';
}

class SyncConflictDiagnosticItem {
  final int ordinal;
  final SyncDiagnosticType type;
  final SyncDiagnosticStatus status;
  final SyncDiagnosticTimestampUnit localTimestampUnit;
  final SyncDiagnosticTimestampUnit cloudTimestampUnit;
  final List<SyncDiagnosticPath> paths;

  SyncConflictDiagnosticItem({
    required this.ordinal,
    required this.type,
    required this.status,
    required this.localTimestampUnit,
    required this.cloudTimestampUnit,
    List<SyncDiagnosticPath> paths = const [],
  }) : paths = List.unmodifiable(paths.take(128));

  @override
  String toString() =>
      '#$ordinal ${type.name}: ${status.name}; '
      'timestamps local=${localTimestampUnit.name}, cloud=${cloudTimestampUnit.name}'
      '${paths.isEmpty ? '' : '\n${paths.map((p) => '  $p').join('\n')}'}';
}

class SyncConflictDiagnosticReport {
  final List<SyncConflictDiagnosticItem> items;
  final bool truncated;
  final SyncDiagnosticStatus status;

  SyncConflictDiagnosticReport({
    List<SyncConflictDiagnosticItem> items = const [],
    this.truncated = false,
    this.status = SyncDiagnosticStatus.compared,
  }) : items = List.unmodifiable(items.take(50));

  String toSafeText() =>
      'Sync conflict diagnostics: ${status.name}\n'
      'Structural comparison only; no equivalence or repair decision.\n'
      'Timestamp units are magnitude estimates, not normalized comparisons.\n'
      '${items.join('\n')}${truncated ? '\nItems omitted (limit 50).' : ''}';

  @override
  String toString() => toSafeText();
}
