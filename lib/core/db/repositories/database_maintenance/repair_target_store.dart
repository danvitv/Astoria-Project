part of '../database_maintenance_repo.dart';

/// Finite three-target SQL owner. All restoration statements are narrow and
/// exact; private guards may contain raw narrative but never expose/decode it.
final class _MaintenanceTargetStore {
  _MaintenanceTargetStore(this.db);
  final AppDatabase db;
  static const maxGuardBytes = 65536;

  Future<void> narrowSchema(
    TableInfo<Table, dynamic> table,
    bool Function() current,
  ) async {
    final name = table.actualTableName;
    // These three source-owned targets have no triggers or SQL FK edges. Refuse
    // an altered schema that could turn a narrow UPDATE/DELETE into collateral
    // effects. Only scalar metadata is returned; no SQL/DDL is evaluated/exposed.
    final trigger = await checked(
      current,
      () => db
          .customSelect(
            "SELECT count(*) AS n FROM sqlite_master WHERE type = 'trigger' AND tbl_name = ?",
            variables: [Variable<String>(name)],
          )
          .getSingle(),
    );
    _maintenanceRequire(trigger.data['n'] == 0);
    final outgoing = await checked(
      current,
      () => db
          .customSelect(
            'SELECT count(*) AS n FROM pragma_foreign_key_list(?)',
            variables: [Variable<String>(name)],
          )
          .getSingle(),
    );
    _maintenanceRequire(outgoing.data['n'] == 0);
    final incoming = await checked(
      current,
      () => db
          .customSelect(
            'SELECT count(*) AS n FROM sqlite_master m, '
            'pragma_foreign_key_list(m.name) f WHERE m.type = \'table\' '
            'AND f."table" = ?',
            variables: [Variable<String>(name)],
          )
          .getSingle(),
    );
    _maintenanceRequire(incoming.data['n'] == 0);
  }

  Future<T> checked<T>(
    bool Function() current,
    Future<T> Function() read,
  ) async {
    _maintenanceRequire(current());
    final result = await read();
    _maintenanceRequire(current());
    return result;
  }

  (String, List<Variable>) predicate(
    Map<String, Object?> row, {
    bool withTypes = false,
  }) {
    final clauses = <String>[];
    final values = <Variable>[];
    for (final entry in row.entries) {
      final c = _maintenanceIdentifier(entry.key);
      clauses.add('$c IS ? COLLATE BINARY');
      values.add(_maintenanceVariable(entry.value));
      if (withTypes) {
        final type = entry.value == null
            ? 'null'
            : entry.value is String
            ? 'text'
            : entry.value is int
            ? 'integer'
            : 'real';
        clauses.add('typeof($c) = ?');
        values.add(Variable<String>(type));
      }
    }
    return (clauses.join(' AND '), values);
  }

  Future<_MaintenanceRawGuard> capture(
    TableInfo<Table, dynamic> table,
    Map<String, Object?> keys,
    bool Function() current,
  ) async {
    final name = table.actualTableName;
    final quoted = _maintenanceIdentifier(name);
    final columns = table.$columns;
    // Extra/unregistered columns cannot be omitted from an exact raw-row guard.
    final declared = await checked(
      current,
      () => db
          .customSelect(
            'SELECT count(*) AS n FROM pragma_table_info(?)',
            variables: [Variable<String>(name)],
          )
          .getSingle(),
    );
    _maintenanceRequire(declared.data['n'] == columns.length);
    final where = predicate(keys);
    final size = columns
        .map(
          (c) =>
              'coalesce(length(CAST(${_maintenanceIdentifier(c.name)} AS BLOB)), 0)',
        )
        .join(' + ');
    final sizes = await checked(
      current,
      () => db
          .customSelect(
            'SELECT ($size) AS bytes FROM $quoted WHERE ${where.$1} LIMIT 2',
            variables: where.$2,
            readsFrom: {table},
          )
          .get(),
    );
    _maintenanceRequire(sizes.length <= 1);
    if (sizes.isEmpty) return _MaintenanceRawGuard(table, keys, null);
    final bytes = sizes.single.data['bytes'];
    _maintenanceRequire(bytes is int && bytes >= 0 && bytes <= maxGuardBytes);
    final selection = columns
        .map((c) => _maintenanceIdentifier(c.name))
        .join(',');
    final rows = await checked(
      current,
      () => db
          .customSelect(
            'SELECT $selection FROM $quoted WHERE ${where.$1} '
            'AND ($size) <= $maxGuardBytes LIMIT 2',
            variables: where.$2,
            readsFrom: {table},
          )
          .get(),
    );
    _maintenanceRequire(rows.length == 1);
    final row = rows.single.data;
    // All owned target/dependency tables here contain scalar columns only. A
    // dynamic BLOB/unsupported scalar refuses before creating executable custody.
    for (final column in columns) {
      final value = row[column.name];
      if (value == null) {
        _maintenanceRequire(column.$nullable);
      } else if (column.type == DriftSqlType.string) {
        _maintenanceRequire(
          value is String && utf8.encode(value).length <= maxGuardBytes,
        );
      } else if (column.type == DriftSqlType.double) {
        _maintenanceRequire(value is num && value.isFinite);
      } else {
        _maintenanceRequire(value is int);
        if (column.type == DriftSqlType.bool) {
          _maintenanceRequire(value == 0 || value == 1);
        }
      }
    }
    final result = _MaintenanceRawGuard(table, keys, row);
    _maintenanceRequire(await matches(result, current));
    return result;
  }

