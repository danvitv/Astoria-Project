import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_mode_test_fixture.dart';
import 'theme_selection_test_store.dart';

void _changeBacking(ThemeSelectionBacking backing, String change) {
  switch (change) {
    case 'active full content':
      final index = backing.presets.indexWhere((preset) => preset.id == 'a');
      backing.presets[index] = backing.presets[index].copyWith(
        chatFont: 'USER_NEW_FONT_CANARY',
        hideTokenCount: false,
      );
    case 'other edit':
      backing.presets[0] = selectionC.copyWith(
        bgImage: 'USER_OTHER_IMAGE_CANARY',
      );
    case 'reorder':
      backing.presets = backing.presets.reversed.toList();
    case 'add':
      backing.presets.add(selectionB.copyWith(id: 'new', name: 'New'));
    case 'other delete':
      backing.presets.removeWhere((preset) => preset.id == 'b');
    case 'active selection':
      backing.activeId = 'c';
    case 'active delete':
      backing.presets.removeWhere((preset) => preset.id == 'a');
      backing.activeId = 'c';
  }
}

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await createModeHarness());
  tearDown(() => h.dispose());

  const changes = [
    'active full content',
    'other edit',
    'reorder',
    'add',
    'other delete',
    'active selection',
    'active delete',
  ];
  for (final change in changes) {
    test(
      'fresh $change before mode write denies full-list replacement',
      () async {
        final plan = await h.modePlan();
        final gate = ThemeSelectionGate();
        h.store.freshReadGates.add(gate);
        final future = h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => true,
        );
        await gate.started.future;
        _changeBacking(h.store.backing, change);
        final userList = List.of(h.store.backing.presets);
        final userActive = h.store.backing.activeId;
        gate.release.complete();
        final result = await future;
        expect(result.code, ThemeSelectionCode.conflict);
        expect(result.effectStarted, isFalse);
        expect(result.receipt, isNull);
        expect(h.store.checkedModeWrites, isEmpty);
        expect(h.store.checkedWrites, isEmpty);
        expect(h.store.backing.presets, userList);
        expect(h.store.backing.activeId, userActive);
      },
    );

    test(
      'fresh $change during mode write is separate verification conflict',
      () async {
        final plan = await h.modePlan();
        final gate = ThemeSelectionGate();
        h.store.modeWriteGates.add(gate);
        h.store.afterCheckedModeWrite = () =>
            _changeBacking(h.store.backing, change);
        final future = h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => true,
        );
        await gate.started.future;
        expect(h.store.checkedModeWrites, [modeList('light')]);
        expect(h.store.backing.presets, modeList('dark'));
        expect(h.notifier.state.presets, modeList('dark'));
        gate.release.complete();
        final result = await future;
        expect(result.code, ThemeSelectionCode.verificationConflict);
        expect(result.effectStarted, isTrue);
        expect(result.writeAccepted, isTrue);
        expect(result.freshObserved, ThemeSelectionFreshObservation.other);
        expect(result.receipt, isNull);
        expect(h.notifier.state.presets, modeList('dark'));
        expect(h.store.checkedModeWrites, hasLength(1));
        expect(h.store.checkedWrites, isEmpty);
      },
    );

    test(
      'original mode Undo denies fresh $change and retains user snapshot',
      () async {
        final applied = await h.notifier.applyInstalledSelection(
          await h.modePlan(),
          isCurrent: () => true,
        );
        _changeBacking(h.store.backing, change);
        final userList = List.of(h.store.backing.presets);
        final userActive = h.store.backing.activeId;
        final result = await h.notifier.undoInstalledSelection(
          applied.receipt!,
          isCurrent: () => true,
        );
        expect(result.code, ThemeSelectionCode.conflict);
        expect(result.effectStarted, isFalse);
        expect(h.store.checkedModeWrites, hasLength(1));
        expect(h.store.backing.presets, userList);
        expect(h.store.backing.activeId, userActive);
      },
    );
  }

  test(
    'observation owns ordered contents independent of backing list mutation',
    () async {
      final read = await h.notifier.observeInstalledThemes(
        isCurrent: () => true,
      );
      final observation = read.observation!;
      h.store.backing.presets[0] = selectionC.copyWith(
        name: 'Changed after read',
      );
      final plan = observation.planForMode('system')!;
      expect(observation.installed.first.name, 'C');
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.conflict);
      expect(h.store.checkedModeWrites, isEmpty);
    },
  );

  test('same active ID with old mode is BEFORE, not synthetic AFTER', () async {
    final plan = await h.modePlan();
    h.store.checkedModeOutcomes.add(
      ThemeSelectionSyntheticWrite.acceptedWithoutWrite,
    );
    final result = await h.notifier.applyInstalledSelection(
      plan,
      isCurrent: () => true,
    );
    expect(result.code, ThemeSelectionCode.verificationConflict);
    expect(result.freshObserved, ThemeSelectionFreshObservation.before);
    expect(result.receipt, isNull);
    expect(h.store.backing.activeId, plan.after.id);
    expect(h.store.backing.presets, modeList('dark'));
  });
}
