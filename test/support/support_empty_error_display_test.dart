import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_run_view.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';

import 'helpers/support_message_list_passivity_fixture.dart';

void main() {
  for (final matching in [false, true]) {
    testWidgets(
      'empty failed ${matching ? 'current' : 'restored'} row has useful fixed diagnostics',
      (tester) async {
        final f = SupportMessageListPassivityFixture();
        await f.run(tester, () async {
          final row = SupportMessageItem(
            id: 'safe-error',
            sessionId: 'safe-session',
            role: SupportMessageRole.assistant,
            body: '',
            createdAt: DateTime.utc(2026),
            runId: 'safe-run',
            status: 'error',
          );
          final run = SupportModelRunView(
            phase: SupportModelPhase.settled,
            accepted: true,
            saved: true,
            status: PrivateTextStatus.error,
            transportReason: PrivateTextReason.httpStatus,
            sessionId: 'safe-session',
            runId: matching ? 'safe-run' : 'unrelated-run',
          );
          await tester.pumpWidget(
            f.host(
              SupportMessageList(
                messages: [row],
                hasConfiguredModel: true,
                onQuickAction: (_) {},
                onApplyPlan: (_) {},
                onRollback: (_) {},
                run: run,
              ),
            ),
          );
          await tester.pumpAndSettle();
          final body = tester
              .widget<SupportPlainMarkdown>(find.byType(SupportPlainMarkdown))
              .text;
          expect(body.trim(), isNotEmpty);
          expect(
            body,
            matching
                ? contains('Сервис модели отклонил запрос')
                : contains('Причина для сохранённого сообщения недоступна'),
          );
          expect(body, isNot(contains('Exception')));
          expect(body, isNot(contains('Authorization')));
          expect(body, isNot(contains('https://')));
          expect(body, isNot(contains('safe-run')));
        });
      },
    );
  }
  test(
    'settled diagnostics cannot attach to busy, unsaved or unrelated rows',
    () {
      for (final view in [
        const SupportModelRunView(
          phase: SupportModelPhase.settled,
          busy: true,
          saved: true,
          accepted: true,
          status: PrivateTextStatus.error,
          sessionId: 'session',
          runId: 'run',
          transportReason: PrivateTextReason.providerError,
        ),
        const SupportModelRunView(
          phase: SupportModelPhase.settled,
          accepted: true,
          status: PrivateTextStatus.error,
          sessionId: 'session',
          runId: 'run',
          transportReason: PrivateTextReason.providerError,
        ),
      ]) {
        expect(view.settledDiagnostic('run', 'session'), isEmpty);
      }
    },
  );
}
