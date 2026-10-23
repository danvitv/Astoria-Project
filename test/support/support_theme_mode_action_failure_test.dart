import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';
import 'package:glaze_flutter/shared/theme/theme_selection.dart';

import 'support_theme_mode_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final undo in [false, true]) {
    for (final outcome in ThemeSelectionSyntheticWrite.values) {
      modeActionTest('mode ${undo ? 'Undo' : 'Apply'} ${outcome.name} facts', (
        f,
      ) async {
        SupportThemeApproval approval;
        if (undo) {
          final applied = await modeApply(f);
          approval = f.service.approve(
            (await f.service.prepareUndo(f.intent(), applied.applied!))!,
          )!;
        } else {
          approval = await modeApproval(f);
        }
        final writes = modeStore(f).modeWrites.length;
        modeStore(f).modeOutcomes.add(outcome);
        final result = await f.service.execute(approval);
        final accepted = outcome == ThemeSelectionSyntheticWrite.accepted;
        expect(
          result.effect,
          accepted
              ? (undo ? SupportThemeEffect.undone : SupportThemeEffect.applied)
              : SupportThemeEffect.uncertain,
        );
        expect(
          result.status,
          accepted
              ? (undo
                    ? SupportMutationStatus.undone
                    : SupportMutationStatus.applied)
              : SupportMutationStatus.reconciliationRequired,
        );
        expect(result.effectStarted, isTrue);
        expect(result.journal, SupportThemeJournalSave.settled);
        expect(modeStore(f).modeWrites.length, writes + 1);
        expect(
          (await f.service.execute(approval)).effect,
          SupportThemeEffect.refused,
        );
        expect(modeStore(f).modeWrites.length, writes + 1);
        if (!accepted) expect(result.applied, isNull);
        expect(f.backing.activeId, 'a');
        final written = !const [
          ThemeSelectionSyntheticWrite.falseBeforeWrite,
          ThemeSelectionSyntheticWrite.throwBeforeWrite,
          ThemeSelectionSyntheticWrite.acceptedWithoutWrite,
        ].contains(outcome);
        expect(
          f.backing.presets.first.themeMode,
          written ? (undo ? 'dark' : 'light') : (undo ? 'light' : 'dark'),
        );
        expect(
          '${result.effect.name}/${result.domainCode?.name}',
          isNot(contains('SYNTHETIC_PRIVATE_EXCEPTION_CANARY')),
        );
      });
    }
  }

  for (final postEffect in [false, true]) {
    modeActionTest(
      'mode fresh read failure ${postEffect ? 'after' : 'before'} write',
      (f) async {
        final approval = await modeApproval(f);
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
        expect(modeStore(f).modeWrites.length, postEffect ? 1 : 0);
        expect(result.applied, isNull);
      },
    );
  }

  for (final boundary in ['encrypt:', 'insert:']) {
    modeActionTest('mode $boundary reservation failure never invokes domain', (
      f,
    ) async {
      final approval = await modeApproval(f);
      f.hook = (e) async {
        if (e.startsWith(boundary) && e.contains('support_mutation_journal')) {
          throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
        }
      };
      final result = await f.service.execute(approval);
      expect(result.effect, SupportThemeEffect.refused);
      expect(result.journal, SupportThemeJournalSave.unresolved);
      expect(result.effectStarted, isFalse);
      expect(modeStore(f).modeWrites, isEmpty);
      expect(await f.record(), isNull);
    });
  }

  for (final undo in [false, true]) {
    modeActionTest(
      'mode settlement failure retains ${undo ? 'reverse' : 'forward'} truth',
      (f) async {
        final applied = undo ? await modeApply(f) : null;
        final approval = undo
            ? f.service.approve(
                (await f.service.prepareUndo(f.intent(), applied!.applied!))!,
              )!
            : await modeApproval(f);
        final initialWrites = modeStore(f).modeWrites.length;
        f.hook = (e) async {
          if (e.startsWith('update:') &&
              e.contains('support_mutation_journal') &&
              modeStore(f).modeWrites.length > initialWrites) {
            throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
          }
        };
        final result = await f.service.execute(approval);
        expect(
          result.effect,
          undo ? SupportThemeEffect.undone : SupportThemeEffect.applied,
        );
        expect(result.journal, SupportThemeJournalSave.unresolved);
        expect(
          result.status,
          undo
              ? SupportMutationStatus.undoPending
              : SupportMutationStatus.pending,
        );
        expect(result.applied, isNull);
        expect(f.custody.unresolvedCount, 1);
        expect(f.backing.presets.first.themeMode, undo ? 'dark' : 'light');
        expect((await f.record())!.status, undo ? 'undo_pending' : 'pending');
      },
    );
  }

  modeActionTest(
    'mode create-only ID collision cannot replace selection evidence',
    (f) async {
      await f.apply();
      final original = (await f.record())!;
      final raw = await f.db.select(f.db.supportMutationJournal).getSingle();
      f.forcedId = f.lastId;
      final result = await modeApply(f);
      expect(result.effect, SupportThemeEffect.refused);
      expect(result.journal, SupportThemeJournalSave.notReserved);
      expect(await f.record(), original);
      expect(await f.db.select(f.db.supportMutationJournal).getSingle(), raw);
      expect(modeStore(f).modeWrites, isEmpty);
      expect(f.themeStore.checkedWrites, ['b']);
    },
  );

  modeActionTest('unresolved original mode ID excludes both action kinds', (
    f,
  ) async {
    final approval = await modeApproval(f);
    f.hook = (e) async {
      if (e.startsWith('update:') && e.contains('support_mutation_journal')) {
        throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_CANARY');
      }
    };
    final result = await f.service.execute(approval);
    expect(result.effect, SupportThemeEffect.applied);
    expect(result.journal, SupportThemeJournalSave.unresolved);
    final original = (await f.record())!;
    f.forcedId = f.lastId;
    expect((await f.apply()).effect, SupportThemeEffect.refused);
    expect((await modeApply(f, 'system')).effect, SupportThemeEffect.refused);
    expect(await f.record(), original);
    expect(f.themeStore.checkedWrites, isEmpty);
    expect(modeStore(f).modeWrites.length, 1);
  });
}
