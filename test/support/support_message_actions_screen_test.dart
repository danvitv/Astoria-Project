import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_message_display_projection.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_message_list.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_direct_conversation_fixture.dart';

/// Consume only this requested synthetic write; delegate all other channels to
/// the unchanged isolation guard rather than to the real platform.
VoidCallback _captureClipboard(List<String> copied) {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final original = messenger.allMessagesHandler!;
  messenger.allMessagesHandler = (channel, handler, message) async {
    if (channel == SystemChannels.platform.name && message != null) {
      final call = SystemChannels.platform.codec.decodeMethodCall(message);
      if (call.method == 'Clipboard.setData') {
        final args = call.arguments;
        if (args is! Map<Object?, Object?> ||
            args.length != 1 ||
            args['text'] is! String) {
          throw StateError('Unexpected synthetic clipboard payload.');
        }
        copied.add(args['text'] as String);
        return SystemChannels.platform.codec.encodeSuccessEnvelope(null);
      }
    }
    return original(channel, handler, message);
  };
  return () => messenger.allMessagesHandler = original;
}

void main() {
  for (final role in ['user', 'assistant']) {
    directConversationTest(
      'actual $role menu copies only its safe displayed text',
      (tester, f) async {
        const id = 'copy-selected';
        final body = 'VISIBLE_WORDS ${ModelScreenFixture.secret} **tail**';
        await f.action(tester, () async {
          await f.repo.appendMessage(
            SupportMessage(
              id: id,
              sessionId: ModelScreenFixture.session,
              role: role,
              body: body,
              createdAt: 10,
            ),
          );
          await f.workspace.refresh();
        });
        final copied = <String>[];
        final restoreClipboard = _captureClipboard(copied);
        try {
          await _menu(tester, f, id);
          await f.action(tester, () => tester.tap(find.text('Копировать')));
          await _frames(tester);
          expect(copied, [
            SupportMessageDisplayProjection(
              redactor: f.redaction.redactor,
            ).project(body),
          ]);
          expect(copied.single, isNot(contains(ModelScreenFixture.secret)));
          expect(copied.single, contains('VISIBLE_WORDS'));
          expect(f.adapters, isEmpty);
          expect(
            (await f.action(tester, () => f.repo.getMessageById(id)))!.body,
            body,
          );
        } finally {
          restoreClipboard();
        }
      },
    );
  }

  directConversationTest(
    'copy uses newly registered redaction rather than an old menu policy',
    (tester, f) async {
      const id = 'copy-policy';
      const newlySecret = 'SYNTHETIC_NEWLY_REGISTERED_CLIPBOARD_VALUE';
      await f.action(tester, () async {
        await f.repo.appendMessage(
          const SupportMessage(
            id: id,
            sessionId: ModelScreenFixture.session,
            role: 'assistant',
            body: 'Visible prefix $newlySecret',
            createdAt: 10,
          ),
        );
        await f.workspace.refresh();
      });
      final copied = <String>[];
      final restoreClipboard = _captureClipboard(copied);
      try {
        await _menu(tester, f, id);
        await f.action(tester, () => f.redaction.registerSecret(newlySecret));
        await tester.pump();
        await f.action(tester, () => tester.tap(find.text('Копировать')));
        await _frames(tester);
        expect(copied, hasLength(1));
        expect(copied.single, isNot(contains(newlySecret)));
        expect(f.adapters, isEmpty);
      } finally {
        restoreClipboard();
      }
    },
  );

  directConversationTest(
    'actual user editor saves only wording without sending or replacing other rows',
    (tester, f) async {
      const id = 'edit-selected';
      final before = await f.action(tester, () async {
        await f.repo.appendMessage(
          const SupportMessage(
            id: id,
            sessionId: ModelScreenFixture.session,
            role: 'user',
            body: 'Original wording',
            createdAt: 10,
          ),
        );
        await f.repo.appendMessage(
          const SupportMessage(
            id: 'unchanged-later-answer',
            sessionId: ModelScreenFixture.session,
            role: 'assistant',
            body: 'Prior answer keeps its meaning',
            createdAt: 11,
          ),
        );
        await f.workspace.refresh();
        return (
          await f.repo.getMessagesForSession(ModelScreenFixture.session),
          await f.repo.getContextBlocksForSession(ModelScreenFixture.session),
          await f.repo.getMessagesForSession(ModelScreenFixture.other),
          await f.db.select(f.db.chatSessions).get(),
        );
      });
      directDraft(tester).text = 'UNSENT_COMPOSER_DRAFT';
      await _menu(tester, f, id);
      await f.action(tester, () => tester.tap(find.text('Изменить сообщение')));
      await _frames(tester);
      final field = find.descendant(
        of: find.byKey(const ValueKey('support_message_edit_field')),
        matching: find.byType(TextField),
      );
      await tester.enterText(field, '  Corrected wording\nkeeps whitespace  ');
      await tester.pump();
      expect(
        tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_message_edit_save')),
            )
            .onTap,
        isNotNull,
      );
      final saved = await f.signal(
        tester,
        () => _edited(f, id, '  Corrected wording\nkeeps whitespace  '),
        label: 'committed user wording publication',
      );
      await f.action(
        tester,
        () =>
            tester.tap(find.byKey(const ValueKey('support_message_edit_save'))),
      );
      await f.finish(tester, saved);
      final after = await f.action(
        tester,
        () async => (
          await f.repo.getMessagesForSession(ModelScreenFixture.session),
          await f.repo.getContextBlocksForSession(ModelScreenFixture.session),
          await f.repo.getMessagesForSession(ModelScreenFixture.other),
          await f.db.select(f.db.chatSessions).get(),
        ),
      );
      expect(after.$1, [
        for (final m in before.$1)
          m.id == id
              ? m.copyWith(body: '  Corrected wording\nkeeps whitespace  ')
              : m,
      ]);
      expect(after.$2, before.$2);
      expect(after.$3, before.$3);
      expect(after.$4, before.$4);
      expect(directDraft(tester).text, 'UNSENT_COMPOSER_DRAFT');
      expect(f.adapters, isEmpty);
    },
  );

  directConversationTest(
    'old user edit confirmation expires on away-and-back session selection',
    (tester, f) async {
      const id = 'stale-editor';
      await f.action(tester, () async {
        await f.repo.appendMessage(
          const SupportMessage(
            id: id,
            sessionId: ModelScreenFixture.session,
            role: 'user',
            body: 'UNEDITED_ORIGINAL',
            createdAt: 10,
          ),
        );
        await f.workspace.refresh();
      });
      await _menu(tester, f, id);
      await f.action(tester, () => tester.tap(find.text('Изменить сообщение')));
      await _frames(tester);
      await f.action(tester, () {
        f.workspace.selectSession(ModelScreenFixture.other);
        f.workspace.selectSession(ModelScreenFixture.session);
      });
      await f.action(tester, f.workspace.refresh);
      await tester.enterText(
        find.descendant(
          of: find.byKey(const ValueKey('support_message_edit_field')),
          matching: find.byType(TextField),
        ),
        'STALE_EDIT_MUST_NOT_SAVE',
      );
      await tester.pump();
      final save = tester.widget<GlazeActionButton>(
        find.byKey(const ValueKey('support_message_edit_save')),
      );
      save.onTap?.call();
      await _frames(tester);
      expect(
        (await f.action(tester, () => f.repo.getMessageById(id)))!.body,
        'UNEDITED_ORIGINAL',
      );
      expect(f.adapters, isEmpty);
      await f.action(tester, () => tester.tap(find.text('Отмена')));
      await _frames(tester);
    },
  );
}

Future<void> _menu(WidgetTester tester, ModelScreenFixture f, String id) async {
  final menu = find.byKey(ValueKey('support_message_menu_$id'));
  final scroll = find
      .descendant(
        of: find.byType(SupportMessageList),
        matching: find.byType(Scrollable),
      )
      .first;
  await f.action(
    tester,
    () => tester.scrollUntilVisible(menu, 200, scrollable: scroll),
  );
  await _frames(tester);
  expect(tester.widget<IconButton>(menu).onPressed, isNotNull);
  await f.action(tester, () => tester.tap(menu));
  await _frames(tester);
}

Future<void> _frames(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _edited(ModelScreenFixture f, String id, String body) {
  final done = Completer<void>();
  final subscription = f.container.listen(supportWorkspaceProvider, (_, state) {
    if (!done.isCompleted &&
        state.activeMessages.any((m) => m.id == id && m.body == body)) {
      done.complete();
    }
  });
  addTearDown(subscription.close);
  return done.future;
}
