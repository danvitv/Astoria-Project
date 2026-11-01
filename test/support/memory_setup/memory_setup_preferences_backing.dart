// Existing plugin seam; no platform channels or external preferences.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

final class MemorySetupPreferencesBacking
    extends SharedPreferencesStorePlatform {
  MemorySetupPreferencesBacking(Map<String, Object> initial)
    : values = {for (final e in initial.entries) 'flutter.${e.key}': e.value};
  final Map<String, Object> values;
  Future<void> Function(String)? beforeWrite;
  String? rejected, thrown;
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    await beforeWrite?.call(key);
    values[key] = value; // Deliberately persist even on false/throw.
    if (thrown == key) throw StateError('SYNTHETIC_WIZARD_WRITE_AFTER_PERSIST');
    return rejected != key;
  }

  @override
  Future<bool> remove(String key) async {
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    values.clear();
    return true;
  }
}
