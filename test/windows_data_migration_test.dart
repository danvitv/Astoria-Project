import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:glaze_flutter/core/services/windows_data_migration.dart';

void main() {
  late Directory appData;
  setUp(() async {
    appData = await Directory.systemTemp.createTemp('astoria_data_migration_');
  });
  tearDown(() async {
    if (await appData.exists()) await appData.delete(recursive: true);
  });

  test(
    'imports a live WAL database and media to Astoria-dev, leaving Glaze untouched',
    () async {
      final oldRoot = Directory(p.join(appData.path, 'Glaze-nightly'));
      final newRoot = Directory(p.join(appData.path, 'Astoria-dev'));
      await oldRoot.create(recursive: true);
      final oldDb = sqlite3.open(p.join(oldRoot.path, 'glaze.db'));
      try {
        oldDb.execute('PRAGMA journal_mode=WAL');
        oldDb.execute('CREATE TABLE data (value TEXT)');
        oldDb.execute("INSERT INTO data VALUES ('preserved')");
        final oldImage = File(p.join(oldRoot.path, 'avatars', 'picture.png'));
        await oldImage.parent.create(recursive: true);
        await oldImage.writeAsString('image');

        await migrateAstoriaWindowsData(
          environment: {'APPDATA': appData.path},
          channel: 'dev',
        );
        final imported = sqlite3.open(p.join(newRoot.path, 'glaze.db'));
        try {
          expect(
            imported.select('SELECT value FROM data').single.values.single,
            'preserved',
          );
        } finally {
          imported.close();
        }
        expect(
          await File(
            p.join(newRoot.path, 'avatars', 'picture.png'),
          ).readAsString(),
          'image',
        );

        await oldImage.writeAsString('new Glaze data');
        await migrateAstoriaWindowsData(
          environment: {'APPDATA': appData.path},
          channel: 'dev',
        );
        expect(
          await File(
            p.join(newRoot.path, 'avatars', 'picture.png'),
          ).readAsString(),
          'image',
        );
        expect(await oldImage.readAsString(), 'new Glaze data');
      } finally {
        oldDb.close();
      }
    },
  );

  test('an existing Astoria database wins over the old install', () async {
    final oldRoot = Directory(p.join(appData.path, 'Glaze-nightly'));
    final newRoot = Directory(p.join(appData.path, 'Astoria-dev'));
    await oldRoot.create(recursive: true);
    await newRoot.create(recursive: true);
    final oldDb = sqlite3.open(p.join(oldRoot.path, 'glaze.db'));
    oldDb.execute('CREATE TABLE old_data (value TEXT)');
    oldDb.close();
    final newDb = sqlite3.open(p.join(newRoot.path, 'glaze.db'));
    newDb.execute('CREATE TABLE astoria_data (value TEXT)');
    newDb.close();

    await migrateAstoriaWindowsData(
      environment: {'APPDATA': appData.path},
      channel: 'dev',
    );

    final imported = sqlite3.open(p.join(newRoot.path, 'glaze.db'));
    try {
      expect(
        imported
            .select("SELECT name FROM sqlite_master WHERE type = 'table'")
            .single
            .values
            .single,
        'astoria_data',
      );
    } finally {
      imported.close();
    }
  });
}
