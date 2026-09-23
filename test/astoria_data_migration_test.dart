import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import 'package:glaze_flutter/core/services/astoria_data_migration.dart';

void main() {
  late Directory temp;
  setUp(() async {
    temp = await Directory.systemTemp.createTemp('astoria_storage_test_');
  });
  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  test('imports live WAL, media and backups without touching Glaze', () async {
    final oldRoot = Directory(p.join(temp.path, 'Glaze'));
    final root = Directory(p.join(temp.path, 'Astoria'));
    await oldRoot.create(recursive: true);
    final old = sqlite3.open(p.join(oldRoot.path, 'glaze.db'));
    try {
      old.execute('PRAGMA journal_mode=WAL');
      old.execute('CREATE TABLE data (value TEXT)');
      old.execute("INSERT INTO data VALUES ('chat')");
      final image = File(p.join(oldRoot.path, 'avatars', 'one.png'));
      await image.parent.create(recursive: true);
      await image.writeAsString('image');
      await File(
        p.join(oldRoot.path, 'glaze.db.bak_before_upgrade'),
      ).writeAsString('backup');

      await migrateAstoriaData(
        dataRoot: root.path,
        legacyDataRoot: oldRoot.path,
      );
      final imported = sqlite3.open(p.join(root.path, 'astoria.db'));
      try {
        expect(
          imported.select('SELECT value FROM data').single.values.single,
          'chat',
        );
      } finally {
        imported.close();
      }
      expect(
        await File(p.join(root.path, 'avatars', 'one.png')).readAsString(),
        'image',
      );
      expect(
        await File(
          p.join(root.path, 'glaze.db.bak_before_upgrade'),
        ).readAsString(),
        'backup',
      );
      expect(await File(p.join(oldRoot.path, 'glaze.db')).exists(), isTrue);

      await image.writeAsString('changed in Glaze');
      await migrateAstoriaData(
        dataRoot: root.path,
        legacyDataRoot: oldRoot.path,
      );
      expect(
        await File(p.join(root.path, 'avatars', 'one.png')).readAsString(),
        'image',
      );
    } finally {
      old.close();
    }
  });

  test(
    'renames an existing Astoria database and preserves its media',
    () async {
      final root = Directory(p.join(temp.path, 'Astoria-dev'));
      await root.create(recursive: true);
      final db = sqlite3.open(p.join(root.path, 'glaze.db'));
      db.execute('CREATE TABLE local (value INTEGER)');
      db.execute('INSERT INTO local VALUES (42)');
      db.close();
      final image = File(p.join(root.path, 'gallery', 'my.png'));
      await image.parent.create(recursive: true);
      await image.writeAsString('my data');

      await migrateAstoriaData(dataRoot: root.path);

      final imported = sqlite3.open(p.join(root.path, 'astoria.db'));
      expect(
        imported.select('SELECT value FROM local').single.values.single,
        42,
      );
      imported.close();
      expect(await File(p.join(root.path, 'glaze.db')).exists(), isTrue);
      expect(await image.readAsString(), 'my data');
    },
  );

  test('never overwrites an existing Astoria database', () async {
    final root = Directory(p.join(temp.path, 'Astoria'));
    final oldRoot = Directory(p.join(temp.path, 'Glaze'));
    await root.create(recursive: true);
    await oldRoot.create(recursive: true);
    final current = sqlite3.open(p.join(root.path, 'astoria.db'));
    current.execute('CREATE TABLE own (id INTEGER)');
    current.close();
    final old = sqlite3.open(p.join(oldRoot.path, 'glaze.db'));
    old.execute('CREATE TABLE previous (id INTEGER)');
    old.close();

    await migrateAstoriaData(dataRoot: root.path, legacyDataRoot: oldRoot.path);

    final retained = sqlite3.open(p.join(root.path, 'astoria.db'));
    expect(
      retained.select("SELECT name FROM sqlite_master WHERE name='own'"),
      isNotEmpty,
    );
    retained.close();
  });

  test('resumes a partially copied media directory', () async {
    final root = Directory(p.join(temp.path, 'Astoria'));
    final oldRoot = Directory(p.join(temp.path, 'Glaze'));
    await root.create(recursive: true);
    await oldRoot.create(recursive: true);
    final old = sqlite3.open(p.join(oldRoot.path, 'glaze.db'));
    old.execute('CREATE TABLE data (id INTEGER)');
    old.close();
    final oldImage = File(p.join(oldRoot.path, 'avatars', 'two.png'));
    await oldImage.parent.create(recursive: true);
    await oldImage.writeAsString('second');
    await File(
      p.join(root.path, '.astoria-storage-import-pending'),
    ).writeAsString('pending');
    final current = sqlite3.open(p.join(root.path, 'astoria.db'));
    current.execute('CREATE TABLE own (id INTEGER)');
    current.close();

    await migrateAstoriaData(dataRoot: root.path, legacyDataRoot: oldRoot.path);

    expect(
      await File(p.join(root.path, 'avatars', 'two.png')).readAsString(),
      'second',
    );
    expect(
      await File(p.join(root.path, '.astoria-storage-import-pending')).exists(),
      isFalse,
    );
  });

  test('removes a stale pending marker after an existing import', () async {
    final root = Directory(p.join(temp.path, 'Astoria'));
    await root.create(recursive: true);
    final db = sqlite3.open(p.join(root.path, 'astoria.db'));
    db.execute('CREATE TABLE own (value INTEGER)');
    db.close();
    final marker = File(p.join(root.path, '.astoria-storage-import-pending'));
    await marker.writeAsString('pending');
    await File(
      p.join(root.path, '.astoria-legacy-media-import-v1'),
    ).writeAsString('done');

    await migrateAstoriaData(dataRoot: root.path);

    expect(await marker.exists(), isFalse);
    expect(await File(p.join(root.path, 'astoria.db')).exists(), isTrue);
  });

  test('keeps an incomplete import pending when its source is lost', () async {
    final root = Directory(p.join(temp.path, 'Astoria'));
    await root.create(recursive: true);
    final marker = File(p.join(root.path, '.astoria-storage-import-pending'));
    await marker.writeAsString('pending');

    await expectLater(
      migrateAstoriaData(dataRoot: root.path),
      throwsA(isA<StateError>()),
    );
    expect(await marker.exists(), isTrue);
    expect(await File(p.join(root.path, 'astoria.db')).exists(), isFalse);
  });
}
