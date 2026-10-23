import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';

import 'support_theme_screen_helpers.dart';

void main() {
  testWidgets(
    'actual restored reconciliation row is uncertain, never a settled effect or executable Undo',
    (tester) async {
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await f.action(
          tester,
          () => f.seedHistory(status: 'reconciliation_required'),
        );
        final before = await f.action(tester, f.baseline);
        final c = await openThemes(tester, f);
        final loaded = await f.signal(
          tester,
          () => uiReached(c, () => !c.busy && c.pages.isNotEmpty),
          label: 'original uncertain restored row',
        );
        await tapSheet(tester, f, 'support_theme_history_refresh');
        await f.finish(tester, loaded);
        await tester.pumpAndSettle();
        final view = c.intent!.history(c.pages.single)!;
        expect(view.entries.single.state, SupportThemeRecoveryState.uncertain);
        await reveal(
          tester,
          f,
          find.text('support_theme_history_uncertain'),
          find.byKey(const ValueKey('support_theme_scroll')),
        );
        expect(find.text('support_theme_history_uncertain'), findsOneWidget);
        expect(find.text('support_theme_effect_applied'), findsNothing);
        expect(c.originalJob, isNull);
        expect(await f.action(tester, f.baseline), before);
      });
    },
  );

  testWidgets(
    'actual restored 65 history entries: 32/32/1 native order, read-only, no receipts or replay',
    (tester) async {
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await f.action(tester, () => f.seedHistory(count: 65));
        final baseline = await f.action(tester, f.baseline);
        final freshReads = f.theme.store.freshReads;
        final c = await openThemes(tester, f);
        for (var page = 0; page < 3; page++) {
          final loaded = await f.signal(
            tester,
            () => uiReached(c, () => !c.busy && c.pages.length == page + 1),
            label: 'original native history page $page',
          );
          await tapSheet(
            tester,
            f,
            page == 0
                ? 'support_theme_history_refresh'
                : 'support_theme_history_next',
          );
          await f.finish(tester, loaded);
          await tester.pumpAndSettle();
        }
        final views = c.pages.map(c.intent!.history).toList();
        expect(views.map((v) => v!.entries.length), [32, 32, 1]);
        expect(
          views.every(
            (v) => v!.availability == SupportThemeHistoryAvailability.available,
          ),
          isTrue,
        );
        final entries = views.expand((v) => v!.entries).toList();
        expect(entries.map((e) => e.operationId), [
          for (var i = 64; i >= 0; i--)
            'restored-${i.toString().padLeft(3, '0')}',
        ]);
        expect(
          entries.every(
            (e) => e.before!.active == false && e.after!.active == false,
          ),
          isTrue,
        );
        expect(
          entries.every((e) => e.state == SupportThemeRecoveryState.history),
          isTrue,
        );
        expect(views.last!.nextCursor, isNull);
        expect(f.theme.store.freshReads, freshReads);
        expect(f.theme.store.checkedWrites, isEmpty);
        expect(await f.action(tester, f.baseline), baseline);
        final denied = await f.signal(
          tester,
          () => uiReached(c, () => !c.busy && c.notice != null),
          label: 'restored history cannot reconstruct Undo',
        );
        await tapSheet(tester, f, 'support_theme_undo');
        await f.finish(tester, denied);
        expect(c.review, isNull);
        expect(c.originalJob, isNull);
        expect(await f.action(tester, f.baseline), baseline);
      });
    },
  );

  for (final unknown in [false, true]) {
    testWidgets(
      'actual history ${unknown ? 'unavailable row is retained' : 'readable empty is explicit'}, never false empty',
      (tester) async {
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          if (unknown) {
            await f.action(tester, () => f.seedHistory(unknown: true));
          }
          final baseline = await f.action(tester, f.baseline);
          final c = await openThemes(tester, f);
          final loaded = await f.signal(
            tester,
            () => uiReached(c, () => !c.busy && c.pages.isNotEmpty),
            label: 'original empty/unavailable history',
          );
          await tapSheet(tester, f, 'support_theme_history_refresh');
          await f.finish(tester, loaded);
          await tester.pumpAndSettle();
          final view = c.intent!.history(c.pages.single)!;
          expect(view.availability, SupportThemeHistoryAvailability.available);
          expect(view.entries.length, unknown ? 1 : 0);
          final label = unknown
              ? 'support_theme_history_unavailable_row'
              : 'support_theme_history_empty';
          await reveal(
            tester,
            f,
            find.text(label),
            find.byKey(const ValueKey('support_theme_scroll')),
          );
          expect(find.text(label), findsOneWidget);
          if (unknown) {
            expect(
              view.entries.single.state,
              SupportThemeRecoveryState.unavailable,
            );
            expect(find.text('support_theme_history_empty'), findsNothing);
          }
          expect(await f.action(tester, f.baseline), baseline);
        });
      },
    );
  }

  testWidgets(
    'actual retained history secret/issuer retirement denies continuation; fresh emission restarts safely',
    (tester) async {
      final f = ThemeScreenFixture();
      await f.run(tester, () async {
        await f.action(tester, () => f.seedHistory(count: 33));
        final c = await openThemes(tester, f);
        final loaded = await f.signal(
          tester,
          () => uiReached(c, () => !c.busy && c.pages.isNotEmpty),
          label: 'original first restored page',
        );
        await tapSheet(tester, f, 'support_theme_history_refresh');
        await f.finish(tester, loaded);
        final oldPage = c.pages.single;
        final oldCursor = c.intent!.history(oldPage)!.nextCursor!;
        await f.action(tester, () => f.redaction.registerSecret('Restored B'));
        await tester.pumpAndSettle();
        expect(find.text('Name: Restored B'), findsNothing);
        expect(
          c.intent!.history(oldPage)!.availability,
          SupportThemeHistoryAvailability.unavailable,
        );
        expect(c.intent!.history(oldPage)!.nextCursor, isNull);
        await tapSheet(tester, f, 'support_theme_cancel');
        await tester.pumpAndSettle();
        final fresh = await openThemes(tester, f);
        final calls = f.sql.statements.length;
        expect(
          await f.action(
            tester,
            () => fresh.intent!.discoverHistory(cursor: oldCursor),
          ),
          isNull,
        );
        expect(f.sql.statements.length, calls);
        final restarted = await f.signal(
          tester,
          () => uiReached(fresh, () => !fresh.busy && fresh.pages.isNotEmpty),
          label: 'fresh native discovery, no cursor transplant',
        );
        await tapSheet(tester, f, 'support_theme_history_refresh');
        await f.finish(tester, restarted);
        expect(fresh.pages, hasLength(1));
        expect(
          fresh.intent!.history(fresh.pages.single)!.entries,
          hasLength(32),
        );
        expect(find.text('Name: Restored B'), findsNothing);
        expect(f.theme.store.checkedWrites, isEmpty);
      });
    },
  );

  testWidgets(
    'actual replacement UI discovers shared original STARTED liveJob, no settled labels or effect by reader',
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
          label: 'actual shared live checked write',
        );
        await tapSheet(tester, f, 'support_theme_confirm');
        final original = c.originalJob!;
        await f.finish(tester, started);
        final custody = await f.action(
          tester,
          () => f.container.read(supportThemeActionCustodyProvider),
        );
        expect(custody.activeJobs, 1);
        await tapSheet(tester, f, 'support_theme_cancel');
        await tester.pumpAndSettle();
        await f.action(tester, f.replaceCipher);
        await tester.pumpAndSettle();
        final baseline = await f.action(tester, f.baseline);
        final fresh = await openThemes(tester, f);
        final loaded = await f.signal(
          tester,
          () => uiReached(fresh, () => !fresh.busy && fresh.pages.isNotEmpty),
          label: 'replacement actual history live-job page',
        );
        await tapSheet(tester, f, 'support_theme_history_refresh');
        await f.finish(tester, loaded);
        await tester.pumpAndSettle();
        final reader = fresh.intent!;
        final oldPage = fresh.pages.single;
        final view = reader.history(oldPage)!;
        expect(fresh.current, isTrue);
        expect(view.availability, SupportThemeHistoryAvailability.available);
        expect(view.entries.single.state, SupportThemeRecoveryState.liveJob);
        expect(view.entries.single.status, isNull);
        expect(view.entries.single.before, isNull);
        expect(view.entries.single.after, isNull);
        expect(fresh.originalJob, isNull);
        expect(fresh.actualResult, isNull);
        expect(
          await f.action(
            tester,
            () => f.container.read(supportThemeActionCustodyProvider),
          ),
          same(custody),
        );
        await reveal(
          tester,
          f,
          find.text('support_theme_history_liveJob'),
          find.byKey(const ValueKey('support_theme_scroll')),
        );
        expect(find.text('support_theme_history_liveJob'), findsOneWidget);
        expect(await f.action(tester, f.baseline), baseline);
        expect(f.backing.activeId, 'a');
        await f.action(tester, () => gate.release.complete());
        final fact = await f.finish(
          tester,
          await f.signal(
            tester,
            () => original,
            label: 'original shared live-job fact',
          ),
        );
        expect(fact.effect, SupportThemeEffect.applied);
        expect(fact.journal, SupportThemeJournalSave.settled);
        expect(f.backing.activeId, 'b');
        expect(f.theme.store.checkedWrites, ['b']);
        final settledBaseline = await f.action(tester, f.baseline);
        expect(fresh.current, isTrue);
        expect(fresh.intent, same(reader));
        expect(fresh.pages.single, same(oldPage));
        expect(custody.activeJobs, 0);
        expect(fresh.originalJob, isNull);
        expect(fresh.actualResult, isNull);
        // The same evidence-free observation is neither stale-running nor settled.
        final retained = reader.history(oldPage)!;
        expect(
          retained.availability,
          SupportThemeHistoryAvailability.available,
        );
        expect(
          retained.entries.single.state,
          SupportThemeRecoveryState.unavailable,
        );
        expect(retained.entries.single.status, isNull);
        expect(retained.entries.single.before, isNull);
        expect(retained.entries.single.after, isNull);
        expect(await f.action(tester, f.baseline), settledBaseline);
        expect(f.theme.store.checkedWrites, ['b']);

        final refreshed = await f.signal(
          tester,
          () => uiReached(
            fresh,
            () =>
                !fresh.busy &&
                fresh.pages.length == 1 &&
                !identical(fresh.pages.single, oldPage),
          ),
          label: 'explicit native refresh produces a different settled page',
        );
        await tapSheet(tester, f, 'support_theme_history_refresh');
        await f.finish(tester, refreshed);
        await tester.pumpAndSettle();
        expect(fresh.current, isTrue);
        expect(fresh.intent, same(reader));
        expect(fresh.pages.single, isNot(same(oldPage)));
        final discovered = reader.history(fresh.pages.single)!;
        expect(
          discovered.availability,
          SupportThemeHistoryAvailability.available,
        );
        expect(
          discovered.entries.single.state,
          SupportThemeRecoveryState.history,
        );
        expect(discovered.entries.single.status, SupportMutationStatus.applied);
        expect(discovered.entries.single.before!.active, isFalse);
        expect(discovered.entries.single.after!.active, isFalse);
        expect(fresh.originalJob, isNull);
        expect(fresh.actualResult, isNull);
        expect(fresh.review, isNull);
        expect(custody.activeJobs, 0);
        final stillRetained = reader.history(oldPage)!;
        expect(
          stillRetained.availability,
          SupportThemeHistoryAvailability.available,
        );
        expect(
          stillRetained.entries.single.state,
          SupportThemeRecoveryState.unavailable,
        );
        expect(stillRetained.entries.single.status, isNull);
        expect(stillRetained.entries.single.before, isNull);
        expect(stillRetained.entries.single.after, isNull);
        expect(f.theme.store.checkedWrites, ['b']);
        expect(await f.action(tester, f.baseline), settledBaseline);
      });
    },
  );
}
