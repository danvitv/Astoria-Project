import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'support_theme_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  themeActionTest(
    'one native Apply then separately approved same-receipt Undo without recipient',
    (f) async {
      expect(f.runtime.snapshot.preferences!.recipient, isNull);
      final review = await f.review();
      expect(f.themeStore.checkedWrites, isEmpty);
      expect(f.service.projectReview(review)!.after.id, 'b');
      final approval = f.service.approve(review)!;
      expect(f.service.approve(review), isNull);
      final job = f.service.execute(approval);
      final duplicate = await f.service.execute(approval);
      expect(duplicate.effect, SupportThemeEffect.refused);
      final applied = await job;
      expect(applied.effect, SupportThemeEffect.applied);
      expect(applied.journal, SupportThemeJournalSave.settled);
      expect(applied.status, SupportMutationStatus.applied);
      expect(applied.operationId, f.lastId);
      expect(f.backing.activeId, 'b');
      final immutable = await f.record();
      final undoReview = (await f.service.prepareUndo(
        f.intent(),
        applied.applied!,
      ))!;
      expect(f.themeStore.checkedWrites, ['b']);
      final undoApproval = f.service.approve(undoReview)!;
      final undone = await f.service.execute(undoApproval);
      expect(undone.effect, SupportThemeEffect.undone);
      expect(undone.status, SupportMutationStatus.undone);
      expect(
        (await f.service.execute(undoApproval)).effect,
        SupportThemeEffect.refused,
      );
      expect(f.themeStore.checkedWrites, ['b', 'a']);
      final finalRecord = (await f.record())!;
      expect(finalRecord.beforeJson, immutable!.beforeJson);
      expect(finalRecord.afterJson, immutable.afterJson);
      expect(finalRecord.createdAt, immutable.createdAt);
    },
  );

  for (final right in [
    SupportPermission.readSafeSettings,
    SupportPermission.confirmedSettingsChanges,
  ]) {
    themeActionTest('missing ${right.name} refuses its own boundary', (
      f,
    ) async {
      await f.grant(right, false);
      if (right == SupportPermission.readSafeSettings) {
        final reads = f.themeStore.freshReads;
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
        final observation = (await f.service.observe(f.intent()))!;
        final choice = f.service.projectInstalled(observation)!.choices.last;
        expect(await f.service.prepareApply(choice), isNull);
      }
      expect(f.themeStore.checkedWrites, isEmpty);
    });
  }

  themeActionTest('no theme category denies before installed storage read', (
    f,
  ) async {
    f.runtime.invalidateLease();
    await f.permissions.selectScopeFromNative(
      ThemeActionFixture.session,
      SupportPermissionScope(
        selectionRevision: 2,
        safeCategories: [SupportSafeCategory.connections],
      ),
      isCurrent: () => true,
    );
    await f.permissions.setGrantFromNative(
      ThemeActionFixture.session,
      SupportPermission.readSafeSettings,
      true,
      isCurrent: () => true,
    );
    await f.runtime.refresh();
    final reads = f.themeStore.freshReads;
    expect(
      f.service.emit(
        controller: f.controller,
        uiLifetime: f.uiLifetime,
        isCurrent: () => true,
      ),
      isNull,
    );
    expect(f.themeStore.freshReads, reads);
    expect(f.themeStore.checkedWrites, isEmpty);
  });

  themeActionTest(
    'opaque domain plan and restored journal ID are not native approval',
    (f) async {
      final domain = (await f.theme.observeInstalledThemes(
        isCurrent: () => true,
      )).observation!.planFor('b')!;
      expect(
        () => f.service.execute(forgedThemeApproval(domain)),
        throwsA(isA<TypeError>()),
      );
      expect(
        () => f.service.execute(
          forgedThemeApproval('restored-success-shaped-card'),
        ),
        throwsA(isA<TypeError>()),
      );
      final view = f.service.projectInstalled(
        (await f.service.observe(f.intent()))!,
      )!;
      expect(
        () => f.service.execute(forgedThemeApproval(view.choices.first.value)),
        throwsA(isA<TypeError>()),
      );
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );

  themeActionTest(
    'foreign original service handles cannot target a replacement owner',
    (f) async {
      final approval = await f.approval();
      final old = f.service;
      await f.replaceRuntime();
      expect(
        (await f.service.execute(approval)).effect,
        SupportThemeEffect.refused,
      );
      expect((await old.execute(approval)).effect, SupportThemeEffect.refused);
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );

  themeActionTest(
    'active selection is observed noOp, no effect and no Undo receipt',
    (f) async {
      final result = await f.apply('a');
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(result.status, SupportMutationStatus.failed);
      expect(result.applied, isNull);
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );
  themeActionTest(
    'original displayed UI lifetime cannot rebind at a later click',
    (f) async {
      final approval = await f.approval();
      f.uiLifetime = Object();
      expect(
        (await f.service.execute(approval)).effect,
        SupportThemeEffect.refused,
      );
      expect(f.themeStore.checkedWrites, isEmpty);
      expect((await f.apply()).effect, SupportThemeEffect.applied);
    },
  );

  themeActionTest(
    'durable grant revision cannot merge into old exact final approval',
    (f) async {
      final approval = await f.approval();
      // No refresh: actual fresh policy read must reject the durable revision.
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
      expect(f.themeStore.checkedWrites, isEmpty);
      expect(await f.record(), isNull);
    },
  );
}
