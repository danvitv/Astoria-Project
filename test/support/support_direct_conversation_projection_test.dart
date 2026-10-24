import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_plain_markdown.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';

import 'support_direct_conversation_fixture.dart';

void main() {
  directConversationTest(
    'idle secret-policy change sends the redacted visible old body exactly once',
    (tester, f) async {
      const secret = 'projection-synthetic-secret-684391';
      const storedBody =
          'Visible old history $secret and ${ModelScreenFixture.key}.';
      final seed = await f.signal(tester, () async {
        final old = await f.repo.getMessageById('old');
        await f.repo.putMessage(old!.copyWith(body: storedBody));
        await f.workspace.refresh();
      }, label: 'synthetic old stored secret body');
      await f.finish(tester, seed);
      await tester.pumpAndSettle();

      final feed = tester.state<ScrollableState>(
        find
            .descendant(
              of: find.byType(SupportMessageList),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await f.action(tester, () {
        feed.position.jumpTo(feed.position.maxScrollExtent);
      });
      await tester.pumpAndSettle();
      final visibleOld = find.byWidgetPredicate(
        (widget) =>
            widget is SupportPlainMarkdown &&
            widget.text.startsWith('Visible old history '),
      );
      expect(visibleOld, findsOneWidget);
      expect(
        tester.widget<SupportPlainMarkdown>(visibleOld).text,
        contains(secret),
      );
      final oldEmitter = tester
          .widget<SupportComposerBar>(find.byType(SupportComposerBar))
          .nativeOwner;

      // Only the injected in-memory policy changes. Do not reload or rewrite
      // stored messages to repair their displayed or emitted projection.
      await f.action(tester, () => f.redaction.registerSecret(secret));
      final policyPublished = await f.signal(
        tester,
        f.container.pump,
        label: 'current synthetic secret-policy publication',
      );
      await f.finish(tester, policyPublished);
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<SupportComposerBar>(find.byType(SupportComposerBar))
            .nativeOwner,
        isNot(same(oldEmitter)),
      );
      expect(visibleOld, findsOneWidget);
      final displayed = tester.widget<SupportPlainMarkdown>(visibleOld).text;
      expect(displayed, isNot(contains(secret)));
      expect(displayed, isNot(contains(ModelScreenFixture.key)));
      expect(f.adapters, isEmpty);

      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'original projected-history direct Send terminal',
      );
      await f.action(tester, () async {
        directDraft(tester).text = 'Safe unrelated current question';
        await tester.tap(find.byKey(directSend));
      });
      final result = await f.finish(tester, terminal);
      await tester.pumpAndSettle();
      expect(result.accepted, isTrue);
      expect(result.saved, isTrue);
      expect(result.reason, SupportModelRefusal.none);
      expect(f.adapters, hasLength(1));
      expect(directWire(f, 0).skip(1), [
        {'role': 'assistant', 'content': displayed},
        {'role': 'user', 'content': 'Safe unrelated current question'},
      ]);
      expect(f.adapters.single.upload, isNot(contains(secret)));
      expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
      expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
      final stored = await f.signal(
        tester,
        () => f.repo.getMessageById('old'),
        label: 'unchanged original stored history body',
      );
      expect((await f.finish(tester, stored))!.body, storedBody);
    },
  );
}
