import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../constants/build_channel.dart';

/// Copies the old Windows data root into Astoria before any database or image
/// service is opened. The source remains untouched. A SQLite backup includes
/// committed WAL transactions even if the old application is still running.
Future<void> migrateAstoriaWindowsData({
  Map<String, String>? environment,
  String? channel,
}) async {
  if (!Platform.isWindows && environment == null) return;
  final appData = (environment ?? Platform.environment)['APPDATA'];
  if (appData == null || appData.isEmpty) return;

  final selectedChannel = channel ?? buildChannel;
  // Glaze's local developer builds used the nightly channel; Astoria uses dev.
  final oldFolder = selectedChannel == 'stable'
      ? 'Glaze'
      : 'Glaze-${selectedChannel == 'dev' ? 'nightly' : selectedChannel}';
  final newFolder = selectedChannel == 'stable'
      ? 'Astoria'
      : 'Astoria-$selectedChannel';
  final source = Directory(p.join(appData, oldFolder));
  if (!await source.exists()) return;
  final destination = Directory(p.join(appData, newFolder));
  await destination.create(recursive: true);
  final marker = File(p.join(destination.path, '.astoria-data-import-v1'));
  if (await marker.exists()) return;

  final sourceDb = File(p.join(source.path, 'glaze.db'));
  final targetDb = File(p.join(destination.path, 'glaze.db'));
  if (!await sourceDb.exists()) return;
  if (!await targetDb.exists()) {
    final temporary = File('${targetDb.path}.astoria-import.tmp');
    if (await temporary.exists()) await temporary.delete();
    try {
      final old = sqlite3.open(sourceDb.path, mode: OpenMode.readOnly);
      try {
        final copy = sqlite3.open(temporary.path);
        try {
          // The sqlite3 package defaults to five pages with a 250 ms pause
          // between steps. A real user database can be hundreds of MB, so
          // copy in larger batches while still yielding to other connections.
          await old.backup(copy, nPage: 4096).drain<void>();
          final integrity = copy
              .select('PRAGMA quick_check')
              .first
              .values
              .first;
          if (integrity != 'ok') throw StateError('Copied database is invalid');
        } finally {
          copy.close();
        }
      } finally {
        old.close();
      }
      // A prior import may have succeeded before a later media copy failed.
      if (!await targetDb.exists()) await temporary.rename(targetDb.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  await _copyMissingMedia(source, destination);
  await marker.writeAsString('done', flush: true);
}

Future<void> _copyMissingMedia(Directory source, Directory destination) async {
  await for (final entity in source.list(followLinks: false)) {
    final name = p.basename(entity.path);
    if (name == 'glaze.db' ||
        name.startsWith('glaze.db-') ||
        name.endsWith('.astoria-import.tmp')) {
      continue;
    }
    final targetPath = p.join(destination.path, name);
    if (entity is Directory) {
      final target = Directory(targetPath);
      await target.create(recursive: true);
      await _copyMissingMedia(entity, target);
    } else if (entity is File) {
      final target = File(targetPath);
      if (await target.exists()) continue;
      final temporary = File('$targetPath.astoria-import.tmp');
      if (await temporary.exists()) await temporary.delete();
      try {
        await entity.copy(temporary.path);
        if (!await target.exists()) await temporary.rename(targetPath);
      } finally {
        if (await temporary.exists()) await temporary.delete();
      }
    }
  }
}
