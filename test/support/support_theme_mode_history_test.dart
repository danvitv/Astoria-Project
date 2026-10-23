import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_theme_action_service.dart';

import 'support_theme_mode_history_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  modeActionTest(
    'mode bounded history retains subtype and refuses cross-domain cursors before SQL',
    (f) async {
      await seedModeHistory(f, count: 33);
      await seedModeHistory(
        f,
        count: 33,
        operation: SupportThemeOperation.selection,
      );
      final intent = f.intent();
      await passiveModeHistory(f, () async {
        final page = await f.service.discoverHistory(
          intent,
          operation: SupportThemeOperation.mode,
        );
        final view = f.service.projectHistory(intent, page);
        expect(page.operation, SupportThemeOperation.mode);
        expect(view.operation, SupportThemeOperation.mode);
        expect(view.availability, SupportThemeHistoryAvailability.available);
        expect(view.entries, hasLength(32));
        expect(view.entries.first.operationId, modeHistoryId(32));
        expect(
          view.entries.every(
            (e) =>
                e.operation == SupportThemeOperation.mode &&
                e.state == SupportThemeRecoveryState.history &&
                e.status == SupportMutationStatus.applied &&
                e.before!.id == e.after!.id &&
                e.before!.mode == 'dark' &&
                e.after!.mode == 'light' &&
                !e.before!.active &&
                !e.after!.active,
          ),
          isTrue,
        );
        final cursor = view.nextCursor!;
        expect(cursor.operation, SupportThemeOperation.mode);
        final events = f.events.length;
        final denied = await f.service.discoverHistory(intent, cursor: cursor);
        expect(
          f.events.length,
          events,
          reason: 'Cross-domain cursor denied before policy/SQL reads.',
        );
        expect(
          f.service.projectHistory(intent, denied).availability,
          SupportThemeHistoryAvailability.unavailable,
        );
        final next = await f.service.discoverHistory(
          intent,
          cursor: cursor,
          operation: SupportThemeOperation.mode,
        );
        final last = f.service.projectHistory(intent, next);
        expect(last.entries.single.operationId, modeHistoryId(0));
        expect(last.nextCursor, isNull);
        final selection = f.service.projectHistory(
          intent,
          await f.service.discoverHistory(intent),
        );
        expect(selection.operation, SupportThemeOperation.selection);
        expect(selection.entries.first.operationId, 'selection-history-032');
        final selectionEvents = f.events.length;
        final deniedMode = await f.service.discoverHistory(
          intent,
          cursor: selection.nextCursor!,
          operation: SupportThemeOperation.mode,
        );
        expect(f.events.length, selectionEvents);
        expect(
          f.service.projectHistory(intent, deniedMode).availability,
          SupportThemeHistoryAvailability.unavailable,
        );
        expect(() => forgedThemeApproval(page), throwsA(isA<TypeError>()));
        expect(() => forgedThemeApplied(page), throwsA(isA<TypeError>()));
        expect(() => forgedThemeApproval(cursor), throwsA(isA<TypeError>()));
        expect(
          () => forgedThemeApplied(view.entries.first),
          throwsA(isA<TypeError>()),
        );
      });
    },
  );

  modeActionTest(
    'mode recovery filters domain before journal AEAD and restores no authority',
    (f) async {
      final result = await modeApply(f);
      final id = f.lastId;
      final intent = f.intent();
      final decrypts = <String>[];
      f.hook = (e) async {
        if (e.startsWith('decrypt-before:') &&
            e.contains('|support_mutation_journal|')) {
          decrypts.add(e);
        }
      };
      await passiveModeHistory(f, () async {
        final selection = await f.service.recover(intent, id);
        expect(selection.state, SupportThemeRecoveryState.unavailable);
        expect(decrypts, isEmpty);
        final mode = await f.service.recover(
          intent,
          id,
          operation: SupportThemeOperation.mode,
        );
        expect(mode.operation, SupportThemeOperation.mode);
        expect(mode.state, SupportThemeRecoveryState.history);
        expect(mode.before!.mode, 'dark');
        expect(mode.after!.mode, 'light');
        expect(mode.before!.active, isFalse);
        expect(mode.after!.active, isFalse);
        expect(decrypts, hasLength(2));
        expect(() => forgedThemeApplied(mode), throwsA(isA<TypeError>()));
        expect(
          () => forgedThemeApproval(mode.after),
          throwsA(isA<TypeError>()),
        );
        expect(
          result.applied,
          isNotNull,
        ); // Only ORIGINAL live execution owns it.
      });
      await f.replaceRuntime();
      final historical = await f.service.recover(
        f.intent(),
        id,
        operation: SupportThemeOperation.mode,
      );
      expect(historical.state, SupportThemeRecoveryState.history);
      expect(
        await f.service.prepareUndo(f.intent(), result.applied!),
        isNotNull,
      );
      // Same custody/theme may review the retained ORIGINAL receipt. History itself
      // exposes no such receipt and cannot manufacture one after recreation.
      await f.replaceTheme();
      expect(await f.service.prepareUndo(f.intent(), result.applied!), isNull);
    },
  );

  for (final status in SupportMutationStatus.values) {
    modeActionTest('mode ${status.value} history is passive observation only', (
      f,
    ) async {
      await seedModeHistory(f, status: status.value);
      final intent = f.intent();
      await passiveModeHistory(f, () async {
        final page = await f.service.discoverHistory(
          intent,
          operation: SupportThemeOperation.mode,
        );
        final row = f.service.projectHistory(intent, page).entries.single;
        expect(row.operation, SupportThemeOperation.mode);
        expect(row.status, status);
        expect(
          row.state,
          status.unresolved
              ? SupportThemeRecoveryState.uncertain
              : SupportThemeRecoveryState.history,
        );
        expect(row.before!.active, isFalse);
        expect(row.after!.active, isFalse);
      });
    });
  }

  for (final invalid in ['unknown-codec', 'foreign-preset']) {
    modeActionTest('mode $invalid history is explicit unavailable, not empty', (
      f,
    ) async {
      await seedModeHistory(
        f,
        malformed: invalid == 'unknown-codec',
        foreignPreset: invalid == 'foreign-preset',
      );
      final intent = f.intent();
      await passiveModeHistory(f, () async {
        final view = f.service.projectHistory(
          intent,
          await f.service.discoverHistory(
            intent,
            operation: SupportThemeOperation.mode,
          ),
        );
        expect(view.availability, SupportThemeHistoryAvailability.available);
        expect(
          view.entries.single.state,
          SupportThemeRecoveryState.unavailable,
        );
        expect(view.entries.single.operation, SupportThemeOperation.mode);
        expect(view.entries.single.before, isNull);
        expect(view.entries.single.after, isNull);
      });
    });
  }

  for (final boundary in [32, 1]) {
    modeActionTest(
      'mode exact encrypted boundary $boundary refuses re-encryption continuation',
      (f) async {
        await seedModeHistory(f, count: 33);
        final intent = f.intent();
        final page = await f.service.discoverHistory(
          intent,
          operation: SupportThemeOperation.mode,
        );
        final cursor = f.service.projectHistory(intent, page).nextCursor!;
        await f.repo.putMutation(
          (await f.repo.getMutationById(modeHistoryId(boundary)))!,
        );
        await passiveModeHistory(f, () async {
          final denied = await f.service.discoverHistory(
            intent,
            cursor: cursor,
            operation: SupportThemeOperation.mode,
          );
          expect(
            f.service.projectHistory(intent, denied).availability,
            SupportThemeHistoryAvailability.unavailable,
          );
        });
      },
    );
  }

  modeActionTest(
    'mode current known label reprojection clears old continuation authority',
    (f) async {
      await seedModeHistory(f, count: 33);
      final intent = f.intent();
      final page = await f.service.discoverHistory(
        intent,
        operation: SupportThemeOperation.mode,
      );
      f.redaction.registerSecret('Historical A');
      await passiveModeHistory(f, () async {
        final view = f.service.projectHistory(intent, page);
        expect(view.entries.first.before!.name, SecretRedactor.removed);
        expect(view.entries.first.after!.name, SecretRedactor.removed);
        expect(view.nextCursor, isNull);
      });
      f.redaction.registerSecret(modeHistoryId(32));
      await passiveModeHistory(f, () async {
        final row = f.service.projectHistory(intent, page).entries.first;
        expect(row.state, SupportThemeRecoveryState.unavailable);
        expect(row.operationId, isNull);
        expect(row.before, isNull);
      });
    },
  );

  modeActionTest(
    'mode history rechecks shared original live Undo jobs at projection',
    (f) async {
      final applied = await modeApply(f);
      final intent = f.intent();
      final page = await f.service.discoverHistory(
        intent,
        operation: SupportThemeOperation.mode,
      );
      final review = (await f.service.prepareUndo(intent, applied.applied!))!;
      final gate = f.themeGate();
      modeStore(f).modeGates.add(gate);
      final job = f.service.execute(f.service.approve(review)!);
      await gate.started.future;
      await passiveModeHistory(f, () async {
        final row = f.service.projectHistory(intent, page).entries.single;
        expect(row.state, SupportThemeRecoveryState.liveJob);
        expect(row.before, isNull);
        expect(row.status, isNull);
        final mode = await f.service.recover(
          intent,
          f.lastId,
          operation: SupportThemeOperation.mode,
        );
        expect(mode.state, SupportThemeRecoveryState.liveJob);
        final selection = await f.service.recover(intent, f.lastId);
        expect(selection.state, SupportThemeRecoveryState.unavailable);
      });
      gate.release.complete();
      expect((await job).effect, SupportThemeEffect.undone);
    },
  );
}
