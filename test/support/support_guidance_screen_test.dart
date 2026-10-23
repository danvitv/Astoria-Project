import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart' as db;
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_card_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_card_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_guidance_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_session_scope_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_switch.dart';

import 'support_guidance_screen_fixture.dart';

Future<void> _request(
  WidgetTester tester,
  GuidanceScreenFixture f,
  String value,
) async {
  await f.turns.real(
    tester,
    () => tester.enterText(find.byType(TextField), value),
  );
  await tester.pump();
  await f.tapKey(tester, 'support_composer_send_btn');
  await f.turns.until(
    tester,
    () => find
        .byKey(const ValueKey('support_contextual_guidance'))
        .evaluate()
        .isNotEmpty,
    label: 'original main-send guidance publication',
  );
}

Future<void> _proposal(WidgetTester tester, GuidanceScreenFixture f) =>
    f.turns.until(
      tester,
      () =>
          find
              .byKey(const ValueKey('support_session_scope_confirm'))
              .evaluate()
              .isNotEmpty &&
          find.byType(LinearProgressIndicator).evaluate().isEmpty,
      label: 'original metadata proposal',
    );

void main() {
  guidanceScreenTest(
    'main send without configured model proposes four prerequisites and retains exact draft',
    (tester, f) async {
      const request = 'анализ ролевой истории';
      expect(f.state.settings.hasConfiguredModel, isFalse);
      await _request(tester, f, request);
      final cards = tester
          .widgetList<SupportCardView>(find.byType(SupportCardView))
          .map((view) => view.card)
          .whereType<SupportGuidanceCard>()
          .toList();
      expect(cards.map((card) => card.target), [
        SupportGuidanceTarget.gameSession,
        SupportGuidanceTarget.readGameData,
        SupportGuidanceTarget.modelGameHistory,
        SupportGuidanceTarget.recipient,
      ]);
      expect(
        tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller
            .text,
        request,
      );
      expect(f.state.activeMessages, isEmpty);
      expect(f.sql.writes, 0);
      expect(
        f.sql.reads,
        isEmpty,
        reason:
            'A proposal does not enumerate sessions or inspect a selected API.',
      );
      expect(f.crypto, isEmpty);
      expect(await f.messageCount(tester), 0);
      expect((await f.saved(tester)).grants, isEmpty);
      f.noReadersOrWire();
    },
  );

  guidanceScreenTest(
    'actual game card proposes newest metadata; cancel is inert; final confirm writes only session scope',
    (tester, f) async {
      await _request(tester, f, 'анализ ролевой истории');
      await f.tapKey(tester, 'support_guidance_gameSession');
      await _proposal(tester, f);
      expect(find.byType(SupportSessionScopeSheet), findsOneWidget);
      expect(
        find.byKey(
          ValueKey(
            'support_session_scope_option_${GuidanceScreenFixture.newest}',
          ),
        ),
        findsOneWidget,
      );
      expect(
        tester
            .widget<Text>(
              find.byKey(const ValueKey('support_session_scope_proposal')),
            )
            .data,
        'Synthetic metadata parent · Native variant · Session 2',
      );
      expect(f.sql.writes, 0);
      expect((await f.saved(tester)).scope, isNull);
      f.noRecipientResolver();
      await f.closeTop(
        tester,
      ); // The original proposal's actual cancel callback.
      expect(f.sql.writes, 0);
      expect((await f.saved(tester)).scope, isNull);
      await f.closeTop(tester); // Guidance container, not the settings menu.

      await f.tapKey(tester, 'support_guidance_gameSession');
      await _proposal(tester, f);
      await f.tapKey(tester, 'support_session_scope_confirm');
      await f.idle(tester);
      final policy = await f.saved(tester);
      expect(policy.supportSessionId, GuidanceScreenFixture.session);
      expect(policy.scope!.gameSessionId, GuidanceScreenFixture.newest);
      expect(
        policy.scope!.gameHistoryExtent,
        SupportHistoryExtent.wholeSession,
      );
      expect(policy.scope!.gameHistory, isNull);
      expect(policy.scope!.supportHistory, isNull);
      expect(policy.scope!.hasSupportHistory, isFalse);
      expect(policy.scope!.selectedData, isEmpty);
      expect(policy.scope!.safeCategories, isEmpty);
      expect(policy.grants, isEmpty);
      expect(policy.recipient, isNull);
      final raw = await f.action(
        tester,
        () => f.repo.getContextBlockById(
          SupportPermissionStore.codec.idFor(GuidanceScreenFixture.session),
        ),
      );
      final stored =
          jsonDecode(raw!.protectedFactsJson) as Map<String, dynamic>;
      expect(stored['version'], 2);
      expect((stored['scope'] as Map)['gameHistory'], isNull);
      expect((stored['scope'] as Map)['supportHistory'], isNull);
      expect((stored['grants'] as Map).values, everyElement(isFalse));
      expect(
        (await f.saved(tester, GuidanceScreenFixture.other)).scope,
        isNull,
      );
      expect(await f.messageCount(tester), 0);
      f.noRecipientResolver();
      await f.closeTop(tester);

      // A SEPARATE card and final actual switch, not consent inherited from scope.
      await f.tapKey(tester, 'support_guidance_readGameData');
      expect(
        tester
            .widget<SupportGuidanceSheet>(find.byType(SupportGuidanceSheet))
            .target,
        SupportGuidanceTarget.readGameData,
      );
      await f.tapKey(tester, 'support_privacy_group');
      final right = find.byKey(const ValueKey('support_privacy_readGameData'));
      await f.reveal(tester, right);
      for (final other in SupportPermission.values.where(
        (p) => p != SupportPermission.readGameData,
      )) {
        expect(
          find.byKey(ValueKey('support_privacy_${other.name}')),
          findsNothing,
        );
      }
      final toggle = find.descendant(
        of: right,
        matching: find.byType(GlazeSwitch),
      );
      expect(tester.widget<GlazeSwitch>(toggle).value, isFalse);
      expect(tester.widget<GlazeSwitch>(toggle).onChanged, isNotNull);
      expect((await f.saved(tester)).grants, isEmpty);
      await f.tap(tester, toggle);
      await f.turns.until(
        tester,
        () => tester.widget<GlazeSwitch>(toggle).value,
        label: 'original local-history grant displayed after native completion',
      );
      await f.idle(tester);
      final enabled = await f.saved(tester);
      expect(enabled.grants, {SupportPermission.readGameData});
      expect(enabled.scope!.sameAs(policy.scope), isTrue);
      expect(enabled.recipient, isNull);
      expect(
        (await f.saved(tester, GuidanceScreenFixture.other)).grants,
        isEmpty,
      );
      await f.closeTop(tester);
      expect(
        tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller
            .text,
        'анализ ролевой истории',
      );
      expect(f.state.activeMessages, isEmpty);
      expect(
        await f.messageCount(tester),
        0,
        reason:
            'Scope and right changes never silently resend the retained draft.',
      );
      f.noRecipientResolver();
    },
  );

  guidanceScreenTest(
    'current Astoria card selects only current parent; separate report prerequisite never exports/resends',
    (tester, f) async {
      await _request(tester, f, 'репорт истории Астории');
      await f.tapKey(tester, 'support_guidance_supportSession');
      await _proposal(tester, f);
      expect(
        find.byKey(const ValueKey('support_session_scope_proposal')),
        findsOneWidget,
      );
      expect(find.text('Текущая сессия Астории'), findsOneWidget);
      expect(
        find.byKey(
          ValueKey(
            'support_session_scope_option_${GuidanceScreenFixture.other}',
          ),
        ),
        findsNothing,
      );
      expect(f.sql.reads.where((r) => r.roleplayMetadata), isEmpty);
      expect(
        f.sql.reads.where((r) => r.exactSessionMetadata).map((r) => r.args),
        everyElement(everyElement(GuidanceScreenFixture.session)),
      );
      expect(f.sql.writes, 0);
      await f.tapKey(tester, 'support_session_scope_confirm');
      await f.idle(tester);
      final policy = await f.saved(tester);
      expect(
        policy.scope!.supportHistoryExtent,
        SupportHistoryExtent.wholeSession,
      );
      expect(policy.scope!.supportHistory, isNull);
      expect(policy.scope!.gameSessionId, isNull);
      expect(policy.scope!.gameHistory, isNull);
      expect(policy.grants, isEmpty);
      expect(policy.recipient, isNull);
      expect(
        (await f.saved(tester, GuidanceScreenFixture.other)).scope,
        isNull,
      );
      f.noRecipientResolver();
      await f.closeTop(tester);
      await f.tapKey(tester, 'support_guidance_reportSupportHistory');
      await f.tapKey(tester, 'support_privacy_group');
      final row = find.byKey(
        const ValueKey('support_privacy_reportSupportHistory'),
      );
      final toggle = find.descendant(
        of: row,
        matching: find.byType(GlazeSwitch),
      );
      await f.tap(tester, toggle);
      await f.turns.until(
        tester,
        () => tester.widget<GlazeSwitch>(toggle).value,
        label: 'original report grant displayed after native completion',
      );
      await f.idle(tester);
      expect((await f.saved(tester)).grants, {
        SupportPermission.reportSupportHistory,
      });
      expect((await f.saved(tester)).scope!.sameAs(policy.scope), isTrue);
      expect(f.crypto.where((e) => e.contains('support_reports')), isEmpty);
      f.noRecipientResolver();
      await f.closeTop(tester);
      expect(await f.messageCount(tester), 0);
      expect(f.state.activeMessages, isEmpty);
      expect(
        tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller
            .text,
        'репорт истории Астории',
      );
    },
  );

  guidanceScreenTest(
    'restored finite card navigates fresh current UI; unknown/foreign authority fields render no controls',
    (tester, f) async {
      for (final value in [
        (
          'restored-valid',
          const SupportCardCodec().encode(const [
            SupportGuidanceCard(target: SupportGuidanceTarget.gameSession),
          ]),
        ),
        (
          'restored-unknown',
          '{"version":1,"cards":[{"type":"guidance","target":"executeAll"}]}',
        ),
        (
          'restored-foreign',
          '{"version":1,"cards":[{"type":"guidance","target":"readGameData",'
              '"session":"guidance-own-other","grant":true}]}',
        ),
      ]) {
        await f.action(
          tester,
          () => f.repo.putMessage(
            db.SupportMessage(
              id: value.$1,
              sessionId: GuidanceScreenFixture.session,
              role: 'assistant',
              body: 'Synthetic passive restored row',
              cardsJson: value.$2,
              createdAt: 3,
            ),
          ),
        );
      }
      await f.action(tester, f.workspace.refresh);
      await tester.pump();
      f.observe();
      final target = find.byKey(const ValueKey('support_guidance_gameSession'));
      // The welcome notice is tall; reveal the actual restored row in its own feed.
      await tester.scrollUntilVisible(
        target,
        250,
        scrollable: find
            .descendant(
              of: find.byType(SupportMessageList),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await f.tap(tester, target);
      await _proposal(tester, f);
      expect(
        tester
            .widget<SupportGuidanceSheet>(find.byType(SupportGuidanceSheet))
            .target,
        SupportGuidanceTarget.gameSession,
      );
      expect(f.sql.writes, 0);
      expect((await f.saved(tester)).scope, isNull);
      expect((await f.saved(tester)).grants, isEmpty);
      expect(
        find.byKey(const ValueKey('support_guidance_executeAll')),
        findsNothing,
      );
      expect(
        find.byKey(const ValueKey('support_guidance_readGameData')),
        findsNothing,
      );
      f.noRecipientResolver();
      await f.closeTop(tester);
      await f.closeTop(tester);
    },
  );
}
