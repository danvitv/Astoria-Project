import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_controls.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_sheet.dart';

import 'support_theme_screen_helpers.dart';

void main() {
  testWidgets(
    'actual current UI shows verified Apply separately from unresolved journal settlement',
    (tester) async {
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        final c = await openThemes(tester, f);
        await readThemes(tester, f, c);
        await reviewTheme(tester, f, c);
        await f.action(tester, () {
          f.sql.event = (event) async {
            if (event.startsWith('update:') &&
                event.contains('support_mutation_journal')) {
              throw StateError('SYNTHETIC_JOURNAL_SETTLEMENT_FAILURE');
            }
          };
        });
        await tapSheet(tester, f, 'support_theme_confirm');
        final fact = await f.finish(
          tester,
          await f.signal(
            tester,
            () => c.originalJob!,
            label: 'original factual Apply with failed journal settlement',
          ),
        );
        await f.action(tester, () => f.sql.event = null);
        await tester.pumpAndSettle();
        expect(fact.effect, SupportThemeEffect.applied);
        expect(fact.journal, SupportThemeJournalSave.unresolved);
        expect(c.intent!.result(fact), same(fact));
        expect(f.backing.activeId, 'b');
        expect(f.theme.store.checkedWrites, ['b']);
        final list = find.byKey(const ValueKey('support_theme_scroll'));
        await reveal(
          tester,
          f,
          find.text('support_theme_effect_applied'),
          list,
        );
        expect(find.text('support_theme_effect_applied'), findsOneWidget);
        await reveal(
          tester,
          f,
          find.text('support_theme_journal_unresolved'),
          list,
        );
        expect(find.text('support_theme_journal_unresolved'), findsOneWidget);
        expect(
          find.textContaining('SYNTHETIC_JOURNAL_SETTLEMENT_FAILURE'),
          findsNothing,
        );
        final row = (await f.action(
          tester,
          () => f.db.select(f.db.supportMutationJournal).get(),
        )).single;
        expect(row.status, 'pending');
        expect(fact.applied, isNull); // no fabricated settled Undo affordance
      });
    },
  );

  testWidgets(
    'actual configured selection with unconfirmed recipient: local Apply, no model adapter/API read',
    (tester) async {
      final f = ThemeScreenFixture(configured: true);
      await f.run(tester, () async {
        expect(f.state.settings.hasConfiguredModel, isTrue);
        expect(f.runtime.recipientConfirmed, isFalse);
        final c = await openThemes(tester, f);
        await readThemes(tester, f, c);
        await reviewTheme(tester, f, c);
        await tapSheet(tester, f, 'support_theme_confirm');
        final fact = await f.finish(
          tester,
          await f.signal(
            tester,
            () => c.originalJob!,
            label: 'local configured/unconfirmed Apply',
          ),
        );
        expect(fact.effect, SupportThemeEffect.applied);
        expect(f.backing.activeId, 'b');
        expect(f.runtime.recipientConfirmed, isFalse);
        expect(f.isolation.attempts, isEmpty);
      });
    },
  );

  for (final ordinary in [
    'selection',
    'selection-ABA',
    'content-edit',
    'delete',
  ]) {
    testWidgets(
      'actual ordinary $ordinary clears point-in-time review, old final callback has no effects',
      (tester) async {
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          final c = await openThemes(tester, f);
          await readThemes(tester, f, c);
          await reviewTheme(tester, f, c);
          final retained = tester
              .widget<SupportThemeButton>(
                find.byKey(const ValueKey('support_theme_confirm')),
              )
              .onTap!;
          final originalPresets = List.of(f.backing.presets);
          final changed = await f.signal(tester, () async {
            switch (ordinary) {
              case 'selection':
                await f.theme.notifier.applyPreset(originalPresets[2]);
              case 'selection-ABA':
                await f.theme.notifier.applyPreset(originalPresets[2]);
                await f.theme.notifier.applyPreset(originalPresets[0]);
              case 'content-edit':
                await f.theme.notifier.updatePreset(
                  originalPresets[0].copyWith(name: 'A updated source content'),
                );
                await f.theme.notifier.flushPersistence();
              case 'delete':
                await f.theme.notifier.deletePreset('b');
            }
          }, label: 'original ordinary $ordinary completion');
          await f.finish(tester, changed);
          await tester.pumpAndSettle();
          expect(c.observation, isNull);
          expect(c.review, isNull);
          final baseline = await f.action(tester, f.baseline);
          await f.action(tester, retained);
          await tester.pumpAndSettle();
          expect(c.originalJob, isNull);
          expect(f.theme.store.checkedWrites, isEmpty);
          expect(await f.action(tester, f.baseline), baseline);
          expect(find.text('support_theme_changed'), findsOneWidget);
          await readThemes(tester, f, c);
          final view = c.intent!.installed(c.observation!)!;
          expect(
            view.choices.any((choice) => choice.value?.id == 'b'),
            ordinary != 'delete',
          );
        });
      },
    );
  }

  for (final loss in ['UI', 'database']) {
    testWidgets(
      'actual STARTED $loss loss retains ORIGINAL factual Future; effect and journal truth separate',
      (tester) async {
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          final c = await openThemes(tester, f);
          await readThemes(tester, f, c);
          await reviewTheme(tester, f, c);
          final gate = await f.action(tester, f.gate);
          await f.action(tester, () => f.theme.store.writeGates.add(gate));
          final started = await f.signal(
            tester,
            () => gate.started.future,
            label: 'ACTUAL checked write invocation',
          );
          await tapSheet(tester, f, 'support_theme_confirm');
          final original = c.originalJob!;
          await f.finish(tester, started);
          expect(f.theme.store.checkedWrites, ['b']);
          final pending = (await f.action(
            tester,
            () => f.db.select(f.db.supportMutationJournal).get(),
          )).single;
          expect(pending.status, 'pending');
          final route = ModalRoute.of<void>(
            tester.element(find.byType(SupportThemeSheet)),
          )!;
          final popped = await f.signal(
            tester,
            () => route.popped,
            label: 'original STARTED close',
          );
          await tapSheet(tester, f, 'support_theme_cancel');
          await f.finish(tester, popped);
          if (loss == 'database') {
            await tester.pumpWidget(const SizedBox.shrink());
            await f.action(tester, () {
              f.container.dispose();
              f.disposed = true;
            });
            await f.finish(
              tester,
              await f.signal(
                tester,
                f.closeDatabase,
                label: 'ACTUAL original DB closure',
              ),
            );
          }
          await f.action(tester, () => gate.release.complete());
          final fact = await f.finish(
            tester,
            await f.signal(
              tester,
              () => original,
              label: 'original STARTED settlement after $loss loss',
            ),
          );
          expect(fact.effectStarted, isTrue);
          expect(fact.effect, SupportThemeEffect.applied);
          expect(f.backing.activeId, 'b');
          expect(
            fact.journal,
            loss == 'UI'
                ? SupportThemeJournalSave.settled
                : SupportThemeJournalSave.unresolved,
          );
          expect(c.intent!.result(fact), isNull); // never replacement paint
          expect(f.theme.store.checkedWrites, ['b']); // no automatic Undo
          if (loss == 'UI') {
            final settled = (await f.action(
              tester,
              () => f.db.select(f.db.supportMutationJournal).get(),
            )).single;
            expect(settled.status, 'applied');
            expect(settled.beforeCiphertext, pending.beforeCiphertext);
            expect(settled.afterCiphertext, pending.afterCiphertext);
          }
        });
      },
    );
  }

  for (final at in ['chooser', 'result']) {
    testWidgets(
      'actual current secret $at labels have no raw/cached-safe fallback',
      (tester) async {
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          final c = await openThemes(tester, f);
          await readThemes(tester, f, c);
          if (at == 'result') {
            await reviewTheme(tester, f, c);
            await tapSheet(tester, f, 'support_theme_confirm');
            await f.finish(
              tester,
              await f.signal(
                tester,
                () => c.originalJob!,
                label: 'current result before policy change',
              ),
            );
            await tester.pumpAndSettle();
          }
          await f.action(
            tester,
            () =>
                f.redaction.registerSecret('B distinguishing installed label'),
          );
          await tester.pumpAndSettle();
          expect(
            find.text('Name: B distinguishing installed label'),
            findsNothing,
          );
          expect(find.text('support_theme_unavailable'), findsWidgets);
          expect(c.current, isFalse);
        });
      },
    );
  }

  for (final width in [320.0, 1100.0]) {
    testWidgets(
      'actual $width / 1.8 scale complete wrap labels and fully visible native Apply controls',
      (tester) async {
        tester.view.physicalSize = Size(width, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          await tester.pumpWidget(f.host(scale: 1.8));
          await tester.pumpAndSettle();
          final c = await openThemes(tester, f);
          await readThemes(tester, f, c);
          await reviewTheme(tester, f, c);
          final list = find.byKey(const ValueKey('support_theme_scroll'));
          expect(
            MediaQuery.paddingOf(tester.element(list)).top,
            greaterThan(0),
          );
          for (final label in [
            'Name: B distinguishing installed label',
            'ID: b',
            'Preset mode: light',
            'Accent: #112233',
          ]) {
            final text = find.text(label);
            await reveal(tester, f, text, list);
            final widget = tester.widget<Text>(text);
            expect(widget.maxLines, isNull);
            expect(widget.overflow, isNot(TextOverflow.ellipsis));
          }
          await tapSheet(tester, f, 'support_theme_confirm');
          final fact = await f.finish(
            tester,
            await f.signal(
              tester,
              () => c.originalJob!,
              label: 'measured $width exact Apply',
            ),
          );
          expect(fact.effect, SupportThemeEffect.applied);
          expect(f.backing.activeId, 'b');
        });
      },
    );
  }
}
