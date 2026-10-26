import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'support_direct_conversation_fixture.dart';

Future<void> _send(
  WidgetTester tester,
  ModelScreenFixture f,
  String text,
) async {
  final terminal = await f.signal(
    tester,
    () => directTerminal(f),
    label: 'original Send terminal',
  );
  final callback = tester.widget<IconButton>(find.byKey(directSend)).onPressed!;
  await f.action(tester, () {
    directDraft(tester).text = text;
    callback();
  });
  expect((await f.finish(tester, terminal)).saved, isTrue);
  await tester.pumpAndSettle();
}

Future<VoidCallback> _button(WidgetTester tester, String id) async {
  final button = find.byKey(ValueKey('support_regenerate_$id'));
  await tester.scrollUntilVisible(
    button,
    200,
    scrollable: find
        .descendant(
          of: find.byType(SupportMessageList),
          matching: find.byType(Scrollable),
        )
        .first,
    maxScrolls: 12,
  );
  await tester.pumpAndSettle();
  expect(button.hitTestable(), findsOneWidget);
  return tester.widget<GlazeActionButton>(button).onTap!;
}

void main() {
  directConversationTest(
    'actual regeneration is one request, unchanged user bytes and assistant identity; composer retained',
    (tester, f) async {
      await _send(tester, f, 'Original once-only question');
      final before = await f.action(
        tester,
        () => f.repo.getMessagesForSession(ModelScreenFixture.session),
      );
      final rows = await f.action(
        tester,
        () => f.db.select(f.db.supportMessages).get(),
      );
      final reply = before.last;
      final callback = await _button(tester, reply.id);
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'original regeneration terminal',
      );
      await f.action(tester, () {
        directDraft(tester).text = 'Unsent composer draft';
        f.response = chatComplete('Fresh regenerated answer');
        callback();
        callback();
      });
      final result = await f.finish(tester, terminal);
      expect(result.saved, isTrue);
      await tester.pumpAndSettle();
      expect(f.adapters, hasLength(2));
      expect(directDraft(tester).text, 'Unsent composer draft');
      final after = await f.action(
        tester,
        () => f.repo.getMessagesForSession(ModelScreenFixture.session),
      );
      final afterRows = await f.action(
        tester,
        () => f.db.select(f.db.supportMessages).get(),
      );
      expect(after, hasLength(before.length));
      expect(after.last.id, reply.id);
      expect(after.last.createdAt, reply.createdAt);
      expect(after.last.runId, isNot(reply.runId));
      expect(after.last.body, 'Fresh regenerated answer');
      for (final row in rows.where((r) => r.role == 'user')) {
        expect(afterRows.singleWhere((r) => r.id == row.id), row);
      }
      final wire = directWire(f, 1);
      expect(
        wire.where((m) => m['content'] == 'Original once-only question'),
        hasLength(1),
      );
      expect(
        wire.any((m) => m['content'] == 'Safe actual screen answer'),
        isFalse,
      );
      expect(wire.first['content'], contains('Only THIS regeneration'));
      await _send(tester, f, 'Next actual Send');
      expect(
        directWire(f, 2).any((m) => m['content'] == 'Fresh regenerated answer'),
        isTrue,
      );
    },
  );

  directConversationTest(
    'retained regeneration callback refuses session ABA without append or request',
    (tester, f) async {
      await _send(tester, f, 'Question before session switch');
      final oldReply = f.state.activeMessages.last;
      final oldCallback = await _button(tester, oldReply.id);
      for (final session in [
        ModelScreenFixture.other,
        ModelScreenFixture.session,
      ]) {
        final refreshed = await f.signal(tester, () async {
          f.workspace.selectSession(session);
          await f.workspace.refresh();
        }, label: 'explicit session ABA refresh');
        await f.finish(tester, refreshed);
        await tester.pumpAndSettle();
      }
      final before = await f.action(
        tester,
        () => f.repo.getMessagesForSession(ModelScreenFixture.session),
      );
      await f.action(tester, oldCallback);
      await tester.pumpAndSettle();
      expect(f.adapters, hasLength(1));
      expect(
        await f.action(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
        ),
        before,
      );
    },
  );

  directConversationTest(
    'regeneration refuses a changed conversation prefix without replacing the answer',
    (tester, f) async {
      await _send(tester, f, 'Question with original context');
      final reply = f.state.activeMessages.last;
      final callback = await _button(tester, reply.id);
      await f.action(tester, () async {
        final old = (await f.repo.getMessageById('old'))!;
        await f.repo.putMessage(old.copyWith(body: 'Different current prefix'));
      });
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'source equality refusal',
      );
      await f.action(tester, callback);
      final result = await f.finish(tester, terminal);
      expect(result.saved, isFalse);
      expect(f.adapters, hasLength(1));
      final durable = await f.action(
        tester,
        () => f.repo.getMessageById(reply.id),
      );
      expect(durable!.runId, reply.runId);
      expect(durable.body, reply.body);
    },
  );
}
