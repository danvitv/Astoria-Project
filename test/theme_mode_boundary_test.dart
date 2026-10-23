import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_mode_test_fixture.dart';
import 'theme_selection_test_store.dart';

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await createModeHarness());
  tearDown(() => h.dispose());

  test(
    'mode accepts only exact supported values; selection defaults unchanged',
    () async {
      final read = await h.notifier.observeInstalledThemes(
        isCurrent: () => true,
      );
      final observation = read.observation!;
      for (final mode in ['dark', 'light', 'system']) {
        final plan = observation.planForMode(mode)!;
        expect(plan.operation, ThemeSelectionOperation.mode);
        expect(plan.before.id, 'a');
        expect(plan.after.id, 'a');
        expect(plan.after.mode, mode);
        expect(plan.after.accent, modeActive.accentColor);
      }
      for (final invalid in ['', 'auto', 'LIGHT', ' light', 'system ']) {
        expect(observation.planForMode(invalid), isNull);
      }
      expect(
        observation.planFor('b')!.operation,
        ThemeSelectionOperation.selection,
      );
    },
  );

  for (final mode in ['light', 'system']) {
    test(
      '$mode Apply/Undo preserves every field, other row and order',
      () async {
        final plan = await h.modePlan(mode);
        final before = List.of(h.store.backing.presets);
        final applied = await h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => true,
        );
        expect(applied.code, ThemeSelectionCode.applied);
        expect(applied.writeAccepted, isTrue);
        expect(applied.freshObserved, ThemeSelectionFreshObservation.after);
        expect(applied.ownerCurrent, isTrue);
        expect(applied.receipt!.operation, ThemeSelectionOperation.mode);
        expect(h.store.backing.activeId, 'a');
        expect(h.store.backing.presets, modeList(mode));
        expect(h.store.checkedModeWrites, [modeList(mode)]);
        expect(h.store.checkedWrites, isEmpty);
        expect(h.store.ordinaryWrites, isEmpty);
        expect(h.store.savedLists, isEmpty);
        expect(
          h.notifier.state.activePreset.copyWith(themeMode: 'dark'),
          modeActive,
        );
        expect(h.notifier.state.presets, modeList(mode));
        expect(h.notifier.state.accentColor, modeActive.accent);
        expect(
          () => h.store.checkedModeWrites.single.add(selectionA),
          throwsUnsupportedError,
        );
        final undone = await h.notifier.undoInstalledSelection(
          applied.receipt!,
          isCurrent: () => true,
        );
        expect(undone.code, ThemeSelectionCode.applied);
        expect(undone.receipt!.operation, ThemeSelectionOperation.mode);
        expect(h.store.backing.presets, before);
        expect(h.store.backing.activeId, 'a');
        expect(h.notifier.state.activePreset, modeActive);
        expect(h.notifier.state.presets, before);
        expect(h.store.checkedModeWrites, [modeList(mode), before]);
        expect(
          (await h.notifier.applyInstalledSelection(
            plan,
            isCurrent: () => true,
          )).code,
          ThemeSelectionCode.alreadyConsumed,
        );
        expect(
          (await h.notifier.undoInstalledSelection(
            applied.receipt!,
            isCurrent: () => true,
          )).code,
          ThemeSelectionCode.alreadyConsumed,
        );
        expect(h.store.checkedModeWrites, hasLength(2));
      },
    );
  }

  test(
    'already-current mode consumes plan without write or synthetic receipt',
    () async {
      final plan = await h.modePlan('dark');
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.noOp);
      expect(result.effectStarted, isFalse);
      expect(result.writeAcceptance, ThemeSelectionWriteAcceptance.notStarted);
      expect(result.freshObserved, ThemeSelectionFreshObservation.before);
      expect(result.receipt, isNull);
      expect(h.store.checkedModeWrites, isEmpty);
      expect(h.store.checkedWrites, isEmpty);
      expect(
        (await h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => true,
        )).code,
        ThemeSelectionCode.alreadyConsumed,
      );
    },
  );

  test(
    'mode preserves independently selected accent rather than resetting it',
    () async {
      const accent = Color(0xFFABCDEF);
      await h.notifier.setAccentColor(accent);
      final result = await h.notifier.applyInstalledSelection(
        await h.modePlan(),
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.applied);
      expect(h.notifier.state.accentColor, accent);
      expect(h.notifier.state.activePreset.accentColor, modeActive.accentColor);
      final undone = await h.notifier.undoInstalledSelection(
        result.receipt!,
        isCurrent: () => true,
      );
      expect(undone.code, ThemeSelectionCode.applied);
      expect(h.notifier.state.accentColor, accent);
    },
  );

  test('foreign owners cannot reuse mode plan or original receipt', () async {
    final plan = await h.modePlan();
    final applied = await h.notifier.applyInstalledSelection(
      plan,
      isCurrent: () => true,
    );
    final backing = h.store.backing;
    h.dispose();
    h = await ThemeSelectionHarness.create(backing);
    expect((await h.modePlan('system')).before.mode, 'light');
    expect(
      (await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      )).code,
      ThemeSelectionCode.ownerChanged,
    );
    expect(
      (await h.notifier.undoInstalledSelection(
        applied.receipt!,
        isCurrent: () => true,
      )).code,
      ThemeSelectionCode.ownerChanged,
    );
    expect(h.store.checkedModeWrites, isEmpty);
    expect(h.store.backing.presets, modeList('light'));
  });

  test('mode and selection plans share a revision fence', () async {
    final read = await h.notifier.observeInstalledThemes(isCurrent: () => true);
    final selection = read.observation!.planFor('b')!;
    final mode = read.observation!.planForMode('light')!;
    expect(
      (await h.notifier.applyInstalledSelection(
        mode,
        isCurrent: () => true,
      )).code,
      ThemeSelectionCode.applied,
    );
    expect(
      (await h.notifier.applyInstalledSelection(
        selection,
        isCurrent: () => true,
      )).code,
      ThemeSelectionCode.conflict,
    );
    expect(h.store.checkedWrites, isEmpty);
  });

  test('installed selection also fences a reviewed mode plan', () async {
    final read = await h.notifier.observeInstalledThemes(isCurrent: () => true);
    final mode = read.observation!.planForMode('system')!;
    final selected = await h.notifier.applyInstalledSelection(
      read.observation!.planFor('b')!,
      isCurrent: () => true,
    );
    expect(selected.code, ThemeSelectionCode.applied);
    final result = await h.notifier.applyInstalledSelection(
      mode,
      isCurrent: () => true,
    );
    expect(result.code, ThemeSelectionCode.conflict);
    expect(result.effectStarted, isFalse);
    expect(h.store.checkedModeWrites, isEmpty);
    expect(h.store.checkedWrites, ['b']);
    expect(h.store.backing.presets, modeList('dark'));
  });

  test(
    'concurrent reuse of a mode plan admits exactly one checked invocation',
    () async {
      final plan = await h.modePlan();
      final write = ThemeSelectionGate();
      h.store.modeWriteGates.add(write);
      final first = h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      final duplicate = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(duplicate.code, ThemeSelectionCode.alreadyConsumed);
      await write.started.future;
      expect(h.store.checkedModeWrites, hasLength(1));
      write.release.complete();
      expect((await first).code, ThemeSelectionCode.applied);
      expect(h.store.checkedModeWrites, hasLength(1));
    },
  );
}
