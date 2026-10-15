@Tags(['db-migration'])
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

const _supportTables = {
  'support_sessions',
  'support_messages',
  'support_context_blocks',
  'support_mutation_journal',
  'support_reports',
};

const _supportIndexes = {
  'idx_support_sessions_updated_at': ['pinned', 'updated_at'],
  'idx_support_messages_session_id': ['session_id'],
  'idx_support_messages_session_created_at': ['session_id', 'created_at'],
  'idx_support_context_blocks_session_id': ['session_id'],
  'idx_support_context_blocks_session_active': ['session_id', 'is_active'],
  'idx_support_mutation_journal_session_id': ['session_id'],
  'idx_support_mutation_journal_session_created_at': [
    'session_id',
    'created_at',
  ],
  'idx_support_reports_session_id': ['session_id'],
};

Directory _fixtureDirectory() {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final base = Platform.isWindows && localAppData != null
      ? Directory('$localAppData/Temp/opencode')
      : Directory.systemTemp;
  return base.createTempSync('astoria_support_v136_');
}

Future<Map<String, String>> _supportSchema(AppDatabase db) async => {
  for (final row
      in await db
          .customSelect(
            "SELECT name, sql FROM sqlite_master WHERE type IN ('table', 'index') "
            "AND tbl_name GLOB 'support_*' AND sql IS NOT NULL ORDER BY name",
          )
          .get())
    row.read<String>('name'): row.read<String>('sql'),
};

Future<List<Map<String, Object?>>> _rows(AppDatabase db, String table) async =>
    [
      for (final row in await db.customSelect('SELECT * FROM "$table"').get())
        row.data,
    ];

Future<Map<String, List<Map<String, Object?>>>> _roleplayRows(
  AppDatabase db,
) async => {
  for (final table in ['characters', 'presets']) table: await _rows(db, table),
};

Future<void> _seedRoleplay(AppDatabase db) async {
  await db.customStatement(
    "INSERT INTO characters (char_id, name, description) "
    "VALUES ('retained-character', 'Synthetic character', 'Unchanged card')",
  );
  await db.customStatement(
    'INSERT INTO presets (preset_id, name, data_json) VALUES (?, ?, ?)',
    ['retained-preset', 'Synthetic preset', '{"synthetic":"unchanged"}'],
  );
}

