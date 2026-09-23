import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

const _legacyProductName = 'glaze_flutter';
const _currentProductName = 'Glaze';
const _migrationMarkerName = '.windows-prefs-product-name-v1';
const _astoriaMigrationMarkerName = '.windows-prefs-astoria-v1';

Future<void> migrateLegacyWindowsPreferences({
  Map<String, String>? environment,
}) async {
  if (!Platform.isWindows && environment == null) return;

  final appData = (environment ?? Platform.environment)['APPDATA'];
  if (appData == null || appData.isEmpty) return;

  final marker = File(p.join(appData, 'Glaze', _migrationMarkerName));
  if (await marker.exists()) return;

  final legacy = File(
    p.join(appData, 'com.glaze', _legacyProductName, 'shared_preferences.json'),
  );
  final current = File(
    p.join(
      appData,
      'com.glaze',
      _currentProductName,
      'shared_preferences.json',
    ),
  );

  if (await legacy.exists()) {
    final legacyValues = await _readPreferences(legacy);
    final currentValues = await _readPreferences(current);
    if (legacyValues != null) {
      await current.parent.create(recursive: true);
      await _replaceJsonFile(current, {...?currentValues, ...legacyValues});
    }
  }

  await marker.parent.create(recursive: true);
  await marker.writeAsString('done', flush: true);
}

/// The Windows preferences plugin derives its directory from the executable's
/// CompanyName/ProductName resource. The Astoria rebrand changed both fields.
/// Copy missing keys before SharedPreferences caches the new file; never write
/// to the old install or replace settings the user already changed in Astoria.
Future<void> migrateAstoriaWindowsPreferences({
  Map<String, String>? environment,
}) async {
  if (!Platform.isWindows && environment == null) return;
  final appData = (environment ?? Platform.environment)['APPDATA'];
  if (appData == null || appData.isEmpty) return;

  final current = File(
    p.join(appData, 'Astoria Project', 'Astoria', 'shared_preferences.json'),
  );
  final marker = File(p.join(current.parent.path, _astoriaMigrationMarkerName));
  if (await marker.exists()) return;

  final oldGlaze = File(
    p.join(appData, 'com.glaze', 'Glaze', 'shared_preferences.json'),
  );
  final oldFlutter = File(
    p.join(appData, 'com.glaze', 'glaze_flutter', 'shared_preferences.json'),
  );
  final existing = await _readPreferences(current);
  final glazeValues = await _readPreferences(oldGlaze);
  final flutterValues = await _readPreferences(oldFlutter);
  // Do not mark the migration complete if the old preferences are not present
  // yet (or could not be parsed); a later launch may find them.
  if (existing == null ||
      (await current.exists() && await current.length() == 0) ||
      (glazeValues == null && flutterValues == null) ||
      ((glazeValues?.isEmpty ?? true) && (flutterValues?.isEmpty ?? true))) {
    return;
  }

  // The old app registration and cloud root are different. Transfer user
  // settings, but do not reuse its OAuth, manifest or auto-sync state.
  bool isOldSyncState(String key) =>
      key.startsWith('flutter.gz_sync_') || key.startsWith('gz_sync_');
  final oldSettings = <String, dynamic>{...?flutterValues, ...?glazeValues}
    ..removeWhere((key, _) => isOldSyncState(key));
  final merged = <String, dynamic>{...oldSettings, ...existing};
  await current.parent.create(recursive: true);
  if (merged.length != existing.length) {
    await _replaceJsonFile(current, merged);
  }
  await marker.writeAsString('done', flush: true);
}

Future<Map<String, dynamic>?> _readPreferences(File file) async {
  if (!await file.exists()) return <String, dynamic>{};
  try {
    final decoded = jsonDecode(await file.readAsString());
    return decoded is Map ? Map<String, dynamic>.from(decoded) : null;
  } on FormatException {
    return null;
  }
}

Future<void> _replaceJsonFile(
  File destination,
  Map<String, dynamic> values,
) async {
  final temporary = File('${destination.path}.migration.tmp');
  await temporary.writeAsString(jsonEncode(values), flush: true);

  final backup = File('${destination.path}.before-product-name-migration');
  if (await destination.exists()) {
    if (await backup.exists()) await backup.delete();
    await destination.rename(backup.path);
  }
  try {
    await temporary.rename(destination.path);
  } catch (_) {
    if (await backup.exists() && !await destination.exists()) {
      await backup.rename(destination.path);
    }
    rethrow;
  }
}
