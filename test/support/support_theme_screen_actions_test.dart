import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_theme_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_controls.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_theme_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_settings_panel.dart';
import 'package:glaze_flutter/shared/widgets/sheet_view.dart';

import 'support_theme_screen_helpers.dart';

void main() {
  testWidgets(
    'actual local no model: default scope/read/change independence, no auto-grant',
    (tester) async {
      final f = ThemeScreenFixture(permissions: false);
      await f.run(tester, () async {
        expect(f.state.settings.hasConfiguredModel, isFalse);
        expect(f.runtime.recipientConfirmed, isFalse);
        expect(f.controller.view.themeSelected, isFalse);
        expect(f.controller.view.rights.where((r) => r.enabled), isEmpty);
        final reads = f.theme.store.freshReads;
        final drawer = find.byKey(const ValueKey('support_drawer_toggle'));
        if (drawer.evaluate().isNotEmpty) {
          await f.gesture(tester, () => tester.tap(drawer));
          await tester.pumpAndSettle();
        }
        await f.gesture(
          tester,
          () => tester.tap(find.byKey(const ValueKey('support_theme_open'))),
        );
        await routeEndpoint(tester, find.byType(SheetView));
        expect(find.text('support_theme_permissions'), findsOneWidget);
        expect(f.theme.store.freshReads, reads);
        await f.action(
          tester,
          () => f.router.routerDelegate.navigatorKey.currentState!.pop(),
        );
        await tester.pumpAndSettle();

        // Use ACTUAL privacy controls, not fixture auto-enable or fake permissions.
        tester.view.physicalSize = const Size(390, 1100);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);
        await tester.pump();
        await f.gesture(
          tester,
          () => tester.tap(
            find.byKey(const ValueKey('mobile_open_settings_btn')),
          ),
        );
        await tester.pumpAndSettle();
        final privacy = find.byKey(const ValueKey('support_privacy_group'));
        // Its actual outer settings ListView has ONE Scrollable, no guessed owner.
        final settingsList = find.descendant(
          of: find.byType(SupportSettingsPanel),
          matching: find.byType(ListView),
        );
        expect(settingsList, findsOneWidget);
        await reveal(tester, f, privacy, settingsList);
        await f.gesture(
          tester,
          () => tester.tap(find.text('support_privacy_title')),
        );
        await tester.pumpAndSettle();
        for (final id in [
          'support_privacy_theme_scope',
          'support_privacy_readSafeSettings',
        ]) {
          final toggle = find.byKey(ValueKey(id));
          await reveal(tester, f, toggle, settingsList);
          final changed = await f.signal(
            tester,
            () => runtimeReached(
              f,
              () =>
                  !f.controller.view.busy &&
                  (id == 'support_privacy_theme_scope'
                      ? f.controller.view.themeSelected
                      : f.controller.view.rights
                            .singleWhere(
                              (r) =>
                                  r.right == SupportPermission.readSafeSettings,
                            )
                            .enabled),
            ),
            label: 'original local privacy toggle $id',
          );
          await f.gesture(tester, () => tester.tap(toggle));
          await f.finish(tester, changed);
          await tester.pumpAndSettle();
          expect(
            f.controller.view.rights
                .singleWhere(
                  (r) => r.right == SupportPermission.confirmedSettingsChanges,
                )
                .enabled,
            isFalse,
          );
          expect(f.theme.store.freshReads, reads);
        }
        expect(f.runtime.recipientConfirmed, isFalse);
        expect(
          f.controller.view.rights.where((r) => r.enabled).map((r) => r.right),
          [SupportPermission.readSafeSettings],
        );
        await f.action(
          tester,
          () => f.router.routerDelegate.navigatorKey.currentState!.pop(),
        );
        await tester.pumpAndSettle();
        final c = await openThemes(tester, f);
        await readThemes(tester, f, c);
        final done = await f.signal(
          tester,
          () => uiReached(c, () => c.notice != null && !c.busy),
          label: 'no change prerequisite refuses exact review',
        );
        await tapSheet(tester, f, 'support_theme_choice_b');
        await f.finish(tester, done);
        expect(c.review, isNull);
        expect(f.theme.store.checkedWrites, isEmpty);
        expect(
          await f.action(
            tester,
            () => f.db.select(f.db.supportMutationJournal).get(),
          ),
          isEmpty,
        );
        await tapSheet(tester, f, 'support_theme_cancel');
        await tester.pumpAndSettle();
        await f.gesture(
          tester,
          () => tester.tap(
            find.byKey(const ValueKey('mobile_open_settings_btn')),
          ),
        );
        await tester.pumpAndSettle();
        final changeList = find.descendant(
          of: find.byType(SupportSettingsPanel),
          matching: find.byType(ListView),
        );
        final changeGroup = find.byKey(const ValueKey('support_privacy_group'));
        await reveal(tester, f, changeGroup, changeList);
        await f.gesture(
          tester,
          () => tester.tap(find.text('support_privacy_title')),
        );
        await tester.pumpAndSettle();
        final changeControl = find.byKey(
          const ValueKey('support_privacy_confirmedSettingsChanges'),
        );
        await reveal(tester, f, changeControl, changeList);
        final changed = await f.signal(
          tester,
          () => runtimeReached(
            f,
            () =>
                !f.controller.view.busy &&
                f.controller.view.rights
                    .singleWhere(
                      (r) =>
                          r.right == SupportPermission.confirmedSettingsChanges,
                    )
                    .enabled,
          ),
          label: 'original local changes grant without recipient',
        );
        await f.gesture(tester, () => tester.tap(changeControl));
        await f.finish(tester, changed);
        expect(f.runtime.recipientConfirmed, isFalse);
        expect(
          f.controller.view.rights.where((r) => r.enabled).map((r) => r.right),
          [
            SupportPermission.readSafeSettings,
            SupportPermission.confirmedSettingsChanges,
          ],
        );
        expect(f.theme.store.checkedWrites, isEmpty);
        await f.action(
          tester,
          () => f.router.routerDelegate.navigatorKey.currentState!.pop(),
        );
        await tester.pumpAndSettle();
        final fresh = await openThemes(tester, f);
        await readThemes(tester, f, fresh);
        await reviewTheme(tester, f, fresh);
        expect(fresh.review, isNotNull);
        expect(
          fresh.originalJob,
          isNull,
        ); // prerequisite + review are NOT approval
        expect(f.theme.store.checkedWrites, isEmpty);
      });
    },
  );

  testWidgets(
    'actual once Apply + separately reviewed new Undo, backing and immutable encrypted CAS evidence',
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
        await tapSheet(tester, f, 'support_theme_confirm');
        final original = c.originalJob!;
        await f.action(
          tester,
          retained,
        ); // original retained callback: consumed once
        final fact = await f.finish(
          tester,
          await f.signal(tester, () => original, label: 'original Apply fact'),
        );
        await tester.pumpAndSettle();
        expect(fact.effect, SupportThemeEffect.applied);
        expect(fact.journal, SupportThemeJournalSave.settled);
        expect(fact.status, SupportMutationStatus.applied);
        expect(f.backing.activeId, 'b');
        expect(f.theme.store.checkedWrites, ['b']);
        expect(f.theme.store.ordinaryWrites, isEmpty);
        final row = (await f.action(
          tester,
          () => f.db.select(f.db.supportMutationJournal).get(),
        )).single;
        expect(row.status, 'applied');
        expect(row.beforeCiphertext, isNot(contains('A full installed label')));
        expect(
          row.afterCiphertext,
          isNot(contains('B distinguishing installed label')),
        );
        final undoReview = await f.signal(
          tester,
          () => uiReached(
            c,
            () => !c.busy && c.review?.kind == SupportThemeActionKind.undo,
          ),
          label: 'NEW original conditional Undo review',
        );
        await tapSheet(tester, f, 'support_theme_undo');
        await f.finish(tester, undoReview);
        await tester.pumpAndSettle();
        expect(f.theme.store.checkedWrites, ['b']); // reviewing is not approval
        await tapSheet(tester, f, 'support_theme_confirm');
        final undone = await f.finish(
          tester,
          await f.signal(
            tester,
            () => c.originalJob!,
            label: 'original fresh Undo fact',
          ),
        );
        await tester.pumpAndSettle();
        expect(undone.effect, SupportThemeEffect.undone);
        expect(undone.journal, SupportThemeJournalSave.settled);
        expect(f.backing.activeId, 'a');
        expect(f.theme.store.checkedWrites, ['b', 'a']);
        final last = (await f.action(
          tester,
          () => f.db.select(f.db.supportMutationJournal).get(),
        )).single;
        expect(last.id, row.id);
        expect(last.beforeCiphertext, row.beforeCiphertext);
        expect(last.afterCiphertext, row.afterCiphertext);
        expect(last.createdAt, row.createdAt);
        expect(last.status, 'undone');
        expect(find.text('support_theme_result_historical'), findsOneWidget);
      });
    },
  );

  for (final dismissal in [
    'cancel',
    'back',
    'barrier',
    'system-back',
    'unmount',
  ]) {
    testWidgets(
      'actual review $dismissal joins route before retained final callback: zero effect',
      (tester) async {
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          final c = await openThemes(tester, f);
          await readThemes(tester, f, c);
          await reviewTheme(tester, f, c);
          final before = await f.action(tester, f.baseline);
          final retained = tester
              .widget<SupportThemeButton>(
                find.byKey(const ValueKey('support_theme_confirm')),
              )
              .onTap!;
          final route = ModalRoute.of<void>(
            tester.element(find.byType(SupportThemeSheet)),
          )!;
          final popped = await f.signal(
            tester,
            () => route.popped,
            label: 'original $dismissal route decision',
          );
          switch (dismissal) {
            case 'cancel':
              await tapSheet(tester, f, 'support_theme_cancel');
            case 'back':
              final sheet = find.byType(SheetView);
              final back = find.descendant(
                of: sheet,
                matching: find.ancestor(
                  of: find.descendant(
                    of: sheet,
                    matching: find.byIcon(Icons.arrow_back),
                  ),
                  matching: find.byType(InkWell),
                ),
              );
              expect(back, findsOneWidget);
              expect(back.hitTestable(), findsOneWidget);
              await f.gesture(tester, () => tester.tap(back));
            case 'barrier':
              await f.gesture(tester, () => tester.tapAt(const Offset(4, 4)));
            case 'system-back':
              await f.gesture(tester, tester.binding.handlePopRoute);
            case 'unmount':
              // Actual GoRouter removal unmounts the original page + pageless
              // sheet and completes its original popped decision (unlike
              // destroying the entire Navigator without a route decision).
              await f.action(tester, () => f.router.go('/characters'));
              await tester.pump();
          }
          await f.finish(tester, popped);
          await f.action(tester, retained);
          await tester.pumpAndSettle();
          expect(c.originalJob, isNull);
          expect(f.theme.store.checkedWrites, isEmpty);
          expect(await f.action(tester, f.baseline), before);
        });
      },
    );
  }

  for (final retirement in [
    'session-ABA',
    'controller',
    'issuer',
    'cipher',
    'secret',
  ]) {
    testWidgets(
      'actual displayed $retirement cannot rebind final review or paint old labels',
      (tester) async {
        final f = ThemeScreenFixture();
        await f.run(tester, () async {
          final c = await openThemes(tester, f);
          await readThemes(tester, f, c);
          await reviewTheme(tester, f, c);
          final finalTap = tester
              .widget<SupportThemeButton>(
                find.byKey(const ValueKey('support_theme_confirm')),
              )
              .onTap!;
          await f.action(tester, () async {
            switch (retirement) {
              case 'session-ABA':
                f.workspace.selectSession(ThemeScreenFixture.other);
                f.workspace.selectSession(ThemeScreenFixture.session);
                await f.workspace.refresh();
                await f.runtime.refresh(resolve: false);
              case 'controller':
                f.container.invalidate(supportNativeConsentControllerProvider);
                f.binding;
              case 'issuer':
                f.controller.invalidateDisplayedIntents();
                f.runtime.notify();
              case 'cipher':
                await f.replaceCipher();
              case 'secret':
                f.redaction.registerSecret('B distinguishing installed label');
            }
            finalTap();
          });
          await tester.pumpAndSettle();
          expect(c.originalJob, isNull);
          expect(f.theme.store.checkedWrites, isEmpty);
          expect(
            find.text('Name: B distinguishing installed label'),
            findsNothing,
          );
          expect(find.text('support_theme_unavailable'), findsWidgets);
        });
      },
    );
  }
}
