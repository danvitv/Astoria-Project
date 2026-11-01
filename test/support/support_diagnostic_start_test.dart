import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_local_reply_service.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';

import 'helpers/support_model_screen_fixture.dart';

// Register on the ORIGINAL issuer before Send; a previous terminal state cannot
// satisfy this turn and no replacement bridge is looked up after the await.
Future<SupportModelRunView> _terminal(SupportModelUiBridge original) {
  final reached = Completer<SupportModelRunView>();
  late final void Function() stop;
  stop = original.listen(() {
    if (!reached.isCompleted &&
        original.view.phase == SupportModelPhase.settled &&
        !original.view.busy) {
      stop();
      reached.complete(original.view);
    }
  });
  addTearDown(stop);
  return reached.future;
}

void main() {
  testWidgets(
    'direct diagnostic question needs no game selection or diagnostic/history grants and makes one private request',
    (tester) async {
      const question = 'Начнём диагностику, какую сессию разобрать?';
      const visible = 'Safe visible local diagnostic conversation';
      final f = ModelScreenFixture(confirm: false, oldBody: visible);
      await f.run(tester, () async {
        final controller = f.container.read(
          supportNativeConsentControllerProvider,
        );
        final originalPolicy = controller.runtime.snapshot.preferences!;
        expect(originalPolicy.scope?.gameSessionId, isNull);
        expect(controller.runtime.recipientConfirmed, isFalse);
        for (final permission in [
          SupportPermission.modelGameHistory,
          SupportPermission.modelSupportHistory,
          SupportPermission.readDiagnostics,
          SupportPermission.readSafeSettings,
        ]) {
          expect(originalPolicy.allows(permission), isFalse);
        }
        final original = await f.action(tester, () => f.bridge);
        final finished = await f.signal(
          tester,
          () => _terminal(original),
          label: 'original direct diagnostic completion',
        );
        final draft = tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller;
        await f.action(tester, () async {
          draft.text = question;
          await tester.tap(
            find.byKey(const ValueKey('support_composer_send_btn')),
          );
        });
        final result = await f.finish(tester, finished);
        await tester.pumpAndSettle();
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(f.adapters, hasLength(1));
        final adapter = f.adapters.single;
        expect(adapter.fetches, 1);
        expect(adapter.options!.method, 'POST');
        expect(adapter.options!.uri.toString(), f.api.endpoint);
        final body = jsonDecode(adapter.upload!) as Map<String, dynamic>;
        final messages = (body['messages'] as List)
            .cast<Map<String, dynamic>>();
        expect(messages.where((m) => m['role'] != 'system'), [
          {'role': 'assistant', 'content': visible},
          {'role': 'user', 'content': question},
        ]);
        for (final excluded in [
          ModelScreenFixture.excluded,
          ModelScreenFixture.secret,
          ModelScreenFixture.key,
          'SYNTHETIC_STALE_VAULT_KEY',
        ]) {
          expect(adapter.upload, isNot(contains(excluded)));
        }
        expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
        expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
        expect(draft.text, isEmpty);
        expect(f.state.settings.apiConfigId, f.settings.apiConfigId);
        expect(controller.runtime.recipientConfirmed, isFalse);
        final currentPolicy = controller.runtime.snapshot.preferences!;
        expect(currentPolicy.scope?.gameSessionId, isNull);
        expect(currentPolicy.grants, originalPolicy.grants);
      });
    },
  );

  test(
    'local diagnostic start explains global read consent without fabricated catalog or diagnosis',
    () {
      const replies = SupportLocalReplyService();
      final reply = replies.reply(
        'own',
        replies.topicForText('Начнём диагностику'),
        text: 'Начнём диагностику',
      );
      expect(reply.body, contains('С единым доступом к данным'));
      expect(reply.body, contains('данные не читал'));
      expect(reply.body, contains('причины ошибки не устанавливал'));
      expect(reply.body, isNot(contains('Вот список твоих последних сессий')));
      expect(
        reply.cards.whereType<SupportGuidanceCard>().map((c) => c.target),
        isNot(contains(SupportGuidanceTarget.gameSession)),
      );
      expect(reply.body, isNot(contains(ModelScreenFixture.excluded)));
    },
  );
}
