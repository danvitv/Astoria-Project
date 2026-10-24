import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';

final class AppControlMemoryTheme
    implements ThemePresetStore, ThemeSelectionStore, ThemeModeStore {
  List<ThemePreset> presets = [
    const ThemePreset(
      id: 'default',
      name: 'Default',
      accentColor: '#F5C400',
      themeMode: 'dark',
    ),
    const ThemePreset(
      id: 'synthetic-night',
      name: 'Synthetic Night',
      accentColor: '#112233',
      themeMode: 'dark',
    ),
  ];
  String activeId = 'default';
  int checkedWrites = 0;
  Future<void> Function()? beforeFresh;
  @override
  Future<List<ThemePreset>> loadAll() async => List.of(presets);
  @override
  Future<String> loadActiveId() async => activeId;
  @override
  Future<void> saveAll(List<ThemePreset> values) async {
    presets = List.of(values);
  }

  @override
  Future<void> setActive(String id) async {
    activeId = id;
  }

  @override
  Future<void> addPreset(ThemePreset preset) async {
    presets = [...presets, preset];
  }

  @override
  Future<void> removePreset(String id) async {
    presets.removeWhere((p) => p.id == id);
  }

  @override
  Future<ThemePreset> importFromFile(String path) =>
      throw StateError('Synthetic no-file fixture.');
  @override
  Future<ThemeSelectionStoredState> readSelectionFresh() async {
    await beforeFresh?.call();
    return ThemeSelectionStoredState(presets: presets, activeId: activeId);
  }

  @override
  Future<bool> setActiveChecked(String id) {
    checkedWrites++;
    activeId = id;
    return Future.value(true);
  }

  @override
  Future<bool> saveAllChecked(List<ThemePreset> values) {
    checkedWrites++;
    presets = List.of(values);
    return Future.value(true);
  }
}
