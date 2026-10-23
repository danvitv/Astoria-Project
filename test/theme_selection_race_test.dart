import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'theme_selection_test_store.dart';

void main() {
  late ThemeSelectionHarness h;
  setUp(() async => h = await ThemeSelectionHarness.create());
  tearDown(() => h.dispose());

  test('revoked observation starts no read and supplies no plan', () async {
    final read = await h.notifier.observeInstalledThemes(
      isCurrent: () => false,
    );
    expect(read.code, ThemeSelectionCode.revoked);
    expect(read.observation, isNull);
    expect(h.store.freshReads, 0);
  });

  test(
    'last predicate callback cannot reentrantly invalidate then start a write',
    () async {
      final plan = await h.plan();
      final preWriteRead = h.store.freshReads + 1;
      var changed = false;
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () {
          if (!changed && h.store.freshReads == preWriteRead) {
            changed = true;
            h.notifier.setIgnoreCustomFont(true);
          }
          return true;
        },
      );
      expect(result.code, ThemeSelectionCode.conflict);
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedWrites, isEmpty);
    },
  );

  test(
    'throwing current predicate denies without propagating private text',
    () async {
      final plan = await h.plan();
      final result = await h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => throw StateError('PRIVATE_PREDICATE_CANARY'),
      );
      expect(result.code, ThemeSelectionCode.revoked);
      expect(result.effectStarted, isFalse);
      expect(result.toString(), isNot(contains('PRIVATE_PREDICATE_CANARY')));
      expect(h.store.checkedWrites, isEmpty);
    },
  );

  for (final retirement in ['cancel', 'dispose']) {
    test(
      '$retirement during fresh observation denies before any effect',
      () async {
        final gate = ThemeSelectionGate();
        h.store.freshReadGates.add(gate);
        var current = true;
        final future = h.notifier.observeInstalledThemes(
          isCurrent: () => current,
        );
        await gate.started.future;
        if (retirement == 'dispose') h.dispose();
        current = false;
        gate.release.complete();
        final read = await future;
        expect(read.code, ThemeSelectionCode.revoked);
        expect(read.observation, isNull);
        expect(h.store.checkedWrites, isEmpty);
      },
    );

    test(
      '$retirement at queued pre-write fresh read starts no effect',
      () async {
        final plan = await h.plan();
        final gate = ThemeSelectionGate();
        h.store.freshReadGates.add(gate);
        var current = true;
        final future = h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => current,
        );
        await gate.started.future;
        if (retirement == 'dispose') h.dispose();
        current = false;
        gate.release.complete();
        final result = await future;
        expect(result.effectStarted, isFalse);
        expect(h.store.checkedWrites, isEmpty);
        expect(h.store.backing.activeId, 'a');
      },
    );

    test(
      '$retirement after write STARTED retains observed result, no paint',
      () async {
        final plan = await h.plan();
        final gate = ThemeSelectionGate();
        h.store.writeGates.add(gate);
        var current = true;
        final painted = <String>[];
        h.notifier.addListener(
          (s) => painted.add(s.activePreset.id),
          fireImmediately: false,
        );
        final future = h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => current,
        );
        await gate.started.future;
        expect(
          h.notifier.state.activePreset,
          selectionA,
          reason: 'no optimistic assistant success while persistence is paused',
        );
        if (retirement == 'dispose') h.dispose();
        current = false;
        gate.release.complete();
        final result = await future;
        expect(result.code, ThemeSelectionCode.applied);
        expect(result.effectStarted, isTrue);
        expect(result.writeAccepted, isTrue);
        expect(result.freshObserved, ThemeSelectionFreshObservation.after);
        expect(result.ownerCurrent, isFalse);
        expect(
          result.receipt,
          isNotNull,
          reason:
              'original journal may settle observation after native retirement',
        );
        expect(painted, isEmpty);
        expect(h.store.backing.activeId, 'b');
        expect(h.store.checkedWrites, ['b']);
      },
    );

    test(
      '$retirement during post-write verification keeps original custody',
      () async {
        final plan = await h.plan();
        final preRead = ThemeSelectionGate();
        final verification = ThemeSelectionGate();
        h.store.freshReadGates.addAll([preRead, verification]);
        var current = true;
        final future = h.notifier.applyInstalledSelection(
          plan,
          isCurrent: () => current,
        );
        await preRead.started.future;
        preRead.release.complete();
        await verification.started.future;
        expect(h.store.backing.activeId, 'b');
        if (retirement == 'dispose') h.dispose();
        current = false;
        verification.release.complete();
        final result = await future;
        expect(result.code, ThemeSelectionCode.applied);
        expect(result.ownerCurrent, isFalse);
        expect(result.receipt, isNotNull);
        expect(h.store.checkedWrites, ['b']);
        if (!h.retired) expect(h.notifier.state.activePreset, selectionA);
      },
    );
  }

  test(
    'ordinary admission during queued read wins BEFORE await/optimistic paint',
    () async {
      final plan = await h.plan();
      final gate = ThemeSelectionGate();
      h.store.freshReadGates.add(gate);
      final future = h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      await gate.started.future;
      final ordinary = h.notifier.applyPreset(selectionC);
      // Do not await ordinary readiness/paint: admission itself must invalidate.
      gate.release.complete();
      final result = await future;
      await ordinary;
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedWrites, isEmpty);
      expect(h.notifier.state.activePreset, selectionC);
      expect(h.store.backing.activeId, 'c');
    },
  );

  test(
    'queued Undo rejects ordinary B-C-B admissions at actual read boundary',
    () async {
      final applied = await h.notifier.applyInstalledSelection(
        await h.plan(),
        isCurrent: () => true,
      );
      final gate = ThemeSelectionGate();
      h.store.freshReadGates.add(gate);
      final future = h.notifier.undoInstalledSelection(
        applied.receipt!,
        isCurrent: () => true,
      );
      await gate.started.future;
      final away = h.notifier.applyPreset(selectionC);
      final back = h.notifier.applyPreset(selectionB);
      gate.release.complete();
      final result = await future;
      await Future.wait([away, back]);
      expect(result.effectStarted, isFalse);
      expect(h.store.checkedWrites, ['b']);
      expect(h.store.backing.activeId, 'b');
      expect(h.notifier.state.activePreset, selectionB);
    },
  );

  test(
    'late assistant completion preserves newer ordinary optimistic paint',
    () async {
      final plan = await h.plan();
      final firstWrite = ThemeSelectionGate();
      final secondWrite = ThemeSelectionGate();
      h.store.writeGates.addAll([firstWrite, secondWrite]);
      final future = h.notifier.applyInstalledSelection(
        plan,
        isCurrent: () => true,
      );
      await firstWrite.started.future;
      final ordinary = h.notifier.applyPreset(selectionC);
      // Ensure optimistic ordinary state has landed while its write stays queued.
      await pumpEventQueue();
      expect(h.notifier.state.activePreset, selectionC);
      firstWrite.release.complete();
      final result = await future;
      await secondWrite.started.future;
      expect(result.code, ThemeSelectionCode.applied);
      expect(result.ownerCurrent, isFalse);
      expect(h.notifier.state.activePreset, selectionC);
      expect(h.store.backing.activeId, 'b');
      secondWrite.release.complete();
      await ordinary;
      expect(h.store.backing.activeId, 'c');
      final undo = await h.notifier.undoInstalledSelection(
        result.receipt!,
        isCurrent: () => true,
      );
      expect(undo.effectStarted, isFalse);
      expect(h.store.checkedWrites, ['b']);
    },
  );

  test('fresh read checks edited installed content AFTER its await', () async {
    final plan = await h.plan();
    final gate = ThemeSelectionGate();
    h.store.freshReadGates.add(gate);
    final future = h.notifier.applyInstalledSelection(
      plan,
      isCurrent: () => true,
    );
    await gate.started.future;
    h.store.backing.presets[0] = selectionA.copyWith(
      chatFont: 'CONTENT_CANARY',
    );
    gate.release.complete();
    final result = await future;
    expect(result.code, ThemeSelectionCode.conflict);
    expect(result.effectStarted, isFalse);
    expect(h.store.checkedWrites, isEmpty);
  });

  test(
    'ordinary reload completion cannot replace later optimistic selection',
    () async {
      final gate = ThemeSelectionGate();
      h.store.loadGates.add(gate);
      final reload = h.notifier.reload();
      await gate.started.future;
      final ordinary = h.notifier.applyPreset(selectionC);
      await pumpEventQueue();
      expect(h.notifier.state.activePreset, selectionC);
      gate.release.complete();
      await reload;
      await ordinary;
      expect(h.notifier.state.activePreset, selectionC);
      expect(h.store.backing.activeId, 'c');
    },
  );

  test(
    'ordinary import completion cannot replace later optimistic selection',
    () async {
      final gate = ThemeSelectionGate();
      h.store.saveGates.add(gate);
      final imported = h.notifier.importPreset(
        selectionB.copyWith(name: 'Edited'),
      );
      await gate.started.future;
      final ordinary = h.notifier.applyPreset(selectionC);
      await pumpEventQueue();
      gate.release.complete();
      await Future.wait([imported, ordinary]);
      expect(h.notifier.state.activePreset, selectionC);
      expect(h.store.backing.activeId, 'c');
    },
  );

  test(
    'preparation behind a pending ordinary save denies intervening admission',
    () async {
      await h.notifier.updatePreset(selectionA.copyWith(name: 'Pending'));
      final gate = ThemeSelectionGate();
      h.store.saveGates.add(gate);
      final observed = h.notifier.observeInstalledThemes(isCurrent: () => true);
      await gate.started.future;
      final ordinary = h.notifier.applyPreset(selectionC);
      gate.release.complete();
      expect((await observed).observation, isNull);
      await ordinary;
      expect(h.store.checkedWrites, isEmpty);
      expect(h.store.backing.activeId, 'c');
    },
  );
}
