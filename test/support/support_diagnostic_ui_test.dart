import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_send_settings_snapshot.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_session_scope_sheet.dart';

import 'support_guidance_screen_fixture.dart';

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
}
