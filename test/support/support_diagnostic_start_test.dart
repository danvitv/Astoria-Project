import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_local_reply_service.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_send_settings_snapshot.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';

import 'helpers/support_model_screen_fixture.dart';

Future<SupportModelRunView> _phase(
  ModelScreenFixture f,
  bool Function(SupportModelRunView) reached,
) {
  final original = f.bridge;
  if (reached(original.view)) return Future.value(original.view);
  final result = Completer<SupportModelRunView>();
  late final void Function() stop;
  stop = original.listen(() {
    if (reached(original.view) && !result.isCompleted) {
      stop();
      result.complete(original.view);
    }
  });
  addTearDown(stop);
  return result.future;
}

void main() {
  for (final question in [
    'Привет, расскажи о себе',
    'Начнём диагностику, какую сессию разобрать?',
  ]) {
    testWidgets(
      '$question opens exact native prompt without selecting game or sharing history',
      (tester) async {
        final f = ModelScreenFixture();
        await f.run(tester, () async {
          final p = f.container
              .read(supportNativeConsentControllerProvider)
              .runtime
              .snapshot
              .preferences!;
          expect(p.scope?.gameSessionId, isNull);
          expect(p.allows(SupportPermission.modelGameHistory), isFalse);
          expect(p.allows(SupportPermission.modelSupportHistory), isFalse);
          expect(p.allows(SupportPermission.readDiagnostics), isFalse);
          expect(p.allows(SupportPermission.readSafeSettings), isFalse);
          final signal = await f.signal(
            tester,
            () => _phase(f, (v) => v.preview != null),
            label: 'original no-history send preview',
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
          final view = await f.finish(tester, signal);
          final preview = view.preview!;
          expect(preview.gameMessages, 0);
          expect(preview.supportMessages, 0);
          expect(preview.messages.last.text, question);
          expect(
            preview.messages.map((m) => m.text).join(),
            isNot(contains(ModelScreenFixture.excluded)),
          );
          expect(f.adapters, isEmpty);
          await tester.pump();
          final route = ModalRoute.of<bool>(
            tester.element(find.byType(SupportModelPromptPreviewSheet)),
          )!;
          await tester.pump(
            route.transitionDuration + const Duration(microseconds: 1),
          );
          final finished = await f.signal(
            tester,
            () => _phase(
              f,
              (v) => v.phase == SupportModelPhase.settled && !v.busy,
            ),
            label: 'original approved send drain',
          );
          await f.action(
            tester,
            () => tester.tap(
              find.byKey(const ValueKey('support_prompt_preview_confirm')),
            ),
          );
          await f.finish(tester, finished);
          await tester.pumpAndSettle();
          expect(f.adapters, hasLength(1));
          expect(f.adapters.single.fetches, 1);
          final body =
              jsonDecode(f.adapters.single.upload!) as Map<String, dynamic>;
          expect(
            jsonEncode(body['messages']),
            isNot(contains(ModelScreenFixture.excluded)),
          );
          expect(draft.text, isEmpty);
          expect(f.state.settings.apiConfigId, f.settings.apiConfigId);
          expect(
            f.container
                .read(supportNativeConsentControllerProvider)
                .runtime
                .snapshot
                .preferences!
                .scope
                ?.gameSessionId,
            isNull,
          );
        });
      },
    );
  }

  testWidgets(
    'unconfirmed greeting shows real safe snapshot, exact blocker and retained draft without wire',
    (tester) async {
      final f = ModelScreenFixture(confirm: false);
      await f.run(tester, () async {
        final draft = tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller;
        await f.action(tester, () async {
          draft.text = 'Привет, расскажи о себе';
          await tester.tap(
            find.byKey(const ValueKey('support_composer_send_btn')),
          );
        });
        await tester.pumpAndSettle();
        final snapshot = tester.widget<SupportSendSettingsSnapshot>(
          find.byType(SupportSendSettingsSnapshot),
        );
        expect(snapshot.settings.maxTokens, 512);
        expect(snapshot.settings.temperature, 0.25);
        expect(snapshot.settings.hasConfiguredModel, isTrue);
        expect(snapshot.recipientConfirmed, isFalse);
        expect(
          snapshot.reason,
          contains('получатель запроса ещё не подтверждён'),
        );
        expect(find.textContaining(ModelScreenFixture.key), findsNothing);
        expect(draft.text, 'Привет, расскажи о себе');
        expect(f.adapters, isEmpty);
        expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
        expect(f.state.activeMessages.map((m) => m.id), ['old']);
      });
    },
  );

  test(
    'local diagnostic start offers native catalog before any game-session selection, not fabricated model knowledge',
    () {
      const replies = SupportLocalReplyService();
      final reply = replies.reply(
        'own',
        replies.topicForText('Начнём диагностику'),
        text: 'Начнём диагностику',
      );
      expect(reply.body, contains('без выбора игровой сессии'));
      expect(reply.body, contains('Вот список твоих последних сессий'));
      expect(reply.body, contains('Сообщения не читались'));
      expect(
        reply.cards.whereType<SupportGuidanceCard>().map((c) => c.target),
        contains(SupportGuidanceTarget.gameSession),
      );
      expect(reply.body, isNot(contains(ModelScreenFixture.excluded)));
    },
  );
}
