import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';

import 'support_theme_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  themeProviderTest(
    'actual service retirement inside original real-AEAD reservation denies T',
    (f) async {
      final intent = f.emit()!;
      final review = await f.review(intent);
      final original = f.custody;
      final gate = f.barrier();
      var held = false;
      f.primitive.event = (event) async {
        if (!held &&
            event.startsWith('encrypt:') &&
            event.contains('support_mutation_journal')) {
          held = true;
          await gate.wait();
        }
      };
      final job = f.confirm(intent, review);
      await gate.entered.future;
      f.container.invalidate(supportThemeActionServiceProvider);
      f.binding;
      expect(f.custody, same(original));
      gate.release.complete();
      expect((await job).effectStarted, isFalse);
      f.primitive.event = null;
      expect(
        await f.repo.getMutationsForSession(ThemeProviderFixture.session),
        isEmpty,
      );
      expect(f.harness.store.checkedWrites, isEmpty);
    },
  );
  for (final retirement in ['ui', 'runtime', 'service', 'cipher', 'theme']) {
    themeProviderTest(
      'STARTED original fact survives $retirement retirement, no old paint',
      (f) async {
        final original = f.emit()!;
        final review = await f.review(original);
        final custody = f.custody;
        final store = f.harness.store;
        final gate = f.gate();
        store.writeGates.add(gate);
        final job = f.confirm(original, review);
        await gate.started.future;
        expect(custody.activeJobs, 1);
        switch (retirement) {
          case 'ui':
            f.uiCurrent = false;
          case 'runtime':
            f.container.invalidate(supportNativeRuntimeProvider);
            await f.reconcile();
          case 'service':
            f.container.invalidate(supportThemeActionServiceProvider);
            await f.reconcile();
          case 'cipher':
            await f.replaceCipher();
          case 'theme':
            await f.replaceTheme();
        }
        expect(f.custody, same(custody));
        gate.release.complete();
        final result = await job;
        expect(result.effectStarted, isTrue);
        expect(result.effect, SupportThemeEffect.applied);
        expect(result.journal, SupportThemeJournalSave.settled);
        expect(original.result(result), isNull);
        expect(result.operationId, isNull);
        expect(store.checkedWrites, ['b']);
        final row = (await f.repo.getMutationsForSession(
          ThemeProviderFixture.session,
        )).single;
        expect(row.status, 'applied');
        expect(custody.activeJobs, 0);
        if (retirement == 'ui') {
          f.uiCurrent = true;
          f.uiLifetime = Object();
        }
        // A replacement of the actual theme owner cannot use the original receipt.
        final fresh = f.emit()!;
        final undo = await fresh.prepareLastUndo();
        if (retirement == 'theme') {
          expect(undo, isNull);
        } else {
          expect(undo, isNotNull);
          final conditional = await f.confirm(fresh, undo!);
          // Original factual completion intentionally did not repaint the old
          // notifier. Retaining a receipt cannot bypass T's fresh active check.
          expect(conditional.effect, SupportThemeEffect.noEffect);
          expect(conditional.status, SupportMutationStatus.undoConflict);
          expect(store.checkedWrites, ['b']);
          expect(await f.emit()!.prepareLastUndo(), isNull);
        }
      },
    );
  }
  for (final retirement in ['runtime', 'service', 'cipher']) {
    themeProviderTest(
      'completed current Apply retains real fresh Undo across $retirement replacement',
      (f) async {
        expect((await f.apply()).effect, SupportThemeEffect.applied);
        switch (retirement) {
          case 'runtime':
            f.container.invalidate(supportNativeRuntimeProvider);
          case 'service':
            f.container.invalidate(supportThemeActionServiceProvider);
          case 'cipher':
            await f.replaceCipher();
        }
        await f.reconcile();
        final fresh = f.emit()!;
        final undo = (await fresh.prepareLastUndo())!;
        final result = await f.confirm(fresh, undo);
        expect(result.effect, SupportThemeEffect.undone);
        expect(result.status, SupportMutationStatus.undone);
        expect(f.harness.store.checkedWrites, ['b', 'a']);
      },
    );
  }
  themeProviderTest(
    'genuine DB replacement permanently refuses original settlement',
    (f) async {
      final intent = f.emit()!;
      final review = await f.review(intent);
      final original = f.custody;
      final gate = f.gate();
      f.harness.store.writeGates.add(gate);
      final job = f.confirm(intent, review);
      await gate.started.future;
      await f.replaceDatabase();
      expect(f.custody, isNot(same(original)));
      gate.release.complete();
      final result = await job;
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.journal, SupportThemeJournalSave.unresolved);
      expect(
        (await f.repo.getMutationsForSession(
          ThemeProviderFixture.session,
        )).single.status,
        'pending',
      );
      expect(original.unresolvedCount, 1);
      expect(f.emit(), isNull);
    },
  );
  themeProviderTest(
    'replacement recovery shares retained original live-job exclusion',
    (f) async {
      final original = f.emit()!;
      final review = await f.review(original);
      final gate = f.gate();
      f.harness.store.writeGates.add(gate);
      final job = f.confirm(original, review);
      await gate.started.future;
      final row = (await f.repo.getMutationsForSession(
        ThemeProviderFixture.session,
      )).single;
      await f.replaceCipher();
      final fresh = f.emit()!;
      final recovery = await fresh.recover(row.id);
      expect(recovery.state, SupportThemeRecoveryState.liveJob);
      expect(recovery.before, isNull);
      expect(recovery.after, isNull);
      expect(f.custody.activeJobs, 1);
      gate.release.complete();
      await job;
      final history = await fresh.recover(row.id);
      expect(history.state, SupportThemeRecoveryState.history);
      expect(history.status, SupportMutationStatus.applied);
      expect(f.harness.store.checkedWrites, ['b']);
      f.redaction.registerSecret(history.after!.name);
      expect(history.after?.name, isNot('B'));
    },
  );
  themeProviderTest(
    'reconstructed historical rows never restore receipt or replay',
    (f) async {
      final applied = await f.apply();
      final id = applied.operationId!;
      // Explicit feature owner recreation loses transient receipt, retains history.
      f.container.invalidate(supportThemeOriginalHandlesProvider);
      await f.reconcile();
      final fresh = f.emit()!;
      final history = await fresh.recover(id);
      expect(history.state, SupportThemeRecoveryState.history);
      expect(await fresh.prepareLastUndo(), isNull);
      expect(f.harness.store.checkedWrites, ['b']);
    },
  );
  themeProviderTest(
    'parent title re-encryption denies old settlement without rebind',
    (f) async {
      final intent = f.emit()!;
      final review = await f.review(intent);
      final gate = f.gate();
      f.harness.store.writeGates.add(gate);
      final job = f.confirm(intent, review);
      await gate.started.future;
      expect(
        await f.workspace.renameSession(
          ThemeProviderFixture.session,
          'Fresh title',
        ),
        isTrue,
      );
      gate.release.complete();
      final result = await job;
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.journal, SupportThemeJournalSave.unresolved);
      expect(
        (await f.repo.getMutationsForSession(
          ThemeProviderFixture.session,
        )).single.status,
        'pending',
      );
      expect(await f.emit()!.prepareLastUndo(), isNull);
    },
  );
}
