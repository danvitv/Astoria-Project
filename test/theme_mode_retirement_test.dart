import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_mode_test_fixture.dart';
import 'theme_selection_test_store.dart';

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await createModeHarness());
  tearDown(() => h.dispose());

  for (final retirement in ['cancel', 'dispose']) {
    test(
      '$retirement at fresh pre-write read prevents mode invocation',
      () async {
        final plan = await h.modePlan();
        final read = ThemeSelectionGate();
        h.store.freshReadGates.add(read);
        var current = true;
        final future = h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => current,
        );
        await read.started.future;
        if (retirement == 'dispose') h.dispose();
        current = false;
        read.release.complete();
        final result = await future;
        expect(result.code, ThemeSelectionCode.revoked);
        expect(result.effectStarted, isFalse);
        expect(result.receipt, isNull);
        expect(h.store.backing.presets, modeList('dark'));
        expect(h.store.checkedModeWrites, isEmpty);
      },
    );

    for (final boundary in ['write started', 'verification read']) {
      test(
        '$retirement at $boundary retains mode facts but paints no replacement',
        () async {
          final plan = await h.modePlan();
          final gate = ThemeSelectionGate();
          final preRead = ThemeSelectionGate();
          if (boundary == 'write started') {
            h.store.modeWriteGates.add(gate);
          } else {
            h.store.freshReadGates.addAll([preRead, gate]);
          }
          var current = true;
          final painted = <String>[];
          h.notifier.addListener(
            (state) => painted.add(state.activePreset.themeMode),
            fireImmediately: false,
          );
          final future = h.notifier.applyInstalledSelection(
            plan,
            isCurrent: () => current,
          );
          if (boundary == 'verification read') {
            await preRead.started.future;
            preRead.release.complete();
          }
          await gate.started.future;
          expect(h.store.checkedModeWrites, [modeList('light')]);
          expect(h.notifier.state.presets, modeList('dark'));
          if (retirement == 'dispose') h.dispose();
          current = false;
          final replacement = await ThemeSelectionHarness.create(
            h.store.backing,
          );
          final replacementBefore = replacement.notifier.state;
          final replacementPaints = <String>[];
          replacement.notifier.addListener(
            (state) => replacementPaints.add(state.activePreset.themeMode),
            fireImmediately: false,
          );
          try {
            gate.release.complete();
            final result = await future;
            expect(result.code, ThemeSelectionCode.applied);
            expect(result.effectStarted, isTrue);
            expect(result.writeAccepted, isTrue);
            expect(result.freshObserved, ThemeSelectionFreshObservation.after);
            expect(result.ownerCurrent, isFalse);
            expect(result.receipt!.operation, ThemeSelectionOperation.mode);
            expect(h.store.backing.activeId, 'a');
            expect(h.store.backing.presets, modeList('light'));
            expect(painted, isEmpty);
            expect(replacementPaints, isEmpty);
            expect(replacement.notifier.state, same(replacementBefore));
            expect(replacement.store.checkedModeWrites, isEmpty);
            expect(
              (await replacement.notifier.undoInstalledSelection(
                result.receipt!,
                isCurrent: () => true,
              )).code,
              ThemeSelectionCode.ownerChanged,
            );
            expect(
              (await h.notifier.undoInstalledSelection(
                result.receipt!,
                isCurrent: () => current,
              )).effectStarted,
              isFalse,
            );
            expect(h.store.checkedModeWrites, hasLength(1));
          } finally {
            replacement.dispose();
          }
        },
      );
    }
  }

  test(
    'revoked and throwing mode approval expose no private text or effect',
    () async {
      for (final throws in [false, true]) {
        final plan = await h.modePlan();
        final result = await h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () {
            if (throws) throw StateError('PRIVATE_MODE_PREDICATE_CANARY');
            return false;
          },
        );
        expect(result.code, ThemeSelectionCode.revoked);
        expect(result.effectStarted, isFalse);
        expect(result.receipt, isNull);
        expect(
          result.toString(),
          isNot(contains('PRIVATE_MODE_PREDICATE_CANARY')),
        );
      }
      expect(h.store.checkedModeWrites, isEmpty);
    },
  );
}
