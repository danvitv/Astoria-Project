import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/database_background_snapshot_source_repo.dart';
import 'package:glaze_flutter/core/services/android_snapshot_namespace.dart';
import 'package:glaze_flutter/core/services/database_snapshot_service.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

const _tokenA =
    'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _tokenB =
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

// Genuine background Drift worker, synthetic approved files only. This does not
// prove Android file custody/publication and never launches an Android target.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'worker copies full schema, sparse BLOB rowids and committed WAL under fence',
    () async {
      final fixture = _WorkerFixture();
      final release = Completer<void>();
      Future<void>? original, writer;
      sqlite.Database? copy;
      try {
        await fixture.seed();
        expect(await fixture.command('check'), {
          'status': 'ready',
          'closed': true,
        });
        expect(
          (await fixture.db
                  .customSelect('SELECT value FROM temp.snapshot_worker_marker')
                  .get())
              .single
              .read<String>('value'),
          'actual-worker',
        );
        final expected = await fixture.db
            .customSelect(
              'SELECT type,name,tbl_name,rootpage,sql FROM main.sqlite_schema ORDER BY type,name',
            )
            .get();
        expect(File('${fixture.source.path}-wal').lengthSync(), greaterThan(0));
        final entered = Completer<void>();
        var writerEntered = false;
        original = fixture.fenced(() async {
          expect(await fixture.command('start'), {
            'status': 'ready',
            'closed': false,
          });
          var result = await fixture.command('step');
          expect(result['status'], isIn(['progress', 'ready']));
          entered.complete();
          await release.future;
          for (var i = 0; i < 1026 && result['status'] == 'progress'; i++) {
            result = await fixture.command('step');
          }
          expect(result, {'status': 'ready', 'closed': false});
          final finished = await fixture.command('finish');
          expect(finished['status'], 'verified');
          expect(finished['closed'], isTrue);
          expect(
            finished['tableCount'],
            inInclusiveRange(fixture.db.allTables.length, 512),
          );
        });
        await Future.any<void>([entered.future, original]);
        expect(entered.isCompleted, isTrue);
        writer = fixture.db.transaction(() async {
          writerEntered = true;
          await fixture.db.customStatement(
            "INSERT INTO snapshot_worker_extra(rowid,value) VALUES (1000000,X'AABB')",
          );
        });
        await Future<void>.delayed(Duration.zero);
        expect(writerEntered, isFalse);
        release.complete();
        await original;
        await writer;
        expect(writerEntered, isTrue);

        // Open only after the production terminal truthfully reports raw close.
        copy = sqlite.sqlite3.open(
          fixture.stage(_tokenA).path,
          mode: sqlite.OpenMode.readOnly,
        );
        expect(copy.select('PRAGMA integrity_check').single.values, ['ok']);
        expect(copy.select('PRAGMA journal_mode').single.values, ['delete']);
        expect(
          copy
              .select(
                'SELECT rowid,hex(value) FROM snapshot_worker_extra ORDER BY rowid',
              )
              .map((row) => row.values.toList())
              .toList(),
          [
            [-7, '00FF'],
            [2, '102030'],
            [999999, 'FEED'],
          ],
        );
        expect(
          copy
              .select(
                'SELECT type,name,tbl_name,rootpage,sql FROM main.sqlite_schema ORDER BY type,name',
              )
              .map((row) => Map<String, Object?>.from(row))
              .toList(),
          expected.map((row) => row.data).toList(),
        );
        for (final table in fixture.db.allTables) {
          final name = table.actualTableName.replaceAll('"', '""');
          expect(
            copy.select('SELECT count(*) FROM main."$name"'),
            hasLength(1),
          );
        }
        expect(copy.select('SELECT name FROM temp.sqlite_schema'), isEmpty);
        copy.close();
        copy = null;
        final saved = fixture.stage(_tokenA).readAsBytesSync();
        await fixture.fenced(() async {
          expect((await fixture.command('start'))['status'], 'unavailable');
        });
        expect(fixture.stage(_tokenA).readAsBytesSync(), saved);
        expect(
          (await fixture.db
                  .customSelect('SELECT value FROM temp.snapshot_worker_marker')
                  .get())
              .single
              .read<String>('value'),
          'actual-worker',
        );
      } finally {
        if (!release.isCompleted) release.complete();
        try {
          await original;
        } finally {
          try {
            await writer;
          } finally {
            copy?.close();
            await fixture.close();
          }
        }
      }
    },
    skip: !Platform.isWindows,
    timeout: const Timeout(Duration(seconds: 45)),
  );

  test(
    'check rejects an inherited actual transaction before starting a snapshot',
    () async {
      final fixture = _WorkerFixture();
      try {
        await fixture.seed();
        await fixture.db.transaction(() async {
          await fixture.db
              .customSelect('SELECT count(*) FROM main.sqlite_schema')
              .get();
          expect(await fixture.command('check'), {
            'status': 'unavailable',
            'closed': true,
          });
          var entered = false;
          await expectLater(
            fixture.fenced(() async {
              entered = true;
            }),
            throwsStateError,
          );
          expect(entered, isFalse);
        });
        expect(fixture.stage(_tokenA).lengthSync(), 0);
        expect(await fixture.command('check'), {
          'status': 'ready',
          'closed': true,
        });
      } finally {
        await fixture.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'root cancellation after an awaited step aborts original handles without deletion',
    () async {
      final fixture = _WorkerFixture();
      try {
        await fixture.seed();
        await fixture.fenced(() async {
          expect((await fixture.command('start'))['status'], 'ready');
          final step = await fixture.command('step');
          expect(step['closed'], isFalse);
          expect(step['status'], isIn(['progress', 'ready']));
          // Root cancellation is not a worker-global flag: stop stepping and join.
          expect(await fixture.command('abort'), {
            'status': 'closed',
            'closed': true,
          });
          expect(await fixture.command('abort'), {
            'status': 'closed',
            'closed': true,
          });
        });
        expect(fixture.stage(_tokenA).existsSync(), isTrue);
        expect(
          File(p.join(fixture.stageRoot.path, 'published.db')).existsSync(),
          isFalse,
        );
        final reopened = sqlite.sqlite3.open(fixture.stage(_tokenA).path);
        try {
          // The original raw destination really is closed; exclusive locking works.
          reopened.execute('PRAGMA busy_timeout = 0');
          reopened.execute('BEGIN EXCLUSIVE');
          reopened.execute('ROLLBACK');
        } finally {
          reopened.close();
        }
        expect(
          (await fixture.db
                  .customSelect(
                    'SELECT count(*) AS n FROM snapshot_worker_extra',
                  )
                  .get())
              .single
              .read<int>('n'),
          3,
        );
      } finally {
        await fixture.close();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'stale token and malformed metadata cannot retire active owner A',
    () async {
      final fixture = _WorkerFixture();
      try {
        await fixture.seed();
        await fixture.fenced(() async {
          expect(
            (await fixture.command(
              'start',
              metadata: '["characters", "characters"]',
            ))['status'],
            'invalid',
          );
          expect(fixture.stage(_tokenA).lengthSync(), 0);
          expect((await fixture.command('start'))['status'], 'ready');
          expect(await fixture.command('abort', token: _tokenB), {
            'status': 'unavailable',
            'closed': false,
          });
          expect(await fixture.command('step', token: _tokenB), {
            'status': 'unavailable',
            'closed': false,
          });
          expect(await fixture.command('finish', token: _tokenB), {
            'status': 'unavailable',
            'closed': false,
          });
          expect(await fixture.command('step', metadata: '[]'), {
            'status': 'invalid',
            'closed': false,
          });
          expect(
            (await fixture.command('step'))['status'],
            isIn(['progress', 'ready']),
          );
          expect(await fixture.command('abort'), {
            'status': 'closed',
            'closed': true,
          });
        });
        expect(fixture.stage(_tokenA).existsSync(), isTrue);
        expect(fixture.stage(_tokenB).lengthSync(), 0);
      } finally {
        await fixture.close();
      }
    },
    skip: !Platform.isWindows,
  );
}

// Only immutable configuration crosses the isolate boundary. No AppDatabase,
// fixture, native handle, mutable root control, vault, preferences or network.
void Function(sqlite.Database) _workerSetup(
  String sourcePath,
  String stageRoot,
) => (source) {
  source.execute('PRAGMA journal_mode = WAL');
  source.execute('PRAGMA wal_autocheckpoint = 0');
  source.execute('CREATE TEMP TABLE snapshot_worker_marker(value TEXT)');
  source.execute("INSERT INTO snapshot_worker_marker VALUES ('actual-worker')");
  BackgroundDatabaseSnapshotWorker.installForTestingWindows(
    source,
    sourcePath: sourcePath,
    privateStageRoot: stageRoot,
  );
};

final class _WorkerFixture {
  _WorkerFixture() {
    root = Directory(
      r'C:\Users\Даниил\AppData\Local\Temp\opencode',
    ).createTempSync('astoria-snapshot-worker-');
    source = File(p.join(root.path, 'source.db'));
    stageRoot = Directory(p.join(root.path, 'private_stage'))..createSync();
    for (final token in [_tokenA, _tokenB]) {
      Directory(p.join(stageRoot.path, token)).createSync();
      stage(token).createSync(exclusive: true);
    }
    db = AppDatabase.forTesting(
      NativeDatabase.createInBackground(
        source,
        readPool: 0,
        setup: _workerSetup(source.path, stageRoot.path),
      ),
    );
    repo = DatabaseBackgroundSnapshotSourceRepo(
      database: db,
      namespace: AndroidSnapshotNamespace.forTestingWindows(root.path),
      sourcePath: source.path,
      registeredTables: db.allTables
          .map((table) => table.actualTableName)
          .toSet(),
      isCurrent: () => db.hasCompletedOpening && !db.isClosing,
      joinLifetime: (work) => Future<void>.sync(work),
      retainUnsettled: (_) =>
          throw StateError('Unexpected unknown native cleanup'),
    );
  }
  late final Directory root, stageRoot;
  late final File source;
  late final AppDatabase db;
  late final DatabaseBackgroundSnapshotSourceRepo repo;
  File stage(String token) =>
      File(p.join(stageRoot.path, token, 'snapshot.db'));

  Future<void> seed() async {
    await db.customStatement(
      'CREATE TABLE snapshot_worker_extra(value BLOB NOT NULL)',
    );
    await db.customStatement(
      'INSERT INTO snapshot_worker_extra(rowid,value) VALUES '
      "(-7,X'00FF'),(2,X'102030'),(999999,X'FEED')",
    );
    await db.customStatement(
      'CREATE INDEX snapshot_worker_index ON snapshot_worker_extra(value)',
    );
  }

  Future<Map<String, Object?>> command(
    String command, {
    String token = _tokenA,
    String? metadata,
  }) async {
    if (metadata == null) {
      final result = await repo.runWorkerCommand(command, token);
      expect(jsonEncode(result).length, lessThan(128));
      return result;
    }
    final rows = await db
        .customSelect(
          'SELECT astoria_native_snapshot(?, ?, ?) AS result',
          variables: [
            Variable.withString(command),
            Variable.withString(token),
            Variable.withString(metadata),
          ],
        )
        .get();
    final raw = rows.single.read<String>('result');
    expect(raw.length, lessThan(128));
    final result = Map<String, Object?>.from(
      jsonDecode(raw) as Map<dynamic, dynamic>,
    );
    expect(result.keys, everyElement(isIn(['status', 'closed', 'tableCount'])));
    expect(
      result['status'],
      isIn([
        'ready',
        'progress',
        'verified',
        'closed',
        'unavailable',
        'invalid',
        'tooLarge',
        'uncertain',
      ]),
    );
    expect(result['closed'], isA<bool>());
    return result;
  }

  Future<void> fenced(Future<void> Function() body) => repo.runOriginalScope(
    () => repo.runReadTransaction(() async {
      await db.customSelect('SELECT count(*) FROM main.sqlite_schema').get();
      try {
        await body();
      } finally {
        // Even a failed assertion joins production cleanup before this actual
        // transaction/exclusive fence is released to a competing writer.
        final retired = await command('abort');
        if (retired['status'] != 'unavailable' && retired['closed'] != true) {
          throw StateError('Original worker handles not closed; retain fence');
        }
      }
    }),
  );

  Future<void> close() async {
    final retired = await command('abort');
    if (retired['status'] != 'unavailable' && retired['closed'] != true) {
      throw StateError('Original worker handles not closed; retain fixture');
    }
    await db.close();
    // Delete known synthetic files only, after joining the original worker.
    for (final file in [source, stage(_tokenA), stage(_tokenB)]) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        final owned = File('${file.path}$suffix');
        if (owned.existsSync()) owned.deleteSync();
      }
    }
    for (final token in [_tokenA, _tokenB]) {
      Directory(p.join(stageRoot.path, token)).deleteSync();
    }
    stageRoot.deleteSync();
    root.deleteSync();
  }
}
