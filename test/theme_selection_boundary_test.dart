import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_selection_test_store.dart';

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await ThemeSelectionHarness.create());
  tearDown(() => h.dispose());

  test(
    'one persisted Apply and one conditional Undo, no whole-list write',
    () async {
      final plan = await h.plan();
      final applied = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(applied.code, ThemeSelectionCode.applied);
      expect(applied.writeAccepted, isTrue);
      expect(applied.effectStarted, isTrue);
      expect(applied.freshObserved, ThemeSelectionFreshObservation.after);
      expect(h.store.backing.activeId, 'b');
      expect(h.notifier.state.activePreset, selectionB);
      expect(
        (await h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => true,
        )).code,
        ThemeSelectionCode.alreadyConsumed,
      );
      final receipt = applied.receipt!;
      final undone = await h.notifier.undoInstalledSelection(
        receipt,
        isCurrent: () => true,
      );
      expect(undone.code, ThemeSelectionCode.applied);
      expect(h.store.backing.activeId, 'a');
      expect(h.notifier.state.activePreset, selectionA);
      expect(
        (await h.notifier.undoInstalledSelection(
          receipt,
          isCurrent: () => true,
        )).code,
        ThemeSelectionCode.alreadyConsumed,
      );
      expect(h.store.checkedWrites, ['b', 'a']);
      expect(h.store.savedLists, isEmpty);
      expect(h.store.backing.presets, [selectionA, selectionB, selectionC]);
    },
  );

  test(
    'no-op consumes plan but starts no write and supplies no Undo receipt',
    () async {
      final plan = await h.plan('a');
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.noOp);
      expect(result.effectStarted, isFalse);
      expect(result.receipt, isNull);
      expect(h.store.checkedWrites, isEmpty);
    },
  );

  test('old same-owner ABA Undo never overwrites ordinary selection', () async {
    final applied = await h.notifier.applyInstalledSelection(
      await h.plan(),
      isCurrent: () => true,
    );
    await h.notifier.applyPreset(selectionC);
    await h.notifier.applyPreset(selectionB);
    final result = await h.notifier.undoInstalledSelection(
      applied.receipt!,
      isCurrent: () => true,
    );
    expect(result.effectStarted, isFalse);
    expect(h.store.checkedWrites, ['b']);
    expect(h.store.backing.activeId, 'b');
  });

  for (final mutation in [
    'prior edit',
    'target edit',
    'prior delete',
    'target delete',
  ]) {
    test(
      'Undo rejects ordinary $mutation without recreating presets',
      () async {
        final applied = await h.notifier.applyInstalledSelection(
          await h.plan(),
          isCurrent: () => true,
        );
        if (mutation.endsWith('edit')) {
          final preset = mutation.startsWith('prior') ? selectionA : selectionB;
          await h.notifier.importPreset(preset.copyWith(name: 'Changed'));
        } else {
          await h.notifier.deletePreset(
            mutation.startsWith('prior') ? 'a' : 'b',
          );
        }
        final listBefore = List.of(h.store.backing.presets);
        final activeBefore = h.store.backing.activeId;
        final result = await h.notifier.undoInstalledSelection(
          applied.receipt!,
          isCurrent: () => true,
        );
        expect(result.effectStarted, isFalse);
        expect(h.store.checkedWrites, ['b']);
        expect(h.store.backing.presets, listBefore);
        expect(h.store.backing.activeId, activeBefore);
      },
    );
  }

  for (final field in ['mode', 'accent', 'font override']) {
    test('ordinary $field admission invalidates reviewed plan', () async {
      final plan = await h.plan();
      switch (field) {
        case 'mode':
          await h.notifier.setMode(ThemeMode.light);
        case 'accent':
          await h.notifier.setAccentColor(const Color(0xFFABCDEF));
        case 'font override':
          h.notifier.setIgnoreCustomFont(true);
      }
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedWrites, isEmpty);
    });
  }

  test(
    'fresh target-content change in bypassed backing is a conflict',
    () async {
      final plan = await h.plan();
      h.store.backing.presets[1] = selectionB.copyWith(
        customFont: 'SYNTHETIC_FONT_CANARY',
        bgImage: 'SYNTHETIC_IMAGE_CANARY',
      );
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.conflict);
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedWrites, isEmpty);
      expect(result.toString(), isNot(contains('SYNTHETIC_FONT_CANARY')));
    },
  );

  test(
    'fresh prior-content deletion in bypassed backing denies Undo',
    () async {
      final applied = await h.notifier.applyInstalledSelection(
        await h.plan(),
        isCurrent: () => true,
      );
      h.store.backing.presets.removeWhere((p) => p.id == 'a');
      final result = await h.notifier.undoInstalledSelection(
        applied.receipt!,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.conflict);
      expect(h.store.checkedWrites, ['b']);
      expect(h.store.backing.presets.any((p) => p.id == 'a'), isFalse);
    },
  );

  test(
    'new owners reconstruct observations but cannot reuse plan or receipt',
    () async {
      final plan = await h.plan();
      final applied = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      final backing = h.store.backing;
      h.dispose();
      h = await ThemeSelectionHarness.create(backing);
      final observed = await h.notifier.observeInstalledThemes(
        isCurrent: () => true,
      );
      expect(observed.observation!.active.id, 'b');
      expect(h.store.checkedWrites, isEmpty);
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
      expect(h.store.checkedWrites, isEmpty);
    },
  );
}
