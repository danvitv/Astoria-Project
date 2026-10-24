import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';

import 'support_direct_conversation_fixture.dart';

void main() {
  directConversationTest(
    'direct own-chat consent does NOT declassify recorded game origins',
    (tester, f) async {
      final seed = await f.signal(tester, () async {
        final user = await f.repo.appendCurrentUser(
          message: const SupportMessage(
            id: 'derived-user',
            sessionId: ModelScreenFixture.session,
            role: 'user',
            body: 'Earlier question',
            runId: 'derived-run',
            createdAt: 5,
          ),
          isCurrent: () => true,
        );
        final recipe = SupportModelProvenance(
          supportSessionId: ModelScreenFixture.session,
          replyMessageId: 'derived-reply',
          runId: 'derived-run',
          currentUserMessageId: 'derived-user',
          originalRanges: [
            SupportModelSourceRange(
              domain: SupportModelSourceDomain.game,
              sessionId: 'excluded-game',
              orderedMessageIds: ['excluded-game-message'],
            ),
          ],
          directReplies: const [],
        );
        final reservation = await f.repo.reserveOrderedReply(
          message: const SupportMessage(
            id: 'derived-reply',
            sessionId: ModelScreenFixture.session,
            role: 'assistant',
            body: '',
            runId: 'derived-run',
            status: 'preparing',
            createdAt: 6,
          ),
          originatingUser: user!,
          provenanceJson: SupportModelProvenanceCodec.encodeForEncryptedStorage(
            recipe,
          ),
          isCurrent: () => true,
        );
        expect(
          await f.repo.settleReply(
            expected: reservation!,
            status: 'complete',
            body: 'Recorded game-derived visible answer',
            isCurrent: () => true,
          ),
          isNotNull,
        );
        await f.workspace.refresh();
      }, label: 'explicit externally derived fixture rows');
      await f.finish(tester, seed);
      await tester.pumpAndSettle();
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'direct origin refusal',
      );
      await f.action(tester, () async {
        directDraft(tester).text = 'Next direct question';
        await tester.tap(find.byKey(directSend));
      });
      final result = await f.finish(tester, terminal);
      expect(result.accepted, isTrue);
      expect(result.reason, SupportModelRefusal.lineageUnavailable);
      expect(f.adapters, isEmpty);
      final facts = await f.signal(
        tester,
        () => f.repo.getContextBlockById(
          'support.reply_provenance:derived-reply',
        ),
        label: 'unchanged original source declaration',
      );
      final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        (await f.finish(tester, facts))!.protectedFactsJson,
      ).recipe!;
      expect(decoded.currentConversationMessageIds, isNull);
      expect(
        decoded.originalRanges.single.domain,
        SupportModelSourceDomain.game,
      );
      expect(decoded.originalRanges.single.orderedMessageIds, [
        'excluded-game-message',
      ]);
    },
  );
}
