import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'helpers/support_model_screen_fixture.dart';
import 'support_recipient_send_helpers.dart';

void main() {
  testWidgets(
    'one Send opens recipient review; explicit recipient confirmation retains input; fresh Send plus prompt confirmation makes exactly one HTTP request',
    (tester) async {
      final f = ModelScreenFixture(confirm: false);
      await f.run(tester, () async {
        final c = f.container.read(supportNativeConsentControllerProvider);
        final originalMessages = f.state.activeMessages
            .map((m) => m.id)
            .toList();
        final route = await openRecipientFromSend(tester, f);
        expect(c.runtime.recipientConfirmed, isFalse);
        expect(f.adapters, isEmpty);
        expect(f.state.activeMessages.map((m) => m.id), originalMessages);
        await decideRecipient(tester, f, route, confirmed: true);
        await recipientUiUntil(tester, f, () => c.runtime.recipientConfirmed);
        final draft = tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller;
        expect(draft.text, 'Привет, расскажи о себе');
        expect(c.runtime.snapshot.preferences!.grants, isEmpty);
        expect(c.runtime.snapshot.preferences!.scope?.gameSessionId, isNull);
        expect(f.state.activeMessages.map((m) => m.id), originalMessages);
        expect(
          f.adapters,
          isEmpty,
          reason: 'Recipient setup is not prompt approval or automatic resend.',
        );

        final prepared = await f.signal(
          tester,
          () => recipientModelPhase(f, (v) => v.preview != null),
          label: 'fresh second Send prompt',
        );
        await f.action(
          tester,
          () => tester.tap(
            find.byKey(const ValueKey('support_composer_send_btn')),
          ),
        );
        final preview = (await f.finish(tester, prepared)).preview!;
        expect(preview.messages.last.text, 'Привет, расскажи о себе');
        expect(preview.gameMessages, 0);
        expect(preview.supportMessages, 0);
        expect(f.adapters, isEmpty);
        await tester.pump();
        final promptRoute = ModalRoute.of<bool>(
          tester.element(find.byType(SupportModelPromptPreviewSheet)),
        )!;
        await tester.pump(
          promptRoute.transitionDuration + const Duration(microseconds: 1),
        );
        final settled = await f.signal(
          tester,
          () => recipientModelPhase(
            f,
            (v) => v.phase == SupportModelPhase.settled && !v.busy,
          ),
          label: 'original confirmed prompt settlement',
        );
        await f.action(
          tester,
          () => tester.tap(
            find.byKey(const ValueKey('support_prompt_preview_confirm')),
          ),
        );
        await f.finish(tester, settled);
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
      });
    },
  );

  testWidgets(
    'cancelled and closed original recipient callbacks cannot confirm, append or send',
    (tester) async {
      final f = ModelScreenFixture(confirm: false);
      await f.run(tester, () async {
        final c = f.container.read(supportNativeConsentControllerProvider);
        final route = await openRecipientFromSend(tester, f);
        final confirm = tester
            .widget<GlazeActionButton>(
              await revealRecipientDecision(tester, confirmed: true),
            )
            .onTap!;
        await decideRecipient(tester, f, route, confirmed: false);
        await f.action(tester, () {
          confirm();
          confirm();
        });
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(c.runtime.recipientConfirmed, isFalse);
        expect(c.runtime.snapshot.preferences!.recipient, isNull);
        expect(f.adapters, isEmpty);
        expect(f.state.activeMessages.map((m) => m.id), ['old']);
        expect(
          tester
              .widget<SupportComposerBar>(find.byType(SupportComposerBar))
              .controller
              .text,
          'Привет, расскажи о себе',
        );
      });
    },
  );

  for (final changed in ['session ABA', 'model']) {
    testWidgets(
      'old recipient confirmation after $changed cannot write or send',
      (tester) async {
        final f = ModelScreenFixture(confirm: false);
        await f.run(tester, () async {
          final c = f.container.read(supportNativeConsentControllerProvider);
          final route = await openRecipientFromSend(tester, f);
          final confirm = tester
              .widget<GlazeActionButton>(
                await revealRecipientDecision(tester, confirmed: true),
              )
              .onTap!;
          if (changed == 'session ABA') {
            await f.action(tester, () {
              f.workspace.selectSession(ModelScreenFixture.other);
              f.workspace.selectSession(ModelScreenFixture.session);
            });
            final refreshed = await f.signal(
              tester,
              f.workspace.refresh,
              label: 'original ABA refresh',
            );
            await f.finish(tester, refreshed);
          } else {
            await f.action(
              tester,
              () => f.workspace.selectModel('replacement-model'),
            );
          }
          await f.action(tester, confirm);
          await tester.pump();
          expect(c.runtime.recipientConfirmed, isFalse);
          expect(c.runtime.snapshot.preferences!.recipient, isNull);
          expect(f.adapters, isEmpty);
          expect(f.state.activeMessages.map((m) => m.id), ['old']);
          await decideRecipient(tester, f, route, confirmed: false);
        });
      },
    );
  }

  testWidgets('unavailable connection cannot enable recipient confirmation', (
    tester,
  ) async {
    final f = ModelScreenFixture(confirm: false);
    await f.run(tester, () async {
      await f.action(
        tester,
        () => f.container.read(apiConfigRepoProvider).delete(f.api.id),
      );
      final route = await openRecipientFromSend(tester, f);
      final button = await revealRecipientDecision(tester, confirmed: true);
      expect(tester.widget<GlazeActionButton>(button).onTap, isNull);
      expect(f.adapters, isEmpty);
      await decideRecipient(tester, f, route, confirmed: false);
      expect(f.state.activeMessages.map((m) => m.id), ['old']);
    });
  });
}
