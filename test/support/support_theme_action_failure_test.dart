import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';
import 'support_theme_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final undo in [false, true]) {
    for (final mode in ThemeSelectionSyntheticWrite.values) {
      themeActionTest(
        '${undo ? 'Undo' : 'Apply'} classifies actual ${mode.name}',
        (f) async {
          SupportThemeApproval approval;
          if (undo) {
            final applied = await f.apply();
            approval = f.service.approve(
              (await f.service.prepareUndo(f.intent(), applied.applied!))!,
            )!;
          } else {
            approval = await f.approval();
          }
          final count = f.themeStore.checkedWrites.length;
          f.themeStore.checkedModes.add(mode);
          final result = await f.service.execute(approval);
          final accepted = mode == ThemeSelectionSyntheticWrite.accepted;
          expect(
            result.effect,
            accepted
                ? (undo
                      ? SupportThemeEffect.undone
                      : SupportThemeEffect.applied)
                : SupportThemeEffect.uncertain,
          );
          expect(result.effectStarted, isTrue);
          expect(
            result.status,
            accepted
                ? (undo
                      ? SupportMutationStatus.undone
                      : SupportMutationStatus.applied)
                : SupportMutationStatus.reconciliationRequired,
          );
          expect(result.journal, SupportThemeJournalSave.settled);
          expect(f.themeStore.checkedWrites.length, count + 1);
          expect(
            (await f.service.execute(approval)).effect,
            SupportThemeEffect.refused,
          );
          expect(f.themeStore.checkedWrites.length, count + 1);
          if (!accepted) expect(result.applied, isNull);
          expect(
            '${result.effect.name}/${result.domainCode?.name}',
            isNot(contains('SYNTHETIC_PRIVATE_EXCEPTION_CANARY')),
          );
        },
      );
    }
  }

  for (final postEffect in [false, true]) {
    themeActionTest(
      '${postEffect ? 'post' : 'pre'} effect fresh-read failure is distinctly classified',
      (f) async {
        final approval = await f.approval();
        f.themeStore.failAtFreshRead =
            f.themeStore.freshReads + (postEffect ? 2 : 1);
        final result = await f.service.execute(approval);
        expect(
          result.domainCode,
          postEffect
              ? ThemeSelectionCode.verificationFailed
              : ThemeSelectionCode.readFailed,
        );
        expect(result.effectStarted, postEffect);
        expect(
          result.effect,
          postEffect
              ? SupportThemeEffect.uncertain
              : SupportThemeEffect.noEffect,
        );
        expect(
          result.status,
          postEffect
              ? SupportMutationStatus.reconciliationRequired
              : SupportMutationStatus.failed,
        );
        expect(f.themeStore.checkedWrites.length, postEffect ? 1 : 0);
      },
    );
  }

  themeActionTest(
    'accepted write with fresh conflicting selection is reconciliation, never retry',
    (f) async {
      final approval = await f.approval();
      f.themeStore.afterCheckedWrite = () => f.backing.activeId = 'c';
      final result = await f.service.execute(approval);
      expect(result.domainCode, ThemeSelectionCode.verificationConflict);
      expect(result.effect, SupportThemeEffect.uncertain);
      expect(result.status, SupportMutationStatus.reconciliationRequired);
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );

  themeActionTest(
    'create-only journal ID collision preserves encrypted evidence and starts no new write',
    (f) async {
      await f.apply();
      final before = await f.record();
      final row = await (f.db.select(f.db.supportMutationJournal)).getSingle();
      f.forcedId = f.lastId;
      final result = await f.apply('c');
      expect(result.effect, SupportThemeEffect.refused);
      expect(result.journal, SupportThemeJournalSave.notReserved);
      expect(await f.record(), before);
      expect(await (f.db.select(f.db.supportMutationJournal)).getSingle(), row);
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );

  themeActionTest('real AEAD reservation failure has zero domain effects', (
    f,
  ) async {
    final approval = await f.approval();
    f.hook = (e) async {
      if (e.startsWith('encrypt:') && e.contains('support_mutation_journal')) {
        throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
      }
    };
    final result = await f.service.execute(approval);
    expect(result.effect, SupportThemeEffect.refused);
    expect(result.journal, SupportThemeJournalSave.unresolved);
    expect(await f.record(), isNull);
    expect(f.themeStore.checkedWrites, isEmpty);
  });

  themeActionTest(
    'journal failure after real effect retains separate domain truth and original evidence',
    (f) async {
      final approval = await f.approval();
      f.hook = (e) async {
        if (e.startsWith('update:') && e.contains('support_mutation_journal')) {
          throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
        }
      };
      final result = await f.service.execute(approval);
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.journal, SupportThemeJournalSave.unresolved);
      expect(result.status, SupportMutationStatus.pending);
      expect(result.applied, isNull);
      expect(f.custody.unresolvedCount, 1);
      expect(f.backing.activeId, 'b');
      expect((await f.record())!.status, 'pending');
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );

  themeActionTest(
    'Undo journal failure after real reverse write is not painted as failed rollback',
    (f) async {
      final applied = await f.apply();
      final review = (await f.service.prepareUndo(
        f.intent(),
        applied.applied!,
      ))!;
      f.hook = (e) async {
        if (e.startsWith('update:') &&
            e.contains('support_mutation_journal') &&
            f.themeStore.checkedWrites.length == 2) {
          throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
        }
      };
      final result = await f.service.execute(f.service.approve(review)!);
      expect(result.effect, SupportThemeEffect.undone);
      expect(result.journal, SupportThemeJournalSave.unresolved);
      expect(result.status, SupportMutationStatus.undoPending);
      expect(f.backing.activeId, 'a');
      expect((await f.record())!.status, 'undo_pending');
      expect(f.themeStore.checkedWrites, ['b', 'a']);
    },
  );

  themeActionTest(
    'old custody refuses parent title re-encryption after effect without rebinding',
    (f) async {
      final approval = await f.approval();
      final gate = f.themeGate();
      f.themeStore.writeGates.add(gate);
      final job = f.service.execute(approval);
      await gate.started.future;
      await f.repo.renameSession(
        sessionId: ThemeActionFixture.session,
        title: 'Re-encrypted title',
      );
      gate.release.complete();
      final result = await job;
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.journal, SupportThemeJournalSave.unresolved);
      expect((await f.record())!.status, 'pending');
      expect(f.custody.unresolvedCount, 1);
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );

  themeActionTest(
    'genuine original data-owner loss refuses factual journal settlement',
    (f) async {
      final approval = await f.approval();
      f.themeStore.afterCheckedWrite = () => f.dbCurrent = false;
      final result = await f.service.execute(approval);
      expect(result.effect, SupportThemeEffect.applied);
      expect(result.journal, SupportThemeJournalSave.unresolved);
      expect(result.applied, isNull);
      expect(f.backing.activeId, 'b');
      expect((await f.record())!.status, 'pending');
    },
  );
  themeActionTest(
    'parent rename before Undo refuses old encrypted expected custody, never silently rebinds',
    (f) async {
      final applied = await f.apply();
      await f.repo.renameSession(
        sessionId: ThemeActionFixture.session,
        title: 'Changed title',
      );
      final result = await f.undo(applied.applied!);
      expect(result.effect, SupportThemeEffect.refused);
      expect((await f.record())!.status, 'applied');
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );

  themeActionTest(
    'strict invalid storage after reservation is observed pre-effect refusal',
    (f) async {
      final approval = await f.approval();
      f.backing.malformed = true;
      final result = await f.service.execute(approval);
      expect(result.domainCode, ThemeSelectionCode.invalidStorage);
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(result.status, SupportMutationStatus.failed);
      expect(f.themeStore.checkedWrites, isEmpty);
    },
  );

  themeActionTest(
    'locked real vault refuses authorization before reservation or domain invocation',
    (f) async {
      final approval = await f.approval();
      f.storage.readError = StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
      final result = await f.service.execute(approval);
      expect(result.effect, SupportThemeEffect.refused);
      expect(f.themeStore.checkedWrites, isEmpty);
      f.storage.readError = null;
      expect(await f.record(), isNull);
    },
  );
}
