part of '../database_maintenance_repo.dart';

final class _MaintenanceTableReader {
  _MaintenanceTableReader(this.health);
  final _MaintenanceHealthReader health;

  Future<DatabaseMaintenanceTableHealth> read(
    TableInfo<Table, dynamic> table,
  ) async {
    final name = table.actualTableName;
    var schema = DatabaseMaintenanceCheck.unknown;
    try {
      final quoted = _maintenanceIdentifier(name);
      final present = await health.query(
        'SELECT count(*) AS n FROM '
        'sqlite_master WHERE type = \'table\' AND name = ?',
        [name],
      );
      if (present.single['n'] != 1) {
        health.issue(DatabaseMaintenanceIssueCode.tableMissing, table: name);
        return DatabaseMaintenanceTableHealth(
          table: name,
          schema: DatabaseMaintenanceCheck.issues,
        );
      }
      final columns = table.$columns;
      final names = columns.map((c) => c.name).toList();
      final placeholders = List.filled(names.length, '?').join(',');
      final found = await health.query(
        'SELECT count(*) AS n FROM '
        'pragma_table_info(?) WHERE name IN ($placeholders)',
        [name, ...names],
      );
      if (found.single['n'] != names.length) {
        health.issue(DatabaseMaintenanceIssueCode.columnMissing, table: name);
        return DatabaseMaintenanceTableHealth(
          table: name,
          schema: DatabaseMaintenanceCheck.issues,
        );
      }
      schema = DatabaseMaintenanceCheck.checked;
      final actualColumns = await health.query(
        'SELECT count(*) AS n FROM '
        'pragma_table_info(?)',
        [name],
      );
      if (actualColumns.single['n'] != columns.length) {
        health.issue(DatabaseMaintenanceIssueCode.schemaMismatch, table: name);
        schema = DatabaseMaintenanceCheck.issues;
      }
      final sample = '(SELECT * FROM $quoted LIMIT ${health.rowLimit})';
      final scalarConditions = <String>[];
      final jsonConditions = <String>[];
      final shapeConditions = <String>[];
      final sizeConditions = <String>[];
      final skipConditions = <String>[];
      var unknownShapes = 0;
      var jsonColumns = 0;
      for (final column in columns) {
        final c = _maintenanceIdentifier(column.name);
        final type = column.type;
        final String bad;
        if (type == DriftSqlType.int || type == DriftSqlType.dateTime) {
          bad = "typeof($c) != 'integer'";
        } else if (type == DriftSqlType.bool) {
          bad = "(typeof($c) != 'integer' OR $c NOT IN (0, 1))";
        } else if (type == DriftSqlType.double) {
          bad =
              "(typeof($c) NOT IN ('integer', 'real') OR "
              'abs($c) > 1.7976931348623157e308)';
        } else if (type == DriftSqlType.string) {
          bad = "typeof($c) != 'text'";
        } else if (type == DriftSqlType.blob) {
          bad = "typeof($c) != 'blob'";
        } else {
          // Unrecognized declared type cannot become scalar healthy.
          return DatabaseMaintenanceTableHealth(
            table: name,
            schema: schema,
            scalar: DatabaseMaintenanceCheck.unknown,
          );
        }
        scalarConditions.add(
          column.$nullable ? '($c IS NOT NULL AND ($bad))' : '($bad)',
        );
        if (!column.name.endsWith('_json') &&
            !_maintenanceJsonRoots.containsKey('$name.${column.name}'))
          continue;
        jsonColumns++;
        final root = _maintenanceJsonRoots['$name.${column.name}'];
        if (root == null) unknownShapes++;
        // Only intentional absent defaults are skipped. They are not decoded
        // into empty JSON; absent/unknown shape is distinct from syntax valid.
        final absent = column.$nullable ? '$c IS NULL' : '0';
        final empty = name == 'lorebooks' && column.name == 'settings_json'
            ? " OR $c = ''"
            : '';
        final skip = '($absent$empty)';
        skipConditions.add(skip);
        final size = 'length(CAST($c AS BLOB))';
        final tooLarge = '($size > 65536)';
        sizeConditions.add('(NOT $skip AND $tooLarge)');
        // CASE guarantees no JSON function sees malformed/oversized/non-text
        // rows. No short-circuit assumption on WHERE/AND evaluation ordering.
        final valid =
            'CASE WHEN $skip THEN 1 '
            "WHEN typeof($c) != 'text' THEN 0 "
            'WHEN $tooLarge THEN 1 ELSE json_valid($c) END';
        jsonConditions.add('($valid = 0)');
        if (root != null) {
          shapeConditions.add(
            'CASE WHEN $skip THEN 0 '
            "WHEN typeof($c) != 'text' THEN 0 "
            'WHEN $tooLarge THEN 0 WHEN json_valid($c) = 0 THEN 0 '
            "ELSE json_type($c) != '$root' END",
          );
        }
      }
      String sum(List<String> conditions) => conditions.isEmpty
          ? '0'
          : 'coalesce(sum(CASE WHEN (${conditions.join(' OR ')}) '
                'THEN 1 ELSE 0 END), 0)';
      final aggregate = (await health.query(
        'SELECT '
        '(SELECT count(*) FROM $quoted) AS total_n, count(*) AS sampled_n, '
        '${sum(scalarConditions)} AS scalar_bad, '
        '${sum(jsonConditions)} AS json_bad, '
        '${sum(shapeConditions)} AS shape_bad, '
        '${sum(sizeConditions)} AS size_bad, '
        '${sum(skipConditions)} AS skipped FROM $sample',
      )).single;
      // Counts and scalar/JSON sample share one SQLite statement snapshot. A
      // write between separate count/sample queries must not invent coverage.
      final total = aggregate['total_n'] as int;
      final sampled = aggregate['sampled_n'] as int;
      _maintenanceRequire(
        total >= sampled && sampled >= 0 && sampled <= health.rowLimit,
      );
      final limited = total > sampled;
      if (limited) health.truncated = true;
      final scalarBad = aggregate['scalar_bad'] as int;
      final jsonBad = aggregate['json_bad'] as int;
      final shapeBad = aggregate['shape_bad'] as int;
      final sizeBad = aggregate['size_bad'] as int;
      final skipped = aggregate['skipped'] as int;
      for (final pair in [
        (DatabaseMaintenanceIssueCode.scalarType, scalarBad),
        (DatabaseMaintenanceIssueCode.malformedJson, jsonBad),
        (DatabaseMaintenanceIssueCode.jsonRootShape, shapeBad),
        (DatabaseMaintenanceIssueCode.oversizedJson, sizeBad),
      ]) {
        if (pair.$2 > 0) health.issue(pair.$1, table: name, count: pair.$2);
      }
      // Only declared natural identities are checked, not arbitrary narrative
      // duplicates. LIMIT bounds result materialization; SQLite may scan all.
      final pk = table.$primaryKey
          .map((c) => _maintenanceIdentifier(c.name))
          .join(',');
      var identity = DatabaseMaintenanceCheck.notChecked;
      if (pk.isNotEmpty) {
        final duplicate = await health.query(
          'SELECT count(*) AS n FROM '
          '(SELECT 1 FROM $quoted GROUP BY $pk HAVING count(*) > 1 LIMIT 1)',
        );
        identity = duplicate.single['n'] == 0
            ? DatabaseMaintenanceCheck.checked
            : DatabaseMaintenanceCheck.issues;
        if (identity == DatabaseMaintenanceCheck.issues) {
          health.issue(
            DatabaseMaintenanceIssueCode.duplicateIdentity,
            table: name,
          );
        }
      }
      for (final key in table.uniqueKeys) {
        final names = key.map((c) => _maintenanceIdentifier(c.name)).join(',');
        if (names.isEmpty) continue;
        // SQLite UNIQUE allows multiple NULLs, unlike primary-key identity.
        final nonNull = key
            .map((c) => '${_maintenanceIdentifier(c.name)} IS NOT NULL')
            .join(' AND ');
        final duplicate = await health.query(
          'SELECT count(*) AS n FROM '
          '(SELECT 1 FROM $quoted WHERE $nonNull GROUP BY $names '
          'HAVING count(*) > 1 LIMIT 1)',
        );
        if (duplicate.single['n'] != 0) {
          identity = DatabaseMaintenanceCheck.issues;
          health.issue(
            DatabaseMaintenanceIssueCode.duplicateIdentity,
            table: name,
          );
        }
      }
      final references = await _references(name, sample, limited);
      DatabaseMaintenanceCheck checked(int bad) => bad > 0
          ? DatabaseMaintenanceCheck.issues
          : limited
          ? DatabaseMaintenanceCheck.truncated
          : DatabaseMaintenanceCheck.checked;
      return DatabaseMaintenanceTableHealth(
        table: name,
        schema: schema,
        rowCount: total,
        sampledRows: sampled,
        scalar: checked(scalarBad),
        json: jsonColumns == 0
            ? DatabaseMaintenanceCheck.notChecked
            : sizeBad > 0
            ? DatabaseMaintenanceCheck.unknown
            : jsonBad + shapeBad > 0
            ? DatabaseMaintenanceCheck.issues
            : limited
            ? DatabaseMaintenanceCheck.truncated
            : unknownShapes > 0 || skipped > 0
            ? DatabaseMaintenanceCheck.unknown
            : DatabaseMaintenanceCheck.checked,
        identity: identity,
        references: references,
        unknownJsonShapes: unknownShapes,
        uncheckedJsonRows: skipped,
      );
    } on _MaintenanceRefused {
      if (!health.current()) rethrow;
      health.issue(DatabaseMaintenanceIssueCode.queryUnavailable, table: name);
    } catch (_) {
      health.issue(DatabaseMaintenanceIssueCode.queryUnavailable, table: name);
    }
    return DatabaseMaintenanceTableHealth(table: name, schema: schema);
  }

