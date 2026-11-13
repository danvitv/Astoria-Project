import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/archive_stream.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/services/backup/backup_secrets.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

void main() {
  late AppDatabase db;
  late Directory tempDir;
  late ImageStorageService imageStorage;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    db = AppDatabase.forTesting(NativeDatabase.memory());
    tempDir = await Directory.systemTemp.createTemp('glaze_exporter_test_');
    imageStorage = ImageStorageService(tempDir.path);
  });

  tearDown(() async {
    await db.close();
    if (await tempDir.exists()) {
      await tempDir.delete(recursive: true);
    }
  });

  test(
    'buildArchive streams a large table without buffering it in memory',
    () async {
      await db
          .into(db.characters)
          .insert(CharactersCompanion.insert(charId: 'c1', name: 'Char 1'));

      // >8 MB crosses both stored ZIP export and importer spill thresholds.
      final hugeMessages = jsonEncode(
        List.generate(40000, (i) => {'role': 'user', 'content': 'x' * 200}),
      );
      await db
          .into(db.chatSessions)
          .insert(
            ChatSessionsCompanion.insert(
              sessionId: 's1',
              characterId: 'c1',
              sessionIndex: 0,
              messagesJson: hugeMessages,
            ),
          );
      await db
          .into(db.chatSessions)
          .insert(
            ChatSessionsCompanion.insert(
              sessionId: 's2',
              characterId: 'c1',
              sessionIndex: 1,
              messagesJson: '[]',
            ),
          );

      final archive = await BackupExporter(
        db,
        imageStorage,
      ).buildArchive(tempDir);
      expect(await archive.exists(), isTrue);
      addTearDown(() async {
        if (await archive.exists()) await archive.delete();
      });

      final decoded = ZipDecoder().decodeStream(InputFileStream(archive.path));
      try {
        final manifest = decoded.files
            .firstWhere((f) => f.name == 'manifest.json')
            .readBytes()!;
        expect(
          jsonDecode(utf8.decode(manifest))['schemaVersion'],
          BackupExporter.schemaVersion,
        );
        expect(
          jsonDecode(utf8.decode(manifest))[BackupSecrets.manifestFlag],
          false,
        );

        final chatEntry = decoded.files.firstWhere(
          (f) => f.name == 'tables/chat_sessions.jsonl',
        );
        expect(
          chatEntry.compression,
          CompressionType.none,
          reason: 'large table should be stored, not buffered/compressed',
        );

        final lines = await readArchiveFileLines(chatEntry).toList();
        expect(lines.length, 2);
        final rows = lines
            .map((l) => jsonDecode(l) as Map<String, dynamic>)
            .toList();
        final s1 = rows.firstWhere((r) => r['session_id'] == 's1');
        expect(s1['messages_json'], hugeMessages);
        final s2 = rows.firstWhere((r) => r['session_id'] == 's2');
        expect(s2['messages_json'], '[]');
      } finally {
        await decoded.clear();
      }
      await db.delete(db.chatSessions).go();
      await FlutterBackupImporter(
        db,
        imageStorage,
      ).importFromZipFile(archive.path);
      final restored = await db.select(db.chatSessions).get();
      expect(
        restored.singleWhere((r) => r.sessionId == 's1').messagesJson,
        hugeMessages,
      );
      expect(
        restored.singleWhere((r) => r.sessionId == 's2').messagesJson,
        '[]',
      );
    },
  );

  test(
    'default keyless export pages past 500 rows without losing table data',
    () async {
      await db.batch((batch) {
        for (var i = 0; i < 1201; i++) {
          batch.insert(
            db.apiConfigs,
            ApiConfigsCompanion.insert(configId: 'cfg-$i', name: 'Config $i'),
          );
        }
      });
      final file = await BackupExporter(db, imageStorage).buildArchive(tempDir);
      final archive = ZipDecoder().decodeStream(InputFileStream(file.path));
      try {
        final lines = await readArchiveFileLines(
          archive.findFile('tables/api_configs.jsonl')!,
        ).toList();
        expect(lines, hasLength(1201));
        expect(
          lines.map((l) => jsonDecode(l)['config_id']).toSet(),
          hasLength(1201),
        );
      } finally {
        await archive.clear();
      }
    },
  );

  test('worker preserves images and keyless preferences', () async {
    SharedPreferences.setMockInitialValues({
      'theme': 'synthetic-dark',
      'gz_sync_tokens': 'SYNTHETIC_SECRET',
    });
    await db
        .into(db.characters)
        .insert(CharactersCompanion.insert(charId: 'c1', name: 'Synthetic'));
    await db
        .into(db.personas)
        .insert(
          PersonasCompanion.insert(personaId: 'p1', name: 'Synthetic persona'),
        );
    for (final path in [
      'avatars/c1.png',
      'avatars/p1.webp',
      'avatars/unknown.png',
      'gallery/c1/art.webp',
    ]) {
      final image = File('${tempDir.path}/$path');
      await image.parent.create(recursive: true);
      await image.writeAsBytes([1, 2, 3, 255]);
    }
    final file = await BackupExporter(db, imageStorage).buildArchive(tempDir);
    final archive = ZipDecoder().decodeStream(InputFileStream(file.path));
    try {
      for (final name in [
        'avatars/characters/c1.png',
        'avatars/personas/p1.webp',
        'avatars/unknown.png',
        'gallery/c1/art.webp',
      ]) {
        expect(archive.findFile(name)!.readBytes(), [1, 2, 3, 255]);
      }
      final prefs =
          jsonDecode(
                utf8.decode(archive.findFile('preferences.json')!.readBytes()!),
              )
              as Map;
      expect(prefs['theme'], 'synthetic-dark');
      expect(prefs.containsKey('gz_sync_tokens'), isFalse);
      expect(
        await db.select(db.characters).get(),
        hasLength(1),
        reason: 'closing the borrowed worker must not close the app DB',
      );
    } finally {
      await archive.clear();
    }
  });

  test('worker removes only interrupted backup cache artifacts', () async {
    final staleArchive = File(
      '${tempDir.path}/Astoria_backup_2000-01-01_00-00-00.glz',
    );
    final unrelated = File('${tempDir.path}/keep-me.glz');
    final staleStaging = Directory(
      '${tempDir.path}/glaze_backup_staging_interrupted',
    );
    await staleArchive.writeAsString('partial');
    await unrelated.writeAsString('unrelated');
    await staleStaging.create();
    await File('${staleStaging.path}/partial.jsonl').writeAsString('partial');

    final archive = await BackupExporter(
      db,
      imageStorage,
    ).buildArchive(tempDir);

    expect(await archive.exists(), isTrue);
    expect(await staleArchive.exists(), isFalse);
    expect(await staleStaging.exists(), isFalse);
    expect(await unrelated.readAsString(), 'unrelated');
    expect(
      await tempDir
          .list()
          .where(
            (entity) =>
                entity is Directory &&
                entity.path.contains('glaze_backup_staging_'),
          )
          .toList(),
      isEmpty,
    );
  });
}
