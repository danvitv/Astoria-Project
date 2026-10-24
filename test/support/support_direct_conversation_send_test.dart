import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_model_prompt_preview_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_privacy_review_sheet.dart';

import 'support_direct_conversation_fixture.dart';

void main() {
  directConversationTest(
    'two actual Send turns use current conversation once without either sheet',
    (tester, f) async {
      final controller = f.container.read(
        supportNativeConsentControllerProvider,
      );
      final beforePolicy = controller.runtime.snapshot.preferences!;
      expect(controller.runtime.recipientConfirmed, isFalse);
      for (final text in ['First direct USER', 'Second direct USER']) {
        final terminal = await f.signal(
          tester,
          () => directTerminal(f),
          label: 'original direct $text terminal',
        );
        final callback = tester
            .widget<IconButton>(find.byKey(directSend))
            .onPressed!;
        await f.action(tester, () {
          directDraft(tester).text = text;
          callback();
          callback(); // Original repeated gesture cannot claim a second run.
        });
        final result = await f.finish(tester, terminal);
        await tester.pumpAndSettle();
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(directDraft(tester).text, isEmpty);
        expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
        expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
        expect(controller.runtime.recipientConfirmed, isFalse);
      }
      expect(f.adapters, hasLength(2));
      final first = directWire(f, 0), second = directWire(f, 1);
      expect(first.skip(1), [
        {'role': 'assistant', 'content': directLocalHelp},
        {'role': 'user', 'content': 'First direct USER'},
      ]);
      expect(second.skip(1), [
        {'role': 'assistant', 'content': directLocalHelp},
        {'role': 'user', 'content': 'First direct USER'},
        {'role': 'assistant', 'content': 'Safe actual screen answer'},
        {'role': 'user', 'content': 'Second direct USER'},
      ]);
      final afterPolicy = controller.runtime.snapshot.preferences!;
      expect(afterPolicy.policyIdentity, beforePolicy.policyIdentity);
      expect(afterPolicy.revision, beforePolicy.revision);
      expect(afterPolicy.grants, beforePolicy.grants);
      final old = await f.signal(
        tester,
        () => f.repo.getContextBlockById('support.reply_provenance:old'),
        label: 'no origin backfill',
      );
      expect(await f.finish(tester, old), isNull);
      expect(
        f.sql.observations.where(
          (read) =>
              read.statement.contains('FROM chat_sessions') ||
              read.statement.contains('FROM characters'),
        ),
        isEmpty,
      );
    },
  );

  directConversationTest(
    'global Enter setting uses the exact direct Send path',
    (tester, f) async {
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'actual Enter terminal',
      );
      await f.action(tester, () async {
        directDraft(tester).text = 'Direct Enter USER';
        await tester.tap(find.byKey(directInput));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      });
      expect((await f.finish(tester, terminal)).saved, isTrue);
      await tester.pumpAndSettle();
      expect(f.adapters, hasLength(1));
      expect(directWire(f, 0).last, {
        'role': 'user',
        'content': 'Direct Enter USER',
      });
      expect(find.byType(SupportPrivacyReviewSheet), findsNothing);
      expect(find.byType(SupportModelPromptPreviewSheet), findsNothing);
    },
  );

  directConversationTest(
    'disabled global Enter leaves Send as the direct path',
    (tester, f) async {
      await f.action(tester, () async {
        directDraft(tester).text = 'Send after disabled Enter';
        await tester.tap(find.byKey(directInput));
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      });
      await tester.pumpAndSettle();
      expect(f.adapters, isEmpty);
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'actual Send after disabled Enter',
      );
      await f.action(tester, () => tester.tap(find.byKey(directSend)));
      expect((await f.finish(tester, terminal)).saved, isTrue);
      await tester.pumpAndSettle();
      expect(f.adapters, hasLength(1));
      expect(directWire(f, 0).last['content'], 'Send after disabled Enter');
    },
    enterToSend: false,
  );
}
