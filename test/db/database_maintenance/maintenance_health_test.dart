import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/models/database_maintenance.dart';

import 'maintenance_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  maintenanceTest(
    'whole registration coverage with no private payload hydration',
    (f) async {
      await f.db.customStatement(
        'INSERT INTO api_configs '
        '(config_id, name, api_key, extra_request_parameters_json) VALUES (?, ?, ?, ?)',
        [
          'synthetic-api',
          MaintenanceFixture.canary,
          MaintenanceFixture.canary,
          '[{"private":"${MaintenanceFixture.canary}"}]',
        ],
      );
      final before = await f.snapshot();
      f.events.clear();
      final reads = f.storage.reads;
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(f.storage.reads, reads);
      expect(
        f.events.where(
          (e) =>
              e.startsWith('decrypt:') ||
              e.startsWith('decrypt-before:') ||
              e.startsWith('encrypt:'),
        ),
        isEmpty,
      );
      final names = f.db.allTables.map((t) => t.actualTableName).toSet();
      expect(report.registeredTables, names.length);
      expect(report.tables.map((t) => t.table).toSet(), names);
      expect(report.expectedVersion, f.db.schemaVersion);
      expect(report.actualVersion, f.db.schemaVersion);
      expect(report.physical, DatabaseMaintenanceCheck.checked);
      expect(
        f.events
            .where(
              (e) =>
                  e.startsWith('select:') &&
                  e.contains('FROM pragma_quick_check LIMIT 17'),
            )
            .length,
        1,
      );
      final output = jsonEncode(report.toJson());
      expect(output, isNot(contains(MaintenanceFixture.canary)));
      expect(output, isNot(contains('SYNTHETIC_RECOVERED_OWNER')));
      expect(output, isNot(contains('CREATE TABLE')));
      expect(report.toString(), isNot(contains(MaintenanceFixture.canary)));
      expect(utf8.encode(output).length, lessThanOrEqualTo(32768));
      expect(report.issues.length, lessThanOrEqualTo(64));
      expect(report.toJson()['semanticValidation'], 'not_checked');
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'physical table-valued checks accept schema not the native PRAGMA error budget',
    (f) async {
      for (final mode in DatabaseMaintenancePhysicalCheck.values) {
        final pragma = mode == DatabaseMaintenancePhysicalCheck.quick
            ? 'quick_check'
            : 'integrity_check';
        final report = await f.repo.inspect(
          isCurrent: f.isCurrent,
          physical: mode,
        );
        expect(report.physical, DatabaseMaintenanceCheck.checked);
        expect(report.physicalKind, mode);
        // Table-valued PRAGMAs expose hidden inputs (including schema), not
        // the native statement's numeric error-budget calling convention.
        final hidden = await f.db.executor.runSelect(
          'SELECT name FROM pragma_table_xinfo(?) WHERE hidden != 0',
          ['pragma_$pragma'],
        );
        expect(hidden.map((row) => row['name']), contains('schema'));
        var rejectedBudgetArgument = false;
        try {
          await f.db.executor.runSelect(
            'SELECT count(*) AS n FROM pragma_$pragma(16)',
            const [],
          );
        } catch (_) {
          // Never surface native diagnostic text or SQL causes in assertions.
          rejectedBudgetArgument = true;
        }
        expect(rejectedBudgetArgument, isTrue);
      }
    },
  );

  maintenanceTest(
    'native physical check failures stay fixed-code and capped inside SQLite',
    (f) async {
      Future<void> addConstraintViolation(int i) async {
        // Damage only synthetic production-memory rows. Disable CHECK while
        // seeding, then re-enable it BEFORE the actual physical PRAGMA reads.
        await f.db.customStatement('PRAGMA ignore_check_constraints = ON');
        try {
          await f.db.customStatement(
            'INSERT INTO card_evolution_debug_runs '
            '(session_id, stage, status, model, output, attempts_json, updated_at) '
            'VALUES (?, ?, ?, ?, ?, ?, ?)',
            [
              'synthetic-physical-$i',
              'synthetic-invalid-stage',
              'synthetic',
              MaintenanceFixture.canary,
              MaintenanceFixture.canary,
              '[]',
              0,
            ],
          );
        } finally {
          await f.db.customStatement('PRAGMA ignore_check_constraints = OFF');
        }
      }

      await addConstraintViolation(0);
      for (final mode in DatabaseMaintenancePhysicalCheck.values) {
        final report = await f.repo.inspect(
          isCurrent: f.isCurrent,
          physical: mode,
        );
        expect(report.physical, DatabaseMaintenanceCheck.issues);
        expect(
          report.issues.any(
            (i) => i.code == DatabaseMaintenanceIssueCode.physicalFailure,
          ),
          isTrue,
        );
        final output = jsonEncode(report.toJson());
        expect(output, isNot(contains(MaintenanceFixture.canary)));
        expect(output, isNot(contains('CHECK constraint failed')));
        expect(output, isNot(contains('synthetic-physical-')));
      }
      for (var i = 1; i < 40; i++) {
        await addConstraintViolation(i);
      }
      final capped = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(capped.physical, DatabaseMaintenanceCheck.truncated);
      expect(capped.truncated, isTrue);
      expect(
        capped.issues
            .singleWhere(
              (i) => i.code == DatabaseMaintenanceIssueCode.physicalFailure,
            )
            .count,
        16,
      );
      final output = jsonEncode(capped.toJson());
      expect(utf8.encode(output).length, lessThanOrEqualTo(32768));
      expect(output, isNot(contains(MaintenanceFixture.canary)));
      expect(output, isNot(contains('CHECK constraint failed')));
    },
  );

  maintenanceTest(
    'malformed JSON/root/scalar rows are fixed-code issues, not healthy defaults',
    (f) async {
      await f.db.customStatement(
        'INSERT INTO chat_sessions '
        '(session_id, character_id, session_index, messages_json, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          'synthetic-chat',
          'legacy',
          0,
          '{${MaintenanceFixture.canary}',
          'SYNTHETIC_BAD_TIME',
        ],
      );
      await f.db.customStatement(
        'INSERT INTO memory_book_rows '
        '(session_id, entries_json) VALUES (?, ?)',
        ['synthetic-chat', '{}'],
      );
      final before = await f.snapshot();
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(
        report.issues.any(
          (i) =>
              i.code == DatabaseMaintenanceIssueCode.malformedJson &&
              i.table == 'chat_sessions',
        ),
        isTrue,
      );
      expect(
        report.issues.any(
          (i) =>
              i.code == DatabaseMaintenanceIssueCode.scalarType &&
              i.table == 'chat_sessions',
        ),
        isTrue,
      );
      expect(
        report.issues.any(
          (i) =>
              i.code == DatabaseMaintenanceIssueCode.jsonRootShape &&
              i.table == 'memory_book_rows',
        ),
        isTrue,
      );
      expect(
        report.tables.singleWhere((t) => t.table == 'chat_sessions').json,
        DatabaseMaintenanceCheck.issues,
      );
      expect(
        jsonEncode(report.toJson()),
        isNot(contains(MaintenanceFixture.canary)),
      );
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'oversized/skipped JSON and row sampling explicitly retain uncertainty',
    (f) async {
      await f.db.customStatement(
        'INSERT INTO memory_book_rows '
        '(session_id, entries_json) VALUES (?, ?)',
        ['synthetic-too-large', List.filled(65537, 'x').join()],
      );
      final report = await f.repo.inspect(
        isCurrent: f.isCurrent,
        rowsPerTable: 1,
      );
      final characters = report.tables.singleWhere(
        (t) => t.table == 'characters',
      );
      expect(characters.rowCount, 2);
      expect(characters.sampledRows, 1);
      expect(characters.scalar, DatabaseMaintenanceCheck.truncated);
      expect(characters.uncheckedJsonRows, 1);
      expect(characters.json, isNot(DatabaseMaintenanceCheck.checked));
      expect(
        report.tables.singleWhere((t) => t.table == 'memory_book_rows').json,
        DatabaseMaintenanceCheck.unknown,
      );
      expect(
        report.issues.any(
          (i) => i.code == DatabaseMaintenanceIssueCode.oversizedJson,
        ),
        isTrue,
      );
    },
  );

  maintenanceTest(
    'actual FK enforcement and capped violations are observed not assumed',
    (f) async {
      await f.db.customStatement('PRAGMA foreign_keys = OFF');
      for (var i = 0; i < 40; i++) {
        await f.db.customStatement(
          'INSERT INTO lorebook_use_manifest_entries '
          '(session_id, message_id, swipe_id, agent_swipe_id, lorebook_id, entry_id, '
          'entry_order, evidence_json) VALUES (?, ?, ?, ?, ?, ?, ?, ?)',
          [
            'synthetic-orphan-$i',
            'synthetic-message',
            0,
            0,
            'synthetic-book',
            'synthetic-entry',
            0,
            '{}',
          ],
        );
      }
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(report.foreignKeysEnabled, isFalse);
      expect(report.foreignKeys, DatabaseMaintenanceCheck.truncated);
      expect(
        report.issues
            .singleWhere(
              (i) => i.code == DatabaseMaintenanceIssueCode.foreignKeyViolation,
            )
            .count,
        32,
      );
      expect(jsonEncode(report.toJson()), isNot(contains('synthetic-orphan')));
      await f.db.customStatement('PRAGMA foreign_keys = ON');
      expect(
        (await f.repo.inspect(isCurrent: f.isCurrent)).foreignKeysEnabled,
        isTrue,
      );
    },
  );

  maintenanceTest(
    'missing schema and index presence are diagnosed without reinstalling',
    (f) async {
      await f.db.customStatement('DROP INDEX idx_cfm_folder');
      await f.db.customStatement('DROP TABLE memory_consolidation_rows');
      await f.db.customStatement('PRAGMA user_version = 1');
      final before =
          (await f.db
                  .customSelect(
                    'SELECT name, type FROM sqlite_master ORDER BY name',
                  )
                  .get())
              .map((r) => r.data)
              .toList();
      final report = await f.repo.inspect(
        isCurrent: f.isCurrent,
        physical: DatabaseMaintenancePhysicalCheck.integrity,
      );
      expect(
        report.issues.any(
          (i) => i.code == DatabaseMaintenanceIssueCode.indexMissing,
        ),
        isTrue,
      );
      expect(
        report.issues.any(
          (i) => i.code == DatabaseMaintenanceIssueCode.versionMismatch,
        ),
        isTrue,
      );
      expect(
        report.tables
            .singleWhere((t) => t.table == 'memory_consolidation_rows')
            .schema,
        DatabaseMaintenanceCheck.issues,
      );
      expect(report.toJson()['schemaDefinitionsAndTriggers'], 'not_checked');
      expect(
        (await f.db
                .customSelect(
                  'SELECT name, type FROM sqlite_master ORDER BY name',
                )
                .get())
            .map((r) => r.data)
            .toList(),
        before,
      );
    },
  );

  maintenanceTest(
    'retirement returns every table with explicit unexamined coverage',
    (f) async {
      f.events.clear();
      var reachedPhysicalCompletion = false;
      f.hook = (event) async {
        if (event.startsWith('select:') &&
            event.contains('pragma_quick_check')) {
          reachedPhysicalCompletion = true;
          f.current = false;
        }
      };
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(reachedPhysicalCompletion, isTrue);
      expect(report.retired, isTrue);
      expect(report.truncated, isTrue);
      expect(report.tables.length, f.db.allTables.length);
      expect(
        report.tables.every(
          (t) => t.schema == DatabaseMaintenanceCheck.notChecked,
        ),
        isTrue,
      );
      expect(
        f.events.where((e) => e.startsWith('select:')).length,
        1,
        reason: 'Original retirement stops before FK/version/schema queries.',
      );
      f.hook = null;
    },
  );

  maintenanceTest(
    'retirement at a failed physical completion also stops the original query plan',
    (f) async {
      f.events.clear();
      var reachedPhysicalCompletion = false;
      f.hook = (event) async {
        if (event.startsWith('select:') &&
            event.contains('pragma_quick_check')) {
          reachedPhysicalCompletion = true;
          f.current = false;
          throw StateError(MaintenanceFixture.canary);
        }
      };
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(reachedPhysicalCompletion, isTrue);
      expect(report.retired, isTrue);
      expect(report.truncated, isTrue);
      expect(f.events.where((e) => e.startsWith('select:')).length, 1);
      expect(report.tables.length, f.db.allTables.length);
      expect(
        report.tables.every(
          (t) => t.schema == DatabaseMaintenanceCheck.notChecked,
        ),
        isTrue,
      );
      expect(
        jsonEncode(report.toJson()),
        isNot(contains(MaintenanceFixture.canary)),
      );
      f.hook = null;
    },
  );

  maintenanceTest(
    'query failures only expose fixed codes and retain unknown tables',
    (f) async {
      f.hook = (event) async {
        if (event.startsWith('select:') &&
            event.contains('pragma_quick_check')) {
          throw StateError(MaintenanceFixture.canary);
        }
      };
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(report.physical, DatabaseMaintenanceCheck.unknown);
      expect(
        report.issues.any(
          (i) => i.code == DatabaseMaintenanceIssueCode.queryUnavailable,
        ),
        isTrue,
      );
      expect(
        jsonEncode(report.toJson()),
        isNot(contains(MaintenanceFixture.canary)),
      );
      expect(report.tables.length, f.db.allTables.length);
      f.hook = null;
    },
  );

  maintenanceTest(
    'primary identity duplicates are diagnosed and never auto-deleted',
    (f) async {
      // Synthetic structural damage, never production schema installation.
      await f.db.customStatement(
        'CREATE TABLE synthetic_duplicate_characters '
        'AS SELECT * FROM characters',
      );
      await f.db.customStatement(
        'INSERT INTO synthetic_duplicate_characters '
        "SELECT * FROM characters WHERE char_id = 'legacy'",
      );
      await f.db.customStatement('DROP TABLE characters');
      await f.db.customStatement(
        'ALTER TABLE synthetic_duplicate_characters RENAME TO characters',
      );
      final before = await f.snapshot();
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(
        report.issues.any(
          (i) =>
              i.code == DatabaseMaintenanceIssueCode.duplicateIdentity &&
              i.table == 'characters',
        ),
        isTrue,
      );
      expect(
        await f.prepare(
          const DatabaseMaintenanceTarget.characterGroup('legacy'),
        ),
        isNull,
      );
      expect(await f.snapshot(), before);
    },
  );

  maintenanceTest(
    'issue and serialized output caps survive whole-table query failures',
    (f) async {
      for (final index in [
        'idx_cfm_folder',
        'idx_cfm_char',
        'idx_pfm_folder',
        'idx_pfm_preset',
      ]) {
        await f.db.customStatement('DROP INDEX $index');
      }
      f.hook = (event) async {
        if (event.startsWith('select:') &&
            (event.contains('AS scalar_bad') ||
                event.contains('pragma_quick_check') ||
                event.contains('pragma_foreign_key_check') ||
                event.contains('PRAGMA user_version'))) {
          throw StateError(MaintenanceFixture.canary);
        }
      };
      final report = await f.repo.inspect(isCurrent: f.isCurrent);
      expect(report.issues.length, 64);
      expect(report.truncated, isTrue);
      expect(report.tables.length, f.db.allTables.length);
      final output = jsonEncode(report.toJson());
      expect(utf8.encode(output).length, lessThanOrEqualTo(32768));
      expect(output, isNot(contains(MaintenanceFixture.canary)));
      f.hook = null;
    },
  );
}
