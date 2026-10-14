@Tags(['db-migration'])
library;

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/llm_request_capture_repo.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';

AppDatabase _memoryDb() => AppDatabase.forTesting(NativeDatabase.memory());

Directory _fixtureDirectory(String prefix) {
  final localAppData = Platform.environment['LOCALAPPDATA'];
  final base = Platform.isWindows && localAppData != null
      ? Directory('$localAppData/Temp/opencode')
      : Directory.systemTemp;
  return base.createTempSync(prefix);
}

Future<Map<String, String>> _integrityEntities(AppDatabase db) async => {
  for (final row
      in await db
          .customSelect(
            "SELECT name, sql FROM sqlite_master WHERE type IN ('index', 'trigger') AND sql IS NOT NULL ORDER BY name",
          )
          .get())
    row.read<String>('name'): row.read<String>('sql'),
};

Future<void> _insertCapture(AppDatabase db, int id) => db.customStatement(
  'INSERT INTO llm_request_capture_rows '
  '(id, sequence, created_at_ms, session_id, pipeline_run_id, stage, truncated, event_json) '
  "VALUES (?, ?, 1000, 'session', 'turn', 'main', 0, '{}')",
  [id, id],
);

Future<void> _assertCaptureContract(AppDatabase db) async {
  await _insertCapture(db, 1);
  // Binding may not piggyback any other mutation, including NULL metadata.
  for (final column in db.llmRequestCaptureRows.$columns) {
    if (column.name == 'message_id') continue;
    final changed = switch (column.name) {
      'id' => '99',
      'sequence' => '99',
      'created_at_ms' => '2000',
      'truncated' => '1',
      'stage_ordinal' || 'attempt' => '1',
      _ => "'changed'",
    };
    await expectLater(
      db.customStatement(
        "UPDATE llm_request_capture_rows SET message_id = 'reply', ${column.name} = $changed WHERE id = 1",
      ),
      throwsA(isA<SqliteException>()),
      reason: column.name,
    );
  }
  await expectLater(
    db.customStatement(
      "UPDATE llm_request_capture_rows SET event_json = 'changed' WHERE id = 1",
    ),
    throwsA(isA<SqliteException>()),
  );
  await expectLater(
    db.customStatement(
      'UPDATE llm_request_capture_rows SET message_id = NULL WHERE id = 1',
    ),
    throwsA(isA<SqliteException>()),
  );
  await LlmRequestCaptureRepo(
    db,
  ).bindTurnMessageId(sessionId: 'session', sinceMs: 1000, messageId: 'reply');
  final bound = await db
      .customSelect('SELECT * FROM llm_request_capture_rows WHERE id = 1')
      .getSingle();
  expect(bound.read<String>('message_id'), 'reply');
  expect(bound.read<String>('event_json'), '{}');
  expect(bound.readNullable<String>('call_id'), isNull);
  for (final assignment in [
    "message_id = 'other'",
    'message_id = NULL',
    "message_id = 'reply'",
    "event_json = 'changed'",
  ]) {
    await expectLater(
      db.customStatement(
        'UPDATE llm_request_capture_rows SET $assignment WHERE id = 1',
      ),
      throwsA(isA<SqliteException>()),
    );
  }
  await _insertCapture(db, 2);
  await db.customStatement(
    "UPDATE llm_request_capture_rows SET message_id = 'second-reply' WHERE id = 2",
  );
  await db.customStatement('DELETE FROM llm_request_capture_rows WHERE id = 2');
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'fresh v136 has every declared index and the capture contract',
    () async {
      final db = _memoryDb();
      addTearDown(db.close);
      final entities = await _integrityEntities(db);
      expect(db.schemaVersion, 136);
      expect(db.allTables, hasLength(56));
      expect(
        entities.keys,
        containsAll(
          db.allSchemaEntities.whereType<Index>().map(
            (index) => index.entityName,
          ),
        ),
      );
      await _assertCaptureContract(db);
    },
  );

  for (final version in [88, 89, 92, 135]) {
    test('realistic v$version upgrades to fresh index/trigger parity', () async {
      final dir = _fixtureDirectory('astoria_v136_');
      final file = File('${dir.path}/fixture.db');
      addTearDown(() => dir.delete(recursive: true));
      if (version == 135) {
        final old = AppDatabase.forTesting(NativeDatabase(file));
        await old.customSelect('SELECT 1').get();
        await old.customStatement(
          "INSERT INTO characters (char_id, name) VALUES ('retained', 'Retained')",
        );
        for (final entity in (await _integrityEntities(old)).keys) {
          await old.customStatement('DROP INDEX IF EXISTS "$entity"');
          await old.customStatement('DROP TRIGGER IF EXISTS "$entity"');
        }
        await old.customStatement(
          "CREATE TRIGGER llm_request_capture_rows_no_update BEFORE UPDATE ON llm_request_capture_rows BEGIN SELECT RAISE(ABORT, 'old immutable'); END",
        );
        await old.customStatement('PRAGMA user_version = 135');
        await old.close();
      } else {
        final old = _HistoricalDatabase(NativeDatabase(file), version);
        await old.customSelect('SELECT 1').get();
        await old.close();
      }
      final fresh = _memoryDb();
      final expected = await _integrityEntities(fresh);
      await fresh.close();
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      addTearDown(upgraded.close);
      expect(await _integrityEntities(upgraded), expected);
      expect(
        (await upgraded.customSelect('PRAGMA user_version').getSingle())
            .read<int>('user_version'),
        136,
      );
      expect(
        (await upgraded
                .customSelect(
                  "SELECT name FROM characters WHERE char_id = 'retained'",
                )
                .getSingle())
            .read<String>('name'),
        'Retained',
      );
      expect(
        (await upgraded.customSelect('PRAGMA integrity_check').getSingle())
            .read<String>('integrity_check'),
        'ok',
      );
      if (version == 88) {
        expect(
          await upgraded
              .customSelect('SELECT * FROM lorebook_use_acceptance_records')
              .get(),
          isEmpty,
        );
      }
      if (version == 92) {
        final claim = await upgraded
            .customSelect(
              "SELECT status, input_hash FROM card_evolution_claims WHERE id = 'retained-claim'",
            )
            .getSingle();
        expect(claim.read<String>('status'), 'completed');
        expect(claim.read<String>('input_hash'), 'input');
      }
      await _assertCaptureContract(upgraded);
    });
  }

  test(
    'missing unique index with legacy duplicates fails closed without data loss',
    () async {
      final dir = _fixtureDirectory('astoria_duplicate_');
      final file = File('${dir.path}/fixture.db');
      addTearDown(() => dir.delete(recursive: true));
      final old = AppDatabase.forTesting(NativeDatabase(file));
      await old.customStatement('DROP INDEX idx_card_evolution_claim_input');
      for (final id in ['first', 'second']) {
        await old.customStatement(
          "INSERT INTO card_evolution_claims (id, session_id, character_id, owner_id, status, lease_expires_at, first_run_id, second_run_id, predecessor_cursor_hash, predecessor_run_ordinal, input_hash, created_at) VALUES (?, 'session', 'char', 'owner', 'completed', 0, 'first', 'second', '', 0, 'duplicate', 1)",
          [id],
        );
      }
      await old.customStatement('PRAGMA user_version = 135');
      await old.close();
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      try {
        await expectLater(
          upgraded.customSelect('SELECT 1').get(),
          throwsA(
            isA<SqliteException>().having(
              (e) => e.extendedResultCode,
              'unique constraint',
              2067,
            ),
          ),
        );
      } finally {
        await upgraded.close();
      }
      final raw = sqlite3.open(file.path);
      try {
        expect(raw.select('PRAGMA user_version').single['user_version'], 135);
        expect(
          raw.select('SELECT id FROM card_evolution_claims'),
          hasLength(2),
        );
      } finally {
        raw.close();
      }
    },
  );

  test(
    'unique-index schema errors are not swallowed as duplicate warnings',
    () async {
      final dir = _fixtureDirectory('astoria_invalid_index_');
      final file = File('${dir.path}/fixture.db');
      addTearDown(() => dir.delete(recursive: true));
      final old = AppDatabase.forTesting(NativeDatabase(file));
      await old.customStatement('DROP INDEX idx_card_evolution_claim_input');
      await old.customStatement(
        'ALTER TABLE card_evolution_claims RENAME COLUMN input_hash TO unexpected_hash',
      );
      await old.customStatement('PRAGMA user_version = 135');
      await old.close();
      final upgraded = AppDatabase.forTesting(NativeDatabase(file));
      try {
        await expectLater(
          upgraded.customSelect('SELECT 1').get(),
          throwsA(
            isA<SqliteException>().having(
              (e) => e.message,
              'missing column',
              contains('input_hash'),
            ),
          ),
        );
      } finally {
        await upgraded.close();
      }
    },
  );
}