Future<void> _assertCurrentSchema(
  AppDatabase db,
  Map<String, String> expected,
) async {
  expect(db.schemaVersion, 137);
  expect(db.allTables, hasLength(61));
  expect(
    (await db.customSelect('PRAGMA user_version').getSingle()).read<int>(
      'user_version',
    ),
    137,
  );
  final tables = await db
      .customSelect("SELECT name FROM sqlite_master WHERE type = 'table'")
      .get();
  expect(
    tables
        .map((row) => row.read<String>('name'))
        .where(_supportTables.contains),
    unorderedEquals(_supportTables),
  );
  expect(await _supportSchema(db), expected);
  final declared = db.allSchemaEntities.whereType<Index>().where(
    (index) => index.entityName.startsWith('idx_support_'),
  );
  expect(
    declared.map((index) => index.entityName),
    unorderedEquals(_supportIndexes.keys),
  );
  for (final entry in _supportIndexes.entries) {
    final columns = await db
        .customSelect('PRAGMA index_info("${entry.key}")')
        .get();
    expect(
      columns.map((row) => row.read<String>('name')),
      orderedEquals(entry.value),
      reason: entry.key,
    );
  }
  expect(
    (await db.customSelect('PRAGMA integrity_check').getSingle()).read<String>(
      'integrity_check',
    ),
    'ok',
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'fresh v137 support schema has eight exact indexes and no backup entry',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final schema = await _supportSchema(db);
      expect(
        schema.keys,
        unorderedEquals([..._supportTables, ..._supportIndexes.keys]),
      );
      await _assertCurrentSchema(db, schema);
      expect(BackupExporter.tableNames, containsAll(['characters', 'presets']));
      expect(
        BackupExporter.tableNames.where(
          (table) => table.startsWith('support_'),
        ),
        isEmpty,
      );
    },
  );

  test(
    'synthetic v136 without support tables upgrades without roleplay loss',
    () async {
      final dir = _fixtureDirectory();
      final file = File('${dir.path}/fixture.db');
      addTearDown(() => dir.delete(recursive: true));
      final old = AppDatabase.forTesting(NativeDatabase(file));
      late Map<String, String> expected;
      late Map<String, List<Map<String, Object?>>> retained;
      try {
        await _seedRoleplay(old);
        retained = await _roleplayRows(old);
        expected = await _supportSchema(old);
        // v137 only adds this domain. Dropping its five tables also drops their
        // indexes; all v136 roleplay tables, rows and integrity entities remain.
        for (final table in _supportTables) {
          await old.customStatement('DROP TABLE "$table"');
        }
        expect(await _supportSchema(old), isEmpty);
        await old.customStatement('PRAGMA user_version = 136');
      } finally {
        await old.close();
      }
      final raw = sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 136);
        expect(
          raw.select(
            "SELECT name FROM sqlite_master WHERE type = 'table' "
            "AND name NOT GLOB 'sqlite_*'",
          ),
          hasLength(56),
        );
      } finally {
        raw.close();
      }
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(upgraded.close);
      await _assertCurrentSchema(upgraded, expected);
      expect(await _roleplayRows(upgraded), retained);
      for (final table in _supportTables) {
        expect(await _rows(upgraded, table), isEmpty, reason: table);
      }
    },
  );

  test(
    'partial v136 support schema retains opaque ciphertext and repairs indexes',
    () async {
      final dir = _fixtureDirectory();
      final file = File('${dir.path}/fixture.db');
      addTearDown(() => dir.delete(recursive: true));
      final old = AppDatabase.forTesting(NativeDatabase(file));
      late Map<String, String> expected;
      late Map<String, List<Map<String, Object?>>> retained;
      final ciphertextRows = <String, List<Map<String, Object?>>>{};
      try {
        await _seedRoleplay(old);
        retained = await _roleplayRows(old);
        expected = await _supportSchema(old);
        // Opaque synthetic strings test byte-for-byte storage preservation, not
        // vault access, encryption correctness or successful decryption.
        await old.customStatement(
          'INSERT INTO support_sessions (id, title_ciphertext) VALUES (?, ?)',
          ['support-session', 'synthetic-ciphertext:title'],
        );
        await old.customStatement(
          'INSERT INTO support_messages '
          '(id, session_id, role, body_ciphertext, cards_ciphertext) '
          'VALUES (?, ?, ?, ?, ?)',
          [
            'message',
            'support-session',
            'assistant',
            'synthetic-ciphertext:body',
            'synthetic-ciphertext:cards',
          ],
        );
        await old.customStatement(
          'INSERT INTO support_context_blocks '
          '(id, session_id, start_message_id, end_message_id, '
          'summary_ciphertext, protected_facts_ciphertext) VALUES (?, ?, ?, ?, ?, ?)',
          [
            'context',
            'support-session',
            'message',
            'message',
            'synthetic-ciphertext:summary',
            'synthetic-ciphertext:facts',
          ],
        );
        for (final table in _supportTables.take(3)) {
          ciphertextRows[table] = await _rows(old, table);
        }
        for (final index in _supportIndexes.keys) {
          await old.customStatement('DROP INDEX "$index"');
        }
        for (final table in ['support_mutation_journal', 'support_reports']) {
          await old.customStatement('DROP TABLE "$table"');
        }
        expect(
          (await _supportSchema(old)).keys,
          unorderedEquals(ciphertextRows.keys),
        );
        await old.customStatement('PRAGMA user_version = 136');
      } finally {
        await old.close();
      }
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(upgraded.close);
      await _assertCurrentSchema(upgraded, expected);
      expect(await _roleplayRows(upgraded), retained);
      for (final entry in ciphertextRows.entries) {
        expect(
          await _rows(upgraded, entry.key),
          entry.value,
          reason: entry.key,
        );
      }
      for (final table in ['support_mutation_journal', 'support_reports']) {
        expect(await _rows(upgraded, table), isEmpty, reason: table);
      }
    },
  );
}
