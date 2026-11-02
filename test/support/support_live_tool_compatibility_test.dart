import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'support_app_domain_loop_fixture.dart';

void main() {
  domainLoopTest(
    'MODEL legacy saved connection changes actual theme without migrating its key',
    (tester, f) async {
      const key = 'SYNTHETIC_LEGACY_ASTORIA_KEY';
      final storageBefore = await configurationAction(tester, () async {
        final native = f.screen.core.native;
        // Only this fixture's declared fake slot. No OS or production key access.
        native.storage.values.remove(native.nativeStorageKey);
        await native.apiRepo.put(native.api.copyWith(apiKey: key));
        await native.apiRepo.getById(native.api.id);
        await native.runtime.refresh(resolve: true);
        await f.screen.core.container
            .read(supportWorkspaceProvider.notifier)
            .refresh();
        return Map<String, String>.of(native.storage.values);
      });
      await tester.pumpAndSettle();
      f.script(
        f.screen.core.call('astoria_theme_mode_set', {'mode': 'light'}),
        next: (_) => f.screen.core.answer('Тема изменена.'),
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(reply.status, 'complete');
      expect(f.screen.core.wire, hasLength(2));
      // This memory fixture has no original native source identity, so source
      // tools are unavailable even when the global source capability is on.
      expect(f.screen.core.wire.first['tools'], hasLength(56));
      final messages = (f.screen.core.wire.first['messages'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        messages.first['content'],
        contains('native application assistant'),
      );
      expect(messages.first['content'], isNot(contains('You have no tools')));
      expect(f.lastResult()['ok'], true);
      expect(f.lastResult()['effect'], 'persisted');
      expect(
        f.screen.core.container.read(themeProvider).activePreset.themeMode,
        'light',
      );
      expect(f.screen.core.backing.checkedWrites, greaterThan(0));
      expect(f.screen.core.native.storage.values, storageBefore);
      expect(
        f.screen.core.container
            .read(supportModelUiBridgeProvider)
            .view
            .usage
            ?.totalTokens,
        38,
      );
      expect(jsonEncode(f.screen.core.wire), isNot(contains(key)));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL consecutive current-chat users coalesce after deleting an actual native reply',
    (tester, f) async {
      f.script(f.screen.core.answer('SYNTHETIC_NATIVE_REPLY_TO_DELETE'));
      await f.start(tester, confirmation: false);
      final removed = await f.finish(tester);
      // `drained` is disposal-only. Observe the original completed Send view;
      // the live screen intentionally stays mounted for the second request.
      await f.screen.terminal(tester);
      final before = await configurationAction(tester, () async {
        final core = f.screen.core;
        final workspace = core.container.read(
          supportWorkspaceProvider.notifier,
        );
        await workspace.refresh();
        expect(await workspace.deleteMessage(removed.id), true);
        expect(await core.native.repo.getMessageById(removed.id), isNull);
        for (final (id, body, createdAt) in [
          ('merge-user-a', 'FIRST_USER_TEXT', removed.createdAt + 1),
          ('merge-user-b', 'SECOND_USER_TEXT', removed.createdAt + 2),
        ]) {
          await core.native.repo.appendMessage(
            SupportMessage(
              id: id,
              sessionId: core.native.session,
              role: 'user',
              body: body,
              createdAt: createdAt,
            ),
          );
        }
        await core.container.read(supportWorkspaceProvider.notifier).refresh();
        return core.native.repo.getMessagesForSession(core.native.session);
      });
      await tester.pumpAndSettle();
      f.script(f.screen.core.answer('Контекст принят.'));
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(reply.status, 'complete');
      expect(f.screen.core.wire, hasLength(2));
      expect(
        jsonEncode(f.screen.core.wire.last),
        isNot(contains('SYNTHETIC_NATIVE_REPLY_TO_DELETE')),
      );
      final messages = (f.screen.core.wire.last['messages'] as List)
          .cast<Map<String, dynamic>>();
      final users = messages.where((m) => m['role'] == 'user').toList();
      expect(users, hasLength(2));
      expect(
        users.last['content'],
        'Выполни только точную показанную операцию Astoria.\n\n'
        'FIRST_USER_TEXT\n\nSECOND_USER_TEXT\n\n'
        'Выполни только точную показанную операцию Astoria.',
      );
      for (var i = 1; i < messages.length; i++) {
        expect(
          messages[i - 1]['role'] == 'user' && messages[i]['role'] == 'user',
          false,
        );
      }
      final after = await configurationAction(
        tester,
        () => f.screen.core.native.repo.getMessagesForSession(
          f.screen.core.native.session,
        ),
      );
      for (final original in before) {
        expect(after.singleWhere((m) => m.id == original.id), original);
      }
      f.noEgress(reply.body);
    },
  );
}
