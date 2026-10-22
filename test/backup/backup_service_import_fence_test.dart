import 'dart:async';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/backup/backup_cancel.dart';
import 'package:glaze_flutter/core/services/backup_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import 'import_fence_fixture.dart';

void main() {
  late ImportFenceFixture f;
  setUp(() async => f = await ImportFenceFixture.create());
  tearDown(() async => f.close());

  test(
    'begin runs before reset, detection and first await; missing source settles',
    () async {
      var begins = 0;
      var settlements = 0;
      late BackupService service;
      service = BackupService(
        f.db,
        f.images,
        onImportStarted: () {
          begins++;
          expect(service.cancelToken.isCancelled, isTrue);
          final finish = f.revisions.beginMutation();
          return () {
            settlements++;
            finish();
          };
        },
      );
      service.cancelImport();
      final initial = f.revisions.revision;
      final import = service.importBackupFromFile(
        p.join(f.directory.path, 'missing'),
      );
      expect(begins, 1);
      expect(settlements, 0);
      expect(f.revisions.isStable, isFalse);
      expect(f.revisions.revision, initial + 1);
      expect(service.cancelToken.isCancelled, isFalse);
      await expectLater(import, throwsA(isA<FileSystemException>()));
      expect(settlements, 1);
      expect(f.revisions.isStable, isTrue);
      expect(f.revisions.revision, initial + 2);
    },
  );

  for (final text in [
    'not a backup',
    '{invalid json',
    '{"characters":[],"_source":"flutter"}',
  ]) {
    test('invalid or refused legacy source settles: $text', () async {
      final path = await f.textFile(text);
      final initial = f.revisions.revision;
      await expectLater(
        f.service.importBackupFromFile(path),
        throwsFormatException,
      );
      expect(f.revisions.isStable, isTrue);
      expect(f.revisions.revision, initial + 2);
      expect(f.db.purgeCalls, 0);
    });
  }

  test(
    'unsupported ZIP including disabled Tavo remains refused and settled',
    () async {
      final archive = Archive()
        ..addFile(ArchiveFile.bytes('data.mdb', [1, 2, 3]));
      final file = File(p.join(f.directory.path, 'disabled-tavo.tbk'));
      await file.writeAsBytes(ZipEncoder().encode(archive));
      final initial = f.revisions.revision;
      expect(BackupService.tavoImportEnabled, isFalse);
      await expectLater(
        f.service.importBackupFromFile(file.path),
        throwsFormatException,
      );
      expect(f.revisions.revision, initial + 2);
      expect(f.revisions.isStable, isTrue);
    },
  );

  for (final version in [1, 14]) {
    test('child manifest validation failure settles schema $version', () async {
      final path = await f.zip(schemaVersion: version);
      final initial = f.revisions.revision;
      await expectLater(
        f.service.importBackupFromFile(path),
        throwsFormatException,
      );
      expect(f.revisions.revision, initial + 2);
      expect(f.revisions.isStable, isTrue);
      expect(f.db.purgeCalls, 0);
    });
  }

  test(
    'detected callback failure settles and preserves caller error',
    () async {
      final path = await f.zip();
      final error = StateError('STATIC_DETECTED_ERROR_649321');
      final initial = f.revisions.revision;
      await expectLater(
        f.service.importBackupFromFile(path, onDetected: (_) => throw error),
        throwsA(same(error)),
      );
      expect(f.revisions.revision, initial + 2);
      expect(f.revisions.isStable, isTrue);
    },
  );

  test('failed child DB batch settles after foreign-key cleanup', () async {
    final path = await f.zip(
      tables: {
        'api_configs': [
          {'config_id': 'broken', 'name': null},
        ],
      },
    );
    final initial = f.revisions.revision;
    await expectLater(f.service.importBackupFromFile(path), throwsA(anything));
    expect(f.revisions.revision, initial + 2);
    expect(f.revisions.isStable, isTrue);
    expect(
      (await f.db.customSelect('PRAGMA foreign_keys').getSingle()).read<int>(
        'foreign_keys',
      ),
      1,
    );
    expect(f.db.purgeCalls, 0);
  });

  test(
    'cancel from detection settles; same service later resets cancellation',
    () async {
      final path = await f.zip();
      final initial = f.revisions.revision;
      await expectLater(
        f.service.importBackupFromFile(
          path,
          onDetected: (_) => f.service.cancelImport(),
        ),
        throwsA(isA<ImportCancelledException>()),
      );
      expect(f.revisions.revision, initial + 2);
      expect(f.revisions.isStable, isTrue);
      await f.service.importBackupFromFile(path);
      expect(f.revisions.revision, initial + 4);
      expect(f.revisions.isStable, isTrue);
    },
  );

  test(
    'cancel during awaited image restore stays fenced through cleanup',
    () async {
      final path = await f.zip(
        tables: {
          'characters': [
            {'char_id': 'synthetic', 'name': 'Imported'},
          ],
        },
        preferences: {'import-fence-test': 'not-applied'},
        entries: {
          'avatars/characters/synthetic.png': [1, 2, 3],
        },
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      f.images.beforeAvatar = () {
        entered.complete();
        return release.future;
      };
      final initial = f.revisions.revision;
      final import = f.service.importBackupFromFile(path);
      final result = expectLater(
        import,
        throwsA(isA<ImportCancelledException>()),
      );
      await entered.future;
      expect(f.revisions.revision, initial + 1);
      expect(f.revisions.isStable, isFalse);
      f.service.cancelImport();
      expect(f.revisions.isStable, isFalse);
      release.complete();
      await result;
      expect(f.revisions.revision, initial + 2);
      expect(f.revisions.isStable, isTrue);
      expect(
        (await SharedPreferences.getInstance()).getString('import-fence-test'),
        isNull,
      );
      expect(
        (await f.db.customSelect('PRAGMA foreign_keys').getSingle()).read<int>(
          'foreign_keys',
        ),
        1,
      );
    },
  );

  test(
    'preferences and final purge remain fenced; nested write holds after import',
    () async {
      final path = await f.zip(preferences: {'import-fence-test': 'applied'});
      final entered = Completer<void>();
      final release = Completer<void>();
      f.db.beforePurge = () {
        entered.complete();
        return release.future;
      };
      final initial = f.revisions.revision;
      final states = <bool>[];
      f.revisions.subscribe(() => states.add(f.revisions.isStable));
      final import = f.service.importBackupFromFile(
        path,
        onProgress: (_) {
          expect(f.revisions.isStable, isFalse);
        },
      );
      await entered.future;
      expect(
        (await SharedPreferences.getInstance()).getString('import-fence-test'),
        'applied',
      );
      expect(f.revisions.revision, initial + 1);
      expect(f.revisions.isStable, isFalse);
      final nested = f.revisions.beginMutation();
      release.complete();
      await import;
      expect(f.revisions.isStable, isFalse);
      expect(states, [false, false, false]);
      nested();
      expect(states, [false, false, false, true]);
      expect(f.revisions.revision, initial + 4);
    },
  );

  test(
    'final purge failure revokes again without changing import failure semantics',
    () async {
      final path = await f.zip();
      final error = StateError('STATIC_PURGE_ERROR_549321');
      f.db.beforePurge = () async => throw error;
      final initial = f.revisions.revision;
      await expectLater(
        f.service.importBackupFromFile(path),
        throwsA(same(error)),
      );
      expect(f.revisions.revision, initial + 2);
      expect(f.revisions.isStable, isTrue);
    },
  );

  test(
    'direct service without injection creates no hidden shared registry',
    () async {
      final path = await f.zip();
      final initial = f.revisions.revision;
      await BackupService(f.db, f.images).importBackupFromFile(path);
      expect(f.revisions.revision, initial);
      expect(f.revisions.isStable, isTrue);
    },
  );
}
