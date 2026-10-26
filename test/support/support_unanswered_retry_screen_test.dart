import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_direct_conversation_fixture.dart';

void main() {
  directConversationTest(
    'actual unanswered-user retry button sends once without a second user or draft change',
    (tester, f) async {
      const id = 'unanswered-native-user';
      final before = await f.action(tester, () async {
        await f.repo.appendMessage(
          const SupportMessage(
            id: id,
            sessionId: ModelScreenFixture.session,
            role: 'user',
            body: 'ORIGINAL_UNANSWERED_QUESTION',
            runId: 'original-user-emission',
            createdAt: 10,
          ),
        );
        await f.workspace.refresh();
        return (await (f.db.select(
          f.db.supportMessages,
        )..where((t) => t.id.equals(id))).getSingle());
      });
      directDraft(tester).text = 'UNSENT_DRAFT_REMAINS';
      final button = await _reveal(tester, f, id);
      expect(button.label, 'Отправить повторно');
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'original actual unanswered retry terminal',
      );
      final callback = button.onTap!;
      await f.action(tester, () {
        callback();
        callback();
      });
      final result = await f.finish(tester, terminal);
      expect(result.saved, true, reason: result.reason.label);
      final after = await f.action(
        tester,
        () async => (
          await (f.db.select(
            f.db.supportMessages,
          )..where((t) => t.id.equals(id))).getSingle(),
          await f.repo.getMessagesForSession(ModelScreenFixture.session),
        ),
      );
      expect(after.$1, before);
      expect(after.$2.where((m) => m.role == 'user'), hasLength(1));
      expect(
        after.$2.where((m) => m.role == 'assistant' && m.id != 'old'),
        hasLength(1),
      );
      expect(f.adapters, hasLength(1));
      final wire = directWire(f, 0);
      expect(wire.where((m) => m['role'] == 'user').map((m) => m['content']), [
        'ORIGINAL_UNANSWERED_QUESTION',
      ]);
      expect(directDraft(tester).text, 'UNSENT_DRAFT_REMAINS');
      await tester.pump();
      expect(
        find.byKey(const ValueKey('support_retry_unanswered-native-user')),
        findsNothing,
      );
    },
  );

  directConversationTest(
    'retained retry callback cannot send an old user after a newer question is committed',
    (tester, f) async {
      const id = 'stale-unanswered-user';
      await f.action(tester, () async {
        await f.repo.appendMessage(
          const SupportMessage(
            id: id,
            sessionId: ModelScreenFixture.session,
            role: 'user',
            body: 'OLD_UNANSWERED',
            runId: 'old-user-emission',
            createdAt: 10,
          ),
        );
        await f.workspace.refresh();
      });
      final callback = (await _reveal(tester, f, id)).onTap!;
      final before = await f.action(tester, () async {
        await f.repo.appendMessage(
          const SupportMessage(
            id: 'newer-native-user',
            sessionId: ModelScreenFixture.session,
            role: 'user',
            body: 'NEWER_QUESTION',
            runId: 'newer-user-emission',
            createdAt: 11,
          ),
        );
        await f.workspace.refresh();
        return f.repo.getMessagesForSession(ModelScreenFixture.session);
      });
      await tester.pump();
      await f.action(tester, callback);
      await tester.pump(const Duration(milliseconds: 500));
      expect(f.adapters, isEmpty);
      expect(
        await f.action(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
        ),
        before,
      );
    },
  );
}

Future<GlazeActionButton> _reveal(
  WidgetTester tester,
  ModelScreenFixture f,
  String id,
) async {
  final finder = find.byKey(ValueKey('support_retry_$id'));
  final scroll = find
      .descendant(
        of: find.byType(SupportMessageList),
        matching: find.byType(Scrollable),
      )
      .first;
  await f.action(
    tester,
    () => tester.scrollUntilVisible(finder, 200, scrollable: scroll),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  return tester.widget<GlazeActionButton>(finder);
}
