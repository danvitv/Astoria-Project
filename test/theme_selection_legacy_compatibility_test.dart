import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_selection_test_store.dart';

void main() {
  test(
    'legacy interface-only store still supports ordinary Apply and debounce',
    () async {
      final backing = ThemeSelectionBacking();
      final delegate = ThemeSelectionTestStore(backing);
      final delays = <Completer<void>>[];
      final notifier = ThemeNotifier(
        storage: _LegacyStore(delegate),
        delay: (_) {
          final delay = Completer<void>();
          delays.add(delay);
          return delay.future;
        },
      );
      try {
        await notifier.flushPersistence();
        expect(
          (await notifier.observeInstalledThemes(isCurrent: () => true)).code,
          ThemeSelectionCode.unsupportedStorage,
        );
        await notifier.applyPreset(selectionB);
        expect(backing.activeId, 'b');
        final first = selectionB.copyWith(name: 'First');
        final latest = selectionB.copyWith(name: 'Latest');
        unawaited(notifier.updatePreset(first));
        unawaited(notifier.updatePreset(latest));
        expect(notifier.state.activePreset, latest);
        expect(delegate.savedLists, isEmpty);
        await notifier.flushPersistence();
        expect(delegate.savedLists, hasLength(1));
        expect(backing.presets.firstWhere((p) => p.id == 'b'), latest);
        expect(delegate.checkedWrites, isEmpty);
      } finally {
        notifier.dispose();
        for (final delay in delays) {
          delay.complete();
        }
      }
    },
  );
}

// Intentionally does NOT implement the additive ThemeSelectionStore interface.
class _LegacyStore implements ThemePresetStore {
  _LegacyStore(this.delegate);
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
}
