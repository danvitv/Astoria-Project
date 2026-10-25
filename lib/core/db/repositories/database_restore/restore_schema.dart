part of '../database_restore_repo.dart';

/// Actual compiled registration/migration output in PRIVATE memory. No default
/// constructor, path service, installed DB, schema list or invented app ID.
final class _RestoreSchema {
  _RestoreSchema(
    this.version,
    this.applicationId,
    this.tables,
    this.objects,
    this.columns,
    this.foreignKeys,
    this.indexes,
    this.indexColumns,
  );
  final int version;
  final int applicationId;
  final Set<String> tables;
  final Map<String, List<Object?>> objects;
  final Map<String, List<List<Object?>>> columns;
  final Map<String, List<List<Object?>>> foreignKeys;
  final Map<String, List<List<Object?>>> indexes;
  final Map<String, List<List<Object?>>> indexColumns;

  static Future<_RestoreSchema> compiled(_RestoreWork work) async {
    final memory = sqlite3.openInMemory();
    final wrapper = AppDatabase.forTesting(
      NativeDatabase.opened(memory, closeUnderlyingOnClose: false),
    );
    final resource = _RestoreSchemaMemory(memory, wrapper);
    work._schemaMemory.add(resource);
    try {
      // Real compiled createAll + current integrity triggers/indexes. onCreate
      // is memory-only; no historical upgrades or shared preferences run.
      await work.run(ChatRepo(wrapper).countByCharacterId(''));
      final tables = wrapper.allTables.map((t) => t.actualTableName).toSet();
      if (tables.isEmpty || tables.length > _RestoreLimits.maxTables)
        _refuse(DatabaseRestoreCode.unsupported);
      final objects = _schemaObjects(memory);
      return _RestoreSchema(
        wrapper.schemaVersion,
        _scalar(memory, 'PRAGMA main.application_id'),
        tables,
        objects,
        {
          for (final name in tables)
            name: _metadata(memory, 'table_xinfo', name),
        },
        {
          for (final name in tables)
            name: _metadata(memory, 'foreign_key_list', name),
        },
        {
          for (final name in tables)
            name: _metadata(memory, 'index_list', name),
        },
        {
          for (final row in objects.values.where((r) => r[0] == 'index'))
            row[1] as String: _metadata(
              memory,
              'index_xinfo',
              row[1] as String,
            ),
        },
      );
    } catch (error, stack) {
      work.remember(error, stack);
      rethrow;
    } finally {
      // Never close a database under an unsettled original Drift future.
      if (work.pending == 0) {
        await work.run(resource.close());
        work._schemaMemory.remove(resource);
      }
    }
  }

