import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';

import 'support_theme_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final undo in [false, true]) {
    for (final mode in ThemeSelectionSyntheticWrite.values.where(
      (mode) => mode != ThemeSelectionSyntheticWrite.accepted,
    )) {
      themeProviderTest(
        'actual provider ${undo ? 'Undo' : 'Apply'} ${mode.name} retains separate domain/journal truth',
        (f) async {
          if (undo) await f.apply();
          final intent = f.emit()!;
          final review = undo
              ? (await intent.prepareLastUndo())!
              : await f.review(intent);
          f.harness.store.checkedModes.add(mode);
          final result = await f.confirm(intent, review);
          expect(result.effectStarted, isTrue);
          expect(result.effect, SupportThemeEffect.uncertain);
          expect(result.journal, SupportThemeJournalSave.settled);
          expect(result.status, SupportMutationStatus.reconciliationRequired);
          expect(result.applied, isNull);
          expect(f.harness.store.checkedWrites.length, undo ? 2 : 1);
          final row = (await f.repo.getMutationsForSession(
            ThemeProviderFixture.session,
          )).single;
          expect(row.status, 'reconciliation_required');
          expect(
            await f.workspace.deleteSession(ThemeProviderFixture.session),
            isFalse,
          );
        },
      );
    }
    themeProviderTest(
      'actual ${undo ? 'Undo' : 'Apply'} effect survives journal update failure, no retry',
      (f) async {
        if (undo) await f.apply();
        final intent = f.emit()!;
        final review = undo
            ? (await intent.prepareLastUndo())!
            : await f.review(intent);
        f.sql.event = (event) async {
          if (event.startsWith('update:') &&
              event.contains('support_mutation_journal')) {
            // Undo admission's undo_pending UPDATE must commit before effect.
            if (f.harness.store.checkedWrites.length == (undo ? 2 : 1)) {
              throw StateError('Synthetic journal delivery failure');
            }
          }
        };
        final result = await f.confirm(intent, review);
        f.sql.event = null;
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
        expect(f.custody.unresolvedCount, 1);
        expect(result.applied, isNull);
        expect(f.harness.store.checkedWrites.length, undo ? 2 : 1);
      },
    );
  }
  for (final undo in [false, true]) {
    for (final edit in ['selection', 'selectionABA', 'edit', 'delete']) {
      themeProviderTest(
        'ordinary same-owner $edit queued during ${undo ? 'Undo' : 'Apply'} fresh read preserves current store',
        (f) async {
          if (undo) await f.apply();
          final intent = f.emit()!;
          final review = undo
              ? (await intent.prepareLastUndo())!
              : await f.review(intent);
          final theme = f.harness.notifier;
          final presets = f.backing.presets;
          final gate = f.gate();
          f.harness.store.freshReadGates.add(gate);
          final job = f.confirm(intent, review);
          await gate.started.future;
          Future<void> mutation;
          switch (edit) {
            case 'selection':
              mutation = theme.applyPreset(presets.last);
            case 'selectionABA':
              final first = theme.applyPreset(presets.last);
              final second = theme.applyPreset(presets[undo ? 1 : 0]);
              mutation = Future.wait([first, second]).then((_) {});
            case 'edit':
              mutation = theme.updatePreset(
                presets[1].copyWith(name: 'Changed B'),
              );
            case 'delete':
              mutation = theme.deletePreset('b');
            default:
              throw StateError('Unknown synthetic ordinary edit');
          }
          gate.release.complete();
          final result = await job;
          await mutation;
          await theme.flushPersistence();
          expect(result.effect, SupportThemeEffect.noEffect);
          expect(
            result.status,
            undo
                ? SupportMutationStatus.undoConflict
                : SupportMutationStatus.failed,
          );
          expect(f.harness.store.checkedWrites, undo ? ['b'] : isEmpty);
          if (edit == 'selection') expect(f.backing.activeId, 'c');
          if (edit == 'selectionABA') {
            expect(f.backing.activeId, undo ? 'b' : 'a');
          }
          if (edit == 'delete') {
            expect(
              f.backing.presets.any((preset) => preset.id == 'b'),
              isFalse,
            );
          }
        },
      );
    }
  }
  themeProviderTest(
    'theme preview/effect bypasses held broad workspace display FIFO',
    (f) async {
      final barrier = f.barrier();
      var held = false;
      f.sql.event = (event) async {
        if (!held &&
            event.startsWith('select:') &&
            event.contains('support_sessions')) {
          held = true;
          await barrier.wait();
        }
      };
      final local = f.workspace.refresh();
      await barrier.entered.future;
      expect(f.state.isBusy, isTrue);
      final originalService = f.binding.service;
      final intent = f.emit()!;
      final review = await f.review(intent);
      expect(
        (await f.confirm(intent, review)).effect,
        SupportThemeEffect.applied,
      );
      expect(f.binding.service, same(originalService));
      expect(f.runtime.pending, 0);
      barrier.release.complete();
      expect(await local, isTrue);
    },
  );
}
