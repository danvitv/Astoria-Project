import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_evidence_codec.dart';
import 'support_theme_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final status in [
    SupportMutationStatus.pending,
    SupportMutationStatus.applied,
    SupportMutationStatus.undoPending,
    SupportMutationStatus.reconciliationRequired,
  ]) {
    themeActionTest(
      'new owner reads ${status.value} facts without replay or restored Undo',
      (f) async {
        const codec = SupportThemeEvidenceCodec();
        final review = await f.review();
        final preview = f.service.projectReview(review)!;
        const id = '22222222-2222-4222-8222-222222222222';
        final reserved = (await f.repo.reserveMutation(
          record: SupportMutationRecord(
            id: id,
            sessionId: ThemeActionFixture.session,
            domain: SupportThemeEvidenceCodec.domain,
            targetId: SupportThemeEvidenceCodec.target,
            beforeJson: codec.encode(
              sessionId: ThemeActionFixture.session,
              value: preview.before,
              policy: f.redaction.redactor,
            ),
            afterJson: codec.encode(
              sessionId: ThemeActionFixture.session,
              value: preview.after,
              policy: f.redaction.redactor,
            ),
            status: 'pending',
            createdAt: 5,
          ),
          isCurrent: () => true,
        ))!;
        if (status == SupportMutationStatus.applied ||
            status == SupportMutationStatus.undoPending) {
          final applied = (await f.repo.settleMutation(
            expected: reserved,
            fact: SupportMutationFact.applied,
            hasOriginalDbCustody: () => true,
          ))!;
          if (status == SupportMutationStatus.undoPending) {
            await f.repo.reserveMutationUndo(
              expected: applied,
              isCurrent: () => true,
            );
          }
        } else if (status == SupportMutationStatus.reconciliationRequired) {
          await f.repo.settleMutation(
            expected: reserved,
            fact: SupportMutationFact.reconciliationRequired,
            hasOriginalDbCustody: () => true,
          );
        }
        final immutable = await f.repo.getMutationById(id);
        await f.replaceTheme();
        final recovered = await f.service.recover(f.intent(), id);
        expect(recovered.status, status);
        expect(
          recovered.state,
          status.unresolved
              ? SupportThemeRecoveryState.uncertain
              : SupportThemeRecoveryState.history,
        );
        expect(recovered.before!.id, 'a');
        expect(recovered.after!.id, 'b');
        expect(await f.repo.getMutationById(id), immutable);
        expect(f.themeStore.checkedWrites, isEmpty);
        expect(f.oldThemes.single.store.checkedWrites, isEmpty);
        expect(
          () => f.service.execute(forgedThemeApproval(recovered)),
          throwsA(isA<TypeError>()),
        );
        expect(
          () =>
              f.service.prepareUndo(f.intent(), forgedThemeApplied(recovered)),
          throwsA(isA<TypeError>()),
        );
      },
    );
  }

  themeActionTest(
    'real applied history with recreated domain owner cannot fabricate same-receipt Undo',
    (f) async {
      final applied = await f.apply();
      final id = f.lastId;
      await f.replaceTheme();
      final recovery = await f.service.recover(f.intent(), id);
      expect(recovery.state, SupportThemeRecoveryState.history);
      expect(recovery.status, SupportMutationStatus.applied);
      expect(await f.service.prepareUndo(f.intent(), applied.applied!), isNull);
      expect(f.backing.activeId, 'b');
      expect(f.themeStore.checkedWrites, isEmpty);
      expect(f.oldThemes.single.store.checkedWrites, ['b']);
    },
  );

  themeActionTest(
    'replacement recovery cannot race retained original started job into reconciliation',
    (f) async {
      final approval = await f.approval();
      final gate = f.themeGate();
      f.themeStore.writeGates.add(gate);
      final job = f.service.execute(approval);
      await gate.started.future;
      final id = f.lastId;
      await f.replaceRuntime();
      final recovered = await f.service.recover(f.intent(), id);
      expect(recovered.state, SupportThemeRecoveryState.liveJob);
      expect((await f.record(id))!.status, 'pending');
      gate.release.complete();
      final result = await job;
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.status, SupportMutationStatus.applied);
      await f.custody.drain();
      expect(f.custody.activeJobs, 0);
      final finalRecovery = await f.service.recover(f.intent(), id);
      expect(finalRecovery.state, SupportThemeRecoveryState.history);
      expect(finalRecovery.status, SupportMutationStatus.applied);
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );

  themeActionTest(
    'unknown strict inner evidence remains unavailable, never default restored authority',
    (f) async {
      const id = '22222222-2222-4222-8222-222222222222';
      await f.repo.reserveMutation(
        record: SupportMutationRecord(
          id: id,
          sessionId: ThemeActionFixture.session,
          domain: SupportThemeEvidenceCodec.domain,
          targetId: SupportThemeEvidenceCodec.target,
          beforeJson: SupportMutationEvidence.encode(
            '{"v":99,"model":"Apply now"}',
          ),
          afterJson: SupportMutationEvidence.encode(
            '{"v":99,"model":"applied"}',
          ),
          status: 'pending',
          createdAt: 5,
        ),
        isCurrent: () => true,
      );
      final recovered = await f.service.recover(f.intent(), id);
      expect(recovered.state, SupportThemeRecoveryState.unavailable);
      expect(f.themeStore.checkedWrites, isEmpty);
      expect((await f.repo.getMutationById(id))!.status, 'pending');
    },
  );

  themeActionTest(
    'recovery validates exact session ownership before journal disclosure',
    (f) async {
      await f.apply();
      final id = f.lastId;
      f.runtime.selectSession('foreign-theme-session');
      await f.runtime.refresh();
      expect(
        f.service.emit(
          controller: f.controller,
          uiLifetime: f.uiLifetime,
          isCurrent: () => true,
        ),
        isNull,
      );
      expect((await f.record(id))!.sessionId, ThemeActionFixture.session);
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );
  themeActionTest(
    'foreign session cannot observe existence of a retained original live job',
    (f) async {
      final approval = await f.approval();
      final gate = f.themeGate();
      f.themeStore.writeGates.add(gate);
      final job = f.service.execute(approval);
      await gate.started.future;
      final id = f.lastId;
      const foreign = 'foreign-theme-session';
      await f.repo.createSession(
        const SupportSession(
          id: foreign,
          title: 'Foreign',
          createdAt: 1,
          updatedAt: 2,
        ),
      );
      await f.permissions.selectScopeFromNative(
        foreign,
        SupportPermissionScope(
          selectionRevision: 1,
          safeCategories: [SupportSafeCategory.theme],
        ),
        isCurrent: () => true,
      );
      await f.permissions.setGrantFromNative(
        foreign,
        SupportPermission.readSafeSettings,
        true,
        isCurrent: () => true,
      );
      f.runtime.selectSession(foreign);
      await f.runtime.refresh();
      final recovery = await f.service.recover(f.intent(), id);
      expect(recovery.state, SupportThemeRecoveryState.unavailable);
      gate.release.complete();
      expect((await job).status, SupportMutationStatus.applied);
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );
}