  void validate(Database db) {
    _requireBounds(db);
    if (_scalar(db, 'PRAGMA main.user_version') != version ||
        _scalar(db, 'PRAGMA main.application_id') != applicationId) {
      _refuse(DatabaseRestoreCode.invalidCandidate);
    }
    final actual = _schemaObjects(db);
    final actualTables = _ordinaryTables(db);
    if (!tables.every(actualTables.contains))
      _refuse(DatabaseRestoreCode.invalidCandidate);
    for (final entry in objects.entries) {
      final expected = entry.value;
      // SQLite internal objects are checked by whole digest/integrity. Their
      // names/root pages may depend on data (e.g. sqlite_sequence).
      if ((expected[1] as String).startsWith('sqlite_')) continue;
      final observed = actual[entry.key];
      if (observed == null ||
          observed[0] != expected[0] ||
          observed[2] != expected[2] ||
          _sqlTokens(observed[4] as String?) !=
              _sqlTokens(expected[4] as String?)) {
        _refuse(DatabaseRestoreCode.invalidCandidate);
      }
    }
    for (final name in tables) {
      if (!_rowsEqual(columns[name]!, _metadata(db, 'table_xinfo', name)) ||
          !_rowsEqual(
            foreignKeys[name]!,
            _metadata(db, 'foreign_key_list', name),
          ))
        _refuse(DatabaseRestoreCode.invalidCandidate);
      final observed = _metadata(db, 'index_list', name);
      for (final expected in indexes[name]!) {
        // sequence is incidental; compare name/unique/origin/partial semantics.
        if (!observed.any(
          (row) => _typedRow(row.skip(1)) == _typedRow(expected.skip(1)),
        )) {
          _refuse(DatabaseRestoreCode.invalidCandidate);
        }
      }
    }
    for (final index in indexColumns.entries) {
      if (!_rowsEqual(index.value, _metadata(db, 'index_xinfo', index.key)))
        _refuse(DatabaseRestoreCode.invalidCandidate);
    }
    for (final entry in actual.entries) {
      if (objects.containsKey(entry.key) ||
          (entry.value[1] as String).startsWith('sqlite_'))
        continue;
      final row = entry.value;
      final type = row[0];
      final table = row[2] as String;
      final sql = _sqlTokens(row[4] as String?);
      // Extra ordinary tables, column indexes, simple views and inert triggers
      // are preserved. Unknown code on owning tables is never accepted.
      if (type == 'table') {
        if (!_safeExtraTable(sql)) _refuse(DatabaseRestoreCode.unsupported);
      } else if (type == 'index') {
        if (tables.contains(table) ||
            sql.contains('(') &&
                RegExp(
                  r'\b[a-z_]+ \(',
                ).hasMatch(sql.substring(sql.indexOf('(') + 1))) {
          _refuse(DatabaseRestoreCode.unsupported);
        }
      } else if (type == 'view') {
        if (sql.contains('(') ||
            sql.contains(';') ||
            !sql.contains(' as select '))
          _refuse(DatabaseRestoreCode.unsupported);
      } else if (type == 'trigger') {
        if (tables.contains(table) || !sql.endsWith('begin select 1 ; end'))
          _refuse(DatabaseRestoreCode.unsupported);
      } else {
        _refuse(DatabaseRestoreCode.unsupported);
      }
    }
    _integrity(db);
    final fk = db.prepare('PRAGMA main.foreign_key_check');
    try {
      if (fk.iterateWith(const StatementParameters.empty()).moveNext())
        _refuse(DatabaseRestoreCode.invalidCandidate);
    } finally {
      fk.close();
    }
  }
}

/// Explicit keepalive if an original metadata executor future times out. Raw
/// memory is never released under wrapper work; failed close cannot be revived.
final class _RestoreSchemaMemory {
  _RestoreSchemaMemory(this.raw, this.wrapper);
  final Database raw;
  final AppDatabase wrapper;
  Future<void>? _closing;
  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await wrapper.close();
    raw.close();
  }
}

String _quote(String identifier) => '"${identifier.replaceAll('"', '""')}"';
int _scalar(Database db, String sql) {
  final rows = db.select(sql);
  if (rows.length != 1 ||
      rows.single.values.length != 1 ||
      rows.single.values.single is! int)
    _refuse(DatabaseRestoreCode.unsupported);
  return rows.single.values.single as int;
}

void _requireBounds(Database db) {
  final pages = _scalar(db, 'PRAGMA main.page_count');
  final size = _scalar(db, 'PRAGMA main.page_size');
  if (pages <= 0 || size < 512 || size > 65536 || (size & (size - 1)) != 0)
    _refuse(DatabaseRestoreCode.unsupported);
  if (pages > _RestoreLimits.maxPages || pages * size > _RestoreLimits.maxBytes)
    _refuse(DatabaseRestoreCode.tooLarge);
  if (_scalar(db, 'SELECT count(*) FROM main.sqlite_schema') >
          _RestoreLimits.maxEntities ||
      _scalar(
            db,
            'SELECT coalesce(sum(length(CAST(name AS BLOB)) + length(CAST(tbl_name AS BLOB)) + coalesce(length(CAST(sql AS BLOB)),0)),0) FROM main.sqlite_schema',
          ) >
          _RestoreLimits.maxSchemaBytes) {
    _refuse(DatabaseRestoreCode.tooLarge);
  }
}

