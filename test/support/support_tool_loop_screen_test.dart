import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_tool_native_ui.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_tool_loop_screen_fixture.dart';

void main() {
  toolLoopWidgetTest(
    'actual Send performs tool effect/final answer with numeric composer usage and no Send modal',
    (tester, f) async {
      f.core.replies.addAll([
        f.core.call('astoria_preferences_update', {'hideTooltips': true}),
        f.core.answer('Saved the safe UI preference.'),
      ]);
      final field = find.byType(TextField).first;
      await tester.enterText(field, 'Please hide tooltips.');
      await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
      await f.join(tester, f.core.firstFetch.future);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      await f.terminal(tester);
      await tester.pump();
      expect(f.core.wire, hasLength(2));
      expect(f.core.prefs.getBool('hideTooltips'), isTrue);
      await f.revealReply(tester, 'Saved the safe UI preference.');
      expect(
        find.byKey(const ValueKey('support_request_token_usage')),
        findsOneWidget,
      );
      expect(find.textContaining('31'), findsWidgets);
      expect(find.byType(AlertDialog), findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
    },
  );

  for (final decision in ['cancel', 'accept', 'old callback', 'session ABA']) {
    toolLoopWidgetTest(
      'actual exact native confirmation $decision and real keyless repo effect',
      (tester, f) async {
        final screenContext = tester.element(find.byType(TextField).first);
        var current = true;
        final ui = SupportModelToolNativeUi(
          context: screenContext,
          isOriginalUiCurrent: () => current,
        );
        final token = CancelToken();
        final context = SupportAppActionContext(
          runId: 'native-confirmation-run',
          sessionId: f.core.native.session,
          cancelToken: token,
          isCurrent: () => current,
          allowReversibleChanges: true,
          confirmation: ui,
        );
        final registry = f.core.container.read(
          supportAppActionRegistryProvider,
        );
        final before = await tester.runAsync(
          () => f.core.native.apiRepo.getConfigIds(),
        );
        final result = Completer<NativeToolResult>();
        await tester.runAsync(() async {
          unawaited(
            registry
                .execute(
                  NativeToolCall(
                    id: 'native-confirmation-call',
                    name: 'astoria_connection_create',
                    arguments: const {
                      'template': 'openaiChat',
                      'name': 'Exact native profile',
                      'model': 'synthetic-model',
                    },
                  ),
                  context,
                )
                .then(result.complete, onError: result.completeError),
          );
        });
        for (
          var turn = 0;
          turn < 128 &&
              find
                  .byKey(const ValueKey('support_tool_confirmation_accept'))
                  .evaluate()
                  .isEmpty;
          turn++
        ) {
          await tester.pump();
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        }
        await f.confirmationReady(tester);
        final accept = find.byKey(
          const ValueKey('support_tool_confirmation_accept'),
        );
        expect(accept, findsOneWidget);
        expect(find.textContaining('astoria_connection_create'), findsWidgets);
        final retained = tester.widget<GlazeActionButton>(accept).onTap!;
        if (decision == 'accept') {
          await tester.tap(accept);
        } else {
          if (decision == 'session ABA') {
            current = false;
            token.cancel();
            current =
                true; // Cancellation must still permanently retire the old request.
          } else {
            await tester.tap(
              find.byKey(const ValueKey('support_tool_confirmation_cancel')),
            );
          }
        }
        // The actual pop/reverse frames must advance before joining the native
        // decision; zero-time SQL/event turns do not move route animations.
        await tester.pumpAndSettle();
        final settled = await f.join(tester, result.future);
        await tester.pumpAndSettle();
        if (decision == 'old callback' || decision == 'session ABA') retained();
        final after = await tester.runAsync(
          () => f.core.native.apiRepo.getConfigIds(),
        );
        expect(after!.length, before!.length + (decision == 'accept' ? 1 : 0));
        expect(settled.content['ok'], decision == 'accept');
        expect(
          f.core.wire,
          isEmpty,
        ); // UI configuration decision is not a paid probe/Send.
        ui.dispose();
      },
    );
  }

  toolLoopWidgetTest(
    'model navigation uses finite GoRouter path and never paints answer on destination',
    (tester, f) async {
      f.core.replies.add(
        f.core.call('astoria_navigate', {'destination': 'settings'}),
      );
      await tester.enterText(find.byType(TextField).first, 'Open settings.');
      await tester.tap(find.byKey(const ValueKey('support_composer_send_btn')));
      await f.join(tester, f.core.firstFetch.future);
      for (
        var turn = 0;
        turn < 128 &&
            f.router.routeInformationProvider.value.uri.path == '/support';
        turn++
      ) {
        await tester.pump();
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      }
      expect(
        f.router.routeInformationProvider.value.uri.path,
        '/menu/settings',
      );
      expect(f.core.wire, hasLength(1));
      expect(find.text('Actual final answer'), findsNothing);
      // Origin reservation is settled independently; no tool role becomes chat.
      await tester.pumpAndSettle();
    },
  );
}
