import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_controls.dart';

import 'support_theme_mode_screen_helpers.dart';

void main() {
  testWidgets(
    'actual narrow scaled mode controls and exact confirmation remain reachable',
    (tester) async {
      tester.view.physicalSize = const Size(390, 850);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await tester.pumpWidget(f.host(scale: 1.3));
        await tester.pumpAndSettle();
        final c = await openThemes(tester, f);
        await readThemes(tester, f, c);
        final list = find.byKey(const ValueKey('support_theme_scroll'));
        for (final mode in ['dark', 'light', 'system']) {
          final control = find.byKey(
            ValueKey('support_theme_mode_choice_$mode'),
          );
          await reveal(tester, f, control, list);
          fullControl(tester, control, list);
        }
        await reviewMode(tester, f, c, 'system');
        final confirm = find.byKey(const ValueKey('support_theme_confirm'));
        await reveal(tester, f, confirm, list);
        fullControl(tester, confirm, list);
        expect(f.backing.presets.first.themeMode, 'dark');
        expect(c.originalJob, isNull);
      });
    },
  );

  for (final mode in ['light', 'system']) {
    testWidgets(
      'actual offline $mode preview Apply then separately approved Undo',
      (tester) async {
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          final before = List.of(f.backing.presets);
          final c = await openThemes(tester, f);
          await readThemes(tester, f, c);
          await reviewMode(tester, f, c, mode);
          expect(f.backing.presets, before);
          expect(f.backing.activeId, 'a');
          final preview = c.intent!.preview(c.review!)!;
          expect(preview.before.mode, 'dark');
          expect(preview.after.mode, mode);
          final fact = await confirmMode(tester, f, c);
          expect(fact.effect, SupportThemeEffect.applied);
          expect(fact.journal, SupportThemeJournalSave.settled);
          expect(fact.status, SupportMutationStatus.applied);
          expect(f.backing.activeId, 'a');
          expect(
            f.backing.presets.first,
            before.first.copyWith(themeMode: mode),
          );
          expect(f.backing.presets.skip(1), before.skip(1));
          expect(f.theme.notifier.state.activePreset, f.backing.presets.first);
          expect(f.theme.store.checkedWrites, isEmpty);
          expect(f.runtime.recipientConfirmed, isFalse);
          final row = (await f.action(
            tester,
            () => f.db.select(f.db.supportMutationJournal).get(),
          )).single;
          expect(row.domain, 'theme.mode');
          expect(row.targetId, 'active-preset-mode');
          expect(
            row.beforeCiphertext,
            isNot(contains('A full installed label')),
          );
          expect(
            row.afterCiphertext,
            isNot(contains('A full installed label')),
          );

          final ready = await f.signal(
            tester,
            () => uiReached(
              c,
              () => !c.busy && c.review?.kind == SupportThemeActionKind.undo,
            ),
            label: 'NEW original mode Undo review',
          );
          await tapSheet(tester, f, 'support_theme_undo');
          await f.finish(tester, ready);
          await tester.pumpAndSettle();
          expect(
            c.intent!.preview(c.review!)!.operation,
            SupportThemeOperation.mode,
          );
          expect(f.backing.presets.first.themeMode, mode);
          final undone = await confirmMode(tester, f, c);
          expect(undone.effect, SupportThemeEffect.undone);
          expect(f.backing.presets, before);
          expect(f.backing.activeId, 'a');
          final settled = (await f.action(
            tester,
            () => f.db.select(f.db.supportMutationJournal).get(),
          )).single;
          expect(settled.id, row.id);
          expect(settled.beforeCiphertext, row.beforeCiphertext);
          expect(settled.afterCiphertext, row.afterCiphertext);
          expect(settled.status, 'undone');
        });
      },
    );
  }

  testWidgets(
    'actual native mode controls require changes independently of local read',
    (tester) async {
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await f.action(tester, () async {
          final review = (await f.controller.prepareReview(
            resolveRecipient: false,
          ))!;
          expect(
            await f.controller.setGrant(
              review,
              SupportPermission.confirmedSettingsChanges,
              false,
            ),
            isTrue,
          );
        });
        await tester.pumpAndSettle();
        final c = await openThemes(tester, f);
        await readThemes(tester, f, c);
        final before = await f.action(tester, f.baseline);
        final denied = await f.signal(
          tester,
          () => uiReached(c, () => !c.busy && c.notice != null),
          label: 'mode changes prerequisite refusal',
        );
        await tapSheet(tester, f, 'support_theme_mode_choice_light');
        await f.finish(tester, denied);
        expect(c.review, isNull);
        expect(c.originalJob, isNull);
        expect(await f.action(tester, f.baseline), before);
        expect(f.runtime.recipientConfirmed, isFalse);
      });
    },
  );

  testWidgets(
    'actual mode preview cancel and retained final callback never write',
    (tester) async {
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        final c = await openThemes(tester, f);
        await readThemes(tester, f, c);
        await reviewMode(tester, f, c);
        final list = find.byKey(const ValueKey('support_theme_scroll'));
        final confirm = find.byKey(const ValueKey('support_theme_confirm'));
        await reveal(tester, f, confirm, list);
        final retained = tester.widget<SupportThemeButton>(confirm).onTap!;
        final before = await f.action(tester, f.baseline);
        await tapSheet(tester, f, 'support_theme_cancel');
        await tester.pumpAndSettle();
        await f.action(tester, retained);
        expect(c.originalJob, isNull);
        expect(await f.action(tester, f.baseline), before);
      });
    },
  );

  testWidgets('actual mode Undo refuses ordinary edited active content', (
    tester,
  ) async {
    final f = ThemeScreenFixture();
    await f.run(tester, () async {
      final c = await openThemes(tester, f);
      await readThemes(tester, f, c);
      await reviewMode(tester, f, c);
      final applied = await confirmMode(tester, f, c);
      expect(applied.effect, SupportThemeEffect.applied);
      final edited = f.backing.presets.first.copyWith(accentColor: '#ABCDEF');
      await f.action(tester, () async {
        await f.theme.notifier.updatePreset(edited);
        await f.theme.notifier.flushPersistence();
      });
      await tester.pumpAndSettle();
      final ready = await f.signal(
        tester,
        () => uiReached(c, () => !c.busy && c.review != null),
        label: 'mode Undo review after native edit',
      );
      await tapSheet(tester, f, 'support_theme_undo');
      await f.finish(tester, ready);
      final result = await confirmMode(tester, f, c);
      expect(result.effect, SupportThemeEffect.noEffect);
      expect(f.backing.presets.first, edited);
      expect(f.backing.activeId, 'a');
    });
  });

  testWidgets(
    'actual selection and mode history are separate passive observations',
    (tester) async {
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await f.action(tester, () => f.seedHistory());
        final c = await openThemes(tester, f);
        await readThemes(tester, f, c);
        await reviewMode(tester, f, c);
        await confirmMode(tester, f, c);
        final before = await f.action(tester, f.baseline);
        await tapSheet(tester, f, 'support_theme_history_kind_mode');
        expect(c.historyOperation, SupportThemeOperation.mode);
        final ready = await f.signal(
          tester,
          () => uiReached(c, () => !c.busy && c.pages.isNotEmpty),
          label: 'mode-only native history',
        );
        await tapSheet(tester, f, 'support_theme_history_refresh');
        await f.finish(tester, ready);
        await tester.pumpAndSettle();
        final mode = c.intent!.history(c.pages.single)!.entries.single;
        expect(mode.before!.id, 'a');
        expect(mode.before!.mode, 'dark');
        expect(mode.after!.mode, 'light');
        expect(mode.before!.active, isFalse);
        expect(mode.after!.active, isFalse);
        await tapSheet(tester, f, 'support_theme_history_kind_selection');
        expect(c.pages, isEmpty);
        final selectionReady = await f.signal(
          tester,
          () => uiReached(c, () => !c.busy && c.pages.isNotEmpty),
          label: 'selection-only native history',
        );
        await tapSheet(tester, f, 'support_theme_history_refresh');
        await f.finish(tester, selectionReady);
        expect(
          c.intent!.history(c.pages.single)!.entries.single.operationId,
          'restored-000',
        );
        expect(await f.action(tester, f.baseline), before);
      });
    },
  );
}
