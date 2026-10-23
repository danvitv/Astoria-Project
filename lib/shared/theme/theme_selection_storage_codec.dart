import 'theme_preset.dart';
import 'theme_selection.dart';

/// Strict installed-preset decoding. Ordinary import/load migration remains
/// permissive; an assistant precondition must not mistake corrupt fallback for
/// known content. Missing optional legacy fields use their documented defaults.
List<ThemePreset> decodeThemeSelectionPresets(Object? value) {
  if (value is! List) throw const ThemeSelectionInvalidStorage();
  final template = const ThemePreset(id: '', name: '').toJson();
  const nullableBooleans = {
    'hideMessageId',
    'hideGenerationTime',
    'hideTokenCount',
  };
  const fontSizes = {'uiFontSize', 'chatFontSize'};
  final result = <ThemePreset>[];
  for (final row in value) {
    if (row is! Map<String, dynamic> ||
        row['id'] is! String ||
        row['name'] is! String) {
      throw const ThemeSelectionInvalidStorage();
    }
    for (final entry in row.entries) {
      final key = entry.key;
      final field = entry.value;
      if (key == 'bgOpacity') {
        if (field is! num || !field.isFinite) {
          throw const ThemeSelectionInvalidStorage();
        }
        continue;
      }
      if (!template.containsKey(key)) {
        throw const ThemeSelectionInvalidStorage();
      }
      final sample = template[key];
      final valid = fontSizes.contains(key)
          ? field is String || (field is num && field.isFinite)
          : nullableBooleans.contains(key)
          ? field == null || field is bool
          : sample == null
          ? field == null || field is String
          : sample is int
          ? field is int
          : sample is num
          ? field is num && field.isFinite
          : sample is bool
          ? field is bool
          : field is String;
      if (!valid) throw const ThemeSelectionInvalidStorage();
    }
    try {
      result.add(themePresetFromStoredJson(row));
    } catch (_) {
      throw const ThemeSelectionInvalidStorage();
    }
  }
  return result;
}
