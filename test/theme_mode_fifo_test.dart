import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_mode_test_fixture.dart';
import 'theme_selection_test_store.dart';

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await createModeHarness());
  tearDown(() => h.dispose());

  test(
    'mode observation flushes ordinary debounce through actual notifier FIFO',
    () async {
      final edited = modeActive.copyWith(name: 'Latest ordinary edit');
      await h.notifier.updatePreset(edited);
      final save = ThemeSelectionGate();
      h.store.saveGates.add(save);
      final planFuture = h.modePlan('system');
      await save.started.future;
      expect(h.store.savedLists, hasLength(1));
      expect(h.store.checkedModeWrites, isEmpty);
      expect(h.store.freshReads, 0);
      save.release.complete();
      final plan = await planFuture;
      expect(plan.before.name, edited.name);
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.applied);
      expect(h.store.backing.presets[1], edited.copyWith(themeMode: 'system'));
      expect(h.store.checkedModeWrites, hasLength(1));
    },
  );

  test(
    'ordinary admission while queued mode read denies before user write',
    () async {
      final plan = await h.modePlan();
      final read = ThemeSelectionGate();
      h.store.freshReadGates.add(read);
      final future = h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      await read.started.future;
      final ordinary = h.notifier.applyPreset(selectionB);
      read.release.complete();
      final result = await future;
      await ordinary;
      expect(result.code, ThemeSelectionCode.conflict);
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedModeWrites, isEmpty);
      expect(h.store.ordinaryWrites, ['b']);
      expect(h.store.backing.activeId, 'b');
    },
  );

  test(
    'mode completion observes original effect before queued ordinary edit',
    () async {
      final plan = await h.modePlan();
      final modeWrite = ThemeSelectionGate();
      final ordinarySave = ThemeSelectionGate();
      h.store.modeWriteGates.add(modeWrite);
      h.store.saveGates.add(ordinarySave);
      final future = h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      await modeWrite.started.future;
      final userEdit = modeActive.copyWith(
        name: 'User edit wins',
        chatFont: 'USER_NEW_FONT_CANARY',
        bgImage: 'USER_NEW_IMAGE_CANARY',
      );
      await h.notifier.updatePreset(userEdit);
      final flush = h.notifier.flushPersistence();
      await pumpEventQueue();
      expect(
        h.store.savedLists,
        isEmpty,
        reason: 'ordinary save remains behind mode',
      );
      expect(h.notifier.state.activePreset, userEdit);
      modeWrite.release.complete();
      final result = await future;
      await ordinarySave.started.future;
      expect(result.code, ThemeSelectionCode.applied);
      expect(result.freshObserved, ThemeSelectionFreshObservation.after);
      expect(result.ownerCurrent, isFalse);
      expect(result.receipt, isNotNull);
      expect(h.store.backing.presets, modeList('light'));
      expect(h.notifier.state.activePreset, userEdit);
      ordinarySave.release.complete();
      await flush;
      expect(h.store.backing.presets[1], userEdit);
      final undo = await h.notifier.undoInstalledSelection(
        result.receipt!,
        isCurrent: () => true,
      );
      expect(undo.code, ThemeSelectionCode.conflict);
      expect(undo.effectStarted, isFalse);
      expect(h.store.backing.presets[1], userEdit);
      expect(h.store.checkedModeWrites, hasLength(1));
    },
  );

  for (final operation in ['Apply', 'Undo']) {
    for (final aba in ['selection', 'same full content']) {
      test(
        '$operation denies ordinary $aba ABA even with exact final contents',
        () async {
          final plan = await h.modePlan();
          ThemeSelectionReceipt? receipt;
          if (operation == 'Undo') {
            receipt = (await h.notifier.applyInstalledSelection(
              plan,
              isCurrent: () => true,
            )).receipt!;
          }
          final original = h.notifier.state.activePreset;
          if (aba == 'selection') {
            await h.notifier.applyPreset(selectionC);
            await h.notifier.applyPreset(original);
          } else {
            await h.notifier.updatePreset(
              original.copyWith(name: 'Temporary edit'),
            );
            await h.notifier.updatePreset(original);
            await h.notifier.flushPersistence();
          }
          final snapshot = List.of(h.store.backing.presets);
          final result = operation == 'Undo'
              ? await h.notifier.undoInstalledSelection(
                  receipt!,
                  isCurrent: () => true,
                )
              : await h.notifier.applyInstalledSelection(
                  plan,
                  isCurrent: () => true,
                );
          expect(result.code, ThemeSelectionCode.conflict);
          expect(result.effectStarted, isFalse);
          expect(h.store.backing.presets, snapshot);
          expect(h.store.backing.activeId, 'a');
          expect(
            h.store.checkedModeWrites,
            hasLength(operation == 'Undo' ? 1 : 0),
          );
        },
      );
    }
  }

  test(
    'queued Undo denies ordinary full edit admitted at its fresh read',
    () async {
      final applied = await h.notifier.applyInstalledSelection(
        await h.modePlan(),
        isCurrent: () => true,
      );
      final read = ThemeSelectionGate();
      h.store.freshReadGates.add(read);
      final future = h.notifier.undoInstalledSelection(
        applied.receipt!,
        isCurrent: () => true,
      );
      await read.started.future;
      final edited = h.notifier.state.activePreset.copyWith(
        chatBgImage: 'USER_NEW_CHAT_BACKGROUND_CANARY',
      );
      await h.notifier.updatePreset(edited);
      read.release.complete();
      expect((await future).code, ThemeSelectionCode.conflict);
      await h.notifier.flushPersistence();
      expect(h.store.backing.presets[1], edited);
      expect(h.store.checkedModeWrites, hasLength(1));
    },
  );

  test(
    'reentrant final approval cannot admit ordinary mutation then write',
    () async {
      final plan = await h.modePlan();
      final expectedRead = h.store.freshReads + 1;
      var changed = false;
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () {
          if (!changed && h.store.freshReads == expectedRead) {
            changed = true;
            h.notifier.setIgnoreCustomFont(true);
          }
          return true;
        },
      );
      expect(result.code, ThemeSelectionCode.conflict);
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedModeWrites, isEmpty);
    },
  );
}
