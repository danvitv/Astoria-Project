import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_mode_test_fixture.dart';
import 'theme_selection_test_store.dart';

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await createModeHarness());
  tearDown(() => h.dispose());

  final outcomes =
      <
        ThemeSelectionSyntheticWrite,
        (
          ThemeSelectionCode,
          ThemeSelectionWriteAcceptance,
          ThemeSelectionFreshObservation,
        )
      >{
        ThemeSelectionSyntheticWrite.accepted: (
          ThemeSelectionCode.applied,
          ThemeSelectionWriteAcceptance.accepted,
          ThemeSelectionFreshObservation.after,
        ),
        ThemeSelectionSyntheticWrite.falseBeforeWrite: (
          ThemeSelectionCode.writeRejected,
          ThemeSelectionWriteAcceptance.rejected,
          ThemeSelectionFreshObservation.before,
        ),
        ThemeSelectionSyntheticWrite.throwBeforeWrite: (
          ThemeSelectionCode.writeThrew,
          ThemeSelectionWriteAcceptance.unknown,
          ThemeSelectionFreshObservation.before,
        ),
        ThemeSelectionSyntheticWrite.writeThenThrow: (
          ThemeSelectionCode.writeThrew,
          ThemeSelectionWriteAcceptance.unknown,
          ThemeSelectionFreshObservation.after,
        ),
        ThemeSelectionSyntheticWrite.falseAfterWrite: (
          ThemeSelectionCode.writeRejected,
          ThemeSelectionWriteAcceptance.rejected,
          ThemeSelectionFreshObservation.after,
        ),
        ThemeSelectionSyntheticWrite.acceptedWithoutWrite: (
          ThemeSelectionCode.verificationConflict,
          ThemeSelectionWriteAcceptance.accepted,
          ThemeSelectionFreshObservation.before,
        ),
      };

  for (final undo in [false, true]) {
    for (final entry in outcomes.entries) {
      for (final unreadable in [false, true]) {
        test('${undo ? 'Undo' : 'Apply'} ${entry.key}, unreadable=$unreadable: '
            'acceptance and exact same-ID contents stay separate', () async {
          final plan = await h.modePlan();
          ThemeSelectionReceipt? receipt;
          if (undo) {
            receipt = (await h.notifier.applyInstalledSelection(
              plan,
              isCurrent: () => true,
            )).receipt!;
          }
          h.store.checkedModeOutcomes.add(entry.key);
          if (unreadable) h.store.failAtFreshRead = h.store.freshReads + 2;
          final result = undo
              ? await h.notifier.undoInstalledSelection(
                  receipt!,
                  isCurrent: () => true,
                )
              : await h.notifier.applyInstalledSelection(
                  plan,
                  isCurrent: () => true,
                );
          final acceptance = entry.value.$2;
          final observed = unreadable
              ? ThemeSelectionFreshObservation.unavailable
              : entry.value.$3;
          final code =
              unreadable && acceptance == ThemeSelectionWriteAcceptance.accepted
              ? ThemeSelectionCode.verificationFailed
              : entry.value.$1;
          final verified = !unreadable && code == ThemeSelectionCode.applied;
          expect(result.code, code);
          expect(result.effectStarted, isTrue);
          expect(result.writeAcceptance, acceptance);
          expect(result.freshObserved, observed);
          expect(result.receipt != null, verified);
          final beforeMode = undo ? 'light' : 'dark';
          final afterMode = undo ? 'dark' : 'light';
          final backingMode =
              entry.value.$3 == ThemeSelectionFreshObservation.after
              ? afterMode
              : beforeMode;
          expect(h.store.backing.activeId, 'a');
          expect(h.store.backing.presets, modeList(backingMode));
          if (!unreadable) expect(h.store.cachedPresets, modeList(backingMode));
          expect(
            h.notifier.state.presets,
            modeList(verified ? afterMode : beforeMode),
          );
          expect(h.store.checkedModeWrites, hasLength(undo ? 2 : 1));
          expect(h.store.checkedWrites, isEmpty);
          final again = undo
              ? await h.notifier.undoInstalledSelection(
                  receipt!,
                  isCurrent: () => true,
                )
              : await h.notifier.applyInstalledSelection(
                  plan,
                  isCurrent: () => true,
                );
          expect(again.code, ThemeSelectionCode.alreadyConsumed);
          expect(h.store.checkedModeWrites, hasLength(undo ? 2 : 1));
          expect(
            result.toString(),
            isNot(contains('PRIVATE_EXCEPTION_CANARY')),
          );
        });
      }
    }
  }

  for (final failure in ['malformed', 'throw']) {
    test('$failure before mode invocation fails closed', () async {
      final plan = await h.modePlan();
      if (failure == 'malformed') {
        h.store.backing.malformed = true;
      } else {
        h.store.failAtFreshRead = h.store.freshReads + 1;
      }
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(
        result.code,
        failure == 'malformed'
            ? ThemeSelectionCode.invalidStorage
            : ThemeSelectionCode.readFailed,
      );
      expect(result.effectStarted, isFalse);
      expect(result.receipt, isNull);
      expect(h.store.checkedModeWrites, isEmpty);
      expect(h.store.backing.presets, modeList('dark'));
    });
  }

  test(
    'malformed verification after accepted mode write stays uncertain',
    () async {
      final plan = await h.modePlan();
      h.store.afterCheckedModeWrite = () => h.store.backing.malformed = true;
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.verificationFailed);
      expect(result.writeAccepted, isTrue);
      expect(result.freshObserved, ThemeSelectionFreshObservation.unavailable);
      expect(result.receipt, isNull);
      expect(h.notifier.state.presets, modeList('dark'));
      expect(h.store.backing.presets, modeList('light'));
      expect(h.store.checkedModeWrites, hasLength(1));
    },
  );

  test(
    'mode publication listener failure retains original factual receipt',
    () async {
      final reports = <Object>[];
      h.notifier.onError = (error, _) => reports.add(error);
      h.notifier.addListener((state) {
        if (state.activePreset.themeMode == 'light') {
          throw StateError('PRIVATE_MODE_LISTENER_CANARY');
        }
      }, fireImmediately: false);
      final result = await h.notifier.applyInstalledSelection(
        await h.modePlan(),
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.applied);
      expect(result.ownerCurrent, isFalse);
      expect(result.receipt!.operation, ThemeSelectionOperation.mode);
      expect(h.store.backing.presets, modeList('light'));
      expect(reports, hasLength(1));
      expect(
        result.toString(),
        isNot(contains('PRIVATE_MODE_LISTENER_CANARY')),
      );
    },
  );
}
