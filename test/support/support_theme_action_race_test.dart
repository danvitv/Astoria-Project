import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'support_theme_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final retirement in [
    'ui',
    'controller',
    'issuer',
    'epoch',
    'runtime',
    'configuration',
    'db',
    'redactor',
  ]) {
    themeActionTest(
      'pre-effect $retirement retirement at real encrypted reservation checkpoint',
      (f) async {
        final approval = await f.approval();
        final barrier = f.barrier();
        var gated = false;
        f.hook = (e) async {
          if (!gated &&
              e.startsWith('encrypt:') &&
              e.contains('support_mutation_journal')) {
            gated = true;
            await barrier.wait();
          }
        };
        final job = f.service.execute(approval);
        await barrier.entered.future;
        switch (retirement) {
          case 'ui':
            f.uiCurrent = false;
          case 'controller':
            f.controller = Object();
          case 'issuer':
            f.service.retireIntents();
          case 'epoch':
            f.runtime.invalidateLease();
          case 'runtime':
            f.runtime.dispose();
          case 'configuration':
            f.configuration++;
          case 'db':
            f.dbCurrent = false;
          case 'redactor':
            f.redaction.registerSecret('SYNTHETIC_NEW_SECRET');
        }
        barrier.release.complete();
        final result = await job;
        expect(result.effectStarted, isFalse);
        expect(f.themeStore.checkedWrites, isEmpty);
        expect(await f.record(), isNull);
        expect(f.custody.activeJobs, 0);
      },
    );
  }

  for (final retirement in [
    'ui',
    'controller',
    'issuer',
    'session',
    'runtime',
    'policy',
    'redactor',
  ]) {
    themeActionTest(
      'post-start $retirement loss still joins original domain fact and DB custody',
      (f) async {
        final intent = f.intent();
        final approval = await f.approval();
        final gate = f.themeGate();
        f.themeStore.writeGates.add(gate);
        final job = f.service.execute(approval);
        await gate.started.future;
        expect(f.custody.activeJobs, 1);
        switch (retirement) {
          case 'ui':
            f.uiCurrent = false;
          case 'controller':
            f.controller = Object();
          case 'issuer':
            f.service.dispose();
          case 'session':
            f.runtime.selectSession('another-support-session');
          case 'runtime':
            f.runtime.dispose();
          case 'policy':
            await f.grant(SupportPermission.confirmedSettingsChanges, false);
          case 'redactor':
            f.redaction.dispose();
        }
        gate.release.complete();
        final result = await job;
        expect(result.effect, SupportThemeEffect.applied);
        expect(result.journal, SupportThemeJournalSave.settled);
        expect((await f.record())!.status, 'applied');
        expect(f.service.projectResult(intent, result), isNull);
        expect(f.themeStore.checkedWrites, ['b']);
        expect(f.custody.activeJobs, 0);
        // Retired authority must not publish the started theme on its old owner.
        expect(f.theme.state.activePreset.id, 'a');
      },
    );
  }

  themeActionTest(
    'durable reservation delivered after UI cancellation settles no-effect without invoking T',
    (f) async {
      final approval = await f.approval();
      f.db.afterCommit = () async {
        f.uiCurrent = false;
      };
      final result = await f.service.execute(approval);
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(result.status, SupportMutationStatus.failed);
      expect(f.themeStore.checkedWrites, isEmpty);
      expect((await f.record())!.status, 'failed');
    },
  );

  themeActionTest(
    'revocation on queued fresh theme read prevents synchronous effect invocation',
    (f) async {
      final approval = await f.approval();
      final gate = f.themeGate();
      f.themeStore.freshReadGates.add(gate);
      final job = f.service.execute(approval);
      await gate.started.future;
      await f.grant(SupportPermission.confirmedSettingsChanges, false);
      gate.release.complete();
      final result = await job;
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(result.status, SupportMutationStatus.failed);
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );

  for (final ordinary in ['select', 'aba', 'edit', 'delete']) {
    themeActionTest(
      'ordinary queued $ordinary invalidates approved Apply in the SAME theme owner',
      (f) async {
        final approval = await f.approval();
        final gate = f.themeGate();
        f.themeStore.freshReadGates.add(gate);
        final job = f.service.execute(approval);
        await gate.started.future;
        Future<void> mutation;
        switch (ordinary) {
          case 'select':
            mutation = f.theme.applyPreset(ThemeActionFixture.themeC);
          case 'aba':
            final first = f.theme.applyPreset(ThemeActionFixture.themeC);
            final second = f.theme.applyPreset(ThemeActionFixture.themeA);
            mutation = Future.wait([first, second]).then((_) {});
          case 'edit':
            mutation = f.theme.updatePreset(
              ThemeActionFixture.themeB.copyWith(name: 'Edited B'),
            );
          case 'delete':
            mutation = f.theme.deletePreset('b');
          default:
            throw StateError('Unknown synthetic schedule.');
        }
        gate.release.complete();
        final result = await job;
        await mutation;
        await f.theme.flushPersistence();
        expect(result.domainCode, ThemeSelectionCode.conflict);
        expect(result.effect, SupportThemeEffect.noEffect);
        expect(result.status, SupportMutationStatus.failed);
        expect(f.themeStore.checkedWrites, isEmpty);
      },
    );
  }

  for (final ordinary in [
    'select',
    'aba',
    'priorEdit',
    'targetEdit',
    'priorDelete',
    'targetDelete',
  ]) {
    themeActionTest(
      'new Undo preserves ordinary $ordinary conflicts without recreating presets',
      (f) async {
        final applied = await f.apply();
        final review = (await f.service.prepareUndo(
          f.intent(),
          applied.applied!,
        ))!;
        final approval = f.service.approve(review)!;
        switch (ordinary) {
          case 'select':
            await f.theme.applyPreset(ThemeActionFixture.themeC);
          case 'aba':
            await f.theme.applyPreset(ThemeActionFixture.themeC);
            await f.theme.applyPreset(ThemeActionFixture.themeB);
          case 'priorEdit':
            await f.theme.importPreset(
              ThemeActionFixture.themeA.copyWith(name: 'Edited A'),
            );
          case 'targetEdit':
            await f.theme.importPreset(
              ThemeActionFixture.themeB.copyWith(name: 'Edited B'),
            );
          case 'priorDelete':
            await f.theme.deletePreset('a');
          case 'targetDelete':
            await f.theme.deletePreset('b');
        }
        await f.theme.flushPersistence();
        final before = List.of(f.backing.presets), active = f.backing.activeId;
        final result = await f.service.execute(approval);
        expect(result.effect, SupportThemeEffect.noEffect);
        expect(result.status, SupportMutationStatus.undoConflict);
        expect(f.backing.activeId, active);
        expect(f.backing.presets, before);
        expect(f.themeStore.checkedWrites, ['b']);
      },
    );
  }

  themeActionTest(
    'reentrant original UI predicate cannot renew issuer authority',
    (f) async {
      var entered = false;
      final intent = f.service.emit(
        controller: f.controller,
        uiLifetime: f.uiLifetime,
        isCurrent: () {
          if (!entered) {
            entered = true;
            f.service.retireIntents();
          }
          return true;
        },
      );
      expect(intent, isNull);
      expect(f.themeStore.freshReads, 0);
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );
  themeActionTest(
    'guarded undo_pending is durably reserved before ANY Undo effect',
    (f) async {
      final applied = await f.apply();
      final review = (await f.service.prepareUndo(
        f.intent(),
        applied.applied!,
      ))!;
      final gate = f.themeGate();
      f.themeStore.writeGates.add(gate);
      final job = f.service.execute(f.service.approve(review)!);
      await gate.started.future;
      expect((await f.record())!.status, 'undo_pending');
      expect(f.custody.activeJobs, 1);
      gate.release.complete();
      expect((await job).status, SupportMutationStatus.undone);
    },
  );

  themeActionTest(
    'retired completed factual result cannot paint a freshly emitted replacement controller',
    (f) async {
      final intent = f.intent();
      final result = await f.apply();
      expect(f.service.projectResult(intent, result), same(result));
      f.controller = Object();
      f.uiLifetime = Object();
      expect(f.service.projectResult(f.intent(), result), isNull);
      expect(result.operationId, isNull);
    },
  );

  themeActionTest(
    'actual theme read cancellation keeps original controller and denies returned installed values',
    (f) async {
      final intent = f.intent();
      final gate = f.themeGate();
      f.themeStore.freshReadGates.add(gate);
      final job = f.service.observe(intent);
      await gate.started.future;
      f.controller = Object();
      gate.release.complete();
      expect(await job, isNull);
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );
}