/// Pre-90/93 fixtures are created without later tables, indexes or triggers,
/// not a current createAll database with only user_version relabelled.
/// Retained pre-89 tables use today's compatible columns except the real
/// historical Studio and acceptance/claim layouts below.
class _HistoricalDatabase extends AppDatabase {
  _HistoricalDatabase(super.e, this.version) : super.forTesting();
  final int version;
  @override
  int get schemaVersion => version;
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) async {
      const introduced = {
        'reconciliation_successful_runs': 90,
        'reconciliation_run_invalidations': 90,
        'ledger_reconciliation_cursors': 90,
        'card_evolution_claims': 92,
        'card_evolution_proposal_runs': 92,
        'session_lorebook_evolution_rows': 93,
        'card_evolution_debug_runs': 94,
        'preset_folders': 103,
        'preset_folder_members': 103,
        'card_evolution_observations': 108,
        'card_evolution_collector_runs': 116,
        'ledger_debug_runs': 120,
        'session_canon_checkpoint_rows': 121,
        'session_lorebook_revision_rows': 121,
        'session_lorebook_embedding_job_rows': 121,
        'llm_request_capture_rows': 124,
        'llm_call_event_rows': 125,
        'ledger_reconciliation_effects': 126,
        'card_evolution_writer_calls': 128,
        'ledger_reconciliation_leases': 130,
      };
      for (final table in allTables) {
        if ((introduced[table.actualTableName] ?? 1) > version) continue;
        if ([
          'studio_config_rows',
          'studio_preset_rows',
          'card_evolution_claims',
        ].contains(table.actualTableName)) {
          continue;
        }
        if (version == 88 &&
            table.actualTableName == 'lorebook_use_acceptance_records') {
          continue;
        }
        await m.createTable(table);
      }
      await customStatement(
        "CREATE TABLE studio_config_rows (session_id TEXT NOT NULL PRIMARY KEY, enabled INTEGER NOT NULL DEFAULT 0, agents_json TEXT NOT NULL DEFAULT '[]', expensive_api_config_id TEXT NOT NULL DEFAULT '', cheap_api_config_id TEXT NOT NULL DEFAULT '', cleaner_api_config_id TEXT NOT NULL DEFAULT '', run_api_config_id TEXT NOT NULL DEFAULT '', final_preset_id TEXT NOT NULL DEFAULT '', run_model_override TEXT NOT NULL DEFAULT '', profile_id TEXT NOT NULL DEFAULT '', profile_name TEXT NOT NULL DEFAULT '', broadcast_blocks_json TEXT NOT NULL DEFAULT '[]', max_final_history_messages INTEGER NOT NULL DEFAULT 30, created_at INTEGER NOT NULL DEFAULT 0, updated_at INTEGER NOT NULL DEFAULT 0)",
      );
      await customStatement(
        "CREATE TABLE studio_preset_rows (preset_id TEXT NOT NULL PRIMARY KEY, name TEXT NOT NULL, blocks_json TEXT NOT NULL DEFAULT '[]', agent_enabled_json TEXT NOT NULL DEFAULT '{}', execution_mode TEXT NOT NULL DEFAULT 'legacy', updated_at INTEGER NOT NULL DEFAULT 0)",
      );
      await customStatement(
        "INSERT INTO studio_preset_rows (preset_id, name) VALUES ('default', 'Default Studio Preset')",
      );
      await customStatement(
        "INSERT INTO characters (char_id, name) VALUES ('retained', 'Retained')",
      );
      if (version >= 92) {
        await customStatement(
          "CREATE TABLE card_evolution_claims (id TEXT NOT NULL PRIMARY KEY, session_id TEXT NOT NULL, character_id TEXT NOT NULL, owner_id TEXT NOT NULL, status TEXT NOT NULL, lease_expires_at INTEGER NOT NULL, first_run_id TEXT NOT NULL, second_run_id TEXT NOT NULL, predecessor_cursor_hash TEXT NOT NULL, predecessor_run_ordinal INTEGER NOT NULL, input_hash TEXT NOT NULL, rewrite_job_id TEXT, created_at INTEGER NOT NULL, completed_at INTEGER)",
        );
        await customStatement(
          "INSERT INTO card_evolution_claims VALUES ('retained-claim', 'session', 'retained', 'owner', 'completed', 0, 'first', 'second', '', 0, 'input', NULL, 1, 2)",
        );
      }
      if (version == 88) {
        await customStatement(
          "CREATE TABLE lorebook_use_acceptance_records (acceptance_id TEXT NOT NULL PRIMARY KEY, session_id TEXT NOT NULL, message_id TEXT NOT NULL, swipe_id INTEGER NOT NULL, agent_swipe_id INTEGER NOT NULL, acceptance_kind TEXT NOT NULL, selected_lorebook_id TEXT, selected_entry_id TEXT, selected_entry_order INTEGER, evidence_json TEXT NOT NULL DEFAULT '{}', accepted_at INTEGER NOT NULL)",
        );
        await customStatement(
          "INSERT INTO lorebook_use_acceptance_records (acceptance_id, session_id, message_id, swipe_id, agent_swipe_id, acceptance_kind, accepted_at) VALUES ('provisional', 'session', 'reply', 0, 0, 'generation', 1)",
        );
        await customStatement(
          "CREATE TRIGGER lorebook_use_acceptance_records_no_update BEFORE UPDATE ON lorebook_use_acceptance_records BEGIN SELECT RAISE(ABORT, 'legacy immutable'); END",
        );
      }
    },
  );
}
