part of '../database_snapshot_service.dart';

final class _SnapshotSchema {
  const _SnapshotSchema(
    this.applicationId,
    this.userVersion,
    this.schemaVersion,
    this.pageSize,
    this.pageCount,
    this.entities,
    this.counts,
  );
  final int applicationId;
  final int userVersion;
  final int schemaVersion;
  final int pageSize;
  final int pageCount;
  final List<List<Object?>> entities;
  final Map<String, int> counts;
}

/// Fixed native metadata queries only; never application/model hydration.
abstract final class _SnapshotSqlite {
  /// The package stream doesn't finish its native backup in a cancellation
  /// finally block (sqlite3 3.3.2). Use its existing bindings to guarantee finish.
  static Future<void> backup(
    Database source,
    Database copy,
    _SnapshotFiles files,
    _SnapshotGuard guard,
  ) async {
    final memory = files.api.allocate(5).cast<Uint8>();
    memory.asTypedList(5).setAll(0, [109, 97, 105, 110, 0]);
    final name = memory.cast<nsql.sqlite3_char>();
    Pointer<nsql.sqlite3_backup> backup = nullptr;
    try {
      guard.check();
      backup = nsql.sqlite3_backup_init(
        copy.handle.cast(),
        name,
        source.handle.cast(),
        name,
      );
      if (backup == nullptr) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
      for (var step = 0; step < _SnapshotLimits.maxBackupSteps; step++) {
        guard.check();
        files.check();
        final rc = nsql.sqlite3_backup_step(backup, _SnapshotLimits.stepPages);
        guard.check();
        if (nsql.sqlite3_backup_pagecount(backup) > _SnapshotLimits.maxPages) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
        }
        if (rc != 0 && rc != 101) {
          throw _SnapshotFailure(
            rc == 5 || rc == 6
                ? DatabaseSnapshotStatus.unknown
                : DatabaseSnapshotStatus.invalid,
          );
        }
        await guard.boundary(DatabaseSnapshotBoundary.backupPage);
        guard.check();
        files.check();
        if (rc == 101) {
          final finished = nsql.sqlite3_backup_finish(backup);
          backup = nullptr;
          if (finished != 0) {
            throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
          }
          return;
        }
        await Future<void>.delayed(Duration.zero);
        guard.check();
      }
      throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
    } finally {
      if (backup != nullptr) nsql.sqlite3_backup_finish(backup);
      files.api.free(memory.cast());
    }
  }

  static void configure(
    Database db,
    _SnapshotGuard guard, {
    bool readOnly = true,
  }) {
    db.execute('PRAGMA busy_timeout = 0');
    db.execute('PRAGMA trusted_schema = OFF');
    db.execute('PRAGMA temp_store = MEMORY');
    if (readOnly) {
      db.execute('PRAGMA query_only = ON');
    }
    if (!readOnly) {
      db.execute('PRAGMA journal_mode = MEMORY');
    }
  }

  static int scalar(Database db, String sql, _SnapshotGuard guard) {
    guard.check();
    final result = db.select(sql);
    guard.check();
    if (result.length != 1 ||
        result.first.values.length != 1 ||
        result.first.values.first is! int) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
    }
    return result.first.values.first as int;
  }

  static _SnapshotSchema inspect(
    Database db,
    Set<String> registered,
    _SnapshotGuard guard,
  ) {
    final pages = scalar(db, 'PRAGMA page_count', guard);
    final size = scalar(db, 'PRAGMA page_size', guard);
    if (pages <= 0 || size < 512 || size > 65536 || (size & (size - 1)) != 0) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
    if (pages > _SnapshotLimits.maxPages ||
        pages * size > _SnapshotLimits.maxBytes) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
    }
    final entityCount = scalar(
      db,
      'SELECT count(*) FROM main.sqlite_schema',
      guard,
    );
    final schemaBytes = scalar(
      db,
      'SELECT coalesce(sum('
      'length(CAST(name AS BLOB)) + length(CAST(tbl_name AS BLOB)) + '
      'coalesce(length(CAST(sql AS BLOB)),0)),0) FROM main.sqlite_schema',
      guard,
    );
    if (entityCount > _SnapshotLimits.maxEntities ||
        schemaBytes > _SnapshotLimits.maxSchemaBytes ||
        registered.isEmpty ||
        registered.length > _SnapshotLimits.maxTables) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
    }
    final entities = <List<Object?>>[];
    final schema = db.prepare(
      'SELECT type,name,tbl_name,rootpage,sql '
      'FROM main.sqlite_schema ORDER BY type,name LIMIT '
      '${_SnapshotLimits.maxEntities + 1}',
    );
    try {
      final cursor = schema.iterateWith(const StatementParameters.empty());
      while (cursor.moveNext()) {
        guard.check();
        entities.add(List<Object?>.of(cursor.current.values));
      }
    } finally {
      schema.close();
    }
    guard.check();
    if (entities.length != entityCount) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
    }
    final tables = db.select(
      "SELECT name,type FROM pragma_table_list "
      "WHERE schema = 'main' ORDER BY name LIMIT ${_SnapshotLimits.maxTables + 1}",
    );
    guard.check();
    if (tables.length > _SnapshotLimits.maxTables) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
    }
    // Virtual modules can read files or execute arbitrary extension code.
    // A byte copy is possible, but native count/verification is not proven.
    if (tables.any(
      (row) => row['type'] == 'virtual' || row['type'] == 'shadow',
    )) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
    }
    final counts = <String, int>{};
    var totalRows = 0;
    for (final row in tables) {
      if (row['type'] != 'table') continue;
      final name = row['name'];
      if (name is! String ||
          utf8.encode(name).length > _SnapshotLimits.maxIdentifierBytes) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
      }
      // Names originate exclusively in the pinned source schema, not a caller.
      final quoted = '"${name.replaceAll('"', '""')}"';
      final n = scalar(db, 'SELECT count(*) FROM main.$quoted', guard);
      totalRows += n;
      if (n < 0 || totalRows > _SnapshotLimits.maxRows) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
      }
      counts[name] = n;
    }
    if (!registered.every(counts.containsKey)) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
    return _SnapshotSchema(
      scalar(db, 'PRAGMA application_id', guard),
      scalar(db, 'PRAGMA user_version', guard),
      scalar(db, 'PRAGMA schema_version', guard),
      size,
      pages,
      List.unmodifiable(entities),
      Map.unmodifiable(counts),
    );
  }

  static void verify(
    Database db,
    _SnapshotSchema expected,
    Set<String> registered,
    _SnapshotGuard guard,
  ) {
    checkIntegrityRows(
      db,
      'PRAGMA quick_check(${_SnapshotLimits.maxIssues + 1})',
      guard,
    );
    checkIntegrityRows(
      db,
      'PRAGMA integrity_check(${_SnapshotLimits.maxIssues + 1})',
      guard,
    );
    final actual = inspect(db, registered, guard);
    if (actual.applicationId != expected.applicationId ||
        actual.userVersion != expected.userVersion ||
        actual.pageSize != expected.pageSize ||
        actual.pageCount != expected.pageCount ||
        actual.entities.length != expected.entities.length ||
        actual.counts.length != expected.counts.length) {
      throw _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
    // SQLite online backup deliberately changes the destination schema cookie
    // to invalidate prepared statements. It is not the application/schema
    // identity: compare application/user versions and every exact schema row.
    for (var i = 0; i < actual.entities.length; i++) {
      for (var j = 0; j < actual.entities[i].length; j++) {
        if (actual.entities[i][j] != expected.entities[i][j]) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
        }
      }
    }
    for (final entry in expected.counts.entries) {
      if (actual.counts[entry.key] != entry.value) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
    }
  }

  static void checkIntegrityRows(
    Database db,
    String sql,
    _SnapshotGuard guard,
  ) {
    guard.check();
    final statement = db.prepare(sql);
    var rows = 0;
    var allOk = true;
    try {
      final cursor = statement.iterateWith(const StatementParameters.empty());
      while (cursor.moveNext()) {
        guard.check();
        if (++rows > _SnapshotLimits.maxIssues) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
        }
        allOk &=
            cursor.current.values.length == 1 &&
            cursor.current.values.first == 'ok';
      }
    } finally {
      statement.close();
    }
    guard.check();
    if (rows != 1 || !allOk) {
      throw _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
  }
}
