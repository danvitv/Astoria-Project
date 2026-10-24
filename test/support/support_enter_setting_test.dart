import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';

import 'helpers/support_model_screen_fixture.dart';
import 'support_recipient_send_helpers.dart';

Future<void> _confirmPrompt(WidgetTester tester, ModelScreenFixture f) async {
  await tester.pump();
  final sheet = find.byType(SupportModelPromptPreviewSheet);
  final route = ModalRoute.of<bool>(tester.element(sheet))!;
  await tester.pump(route.transitionDuration + const Duration(microseconds: 1));
  final button = find.byKey(const ValueKey('support_prompt_preview_confirm'));
  expect(button.hitTestable(), findsOneWidget);
  final popped = await f.signal(
    tester,
    () => route.popped,
    label: 'original prompt decision',
  );
  await f.action(tester, () => tester.tap(button));
  expect(await f.finish(tester, popped), isTrue);
  await tester.pump();
  await tester.pump(
    route.reverseTransitionDuration + const Duration(microseconds: 1),
  );
}

void main() {
  testWidgets(
    'existing global Enter setting drives the same recipient -> fresh prompt -> one fake HTTP path',
    (tester) async {
      final f = ModelScreenFixture(confirm: false);
      await f.run(tester, () async {
        expect(
          tester
              .widget<SupportComposerBar>(find.byType(SupportComposerBar))
              .enterToSend,
          isTrue,
        );
        final recipient = await openRecipientFromSend(
          tester,
          f,
          viaEnter: true,
        );
        expect(f.adapters, isEmpty);
        await decideRecipient(tester, f, recipient, confirmed: true);
        expect(f.adapters, isEmpty);
        final signal = await f.signal(
          tester,
          () => recipientModelPhase(f, (v) => v.preview != null),
          label: 'fresh Enter full prompt',
        );
        await f.action(tester, () async {
          await tester.tap(
            find.byKey(const ValueKey('support_composer_input')),
          );
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        });
        final preview = (await f.finish(tester, signal)).preview!;
        expect(preview.messages.last.text, 'Привет, расскажи о себе');
        expect(f.adapters, isEmpty);
        final done = await f.signal(
          tester,
          () => recipientModelPhase(
            f,
            (v) => v.phase == SupportModelPhase.settled && !v.busy,
          ),
          label: 'original keyboard run settled',
        );
        await _confirmPrompt(tester, f);
        await f.finish(tester, done);
        expect(f.adapters, hasLength(1));
        expect(f.adapters.single.fetches, 1);
      });
    },
  );

  testWidgets(
    'turning the existing global setting off makes Enter a newline and live change enables native review',
    (tester) async {
      final f = ModelScreenFixture(confirm: false, enterToSend: false);
      await f.run(tester, () async {
        expect(
          tester
              .widget<SupportComposerBar>(find.byType(SupportComposerBar))
              .enterToSend,
          isFalse,
        );
        final draft = tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .controller;
        await f.action(tester, () async {
          await tester.tap(
            find.byKey(const ValueKey('support_composer_input')),
          );
          draft.text = 'Hello';
          await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        });
        await tester.pump();
        expect(
          tester.widget<TextField>(find.byType(TextField)).textInputAction,
          TextInputAction.newline,
        );
        await f.action(tester, () {
          tester.testTextInput.updateEditingValue(
            const TextEditingValue(
              text: 'Hello\n',
              selection: TextSelection.collapsed(offset: 6),
            ),
          );
        });
        await tester.pump();
        expect(draft.text, 'Hello\n');
        expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
        expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
        expect(f.adapters, isEmpty);
        await f.action(tester, () {
          f.changeEnterToSendForTest(true);
        });
        await tester.pump();
        expect(
          tester
              .widget<SupportComposerBar>(find.byType(SupportComposerBar))
              .enterToSend,
          isTrue,
        );
        final recipient = await openRecipientFromSend(
          tester,
          f,
          text: 'Hello',
          viaEnter: true,
        );
        expect(f.adapters, isEmpty);
        await decideRecipient(tester, f, recipient, confirmed: false);
        expect(draft.text, 'Hello');
      });
    },
  );
}
