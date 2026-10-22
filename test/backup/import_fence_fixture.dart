import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup_service.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

/// Test-created files, memory SQLite, fake images and mocked preferences only.
final class ImportFenceFixture {
  ImportFenceFixture._(this.directory)
    : images = ImportFenceImages(directory.path) {
    service = BackupService(
      db,
      images,
      onImportStarted: revisions.beginMutation,
    );
  }

  static Future<ImportFenceFixture> create() async {
    SharedPreferences.setMockInitialValues({});
    return ImportFenceFixture._(
      await Directory.systemTemp.createTemp('astoria_import_fence_'),
    );
  }

  final Directory directory;
  final db = ImportFenceDatabase();
  final revisions = ConnectionRevisionRegistry();
  final ImportFenceImages images;
  late final BackupService service;
  int _fileNumber = 0;

  Future<String> textFile(String text) async {
    final file = File(p.join(directory.path, '${_fileNumber++}.glz'));
    await file.writeAsString(text);
    return file.path;
  }

  Future<String> zip({
    int schemaVersion = 13,
    Map<String, List<Map<String, dynamic>>> tables = const {},
    Map<String, dynamic> preferences = const {},
    Map<String, List<int>> entries = const {},
  }) async {
    final archive = Archive()
      ..addFile(
        ArchiveFile.bytes(
          'manifest.json',
          utf8.encode(jsonEncode({'schemaVersion': schemaVersion})),
        ),
      )
      ..addFile(
        ArchiveFile.bytes(
          'preferences.json',
          utf8.encode(jsonEncode(preferences)),
        ),
      );
    for (final entry in tables.entries) {
      archive.addFile(
        ArchiveFile.bytes(
          'tables/${entry.key}.jsonl',
          utf8.encode('${entry.value.map(jsonEncode).join('\n')}\n'),
        ),
      );
    }
    for (final entry in entries.entries) {
      archive.addFile(ArchiveFile.bytes(entry.key, entry.value));
    }
    final file = File(p.join(directory.path, '${_fileNumber++}.glz'));
    await file.writeAsBytes(ZipEncoder().encode(archive));
    return file.path;
  }

  Future<void> close() async {
    revisions.dispose();
    await db.close();
    await directory.delete(recursive: true);
  }
}

/// The real cleanup is preserved; a gate directly observes its outer fence.
class ImportFenceDatabase extends AppDatabase {
  ImportFenceDatabase() : super.forTesting(NativeDatabase.memory());

  Future<void> Function()? beforePurge;
  int purgeCalls = 0;

  @override
  Future<void> purgeRetiredAgenticMicroMemory() async {
    purgeCalls++;
    await beforePurge?.call();
    await super.purgeRetiredAgenticMicroMemory();
  }
}

/// Never creates platform storage, decodes images, or reads an arbitrary path.
class ImportFenceImages extends ImageStorageService {
  ImportFenceImages(super.baseDir);
  Future<void> Function()? beforeAvatar;
  int avatarCalls = 0;

  @override
  Future<String> saveAvatar(String characterId, Uint8List imageBytes) async {
    avatarCalls++;
    await beforeAvatar?.call();
    return p.join(baseDir, 'fake-avatars', '$characterId.png');
  }

  @override
  Future<String?> saveThumbnail(
    String characterId,
    Uint8List imageBytes,
  ) async => p.join(baseDir, 'fake-thumbnails', '$characterId.jpg');

  @override
  Future<String> saveBytes(
    Uint8List bytes,
    String subfolder,
    String filename,
    String ext,
  ) async => p.join(baseDir, 'fake-images', '$filename.$ext');
}