List<String> _ordinaryTables(Database db) {
  final rows = db.select(
    "SELECT name,type FROM pragma_table_list WHERE schema='main' ORDER BY name LIMIT ${_RestoreLimits.maxTables + 1}",
  );
  if (rows.length > _RestoreLimits.maxTables ||
      rows.any((r) => r['type'] != 'table' && r['type'] != 'view'))
    _refuse(DatabaseRestoreCode.unsupported);
  return rows
      .where((r) => r['type'] == 'table')
      .map((r) => r['name'] as String)
      .toList();
}

Map<String, List<Object?>> _schemaObjects(Database db) {
  _requireBounds(db);
  final rows = db.select(
    'SELECT type,name,tbl_name,rootpage,sql FROM main.sqlite_schema ORDER BY type,name LIMIT ${_RestoreLimits.maxEntities + 1}',
  );
  if (rows.length > _RestoreLimits.maxEntities)
    _refuse(DatabaseRestoreCode.tooLarge);
  return {
    for (final row in rows)
      '${row['type']}\u0000${row['name']}': List<Object?>.of(row.values),
  };
}

List<List<Object?>> _metadata(Database db, String pragma, String name) {
  final rows = db.select('PRAGMA main.$pragma(${_quote(name)})');
  if (rows.length > _RestoreLimits.maxColumns)
    _refuse(DatabaseRestoreCode.tooLarge);
  return rows.map((row) => List<Object?>.of(row.values)).toList();
}

bool _rowsEqual(List<List<Object?>> a, List<List<Object?>> b) =>
    a.length == b.length &&
    Iterable<int>.generate(
      a.length,
    ).every((i) => _typedRow(a[i]) == _typedRow(b[i]));

/// Strict token-equivalent compiled layout, not a whitespace-stripped body.
/// Literal contents/defaults/constraints remain exact; alternative layouts are
/// unsupported rather than inferred equivalent by a home-grown SQL interpreter.
String _sqlTokens(String? sql) {
  if (sql == null) return '';
  final lexer = RegExp(
    r'''\s+|--[^\n]*|/\*[\s\S]*?\*/|'(?:''|[^'])*'|"(?:""|[^"])*"|`(?:``|[^`])*`|\[[^\]]*\]|[A-Za-z_][A-Za-z_0-9]*|[0-9]+(?:\.[0-9]+)?|<>|!=|<=|>=|\|\||[^\s]''',
  );
  final tokens = <String>[];
  for (final match in lexer.allMatches(sql)) {
    final token = match.group(0)!;
    if (token.trim().isEmpty ||
        token.startsWith('--') ||
        token.startsWith('/*'))
      continue;
    if (token.startsWith("'")) {
      tokens.add(token);
    } else if (token.startsWith('"') ||
        token.startsWith('`') ||
        token.startsWith('[')) {
      // Quotes are semantically significant (notably SQLite DQS). Never turn
      // a quoted keyword/expression into unquoted grammar by normalization.
      tokens.add(token);
    } else {
      tokens.add(token.toLowerCase());
    }
  }
  return tokens
      .join(' ')
      .replaceFirst('create table if not exists ', 'create table ')
      .replaceFirst('create trigger if not exists ', 'create trigger ')
      .replaceFirst('create index if not exists ', 'create index ')
      .replaceFirst(
        'create unique index if not exists ',
        'create unique index ',
      );
}

bool _safeExtraTable(String sql) {
  // Narrow ordinary extension tables: no generated columns, expressions,
  // functions, virtual modules, foreign code or expensive CHECK evaluation.
  final match = RegExp(
    r'^create table [a-z_][a-z_0-9]* \( (.*) \)$',
  ).firstMatch(sql);
  if (match == null) return false;
  final columns = match.group(1)!.split(' , ');
  if (columns.isEmpty || columns.length > _RestoreLimits.maxColumns)
    return false;
  final column = RegExp(
    r'^[a-z_][a-z_0-9]* (integer|int|text|blob|real|double|float|boolean|bool)(?: not null)?(?: primary key)?$',
  );
  return columns.every(column.hasMatch);
}

void _integrity(Database db) {
  final rows = db.select('PRAGMA main.integrity_check(2)');
  if (rows.length != 1 || rows.single.values.single != 'ok')
    _refuse(DatabaseRestoreCode.invalidCandidate);
}
