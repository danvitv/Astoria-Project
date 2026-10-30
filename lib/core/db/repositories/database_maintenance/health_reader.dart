part of '../database_maintenance_repo.dart';

final class _MaintenanceHealthReader {
  _MaintenanceHealthReader(this.db, this.current, int rows, this.mode)
    : rowLimit = rows.clamp(1, 1024).toInt();
  final AppDatabase db;
  final bool Function() current;
  final int rowLimit;
  final DatabaseMaintenancePhysicalCheck mode;
  final issues = <DatabaseMaintenanceIssue>[];
  bool truncated = false;
  bool retired = false;

  void issue(
    DatabaseMaintenanceIssueCode code, {
    String? table,
    int count = 1,
  }) {
    if (issues.length == DatabaseMaintenanceHealth.maxIssues) {
      truncated = true;
    } else {
      issues.add(DatabaseMaintenanceIssue(code, table: table, count: count));
    }
  }

  Future<List<Map<String, Object?>>> query(
    String sql, [
    List<Object?> variables = const [],
  ]) async {
    _maintenanceRequire(current());
    // No ensureOpen / customSelect: discovery may not canonicalize or migrate.
    try {
      final rows = await db.executor.runSelect(sql, variables);
      _maintenanceRequire(current());
      return rows;
    } catch (_) {
      // A failed SQLite statement is also an awaited ownership checkpoint. A
      // retired original operation must not continue with FK/schema queries.
      _maintenanceRequire(current());
      rethrow;
    }
  }

  Future<DatabaseMaintenanceCheck> physical() async {
    try {
      final pragma = mode == DatabaseMaintenancePhysicalCheck.quick
          ? 'quick_check'
          : 'integrity_check';
      // Unlike PRAGMA quick_check(N), the table-valued check's optional argument
      // is the schema, NOT an error budget. Passing 16 requests schema "16" and
      // fails before execution. Use its no-argument form, then cap the rows
      // consumed by the aggregate at 16 plus one overflow probe. The underlying
      // PRAGMA retains SQLite's default 100-error budget; it is not interruptible
      // here. Raw diagnostic text remains entirely inside SQLite.
      final rows = await query(
        'SELECT coalesce(sum(CASE WHEN status = \'ok\' COLLATE BINARY '
        'THEN 0 ELSE 1 END), 0) AS bad, count(*) AS n '
        'FROM (SELECT "$pragma" AS status FROM pragma_$pragma LIMIT 17)',
      );
      final count = rows.single['n'];
      final bad = rows.single['bad'];
      if (count is! int ||
          bad is! int ||
          count < 1 ||
          count > 17 ||
          bad < 0 ||
          bad > count) {
        return DatabaseMaintenanceCheck.unknown;
      }
      if (bad != 0) {
        issue(
          DatabaseMaintenanceIssueCode.physicalFailure,
          count: bad.clamp(0, 16).toInt(),
        );
        if (count > 16) {
          truncated = true;
          return DatabaseMaintenanceCheck.truncated;
        }
        return DatabaseMaintenanceCheck.issues;
      }
      return count == 1
          ? DatabaseMaintenanceCheck.checked
          : DatabaseMaintenanceCheck.unknown;
    } on _MaintenanceRefused {
      rethrow;
    } catch (_) {
      issue(DatabaseMaintenanceIssueCode.queryUnavailable);
      return DatabaseMaintenanceCheck.unknown;
    }
  }

  Future<(bool?, DatabaseMaintenanceCheck)> foreignKeys() async {
    bool? enabled;
    try {
      final flag = await query('PRAGMA foreign_keys');
      final value = flag.single['foreign_keys'];
      enabled = value == 1
          ? true
          : value == 0
          ? false
          : null;
      if (enabled == false) {
        issue(DatabaseMaintenanceIssueCode.foreignKeysDisabled);
      }
      // LIMIT in the SQL BEFORE materialization; no FK rowid/parent/table data
      // leaves SQLite. In-flight SQLite work itself has no interrupt port here.
      final rows = await query(
        'SELECT count(*) AS n FROM '
        '(SELECT 1 FROM pragma_foreign_key_check LIMIT 33)',
      );
      final count = rows.single['n'];
      if (count is! int) return (enabled, DatabaseMaintenanceCheck.unknown);
      if (count > 0) {
        issue(
          DatabaseMaintenanceIssueCode.foreignKeyViolation,
          count: count.clamp(0, 32).toInt(),
        );
      }
      if (count > 32) {
        truncated = true;
        return (enabled, DatabaseMaintenanceCheck.truncated);
      }
      return (
        enabled,
        count > 0
            ? DatabaseMaintenanceCheck.issues
            : DatabaseMaintenanceCheck.checked,
      );
    } on _MaintenanceRefused {
      rethrow;
    } catch (_) {
      issue(DatabaseMaintenanceIssueCode.queryUnavailable);
      return (enabled, DatabaseMaintenanceCheck.unknown);
    }
  }

