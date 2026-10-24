/// Metadata only. These states never assert narrative or domain correctness.
enum DatabaseMaintenanceCheck {
  checked,
  issues,
  unknown,
  truncated,
  notChecked,
}

enum DatabaseMaintenancePhysicalCheck { quick, integrity }

enum DatabaseMaintenanceIssueCode {
  physicalFailure,
  queryUnavailable,
  versionMismatch,
  tableMissing,
  columnMissing,
  schemaMismatch,
  indexMissing,
  scalarType,
  malformedJson,
  jsonRootShape,
  oversizedJson,
  duplicateIdentity,
  foreignKeysDisabled,
  foreignKeyViolation,
  emptyCharacterGroup,
  danglingCharacterMembership,
  danglingPresetMembership,
  unsupportedPresetKind,
}

final class DatabaseMaintenanceIssue {
  const DatabaseMaintenanceIssue(this.code, {this.table, this.count = 1});
  final DatabaseMaintenanceIssueCode code;

  /// Only a name obtained from the trusted Drift registration, never row data.
  final String? table;
  final int count;
  Map<String, Object?> toJson() => {
    'code': code.name,
    if (table != null) 'table': table,
    'count': count,
  };
  @override
  String toString() => 'DatabaseMaintenanceIssue(${code.name})';
}

final class DatabaseMaintenanceTableHealth {
  const DatabaseMaintenanceTableHealth({
    required this.table,
    required this.schema,
    this.rowCount,
    this.sampledRows = 0,
    this.scalar = DatabaseMaintenanceCheck.notChecked,
    this.json = DatabaseMaintenanceCheck.notChecked,
    this.identity = DatabaseMaintenanceCheck.notChecked,
    this.references = DatabaseMaintenanceCheck.notChecked,
    this.unknownJsonShapes = 0,
    this.uncheckedJsonRows = 0,
  });
  final String table;
  final DatabaseMaintenanceCheck schema;
  final int? rowCount;
  final int sampledRows;
  final DatabaseMaintenanceCheck scalar;
  final DatabaseMaintenanceCheck json;
  final DatabaseMaintenanceCheck identity;
  final DatabaseMaintenanceCheck references;
  final int unknownJsonShapes;
  final int uncheckedJsonRows;
  Map<String, Object?> toJson() => {
    'table': table,
    'schema': schema.name,
    'rows': rowCount,
    'sampled': sampledRows,
    'scalar': scalar.name,
    'json': json.name,
    'identity': identity.name,
    'references': references.name,
    'unknownShapes': unknownJsonShapes,
    'uncheckedJsonRows': uncheckedJsonRows,
  };
  @override
  String toString() => 'DatabaseMaintenanceTableHealth($table, ${schema.name})';
}

final class DatabaseMaintenanceHealth {
  DatabaseMaintenanceHealth({
    required this.registeredTables,
    required this.expectedVersion,
    required this.actualVersion,
    required this.physical,
    required this.physicalKind,
    required this.foreignKeysEnabled,
    required this.foreignKeys,
    required List<DatabaseMaintenanceTableHealth> tables,
    required List<DatabaseMaintenanceIssue> issues,
    required this.truncated,
    required this.retired,
  }) : tables = List.unmodifiable(tables),
       issues = List.unmodifiable(issues);
  static const maxIssues = 64;
  static const maxOutputBytes = 32768;
  final int registeredTables;
  final int expectedVersion;
  final int? actualVersion;
  final DatabaseMaintenanceCheck physical;
  final DatabaseMaintenancePhysicalCheck physicalKind;
  final bool? foreignKeysEnabled;
  final DatabaseMaintenanceCheck foreignKeys;
  final List<DatabaseMaintenanceTableHealth> tables;
  final List<DatabaseMaintenanceIssue> issues;
  final bool truncated;
  final bool retired;
  Map<String, Object?> toJson() => {
    'registeredTables': registeredTables,
    'expectedVersion': expectedVersion,
    'actualVersion': actualVersion,
    'physical': physical.name,
    'physicalKind': physicalKind.name,
    'foreignKeysEnabled': foreignKeysEnabled,
    'foreignKeys': foreignKeys.name,
    'tables': tables.map((t) => t.toJson()).toList(),
    'issues': issues.map((i) => i.toJson()).toList(),
    'truncated': truncated,
    'retired': retired,
    // Fixed limitations, not a manufactured universal healthy verdict.
    'semanticValidation': 'not_checked',
    'ciphertextAndVectorContents': 'not_checked',
    'schemaDefinitionsAndTriggers': 'not_checked',
    'partialUniqueAndDomainDuplicates': 'not_checked',
    'jsonValidation': 'bounded_syntax_and_known_roots_not_item_fields',
    'snapshotConsistency': 'live_between_queries',
    'sqliteInterruption': 'checkpoints_only_in_flight_sql_not_interruptible',
    'backupAndRestore': 'not_checked_export_is_not_exact_backup',
    'repairCoverage': [
      'empty_character_group',
      'dangling_character_membership',
      'dangling_preset_membership',
    ],
    'unsupportedRepairs': [
      'schema_installation',
      'duplicate_auto_delete',
      'primary_json_invention',
      'vector_blob_rewrite',
      'global_restore',
      'reindex',
      'vacuum',
    ],
  };
  @override
  String toString() =>
      'DatabaseMaintenanceHealth('
      'tables=$registeredTables, issues=${issues.length}, retired=$retired)';
}

enum DatabaseMaintenanceRepairKind {
  normalizeEmptyCharacterGroup,
  removeDanglingCharacterMembership,
  removeDanglingPresetMembership,
}

enum DatabaseMaintenancePresetKind { normal, agentic }

/// Finite typed target. It cannot carry a table, SQL, payload or JSON path.
final class DatabaseMaintenanceTarget {
  const DatabaseMaintenanceTarget.characterGroup(String characterId)
    : kind = DatabaseMaintenanceRepairKind.normalizeEmptyCharacterGroup,
      id = characterId,
      folderId = null,
      presetKind = null;
  const DatabaseMaintenanceTarget.characterMembership({
    required String characterId,
    required String folderId,
  }) : kind = DatabaseMaintenanceRepairKind.removeDanglingCharacterMembership,
       id = characterId,
       folderId = folderId,
       presetKind = null;
  const DatabaseMaintenanceTarget.presetMembership({
    required String presetId,
    required String folderId,
    required DatabaseMaintenancePresetKind presetKind,
  }) : kind = DatabaseMaintenanceRepairKind.removeDanglingPresetMembership,
       id = presetId,
       folderId = folderId,
       presetKind = presetKind;
  final DatabaseMaintenanceRepairKind kind;
  final String id;
  final String? folderId;
  final DatabaseMaintenancePresetKind? presetKind;
  @override
  String toString() => 'DatabaseMaintenanceTarget(${kind.name})';
}

enum DatabaseMaintenanceMutationOutcome { applied, undone, undoConflict }

final class DatabaseMaintenanceException implements Exception {
  const DatabaseMaintenanceException();
  @override
  String toString() => 'DatabaseMaintenanceException(storageUnavailable)';
}