  Future<DatabaseMaintenanceCheck> _references(
    String name,
    String sample,
    bool limited,
  ) async {
    final String condition;
    final DatabaseMaintenanceIssueCode code;
    if (name == 'characters') {
      condition =
          "typeof(s.variant_group_id) = 'text' AND s.variant_group_id = ''";
      code = DatabaseMaintenanceIssueCode.emptyCharacterGroup;
    } else if (name == 'character_folder_members') {
      condition =
          'NOT EXISTS (SELECT 1 FROM character_folders f '
          'WHERE f.folder_id = s.folder_id) OR NOT EXISTS '
          '(SELECT 1 FROM characters c WHERE c.char_id = s.char_id)';
      code = DatabaseMaintenanceIssueCode.danglingCharacterMembership;
    } else if (name == 'preset_folder_members') {
      condition =
          'NOT EXISTS (SELECT 1 FROM preset_folders f '
          'WHERE f.folder_id = s.folder_id) OR '
          "(s.kind = 'normal' AND NOT EXISTS (SELECT 1 FROM presets p "
          'WHERE p.preset_id = s.preset_id)) OR '
          "(s.kind = 'agentic' AND NOT EXISTS (SELECT 1 FROM studio_preset_rows p "
          'WHERE p.preset_id = s.preset_id))';
      code = DatabaseMaintenanceIssueCode.danglingPresetMembership;
      final bad =
          (await health.query(
                'SELECT count(*) AS n FROM $sample s '
                "WHERE typeof(s.kind) != 'text' OR s.kind NOT IN ('normal', 'agentic')",
              )).single['n']
              as int;
      if (bad > 0)
        health.issue(
          DatabaseMaintenanceIssueCode.unsupportedPresetKind,
          table: name,
          count: bad,
        );
      if (bad > 0) return DatabaseMaintenanceCheck.issues;
    } else {
      return DatabaseMaintenanceCheck.notChecked;
    }
    final bad =
        (await health.query(
              'SELECT count(*) AS n FROM $sample s '
              'WHERE $condition',
            )).single['n']
            as int;
    if (bad > 0) health.issue(code, table: name, count: bad);
    return bad > 0
        ? DatabaseMaintenanceCheck.issues
        : limited
        ? DatabaseMaintenanceCheck.truncated
        : DatabaseMaintenanceCheck.checked;
  }
}
