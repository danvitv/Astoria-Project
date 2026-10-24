import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_send_settings_snapshot.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_session_scope_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';

import 'support_guidance_screen_fixture.dart';
import 'helpers/support_model_screen_fixture.dart';

void main() {
  guidanceScreenTest(
    'native diagnostics button shows actual safe snapshot and offers recent catalog with no selected game or history writes',
    (tester, f) async {
      expect((await f.saved(tester)).scope, isNull);
      f.observe();
      await f.tapKey(tester, 'support_composer_diag_btn');
      final snapshot = tester.widget<SupportSendSettingsSnapshot>(
        find.byType(SupportSendSettingsSnapshot),
      );
      expect(snapshot.permissions?.scope?.gameSessionId, isNull);
      expect(snapshot.settings.maxTokens, f.state.settings.maxTokens);
      expect(f.sql.reads, isEmpty);
      expect(f.sql.writes, 0);
      expect(f.state.activeMessages, isEmpty);
      await f.tapKey(tester, 'support_guidance_gameSession');
      await f.turns.until(
        tester,
        () =>
            find
                .byKey(
                  ValueKey(
                    'support_session_scope_option_${GuidanceScreenFixture.newest}',
                  ),
                )
                .evaluate()
                .isNotEmpty &&
            find.byType(LinearProgressIndicator).evaluate().isEmpty,
        label: 'actual latest session metadata proposal',
      );
      expect(find.byType(SupportSessionScopeSheet), findsOneWidget);
      expect(f.sql.writes, 0);
      expect((await f.saved(tester)).scope, isNull);
      expect((await f.saved(tester)).grants, isEmpty);
      f.noRecipientResolver();
      await f.closeTop(tester);
      expect(f.state.activeMessages, isEmpty);
    },
  );

  testWidgets(
    'recipient guidance opens native review directly, but still requires a separate final gesture',
    (tester) async {
      final f = ModelScreenFixture(confirm: false);
      await f.run(tester, () async {
        final c = f.container.read(supportNativeConsentControllerProvider);
        final draft = tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller;
        await f.action(tester, () async {
          draft.text = 'Привет';
          await tester.tap(
            find.byKey(const ValueKey('support_composer_send_btn')),
          );
        });
        await tester.pumpAndSettle();
        final card = find.byKey(const ValueKey('support_guidance_recipient'));
        await Scrollable.ensureVisible(tester.element(card), alignment: 0.5);
        await tester.pump();
        await f.action(tester, () => tester.tap(card));
        for (
          var turn = 0;
          turn < 100 &&
              find.byType(SupportPrivacyReviewSheet).evaluate().isEmpty;
          turn++
        ) {
          await tester.pump();
          await f.action(tester, () => Future<void>.delayed(Duration.zero));
        }
        expect(find.byType(SupportPrivacyReviewSheet), findsOneWidget);
        expect(c.runtime.recipientConfirmed, isFalse);
        expect(c.runtime.snapshot.preferences!.grants, isEmpty);
        expect(f.adapters, isEmpty);
        final cancel = find.byKey(
          const ValueKey('support_privacy_review_cancel'),
        );
        final route = ModalRoute.of<bool>(
          tester.element(find.byType(SupportPrivacyReviewSheet)),
        )!;
        await tester.pump();
        await tester.pump(
          route.transitionDuration + const Duration(microseconds: 1),
        );
        if (cancel.evaluate().isEmpty) {
          final list = find.descendant(
            of: find.byType(SupportPrivacyReviewSheet),
            matching: find.byType(Scrollable),
          );
          await tester.scrollUntilVisible(cancel, 150, scrollable: list);
        }
        await Scrollable.ensureVisible(tester.element(cancel), alignment: 0.5);
        await tester.pump();
        final cancelled = await f.signal(
          tester,
          () => route.popped,
          label: 'original recipient cancel route result',
        );
        await f.action(tester, () => tester.tap(cancel));
        expect(await f.finish(tester, cancelled), isFalse);
        await tester.pump(
          route.reverseTransitionDuration + const Duration(microseconds: 1),
        );
        for (var turn = 0; turn < 20; turn++) {
          await tester.pump();
          await f.action(tester, () => Future<void>.delayed(Duration.zero));
        }
        expect(c.runtime.recipientConfirmed, isFalse);
        expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
        expect(
          c.runtime.snapshot.preferences!.allows(
            SupportPermission.modelGameHistory,
          ),
          isFalse,
        );
        expect(f.adapters, isEmpty);
        expect(draft.text, 'Привет');
      });
    },
  );
}
