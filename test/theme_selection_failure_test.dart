import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_selection_test_store.dart';

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await ThemeSelectionHarness.create());
  tearDown(() => h.dispose());

  final failures =
      <
        ThemeSelectionSyntheticWrite,
        (
          ThemeSelectionCode,
          ThemeSelectionWriteAcceptance,
          ThemeSelectionFreshObservation,
          String,
        )
      >{
        ThemeSelectionSyntheticWrite.falseBeforeWrite: (
          ThemeSelectionCode.writeRejected,
          ThemeSelectionWriteAcceptance.rejected,
          ThemeSelectionFreshObservation.before,
          'a',
        ),
        ThemeSelectionSyntheticWrite.throwBeforeWrite: (
          ThemeSelectionCode.writeThrew,
          ThemeSelectionWriteAcceptance.unknown,
          ThemeSelectionFreshObservation.before,
          'a',
        ),
        ThemeSelectionSyntheticWrite.writeThenThrow: (
          ThemeSelectionCode.writeThrew,
          ThemeSelectionWriteAcceptance.unknown,
          ThemeSelectionFreshObservation.after,
          'b',
        ),
        ThemeSelectionSyntheticWrite.falseAfterWrite: (
          ThemeSelectionCode.writeRejected,
          ThemeSelectionWriteAcceptance.rejected,
          ThemeSelectionFreshObservation.after,
          'b',
        ),
        ThemeSelectionSyntheticWrite.acceptedWithoutWrite: (
          ThemeSelectionCode.verificationConflict,
          ThemeSelectionWriteAcceptance.accepted,
          ThemeSelectionFreshObservation.before,
          'a',
        ),
      };
  for (final entry in failures.entries) {
    test(
      '${entry.key}: response and fresh evidence stay distinct; no retry',
      () async {
        final plan = await h.plan();
        h.store.checkedModes.add(entry.key);
        final result = await h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => true,
        );
        expect(result.code, entry.value.$1);
        expect(result.effectStarted, isTrue);
        expect(result.writeAcceptance, entry.value.$2);
        expect(result.freshObserved, entry.value.$3);
        expect(result.receipt, isNull);
        expect(h.store.backing.activeId, entry.value.$4);
        expect(
          h.store.cachedActiveId,
          entry.value.$4,
          reason: 'fresh reload must not use the optimistic write cache',
        );
        expect(h.notifier.state.activePreset, selectionA);
        expect(
          (await h.notifier.applyInstalledSelection(
            plan,
            isCurrent: () => true,
          )).code,
          ThemeSelectionCode.alreadyConsumed,
        );
        expect(h.store.checkedWrites, ['b']);
        expect(result.toString(), isNot(contains('PRIVATE_EXCEPTION_CANARY')));
      },
    );
  }

  test(
    'verification failure after accepted write is not failed-no-effect',
    () async {
      final plan = await h.plan();
      h.store.failAtFreshRead = h.store.freshReads + 2;
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.verificationFailed);
      expect(result.effectStarted, isTrue);
      expect(result.writeAccepted, isTrue);
      expect(result.freshObserved, ThemeSelectionFreshObservation.unavailable);
      expect(result.receipt, isNull);
      expect(h.store.backing.activeId, 'b');
      expect(h.notifier.state.activePreset, selectionA);
      final backing = h.store.backing;
      h.dispose();
      h = await ThemeSelectionHarness.create(backing);
      expect(
        (await h.notifier.observeInstalledThemes(
          isCurrent: () => true,
        )).observation!.active.id,
        'b',
      );
      expect(
        h.store.checkedWrites,
        isEmpty,
        reason: 'new owner observes state, never replays pending operation',
      );
    },
  );

  test(
    'malformed pre-write fresh projection denies without fallback',
    () async {
      final plan = await h.plan();
      h.store.backing.malformed = true;
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.invalidStorage);
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedWrites, isEmpty);
    },
  );

  test(
    'pre-write fresh read exception denies without secret-bearing errors',
    () async {
      final plan = await h.plan();
      h.store.failAtFreshRead = h.store.freshReads + 1;
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.readFailed);
      expect(result.effectStarted, isFalse);
      expect(result.toString(), isNot(contains('PRIVATE_EXCEPTION_CANARY')));
      expect(h.store.checkedWrites, isEmpty);
    },
  );

  for (final mode in [
    ThemeSelectionSyntheticWrite.falseBeforeWrite,
    ThemeSelectionSyntheticWrite.writeThenThrow,
  ]) {
    test(
      'Undo $mode retains independent observed evidence and never retries',
      () async {
        final applied = await h.notifier.applyInstalledSelection(
          await h.plan(),
          isCurrent: () => true,
        );
        h.store.checkedModes.add(mode);
        final result = await h.notifier.undoInstalledSelection(
          applied.receipt!,
          isCurrent: () => true,
        );
        final rejected = mode == ThemeSelectionSyntheticWrite.falseBeforeWrite;
        expect(
          result.code,
          rejected
              ? ThemeSelectionCode.writeRejected
              : ThemeSelectionCode.writeThrew,
        );
        expect(result.effectStarted, isTrue);
        expect(
          result.freshObserved,
          rejected
              ? ThemeSelectionFreshObservation.before
              : ThemeSelectionFreshObservation.after,
        );
        expect(h.store.backing.activeId, rejected ? 'b' : 'a');
        expect(h.notifier.state.activePreset, selectionB);
        expect(result.receipt, isNull);
        expect(
          (await h.notifier.undoInstalledSelection(
            applied.receipt!,
            isCurrent: () => true,
          )).code,
          ThemeSelectionCode.alreadyConsumed,
        );
        expect(h.store.checkedWrites, ['b', 'a']);
        expect(h.store.savedLists, isEmpty);
      },
    );
  }

  test(
    'accepted write followed by fresh other state supplies no Undo receipt',
    () async {
      final plan = await h.plan();
      h.store.afterCheckedWrite = () => h.store.backing.activeId = 'c';
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      expect(result.code, ThemeSelectionCode.verificationConflict);
      expect(result.writeAccepted, isTrue);
      expect(result.freshObserved, ThemeSelectionFreshObservation.other);
      expect(result.receipt, isNull);
      expect(h.notifier.state.activePreset, selectionA);
    },
  );

  test(
    'native listener failure cannot erase observed receipt or expose private text',
    () async {
      final plan = await h.plan();
      final listenerError = StateError('PRIVATE_LISTENER_CANARY');
      final reports = <(Object, StackTrace?)>[];
      final previousOnError = h.notifier.onError;
      // StateNotifier reports before throwing the publication error. Own only
      // this expected report; callback assertions could be caught by publication.
      h.notifier.onError = (error, stackTrace) {
        reports.add((error, stackTrace));
      };
      try {
        h.notifier.addListener((state) {
          if (state.activePreset.id == 'b') {
            throw listenerError;
          }
        }, fireImmediately: false);
        final result = await h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => true,
        );
        expect(result.code, ThemeSelectionCode.applied);
        expect(result.writeAccepted, isTrue);
        expect(result.freshObserved, ThemeSelectionFreshObservation.after);
        expect(result.ownerCurrent, isFalse);
        expect(result.receipt, isNotNull);
        expect(h.store.backing.activeId, 'b');
        expect(result.toString(), isNot(contains('PRIVATE_LISTENER_CANARY')));
        expect(
          reports,
          hasLength(1),
          reason: 'exactly the injected listener failure must be reported',
        );
        expect(reports.single.$1, same(listenerError));
        expect(reports.single.$2, isA<StackTrace>());
        expect(reports.single.$2, isNot(same(StackTrace.empty)));
      } finally {
        h.notifier.onError = previousOnError;
      }
    },
  );
}
