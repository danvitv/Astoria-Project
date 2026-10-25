import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';

import 'support_direct_conversation_fixture.dart';

void main() {
  for (final (role, status) in [
    ('user', 'complete'),
    ('assistant', 'complete'),
    ('assistant', 'error'),
    ('assistant', 'stopped'),
  ]) {
    directConversationTest(
      'actual $role $status menu deletes only its durable support row',
      (tester, f) async {
        final before = await f.action(tester, () async {
          await f.repo.appendMessage(
            SupportMessage(
              id: 'selected-delete',
              sessionId: ModelScreenFixture.session,
              role: role,
              status: status,
              body: 'SELECTED_INDIVIDUAL_ROW',
              createdAt: 10,
            ),
          );
          await f.repo.appendMessage(
            const SupportMessage(
              id: 'retained-sibling',
              sessionId: ModelScreenFixture.session,
              role: 'user',
              body: 'RETAINED_INDIVIDUAL_SIBLING',
              createdAt: 11,
            ),
          );
          await f.workspace.refresh();
          return (
            await f.repo.getMessagesForSession(ModelScreenFixture.session),
            await f.repo.getMessagesForSession(ModelScreenFixture.other),
            await f.repo.getContextBlocksForSession(ModelScreenFixture.session),
            await f.db.select(f.db.chatSessions).get(),
          );
        });
        await tester.pumpAndSettle();
        await _openConfirmation(tester, f, 'selected-delete');
        // Opening a menu and reviewing it never deletes optimistically.
        expect(
          await f.action(
            tester,
            () => f.repo.getMessageById('selected-delete'),
          ),
          isNotNull,
        );
        final deleted = await f.signal(
          tester,
          () => _deleted(f, 'selected-delete'),
          label: 'selected deletion durable workspace publication',
        );
        await f.action(tester, () => tester.tap(find.text('Удалить')));
        await f.finish(tester, deleted);
        final after = await f.action(
          tester,
          () async => (
            await f.repo.getMessagesForSession(ModelScreenFixture.session),
            await f.repo.getMessagesForSession(ModelScreenFixture.other),
            await f.repo.getContextBlocksForSession(ModelScreenFixture.session),
            await f.db.select(f.db.chatSessions).get(),
          ),
        );
        expect(after.$1, before.$1.where((m) => m.id != 'selected-delete'));
        expect(after.$2, before.$2);
        expect(after.$3, before.$3);
        expect(after.$4, before.$4);
        expect(f.adapters, isEmpty);
      },
    );
  }

  directConversationTest(
    'old message confirmation expires after switching away and back',
    (tester, f) async {
      final before = await f.action(
        tester,
        () => f.repo.getMessagesForSession(ModelScreenFixture.session),
      );
      await _openConfirmation(tester, f, 'old');
      await f.action(tester, () {
        f.workspace.selectSession(ModelScreenFixture.other);
        f.workspace.selectSession(ModelScreenFixture.session);
      });
      await f.action(tester, f.workspace.refresh);
      await tester.pumpAndSettle();
      await f.action(tester, () => tester.tap(find.text('Удалить')));
      await tester.pumpAndSettle();
      await f.action(tester, f.workspace.refresh);
      expect(
        await f.action(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
        ),
        before,
      );
      expect(
        await f.action(tester, () => f.repo.getMessageById('other-private')),
        isNotNull,
      );
      expect(f.adapters, isEmpty);
    },
  );

  directConversationTest(
    'active reply menu deletion cancels original SSE and cannot resurrect its row',
    (tester, f) async {
      await f.action(tester, () {
        f.quiet = true;
        f.response = '';
      });
      final terminal = await f.signal(
        tester,
        () => directTerminal(f),
        label: 'deleted original reply terminal',
      );
      final created = await f.signal(
        tester,
        () => f.adapterCreated.future,
        label: 'original quiet reply adapter',
      );
      await f.action(tester, () async {
        directDraft(tester).text = 'USER_REMAINS_AFTER_REPLY_DELETE';
        await tester.tap(find.byKey(directSend));
      });
      final adapter = await f.finish(tester, created);
      final listening = await f.signal(
        tester,
        () => adapter.responseListening,
        label: 'original reply stream subscription',
      );
      await f.finish(tester, listening);
      await tester.pump();
      final reply = await f.action(
        tester,
        () => f.state.activeMessages.singleWhere(
          (m) => m.role == SupportMessageRole.assistant && m.runId != null,
        ),
      );
      await _openConfirmation(tester, f, reply.id);
      final cancelled = await f.signal(
        tester,
        () => adapter.cancelObserved.future,
        label: 'delete propagates original transport CancelToken',
      );
      final deleted = await f.signal(
        tester,
        () => _deleted(f, reply.id),
        label: 'active reply durable deletion',
      );
      await f.action(tester, () => tester.tap(find.text('Удалить')));
      await f.finish(tester, cancelled);
      await f.finish(tester, deleted);
      final result = await f.finish(tester, terminal);
      expect(result.saved, isFalse);
      expect(adapter.closed, isTrue);
      // Join the original late terminal cleanup, then reload the real repo.
      await f.action(tester, f.workspace.refresh);
      expect(
        await f.action(tester, () => f.repo.getMessageById(reply.id)),
        isNull,
      );
      expect(
        (await f.action(
          tester,
          () => f.repo.getMessagesForSession(ModelScreenFixture.session),
        )).where((m) => m.body == 'USER_REMAINS_AFTER_REPLY_DELETE'),
        hasLength(1),
      );
      expect(f.adapters, hasLength(1));
    },
  );
}

Future<void> _openConfirmation(
  WidgetTester tester,
  ModelScreenFixture f,
  String id,
) async {
  final menu = find.byKey(ValueKey('support_message_menu_$id'));
  final feed = find
      .descendant(
        of: find.byType(SupportMessageList),
        matching: find.byType(Scrollable),
      )
      .first;
  await f.action(
    tester,
    () => tester.scrollUntilVisible(menu, 200, scrollable: feed),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(tester.widget<IconButton>(menu).onPressed, isNotNull);
  await f.action(tester, () => tester.tap(menu));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  await f.action(tester, () => tester.tap(find.text('Удалить сообщение')));
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
  expect(find.text('Удалить это сообщение?'), findsOneWidget);
}

Future<void> _deleted(ModelScreenFixture f, String id) {
  final done = Completer<void>();
  final subscription = f.container.listen(supportWorkspaceProvider, (_, state) {
    if (!done.isCompleted && !state.activeMessages.any((m) => m.id == id)) {
      done.complete();
    }
  });
  addTearDown(subscription.close);
  return done.future;
}
