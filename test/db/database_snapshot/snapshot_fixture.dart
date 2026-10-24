import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/database_snapshot_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

/// Prepared, NOT EXECUTED. All SQLite is real and all data is synthetic.
final class SnapshotFixture {
  static const approvedRoot = r'C:\Users\Даниил\AppData\Local\Temp\opencode';
  static const canary = 'SYNTHETIC_SNAPSHOT_PRIVATE_NOT_FOR_REPORTS';
  late final Directory root;
  late final String sourcePath;
  late final String destinationPath;
  Database? writer;
  AppDatabase? registration;
  DatabaseSnapshotService? service;
  NativeDatabaseSnapshotOwner? native;
  bool sourceCurrent = true;
  bool created = false;
  Set<String> registered = {};

  Future<void> create({bool malformed = false}) async {
    // Explicit approved root, no system-temp/env/platform/default DB lookup.
    root = await Directory(approvedRoot).createTemp('snapshot-');
    created = true;
    sourcePath = p.join(root.path, 'source.db');
    destinationPath = p.join(root.path, 'verified.db');
    if (malformed) {
      await File(sourcePath).writeAsBytes(List.filled(4096, 0x41), flush: true);
      registered = {'synthetic'};
      return;
    }
    writer = sqlite3.open(sourcePath);
    writer!.execute('PRAGMA journal_mode = WAL');
    writer!.execute('PRAGMA wal_autocheckpoint = 0');
    registration = AppDatabase.forTesting(
      NativeDatabase.opened(writer!, closeUnderlyingOnClose: false),
    );
    // Only fresh synthetic production schema creation. The service never
    // constructs AppDatabase and cannot enter migration or payload hydration.
    await registration!.customSelect('SELECT 1').get();
    registered = registration!.allTables.map((t) => t.actualTableName).toSet();
    writer!.execute('PRAGMA application_id = 1095976018');
    writer!.execute('PRAGMA wal_checkpoint(TRUNCATE)');
    writer!.execute('BEGIN');
    writer!.execute(
      'INSERT INTO characters (char_id,name,description) '
      'VALUES (?,?,?)',
      ['character', canary, canary],
    );
    writer!.execute(
      'INSERT INTO character_folders (folder_id,name) VALUES (?,?)',
      ['folder', canary],
    );
    writer!.execute(
      'INSERT INTO preset_folders (folder_id,name) VALUES (?,?)',
      ['preset-folder', canary],
    );
    writer!.execute(
      'INSERT INTO preset_folder_members '
      '(folder_id,preset_id,kind,added_at) VALUES (?,?,?,?)',
      ['preset-folder', 'synthetic', 'normal', 1],
    );
    writer!.execute(
      'INSERT INTO support_sessions (id,title_ciphertext) VALUES (?,?)',
      ['support', 'synthetic-ciphertext-$canary'],
    );
    writer!.execute(
      'INSERT INTO support_context_blocks '
      '(id,session_id,start_message_id,end_message_id,summary_ciphertext) '
      'VALUES (?,?,?,?,?)',
      ['context', 'support', 'a', 'b', canary],
    );
    writer!.execute(
      'INSERT INTO support_mutation_journal '
      '(id,session_id,domain,target_id,before_ciphertext,after_ciphertext) '
      'VALUES (?,?,?,?,?,?)',
      [
        'journal',
        'support',
        'synthetic',
        'target',
        'before-$canary',
        'after-$canary',
      ],
    );
    writer!.execute(
      'INSERT INTO api_configs (config_id,name,api_key) VALUES (?,?,?)',
      ['api', canary, 'synthetic-credential-$canary'],
    );
    writer!.execute(
      'CREATE TABLE extra_snapshot_entity '
      '(id INTEGER PRIMARY KEY, secret BLOB NOT NULL)',
    );
    writer!.execute('INSERT INTO extra_snapshot_entity VALUES (?,?)', [
      1,
      canary.codeUnits,
    ]);
    writer!.execute(
      'CREATE INDEX extra_snapshot_index ON extra_snapshot_entity(secret)',
    );
    writer!.execute(
      'CREATE VIEW extra_snapshot_view AS '
      'SELECT id FROM extra_snapshot_entity',
    );
    writer!.execute(
      'CREATE TRIGGER extra_snapshot_trigger AFTER INSERT '
      'ON extra_snapshot_entity BEGIN SELECT 1; END',
    );
    writer!.execute('COMMIT');
  }

  DatabaseSnapshotService build({
    String? destination,
    bool Function()? current,
    Iterable<String>? tables,
  }) {
    native = NativeDatabaseSnapshotOwner(
      sourcePath: sourcePath,
      destinationPath: destination ?? destinationPath,
      registeredTableNames: tables ?? registered,
      isSourceCurrent: current ?? () => sourceCurrent,
    );
    return service = DatabaseSnapshotService(native: native!);
  }

  void expectStatus(
    DatabaseSnapshotResult result,
    DatabaseSnapshotStatus expected,
  ) {
    expect(
      result.status,
      expected,
      reason:
          'Native identity proof gate: ${native?.identityFailure ?? 'none'}',
    );
  }

  List<List<Object?>> schema(Database db) => db
      .select(
        'SELECT type,name,tbl_name,rootpage,sql FROM sqlite_schema ORDER BY type,name',
      )
      .map((row) => row.values.toList())
      .toList();

  Future<List<String>> partials() async =>
      (await root.list(followLinks: false).toList())
          .where((entry) => entry.path.contains('.snapshot-'))
          .map((entry) => p.basename(entry.path))
          .toList();

  Future<void> close() async {
    if (!created) return;
    service?.dispose();
    await registration?.close();
    writer?.close();
    // Flat fixture-owned files only. No recursive or broad directory cleanup.
    await for (final entry in root.list(followLinks: false)) {
      expect(p.dirname(entry.path), root.path);
      if (entry is File) {
        await entry.delete();
      } else if (entry is Link) {
        await entry.delete();
      } else {
        fail('Unexpected directory inside synthetic snapshot fixture');
      }
    }
    await root.delete();
  }
}

void snapshotTest(
  String name,
  Future<void> Function(SnapshotFixture) body, {
  bool malformed = false,
}) {
  test(name, () async {
    final fixture = SnapshotFixture();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        throw StateError(
          'Platform/prefs/vault calls forbidden in snapshot tests',
        );
    try {
      await HttpOverrides.runZoned(
        () async {
          try {
            await fixture.create(malformed: malformed);
            await body(fixture);
          } finally {
            await fixture.close();
          }
        },
        createHttpClient: (_) =>
            throw StateError('Network forbidden in snapshot tests'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  }, skip: !Platform.isWindows);
}
