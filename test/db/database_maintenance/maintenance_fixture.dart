import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/models/database_maintenance.dart';
import 'package:glaze_flutter/core/db/repositories/database_maintenance_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../../credentials/fake_credential_storage.dart';
import '../../support/helpers/support_mutation_journal_fixture.dart';

/// Production AppDatabase registration, creation, indexes/triggers and actual
/// journal AEAD. Only in-memory SQLite and fake vault; no inherited toy schema.
void maintenanceTest(
  String name,
  Future<void> Function(MaintenanceFixture f) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String name) {
      attempts.add(name);
      throw StateError('Outside synthetic maintenance fixture.');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final f = MaintenanceFixture();
            try {
              await f.seed();
              await body(f);
            } finally {
              f.clearHooks();
              await f.db.close();
              await messenger.platformMessagesFinished;
              expect(attempts, isEmpty);
            }
          },
          createFile: (_) => block('file/default database'),
          createDirectory: (_) => block('directory'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HttpClient'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

final class MaintenanceFixture {
  MaintenanceFixture() {
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(sql));
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_maintenance',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    support = SupportRepo(db, cipher);
    repo = DatabaseMaintenanceRepo(db, support);
    sql.event = event;
    primitive.event = event;
  }
  static const sessionId = 'synthetic-maintenance-session';
  static const canary = 'SYNTHETIC_PRIVATE_MAINTENANCE_CANARY';
  final storage = FakeCredentialStorage();
  final sql = JournalControlledSql();
  final primitive = JournalControlledCipher();
  late final AppDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo support;
  late final DatabaseMaintenanceRepo repo;
  bool current = true;
  bool isCurrent() => current;
  Future<void> Function(String)? hook;
  final events = <String>[];
  Future<void> event(String event) async {
    events.add(event);
    await hook?.call(event);
  }

  void clearHooks() {
    hook = null;
    storage.readError = null;
    storage.writeError = null;
  }

  Future<void> seed() async {
    // This explicitly opens ONLY production memory DB before discovery. The
    // health primitive itself must never trigger these creation/migration hooks.
    await db.customSelect('SELECT 1').get();
    await support.createSession(
      const SupportSession(
        id: sessionId,
        title: canary,
        createdAt: 1,
        updatedAt: 2,
      ),
    );
    await db.customStatement(
      'INSERT INTO characters '
      '(char_id, name, description, variant_group_id) VALUES (?, ?, ?, ?)',
      ['legacy', canary, canary, ''],
    );
    await db.customStatement(
      'INSERT INTO characters '
      '(char_id, name, description, variant_group_id) VALUES (?, ?, ?, ?)',
      ['unrelated', canary, canary, 'unrelated'],
    );
    await db.customStatement(
      'INSERT INTO character_folders (folder_id, name) '
      'VALUES (?, ?)',
      ['character-folder', canary],
    );
    await db.customStatement(
      'INSERT INTO preset_folders (folder_id, name) '
      'VALUES (?, ?)',
      ['preset-folder', canary],
    );
    await db.customStatement(
      'INSERT INTO character_folder_members '
      '(folder_id, char_id, added_at) VALUES (?, ?, ?)',
      ['character-folder', 'missing-character', 7],
    );
    await db.customStatement(
      'INSERT INTO character_folder_members '
      '(folder_id, char_id, added_at) VALUES (?, ?, ?)',
      ['character-folder', 'unrelated', 8],
    );
    // Same ID in both independent domains, plus a domain-only missing member.
    await db.customStatement(
      'INSERT INTO presets (preset_id, name, data_json) '
      'VALUES (?, ?, ?)',
      ['collision', canary, '{"private":"$canary"}'],
    );
    await db.customStatement(
      'INSERT INTO studio_preset_rows (preset_id, name) '
      'VALUES (?, ?)',
      ['collision', canary],
    );
    await db.customStatement(
      'INSERT INTO presets (preset_id, name, data_json) '
      'VALUES (?, ?, ?)',
      ['ordinary-only', canary, '{}'],
    );
    for (final kind in ['normal', 'agentic']) {
      await db.customStatement(
        'INSERT INTO preset_folder_members '
        '(folder_id, preset_id, kind, added_at) VALUES (?, ?, ?, ?)',
        ['preset-folder', 'collision', kind, 9],
      );
      await db.customStatement(
        'INSERT INTO preset_folder_members '
        '(folder_id, preset_id, kind, added_at) VALUES (?, ?, ?, ?)',
        ['preset-folder', 'ordinary-only', kind, 10],
      );
    }
    events.clear();
  }

  Future<DatabaseMaintenancePlan?> prepare(
    DatabaseMaintenanceTarget target, {
    String operation = 'synthetic-repair',
  }) => repo.prepare(
    target: target,
    operationId: operation,
    supportSessionId: sessionId,
    createdAt: 11,
    isCurrent: isCurrent,
  );
  Future<String> snapshot() async {
    final tables = <String, Object>{};
    for (final table in db.allTables) {
      final rows = await db
          .customSelect(
            'SELECT * FROM '
            '"${table.actualTableName}" ORDER BY rowid',
          )
          .get();
      tables[table.actualTableName] = rows.map((r) => r.data).toList();
    }
    return jsonEncode(tables);
  }

  Future<Map<String, Object?>> character(String id) async =>
      (await db
              .customSelect(
                'SELECT * FROM characters WHERE char_id = ?',
                variables: [Variable<String>(id)],
              )
              .getSingle())
          .data;
  Future<int> memberCount(String id, String kind) async =>
      (await db
              .customSelect(
                'SELECT count(*) AS n FROM preset_folder_members '
                'WHERE preset_id = ? AND kind = ?',
                variables: [Variable<String>(id), Variable<String>(kind)],
              )
              .getSingle())
          .read<int>('n');
}
