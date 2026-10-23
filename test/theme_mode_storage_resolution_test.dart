import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_mode_test_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final legacy in ThemeMode.values) {
    for (final entry in {
      'dark': ThemeMode.dark,
      'light': ThemeMode.light,
      'system': ThemeMode.system,
    }.entries) {
      test(
        'explicit ${entry.key} resolves ${entry.value}, ignores legacy $legacy',
        () {
          final settings = ThemeSettings(
            mode: legacy,
            activePreset: modeActive.copyWith(themeMode: entry.key),
          );
          expect(settings.resolvedMode, entry.value);
        },
      );
    }
    test('unknown preset mode alone falls back to legacy $legacy', () {
      final settings = ThemeSettings(
        mode: legacy,
        activePreset: modeActive.copyWith(themeMode: 'legacy-unknown'),
      );
      expect(settings.resolvedMode, legacy);
    });
  }

  for (final entry in {
    'light': ThemeMode.light,
    'system': ThemeMode.system,
  }.entries) {
    test(
      'actual storage ${entry.key} survives fresh reload and resolves in owner',
      () async {
        // Only the isolated preferences mock is initialized or read in this test.
        // No persistent user preferences/plugin backend is used.
        SharedPreferences.setMockInitialValues({
          'theme_presets': jsonEncode(
            modeList('dark').map((p) => p.toJson()).toList(),
          ),
          'theme_active_preset': 'a',
        });
        final prefs = await SharedPreferences.getInstance();
        final storage = ThemePresetStorage(prefs);
        final notifier = ThemeNotifier(storage: storage);
        ThemeNotifier? replacement;
        try {
          await notifier.flushPersistence();
          final before = await storage.readSelectionFresh();
          final read = await notifier.observeInstalledThemes(
            isCurrent: () => true,
          );
          final applied = await notifier.applyInstalledSelection(
            read.observation!.planForMode(entry.key)!,
            isCurrent: () => true,
          );
          expect(applied.code, ThemeSelectionCode.applied);
          expect(applied.freshObserved, ThemeSelectionFreshObservation.after);
          expect(notifier.state.mode, ThemeMode.dark);
          expect(notifier.state.resolvedMode, entry.value);
          final expected = before.presets
              .map((p) => p.id == 'a' ? p.copyWith(themeMode: entry.key) : p)
              .toList();
          final fresh = await storage.readSelectionFresh();
          expect(fresh.activeId, 'a');
          expect(fresh.presets, expected);
          expect(fresh.active.copyWith(themeMode: 'dark'), modeActive);
          expect(
            jsonDecode(prefs.getString('theme_presets')!),
            expected.map((preset) => preset.toJson()).toList(),
          );
          expect(prefs.getString('theme_active_preset'), 'a');
          replacement = ThemeNotifier(storage: ThemePresetStorage(prefs));
          await replacement.flushPersistence();
          expect(replacement.state.activePreset, fresh.active);
          expect(replacement.state.presets, expected);
          expect(replacement.state.resolvedMode, entry.value);
          expect(
            (await replacement.undoInstalledSelection(
              applied.receipt!,
              isCurrent: () => true,
            )).code,
            ThemeSelectionCode.ownerChanged,
          );
          final undone = await notifier.undoInstalledSelection(
            applied.receipt!,
            isCurrent: () => true,
          );
          expect(undone.code, ThemeSelectionCode.applied);
          expect((await storage.readSelectionFresh()).presets, before.presets);
          expect(notifier.state.resolvedMode, ThemeMode.dark);
          expect(notifier.state.presets, before.presets);
        } finally {
          replacement?.dispose();
          notifier.dispose();
        }
      },
    );
  }
}
