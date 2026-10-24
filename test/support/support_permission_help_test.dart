import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_guidance_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_permission_help_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_session_scope_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';

import 'support_guidance_screen_fixture.dart';

Finder _right(String name) => find.byKey(ValueKey('support_privacy_$name'));
Finder _knob(String name) =>
    find.descendant(of: _right(name), matching: find.byType(GlazeSwitch));
Finder _knobHit(String name) {
  final blockedHitArea = find.descendant(
    of: _right(name),
    matching: find.byWidgetPredicate(
      (widget) => widget is InkWell && widget.child is IgnorePointer,
    ),
  );
  return blockedHitArea.evaluate().isEmpty ? _knob(name) : blockedHitArea;
}

Future<void> _open(
  WidgetTester tester,
  GuidanceScreenFixture f,
  String right,
) async {
  await f.tapKey(tester, 'support_guidance_$right');
  await f.tapKey(tester, 'support_privacy_group');
  await f.idle(tester);
}

Future<void> _scopeReady(WidgetTester tester, GuidanceScreenFixture f) =>
    f.turns.until(
      tester,
      () =>
          find
              .byKey(const ValueKey('support_session_scope_confirm'))
              .evaluate()
              .isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
      label: 'actual prerequisite session proposal',
    );

Future<void> _helpReady(WidgetTester tester, GuidanceScreenFixture f) =>
    f.turns.until(
      tester,
      () => find.byType(SupportPermissionHelpSheet).evaluate().isNotEmpty,
      label: 'original local review and prerequisite help sheet',
    );

