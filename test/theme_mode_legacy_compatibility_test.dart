import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';

import 'theme_selection_test_store.dart';

void main() {
  test(
    'selection-only capability stays supported; checked mode is fail-closed',
    () async {
      final delegate = ThemeSelectionTestStore(ThemeSelectionBacking());
      final notifier = ThemeNotifier(storage: _SelectionOnlyStore(delegate));
      try {
        await notifier.flushPersistence();
        final read = await notifier.observeInstalledThemes(
          isCurrent: () => true,
        );
        expect(read.code, ThemeSelectionCode.ready);
        final mode = read.observation!.planForMode('system')!;
        final result = await notifier.applyInstalledSelection(
          mode,
          isCurrent: () => true,
        );
        expect(result.code, ThemeSelectionCode.unsupportedStorage);
        expect(result.effectStarted, isFalse);
        expect(result.receipt, isNull);
        expect(delegate.checkedModeWrites, isEmpty);
        expect(delegate.checkedWrites, isEmpty);
        expect(delegate.savedLists, isEmpty);
        expect(delegate.backing.presets, [selectionA, selectionB, selectionC]);
        expect(delegate.backing.activeId, 'a');
        final selection = await notifier.applyInstalledSelection(
          read.observation!.planFor('b')!,
          isCurrent: () => true,
        );
        expect(selection.code, ThemeSelectionCode.applied);
        expect(selection.receipt!.operation, ThemeSelectionOperation.selection);
        expect(delegate.checkedWrites, ['b']);
        expect(delegate.checkedModeWrites, isEmpty);
      } finally {
        notifier.dispose();
      }
    },
  );
}

// Intentionally has no ThemeModeStore, even though its independent delegate does.
class _SelectionOnlyStore implements ThemePresetStore, ThemeSelectionStore {
  _SelectionOnlyStore(this.delegate);
  final ThemeSelectionTestStore delegate;
  @override
  Future<List<ThemePreset>> loadAll() => delegate.loadAll();
  @override
  Future<String> loadActiveId() => delegate.loadActiveId();
  @override
  Future<void> saveAll(List<ThemePreset> presets) => delegate.saveAll(presets);
  @override
  Future<void> setActive(String id) => delegate.setActive(id);
  @override
  Future<void> addPreset(ThemePreset preset) => delegate.addPreset(preset);
  @override
  Future<void> removePreset(String id) => delegate.removePreset(id);
  @override
  Future<ThemePreset> importFromFile(String path) =>
      delegate.importFromFile(path);
  @override
  Future<ThemeSelectionStoredState> readSelectionFresh() =>
      delegate.readSelectionFresh();
  @override
  Future<bool> setActiveChecked(String id) => delegate.setActiveChecked(id);
}