  Future<DatabaseMaintenanceHealth> read() async {
    final registration = db.allTables.toList();
    final tables = <DatabaseMaintenanceTableHealth>[];
    int? version;
    var physicalState = DatabaseMaintenanceCheck.notChecked;
    bool? fkEnabled;
    var fkState = DatabaseMaintenanceCheck.notChecked;
    Future<void> readRegistration() async {
      _maintenanceRequire(!db.isClosing && current());
      physicalState = await physical();
      final fk = await foreignKeys();
      fkEnabled = fk.$1;
      fkState = fk.$2;
      try {
        final rows = await query('PRAGMA user_version');
        final raw = rows.single['user_version'];
        if (raw is int && raw >= 0 && raw <= 2147483647) version = raw;
        if (version != db.schemaVersion) {
          issue(DatabaseMaintenanceIssueCode.versionMismatch);
        }
      } on _MaintenanceRefused {
        rethrow;
      } catch (_) {
        issue(DatabaseMaintenanceIssueCode.queryUnavailable);
      }
      // Only registered index names are compared; no arbitrary schema rows or
      // SQL/DDL are materialized. Definitions/triggers explicitly not checked.
      for (final index in db.allSchemaEntities.whereType<Index>()) {
        final rows = await query(
          'SELECT count(*) AS n FROM sqlite_master '
          'WHERE type = \'index\' AND name = ?',
          [index.entityName],
        );
        if (rows.single['n'] != 1) {
          issue(DatabaseMaintenanceIssueCode.indexMissing);
        }
      }
      final reader = _MaintenanceTableReader(this);
      for (final table in registration) {
        _maintenanceRequire(current());
        tables.add(await reader.read(table));
        _maintenanceRequire(current());
      }
    }

    try {
      _maintenanceRequire(!db.isClosing);
      if (db.hasCompletedOpening) {
        await outsideDatabaseTransaction(
          db,
          readRegistration,
          onRejected: () => const _MaintenanceRefused(),
        );
      } else {
        // Never let context inspection open/migrate an unopened or closed DB.
        // Real ambient transaction callbacks run only after beforeOpen. An
        // explicitly supplied transactional root is also refused here.
        _maintenanceRequire(db.executor is! TransactionExecutor);
        await readRegistration();
      }
    } on _MaintenanceRefused {
      retired = !current();
      truncated = true;
    } catch (_) {
      issue(DatabaseMaintenanceIssueCode.queryUnavailable);
      truncated = true;
    }
    for (final table in registration.skip(tables.length)) {
      tables.add(
        DatabaseMaintenanceTableHealth(
          table: table.actualTableName,
          schema: DatabaseMaintenanceCheck.notChecked,
        ),
      );
    }
    DatabaseMaintenanceHealth result() => DatabaseMaintenanceHealth(
      registeredTables: registration.length,
      expectedVersion: db.schemaVersion,
      actualVersion: version,
      physical: physicalState,
      physicalKind: mode,
      foreignKeysEnabled: fkEnabled,
      foreignKeys: fkState,
      tables: tables,
      issues: issues,
      truncated: truncated,
      retired: retired,
    );
    // Current registration is comfortably below the cap. Keep table coverage if
    // issue text ever approaches it; never return an oversized DTO.
    while (utf8.encode(jsonEncode(result().toJson())).length >
            DatabaseMaintenanceHealth.maxOutputBytes &&
        issues.isNotEmpty) {
      issues.removeLast();
      truncated = true;
    }
    final report = result();
    if (utf8.encode(jsonEncode(report.toJson())).length >
        DatabaseMaintenanceHealth.maxOutputBytes) {
      throw const DatabaseMaintenanceException();
    }
    return report;
  }
}
