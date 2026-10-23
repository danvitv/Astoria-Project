import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';

import 'support_theme_mode_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final boundary in ['encrypt:', 'insert:']) {
    modeActionTest(
      'mode revoke at $boundary reservation checkpoint starts no write',
      (f) async {
        final approval = await modeApproval(f);
        final barrier = f.barrier();
        var gated = false;
        f.hook = (e) async {
          if (!gated &&
              e.startsWith(boundary) &&
              e.contains('support_mutation_journal')) {
            gated = true;
            await barrier.wait();
          }
        };
        final job = f.service.execute(approval);
        await barrier.entered.future;
        f.runtime.invalidateLease();
        barrier.release.complete();
        final result = await job;
        expect(result.effectStarted, isFalse);
        expect(modeStore(f).modeWrites, isEmpty);
        expect(await f.record(), isNull);
      },
    );
  }

  modeActionTest(
    'mode delivered reservation after retirement settles noEffect',
    (f) async {
      final approval = await modeApproval(f);
      f.db.afterCommit = () async {
        f.uiCurrent = false;
      };
      final result = await f.service.execute(approval);
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(result.status, SupportMutationStatus.failed);
      expect((await f.record())!.status, 'failed');
      expect(modeStore(f).modeWrites, isEmpty);
    },
  );

  for (final retirement in [
    'controller',
    'service',
    'runtime',
    'theme',
    'policy',
  ]) {
    modeActionTest(
      'mode late $retirement retirement keeps original factual settlement',
      (f) async {
        final oldService = f.service, oldTheme = f.theme;
        final oldIntent = f.intent();
        final approval = await modeApproval(f);
        final store = modeStore(f), gate = f.themeGate();
        store.modeGates.add(gate);
        final job = f.service.execute(approval);
        await gate.started.future;
        switch (retirement) {
          case 'controller':
            f.controller = Object();
          case 'service':
            f.service.dispose();
          case 'runtime':
            await f.replaceRuntime();
          case 'theme':
            await f.replaceTheme();
          case 'policy':
            await f.grant(SupportPermission.confirmedSettingsChanges, false);
        }
        gate.release.complete();
        final result = await job;
        expect(result.effect, SupportThemeEffect.applied);
        expect(result.journal, SupportThemeJournalSave.settled);
        expect((await f.record())!.status, 'applied');
        expect(f.backing.presets.first.themeMode, 'light');
        expect(oldService.projectResult(oldIntent, result), isNull);
        if (retirement == 'runtime' || retirement == 'theme') {
          expect(f.service.projectResult(f.intent(), result), isNull);
        }
        expect(oldTheme.state.activePreset.themeMode, 'dark');
        expect(f.theme.state.activePreset.themeMode, 'dark');
        expect(store.modeWrites.length, 1);
        expect(f.custody.activeJobs, 0);
      },
    );
  }

  for (final edit in [
    'active-content',
    'other-content',
    'reorder',
    'delete',
    'aba',
  ]) {
    modeActionTest(
      'mode original approved Undo refuses ordinary $edit conflict',
      (f) async {
        final applied = await modeApply(f);
        switch (edit) {
          case 'active-content':
            await f.theme.updatePreset(
              f.backing.presets.first.copyWith(
                name: 'User edit',
                customFont: 'SYNTHETIC_NEW_PRIVATE_FONT',
              ),
            );
          case 'other-content':
            await f.theme.importPreset(
              ThemeActionFixture.themeB.copyWith(name: 'User B'),
            );
          case 'reorder':
            f.backing.presets = f.backing.presets.reversed.toList();
          case 'delete':
            await f.theme.deletePreset('a');
          case 'aba':
            await f.theme.applyPreset(ThemeActionFixture.themeC);
            await f.theme.applyPreset(
              ThemeActionFixture.themeA.copyWith(themeMode: 'light'),
            );
        }
        await f.theme.flushPersistence();
        final before = List.of(f.backing.presets), active = f.backing.activeId;
        final review = (await f.service.prepareUndo(
          f.intent(),
          applied.applied!,
        ))!;
        final approval = f.service.approve(review)!;
        final result = await f.service.execute(approval);
        expect(result.effect, SupportThemeEffect.noEffect);
        expect(result.status, SupportMutationStatus.undoConflict);
        expect(f.backing.presets, before);
        expect(f.backing.activeId, active);
        expect(modeStore(f).modeWrites.length, 1);
      },
    );
  }

  modeActionTest(
    'mode fresh full-content conflict after reservation has zero writes',
    (f) async {
      final approval = await modeApproval(f);
      f.backing.presets[1] = ThemeActionFixture.themeB.copyWith(
        chatFont: 'User font',
      );
      final before = List.of(f.backing.presets);
      final result = await f.service.execute(approval);
      expect(result.domainCode, ThemeSelectionCode.conflict);
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(modeStore(f).modeWrites, isEmpty);
      expect(f.backing.presets, before);
    },
  );

  modeActionTest(
    'mode accepted write with another-preset edit remains reconciliation',
    (f) async {
      final approval = await modeApproval(f);
      modeStore(f).afterModeWrite = () {
        f.backing.presets[1] = ThemeActionFixture.themeB.copyWith(
          name: 'External B',
        );
      };
      final result = await f.service.execute(approval);
      expect(result.domainCode, ThemeSelectionCode.verificationConflict);
      expect(result.effect, SupportThemeEffect.uncertain);
      expect(result.status, SupportMutationStatus.reconciliationRequired);
      expect(result.applied, isNull);
      expect(f.theme.state.activePreset.themeMode, 'dark');
      expect(f.backing.presets[1].name, 'External B');
      expect(modeStore(f).modeWrites.length, 1);
    },
  );
}
