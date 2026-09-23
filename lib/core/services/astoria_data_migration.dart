import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';

import '../constants/build_channel.dart';

/// Imports the previous install into Astoria before Drift opens. Existing
/// Astoria databases win; the old install and its backups are never deleted.
/// The SQLite backup includes committed WAL transactions. A pending marker
/// prevents a failed database copy from opening a new empty database.
Future<void> migrateAstoriaData({
  String? dataRoot,
  String? legacyDataRoot,
}) async {
  final root = dataRoot ?? await _dataRoot();
  if (root == null) return;
  final dir = Directory(root);
  final current = File(p.join(root, 'astoria.db'));
  final pending = File(p.join(root, '.astoria-storage-import-pending'));
  final mediaMarker = File(p.join(root, '.astoria-legacy-media-import-v1'));
  if (await current.exists() && await mediaMarker.exists()) {
    if (await pending.exists()) await pending.delete();
    return;
  }
  final legacy = legacyDataRoot ?? await _legacyDataRoot();
  final localOld = File(p.join(root, 'glaze.db'));
  final source = await localOld.exists()
      ? localOld
      : legacy == null
      ? null
      : File(p.join(legacy, 'glaze.db'));
  final hasSource = source != null && await source.exists();
  if (await pending.exists() && !hasSource && !await current.exists()) {
    throw StateError(
      'Astoria import is incomplete: source database is missing',
    );
  }
  if (!await current.exists() && !hasSource) return;

  await dir.create(recursive: true);
  if (!await current.exists()) {
    await pending.writeAsString('pending', flush: true);
  }

  if (!await current.exists()) {
    final oldDb = source!;
    final temporary = File('${current.path}.import.tmp');
    if (await temporary.exists()) await temporary.delete();
    try {
      final old = sqlite3.open(oldDb.path, mode: OpenMode.readOnly);
      try {
        final destination = sqlite3.open(temporary.path);
        try {
          await old.backup(destination, nPage: 4096).drain<void>();
          if (destination.select('PRAGMA quick_check').first.values.first !=
              'ok') {
            throw StateError('Imported database is invalid');
          }
        } finally {
          destination.close();
        }
      } finally {
        old.close();
      }
      if (!await current.exists()) await temporary.rename(current.path);
    } finally {
      if (await temporary.exists()) await temporary.delete();
    }
  }

  if (!await mediaMarker.exists() &&
      legacy != null &&
      legacy != root &&
      await File(p.join(legacy, 'glaze.db')).exists()) {
    await _copyMissingFiles(Directory(legacy), dir);
    await mediaMarker.writeAsString('done', flush: true);
  }
  if (await pending.exists()) await pending.delete();
}

Future<void> _copyMissingFiles(Directory source, Directory target) async {
  await for (final entry in source.list(followLinks: false)) {
    final name = p.basename(entry.path);
    if (name == 'glaze.db' ||
        name.startsWith('glaze.db-') ||
        name.endsWith('.astoria-import.tmp') ||
        name.endsWith('.import.tmp') ||
        name == '.astoria-storage-import-pending' ||
        name == '.astoria-legacy-media-import-v1' ||
        name.startsWith('.windows-prefs-') ||
        name == 'shared_preferences.json') {
      continue;
    }
    final to = p.join(target.path, name);
    if (entry is Directory) {
      final targetType = await FileSystemEntity.type(to, followLinks: false);
      if (targetType != FileSystemEntityType.notFound &&
          targetType != FileSystemEntityType.directory) {
        continue;
      }
      await Directory(to).create(recursive: true);
      await _copyMissingFiles(entry, Directory(to));
    } else if (entry is File && !await File(to).exists()) {
      if (await FileSystemEntity.type(to, followLinks: false) !=
          FileSystemEntityType.notFound) {
        continue;
      }
      final temp = File('$to.astoria-import.tmp');
      if (await temp.exists()) await temp.delete();
      try {
        await entry.copy(temp.path);
        if (!await File(to).exists()) await temp.rename(to);
      } finally {
        if (await temp.exists()) await temp.delete();
      }
    }
  }
}

Future<String?> _dataRoot() async {
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    return appData == null ? null : p.join(appData, astoriaDataFolderName);
  }
  if (Platform.isLinux) {
    final home = Platform.environment['HOME'];
    final xdg = Platform.environment['XDG_DATA_HOME'];
    return p.join(
      xdg ?? p.join(home!, '.local', 'share'),
      astoriaDataFolderName,
    );
  }
  if (Platform.isMacOS) {
    return p.join(
      Platform.environment['HOME']!,
      'Library',
      'Application Support',
      astoriaDataFolderName,
    );
  }
  return null;
}

Future<String?> _legacyDataRoot() async {
  final oldFolder = isStableChannel
      ? 'Glaze'
      : 'Glaze-${buildChannel == 'dev' ? 'nightly' : buildChannel}';
  if (Platform.isWindows) {
    final appData = Platform.environment['APPDATA'];
    return appData == null ? null : p.join(appData, oldFolder);
  }
  if (Platform.isLinux) {
    final home = Platform.environment['HOME'];
    final xdg = Platform.environment['XDG_DATA_HOME'];
    return p.join(xdg ?? p.join(home!, '.local', 'share'), oldFolder);
  }
  if (Platform.isMacOS) {
    return p.join(
      Platform.environment['HOME']!,
      'Library',
      'Application Support',
      oldFolder,
    );
  }
  return null;
}