  Future<bool> matches(
    _MaintenanceRawGuard guard,
    bool Function() current, {
    Map<String, Object?>? expectedRow,
    bool absent = false,
  }) async {
    final where = predicate(guard.keys);
    final table = _maintenanceIdentifier(guard.table.actualTableName);
    final keyCount = await checked(
      current,
      () => db
          .customSelect(
            'SELECT count(*) AS n FROM $table WHERE ${where.$1}',
            variables: where.$2,
            readsFrom: {guard.table},
          )
          .getSingle(),
    );
    final row = expectedRow ?? guard.row;
    if (absent || row == null) return keyCount.data['n'] == 0;
    if (keyCount.data['n'] != 1) return false;
    final exact = predicate(row, withTypes: true);
    final match = await checked(
      current,
      () => db
          .customSelect(
            'SELECT 1 FROM $table WHERE ${exact.$1} LIMIT 1',
            variables: exact.$2,
            readsFrom: {guard.table},
          )
          .get(),
    );
    return match.length == 1;
  }

  Future<List<_MaintenanceRawGuard>> prepare(
    DatabaseMaintenanceTarget target,
    bool Function() current,
  ) async {
    if (target.kind ==
        DatabaseMaintenanceRepairKind.normalizeEmptyCharacterGroup) {
      await narrowSchema(db.characters, current);
      final row = await capture(db.characters, {'char_id': target.id}, current);
      _maintenanceRequire(
        row.row != null && row.row!['variant_group_id'] == '',
      );
      return [row];
    }
    final character =
        target.kind ==
        DatabaseMaintenanceRepairKind.removeDanglingCharacterMembership;
    await narrowSchema(
      character ? db.characterFolderMembers : db.presetFolderMembers,
      current,
    );
    final member = await capture(
      character ? db.characterFolderMembers : db.presetFolderMembers,
      {
        'folder_id': target.folderId,
        character ? 'char_id' : 'preset_id': target.id,
        if (!character) 'kind': target.presetKind!.name,
      },
      current,
    );
    _maintenanceRequire(member.row != null);
    final addedAt = member.row!['added_at'];
    _maintenanceRequire(
      addedAt is int && addedAt >= 0 && addedAt <= 9007199254740991,
    );
    final folder = await capture(
      character ? db.characterFolders : db.presetFolders,
      {'folder_id': target.folderId},
      current,
    );
    final TableInfo<Table, dynamic> owner = character
        ? db.characters
        : target.presetKind == DatabaseMaintenancePresetKind.normal
        ? db.presets
        : db.studioPresetRows;
    final source = await capture(owner, {
      character ? 'char_id' : 'preset_id': target.id,
    }, current);
    _maintenanceRequire(folder.row == null || source.row == null);
    return [member, folder, source];
  }

  Map<String, Object?> afterRow(DatabaseMaintenancePlan plan) => {
    ...plan._guards.first.row!,
    'variant_group_id': plan._target.id,
  };

  Future<bool> allMatch(
    DatabaseMaintenancePlan plan,
    bool Function() current, {
    bool after = false,
  }) async {
    for (var i = 0; i < plan._guards.length; i++) {
      final group =
          plan.kind ==
          DatabaseMaintenanceRepairKind.normalizeEmptyCharacterGroup;
      if (!await matches(
        plan._guards[i],
        current,
        expectedRow: after && i == 0 && group ? afterRow(plan) : null,
        absent: after && i == 0 && !group,
      ))
        return false;
      _maintenanceRequire(current());
    }
    return true;
  }

  Future<void> effect(
    DatabaseMaintenancePlan plan,
    bool Function() current, {
    bool undo = false,
  }) async {
    final guard = plan._guards.first;
    final table = _maintenanceIdentifier(guard.table.actualTableName);
    final group =
        plan.kind == DatabaseMaintenanceRepairKind.normalizeEmptyCharacterGroup;
    await narrowSchema(guard.table, current);
    _maintenanceRequire(await allMatch(plan, current, after: undo));
    _maintenanceRequire(current());
    int changed;
    if (group) {
      final where = predicate(
        undo ? afterRow(plan) : guard.row!,
        withTypes: true,
      );
      changed = await db.customUpdate(
        'UPDATE $table SET variant_group_id = ? '
        'WHERE ${where.$1}',
        variables: [Variable<String>(undo ? '' : plan._target.id), ...where.$2],
        updates: {guard.table},
      );
    } else if (!undo) {
      final where = predicate(guard.row!, withTypes: true);
      changed = await db.customUpdate(
        'DELETE FROM $table WHERE ${where.$1}',
        variables: where.$2,
        updates: {guard.table},
      );
    } else {
      // Membership rows have ONLY identity+added_at. No OR REPLACE/upsert:
      // existing rows must cause a conflict, never overwrite newer membership.
      final row = guard.row!;
      changed = await db.customUpdate(
        'INSERT INTO $table '
        '(${row.keys.map(_maintenanceIdentifier).join(',')}) VALUES '
        '(${List.filled(row.length, '?').join(',')})',
        variables: row.values.map(_maintenanceVariable).toList(),
        updates: {guard.table},
      );
    }
    // Retired before outer commit rolls effect+journal back together. After
    // durable completion, caller retirement does not rewrite the factual result.
    _maintenanceRequire(current() && changed == 1);
    _maintenanceRequire(await allMatch(plan, current, after: !undo));
    _maintenanceRequire(current());
  }
}
