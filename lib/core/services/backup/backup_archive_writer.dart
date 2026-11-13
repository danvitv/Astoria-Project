import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:path/path.dart' as p;

import '../../db/repositories/backup_export_repo.dart';
import 'backup_secrets.dart';

/// Runs entirely in a backup isolate. No platform channels or UI state.
final class BackupArchiveWriter {
  BackupArchiveWriter(this._repo);

  final BackupExportRepo _repo;
  static const _compressInMemoryBytes = 4 * 1024 * 1024;

  Future<String> build({
    required String directory,
    required String imageDirectory,
    required List<String> tableNames,
    required int schemaVersion,
    required bool includeApiKeys,
    required Map<String, dynamic> preferences,
  }) async {
    await _removeInterruptedArtifacts(Directory(directory));
    final now = DateTime.now();
    final filename =
        'Astoria_backup_${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}_'
        '${now.hour.toString().padLeft(2, '0')}-${now.minute.toString().padLeft(2, '0')}-${now.second.toString().padLeft(2, '0')}.glz';
    final output = File(p.join(directory, filename));
    final staging = await Directory(
      directory,
    ).createTemp('glaze_backup_staging_');
    final encoder = ZipFileEncoder();
    try {
      encoder.create(output.path);
      _addJson(encoder, 'manifest.json', {
        '_isGlazeBackup': true,
        '_glazeVersion': schemaVersion,
        '_source': 'flutter',
        'schemaVersion': schemaVersion,
        'exportedAt': now.toIso8601String(),
        'tables': tableNames,
        BackupSecrets.manifestFlag: includeApiKeys,
      });
      for (final table in tableNames) {
        final staged = File(p.join(staging.path, '$table.jsonl'));
        await _writeTable(table, staged, includeApiKeys: includeApiKeys);
        await _addTable(encoder, staged, 'tables/$table.jsonl');
      }
      _addJson(
        encoder,
        'preferences.json',
        includeApiKeys ? preferences : BackupSecrets.stripPrefs(preferences),
      );
      await _addImages(encoder, imageDirectory);
      await encoder.close();
      return output.path;
    } catch (_) {
      try {
        await encoder.close();
      } catch (_) {}
      if (await output.exists()) await output.delete();
      rethrow;
    } finally {
      try {
        await staging.delete(recursive: true);
      } catch (_) {}
    }
  }

  Future<void> _removeInterruptedArtifacts(Directory directory) async {
    if (!await directory.exists()) return;
    await for (final entity in directory.list(followLinks: false)) {
      final name = p.basename(entity.path);
      final owned =
          entity is Directory && name.startsWith('glaze_backup_staging_') ||
          entity is File &&
              RegExp(
                r'^Astoria_backup_\d{4}-\d{2}-\d{2}_\d{2}-\d{2}-\d{2}\.glz$',
              ).hasMatch(name);
      if (!owned) continue;
      try {
        await entity.delete(recursive: entity is Directory);
      } catch (_) {}
    }
  }

  void _addJson(ZipFileEncoder encoder, String name, Object data) => encoder
      .addArchiveFile(ArchiveFile.bytes(name, utf8.encode(jsonEncode(data))));

  Future<void> _writeTable(
    String table,
    File output, {
    required bool includeApiKeys,
  }) async {
    final file = output.openSync(mode: FileMode.write);
    try {
      final sink = _BackupFileSink(file);
      await for (final rows in _repo.pages(table)) {
        for (final row in rows) {
          final data = includeApiKeys
              ? row
              : BackupSecrets.stripRow(table, row);
          // Chunked UTF-8 writes avoid a second row-sized JSON string/byte
          // array and an unbounded IOSink queue for a single huge chat.
          final json = JsonUtf8Encoder().startChunkedConversion(sink);
          json.add(data);
          json.close();
          file.writeByteSync(0x0A);
        }
      }
    } finally {
      file.closeSync();
    }
  }

  Future<void> _addTable(ZipFileEncoder encoder, File file, String name) async {
    if (await file.length() <= _compressInMemoryBytes) {
      encoder.addArchiveFile(ArchiveFile.bytes(name, await file.readAsBytes()));
      return;
    }
    final entry = ArchiveFile.stream(name, InputFileStream(file.path));
    entry.compression = CompressionType.none;
    entry.lastModTime =
        (await file.lastModified()).millisecondsSinceEpoch ~/ 1000;
    entry.mode = (await file.stat()).mode;
    encoder.addArchiveFile(entry);
  }

  Future<void> _addImages(ZipFileEncoder encoder, String directory) async {
    final characters = await _repo.avatarIds('characters', 'char_id');
    final personas = await _repo.avatarIds('personas', 'persona_id');
    final avatars = Directory(p.join(directory, 'avatars'));
    if (await avatars.exists()) {
      await for (final entity in avatars.list(followLinks: false)) {
        if (entity is! File) continue;
        final id = p.basenameWithoutExtension(entity.path);
        final subfolder = characters.contains(id)
            ? 'characters/'
            : personas.contains(id)
            ? 'personas/'
            : '';
        await encoder.addFile(
          entity,
          'avatars/$subfolder${p.basename(entity.path)}',
        );
      }
    }
    final gallery = Directory(p.join(directory, 'gallery'));
    if (await gallery.exists()) {
      await for (final charDir in gallery.list(followLinks: false)) {
        if (charDir is! Directory) continue;
        await for (final image in charDir.list(followLinks: false)) {
          if (image is File) {
            await encoder.addFile(
              image,
              'gallery/${p.basename(charDir.path)}/${p.basename(image.path)}',
            );
          }
        }
      }
    }
  }
}

/// The JSON converter closes its per-row sink, not the shared table file.
final class _BackupFileSink implements Sink<List<int>> {
  _BackupFileSink(this.file);
  final RandomAccessFile file;

  @override
  void add(List<int> bytes) => file.writeFromSync(bytes);

  @override
  void close() {}
}