void main() {
  for (final hitKnob in [false, true]) {
    guidanceScreenTest(
      'blocked readGameData ${hitKnob ? 'knob' : 'row'} selects exact scope; only a second gesture grants that right',
      (tester, f) async {
        await _open(tester, f, 'readGameData');
        final toggle = tester.widget<GlazeSwitch>(_knob('readGameData'));
        expect(toggle.value, isFalse);
        expect(toggle.onChanged, isNull);
        f.observe();
        await f.tap(
          tester,
          hitKnob ? _knobHit('readGameData') : _right('readGameData'),
        );
        await _scopeReady(tester, f);
        expect(find.byType(SupportSessionScopeSheet), findsOneWidget);
        expect(f.sql.writes, 0);
        f.noRecipientResolver();
        await f.tapKey(
          tester,
          'support_session_scope_option_${GuidanceScreenFixture.older}',
        );
        await _scopeReady(tester, f);
        await f.tapKey(tester, 'support_session_scope_confirm');
        await f.idle(tester);
        final scopeOnly = await f.saved(tester);
        expect(scopeOnly.scope!.gameSessionId, GuidanceScreenFixture.older);
        expect(
          scopeOnly.scope!.gameHistoryExtent,
          SupportHistoryExtent.wholeSession,
        );
        expect(scopeOnly.scope!.selectedData, isEmpty);
        expect(scopeOnly.grants, isEmpty);
        expect(scopeOnly.recipient, isNull);
        expect(
          tester.widget<GlazeSwitch>(_knob('readGameData')).value,
          isFalse,
        );
        expect(
          f.controller.view.rights.every((right) => !right.enabled),
          isTrue,
        );
        // A new native gesture, not a continuation/autogrant from the scope sheet.
        await f.tap(tester, _knob('readGameData'));
        await f.turns.until(
          tester,
          () => tester.widget<GlazeSwitch>(_knob('readGameData')).value,
          label: 'original grant review and durable switch publication',
        );
        await f.idle(tester);
        expect((await f.saved(tester)).grants, {
          SupportPermission.readGameData,
        });
        f.noRecipientResolver();
        await f.closeTop(tester);
      },
      screen: false,
    );
  }

  for (final right in [
    'reportGameHistory',
    'reportSupportHistory',
    'modelSupportHistory',
    'modelGameHistory',
  ]) {
    guidanceScreenTest(
      'blocked $right opens its own native history prerequisite without recipient resolution or grants',
      (tester, f) async {
        await _open(tester, f, right);
        f.observe();
        await f.tap(tester, _knobHit(right));
        await _scopeReady(tester, f);
        await f.tapKey(tester, 'support_session_scope_confirm');
        await f.idle(tester);
        final saved = await f.saved(tester);
        expect(saved.grants, isEmpty);
        expect(saved.recipient, isNull);
        if (right == 'reportGameHistory' || right == 'modelGameHistory') {
          expect(saved.scope!.gameSessionId, GuidanceScreenFixture.newest);
          expect(saved.scope!.hasSupportHistory, isFalse);
        } else {
          expect(saved.scope!.hasSupportHistory, isTrue);
          expect(saved.scope!.gameSessionId, isNull);
          if (right == 'modelSupportHistory') {
            expect(
              SupportPermissionHelp.forRight(
                SupportPermission.modelSupportHistory,
                saved,
                needsRecipientConfirmation: true,
              ),
              SupportPermissionHelp.recipient,
            );
          }
        }
        f.noRecipientResolver();
        await f.closeTop(tester);
      },
      screen: false,
    );
  }

  guidanceScreenTest(
    'safe-settings help explicitly selects only theme; model help offers only implemented connections',
    (tester, f) async {
      await _open(tester, f, 'readSafeSettings');
      f.observe();
      await f.tap(tester, _knobHit('readSafeSettings'));
      await _helpReady(tester, f);
      expect(find.byType(SupportPermissionHelpSheet), findsOneWidget);
      expect(
        find.byKey(const ValueKey('support_permission_help_theme')),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('support_permission_help_connections')),
        findsOneWidget,
      );
      expect(f.sql.writes, 0);
      await f.tapKey(tester, 'support_permission_help_theme');
      await f.idle(tester);
      var saved = await f.saved(tester);
      expect(saved.scope!.safeCategories, {SupportSafeCategory.theme});
      expect(saved.grants, isEmpty);
      await f.tap(tester, _knob('readSafeSettings'));
      await f.turns.until(
        tester,
        () => tester.widget<GlazeSwitch>(_knob('readSafeSettings')).value,
        label: 'original safe-settings grant publication',
      );
      await f.idle(tester);
      expect((await f.saved(tester)).grants, {
        SupportPermission.readSafeSettings,
      });
      f.noRecipientResolver();
      await f.closeTop(tester);
      await _open(tester, f, 'modelSafeSettingsDiagnostics');
      f.observe();
      await f.tap(tester, _knobHit('modelSafeSettingsDiagnostics'));
      await _helpReady(tester, f);
      expect(
        find.byKey(const ValueKey('support_permission_help_theme')),
        findsNothing,
      );
      expect(f.sql.writes, 0);
      await f.tapKey(tester, 'support_permission_help_connections');
      await f.idle(tester);
      saved = await f.saved(tester);
      expect(saved.scope!.safeCategories, {
        SupportSafeCategory.theme,
        SupportSafeCategory.connections,
      });
      expect(saved.grants, isEmpty);
      expect(saved.recipient, isNull);
      f.noRecipientResolver();
      await f.closeTop(tester);
    },
    screen: false,
  );

  guidanceScreenTest(
    'diagnostics knob shows a fixed unimplemented note with no SQL, bodies, grants, API or wire',
    (tester, f) async {
      await _open(tester, f, 'readDiagnostics');
      final before = await f.saved(tester);
      f.observe();
      await f.tap(tester, _knobHit('readDiagnostics'));
      expect(
        find.descendant(
          of: find.byType(SupportPermissionHelpSheet),
          matching: find.text(
            'Сбор структурированной диагностики пока не подключён. Разрешение не включено.',
          ),
        ),
        findsOneWidget,
      );
      expect(
        find.byKey(const ValueKey('support_permission_help_theme')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('support_permission_help_connections')),
        findsNothing,
      );
      expect(f.sql.reads, isEmpty);
      expect(f.sql.writes, 0);
      expect(f.crypto, isEmpty);
      f.noRecipientResolver();
      await f.tapKey(tester, 'support_permission_help_close');
      expect(f.sql.reads, isEmpty);
      expect(f.sql.writes, 0);
      final after = await f.saved(tester);
      expect(after.revision, before.revision);
      expect(after.scope, isNull);
      expect(after.grants, isEmpty);
      await f.closeTop(tester);
    },
    screen: false,
  );

  guidanceScreenTest(
    'closed safe-category confirm is once-only and cannot select a scope or grant',
    (tester, f) async {
      await _open(tester, f, 'readSafeSettings');
      await f.tap(tester, _knobHit('readSafeSettings'));
      await _helpReady(tester, f);
      final retained = tester
          .widget<GlazeActionButton>(
            find.byKey(const ValueKey('support_permission_help_theme')),
          )
          .onTap!;
      await f.tapKey(tester, 'support_permission_help_close');
      await f.idle(tester);
      f.observe();
      await f.turns.real(tester, () async {
        retained();
        retained();
      });
      await tester.pump();
      expect(f.sql.reads, isEmpty);
      expect(f.sql.writes, 0);
      expect(find.byType(SupportPermissionHelpSheet), findsNothing);
      final saved = await f.saved(tester);
      expect(saved.scope, isNull);
      expect(saved.grants, isEmpty);
      f.noRecipientResolver();
      await f.closeTop(tester);
    },
    screen: false,
  );

  for (final right in ['readGameData', 'readDiagnostics']) {
    for (final retirement in [
      'session-aba',
      'controller',
      'closed-ui',
      'busy',
    ]) {
      guidanceScreenTest(
        'retained blocked $right callbacks deny $retirement without minting fresh intents',
        (tester, f) async {
          await _open(tester, f, right);
          final before = await f.saved(tester);
          final callbacks = find
              .descendant(of: _right(right), matching: find.byType(InkWell))
              .evaluate()
              .map((element) => (element.widget as InkWell).onTap)
              .whereType<VoidCallback>()
              .toList();
          expect(
            callbacks,
            hasLength(2),
          ); // Actual emitted row AND knob owners.
          void Function()? settle;
          switch (retirement) {
            case 'session-aba':
              await f.action(tester, () async {
                f.workspace.selectSession(GuidanceScreenFixture.other);
                await f.workspace.refresh();
                f.workspace.selectSession(GuidanceScreenFixture.session);
                await f.workspace.refresh();
              });
            case 'controller':
              final original = f.controller;
              await f.turns.real(tester, () async {
                f.container.invalidate(supportNativeConsentControllerProvider);
                expect(f.controller, isNot(same(original)));
              });
            case 'closed-ui':
              await f.closeTop(tester);
            case 'busy':
              settle = f.runtime.beginSettingsChange();
          }
          await tester.pump();
          if (retirement != 'busy') await f.idle(tester);
          f.observe();
          try {
            await f.turns.real(tester, () async {
              for (final callback in callbacks) {
                callback();
              }
            });
            await tester.pump();
            expect(find.byType(SupportSessionScopeSheet), findsNothing);
            expect(find.byType(SupportPermissionHelpSheet), findsNothing);
            expect(f.sql.reads, isEmpty);
            expect(f.sql.writes, 0);
            expect(f.crypto, isEmpty);
            f.noRecipientResolver();
          } finally {
            settle?.call();
          }
          await f.idle(tester);
          final after = await f.saved(tester);
          expect(after.revision, before.revision);
          expect(after.scope, isNull);
          expect(after.grants, isEmpty);
          if (find.byType(SupportGuidanceSheet).evaluate().isNotEmpty) {
            await f.closeTop(tester);
          }
        },
        screen: false,
      );
    }
  }
}
