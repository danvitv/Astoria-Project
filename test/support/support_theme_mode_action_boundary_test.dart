import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';

import 'support_theme_mode_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  modeActionTest(
    'mode is local, active-only and once-approved with original Undo',
    (f) async {
      expect(f.runtime.snapshot.preferences!.recipient, isNull);
      final observed = (await f.service.observe(f.intent()))!;
      final choices = f.service.projectModeChoices(observed)!.choices;
      expect(
        choices.map((c) => c.operation),
        everyElement(SupportThemeOperation.mode),
      );
      expect(choices.map((c) => c.value!.mode), ['dark', 'light', 'system']);
      expect(choices.map((c) => c.value!.id), everyElement('a'));
      expect(choices.map((c) => c.value!.active), everyElement(true));
      final beforeList = List.of(f.backing.presets);
      final review = (await f.service.prepareApply(choices[1]))!;
      final preview = f.service.projectReview(review)!;
      expect(preview.operation, SupportThemeOperation.mode);
      expect(preview.before.id, preview.after.id);
      expect(preview.before.mode, 'dark');
      expect(preview.after.mode, 'light');
      expect(modeStore(f).modeWrites, isEmpty);
      final approval = f.service.approve(review)!;
      expect(f.service.approve(review), isNull);
      final job = f.service.execute(approval);
      expect(
        (await f.service.execute(approval)).effect,
        SupportThemeEffect.refused,
      );
      final applied = await job;
      expect(applied.effect, SupportThemeEffect.applied);
      expect(applied.status, SupportMutationStatus.applied);
      expect(f.backing.activeId, 'a');
      expect(f.backing.presets, [
        beforeList.first.copyWith(themeMode: 'light'),
        ...beforeList.skip(1),
      ]);
      expect(f.theme.state.activePreset.themeMode, 'light');
      expect(f.themeStore.checkedWrites, isEmpty);
      final immutable = (await f.record())!;
      expect(immutable.domain, 'theme.mode');
      expect(immutable.targetId, 'active-preset-mode');
      final undoReview = (await f.service.prepareUndo(
        f.intent(),
        applied.applied!,
      ))!;
      final undoPreview = f.service.projectReview(undoReview)!;
      expect(undoPreview.kind, SupportThemeActionKind.undo);
      expect(undoPreview.operation, SupportThemeOperation.mode);
      expect(undoPreview.before.mode, 'light');
      expect(undoPreview.after.mode, 'dark');
      expect(modeStore(f).modeWrites.length, 1);
      final undone = await f.service.execute(f.service.approve(undoReview)!);
      expect(undone.effect, SupportThemeEffect.undone);
      expect(undone.status, SupportMutationStatus.undone);
      expect(f.backing.presets, beforeList);
      final settled = (await f.record())!;
      expect(settled.id, immutable.id);
      expect(settled.beforeJson, immutable.beforeJson);
      expect(settled.afterJson, immutable.afterJson);
      expect(settled.createdAt, immutable.createdAt);
      expect(modeStore(f).modeWrites.length, 2);
    },
  );

  for (final right in [
    SupportPermission.readSafeSettings,
    SupportPermission.confirmedSettingsChanges,
  ]) {
    modeActionTest('mode ${right.name} grant has its own boundary', (f) async {
      await f.grant(right, false);
      final reads = f.themeStore.freshReads;
      if (right == SupportPermission.readSafeSettings) {
        expect(
          f.service.emit(
            controller: f.controller,
            uiLifetime: f.uiLifetime,
            isCurrent: () => true,
          ),
          isNull,
        );
        expect(f.themeStore.freshReads, reads);
      } else {
        final observed = (await f.service.observe(f.intent()))!;
        final choices = f.service.projectModeChoices(observed)!.choices;
        expect(choices, hasLength(3));
        expect(await f.service.prepareApply(choices[1]), isNull);
      }
      expect(modeStore(f).modeWrites, isEmpty);
      expect(await f.record(), isNull);
    });
  }

  modeActionTest(
    'already-current mode reserves noEffect without synthetic Undo',
    (f) async {
      final result = await modeApply(f, 'dark');
      expect(result.domainCode, ThemeSelectionCode.noOp);
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(result.effectStarted, isFalse);
      expect(result.status, SupportMutationStatus.failed);
      expect(result.journal, SupportThemeJournalSave.settled);
      expect(result.applied, isNull);
      expect(modeStore(f).modeWrites, isEmpty);
      expect((await f.record())!.domain, 'theme.mode');
    },
  );

  modeActionTest(
    'fresh durable policy revision cannot merge into mode approval',
    (f) async {
      final approval = await modeApproval(f);
      await f.permissions.setGrantFromNative(
        ThemeActionFixture.session,
        SupportPermission.confirmedSettingsChanges,
        false,
        isCurrent: () => true,
      );
      expect(
        (await f.service.execute(approval)).effect,
        SupportThemeEffect.refused,
      );
      expect(modeStore(f).modeWrites, isEmpty);
      expect(await f.record(), isNull);
    },
  );

  modeActionTest(
    'mode observation and final approval cannot move between owners',
    (f) async {
      final observed = (await f.service.observe(f.intent()))!;
      final approval = await modeApproval(f);
      await f.replaceRuntime();
      expect(f.service.projectModeChoices(observed), isNull);
      expect(
        (await f.service.execute(approval)).effect,
        SupportThemeEffect.refused,
      );
      expect(modeStore(f).modeWrites, isEmpty);
    },
  );
}
