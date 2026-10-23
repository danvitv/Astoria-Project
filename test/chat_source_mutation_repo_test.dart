import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/application/session_deletion_store.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

import 'helpers/chat_source_mutation_fixture.dart';

const _session = ChatSession(
  id: 'game',
  characterId: 'character',
  sessionIndex: 0,
  messages: [ChatMessage(id: 'old', role: 'user', content: 'Fixture body')],
  sessionVars: {'sessionName': 'Retained', 'branchedAt': '10'},
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final clear in [false, true]) {
    test(
      '${clear ? 'clear' : 'delete'} direct neutral store fences before transaction and rolls back without restoring authority',
      () async {
        final f = await GameSourceFixture.create();
        try {
          await f.seed(_session);
          await f.container
              .read(studioConfigRepoProvider)
              .upsert(const StudioConfig(sessionId: 'game', enabled: true));
          await f.db.customStatement('''
          CREATE TRIGGER reject_fixture_mutation
          BEFORE ${clear ? 'UPDATE OF messages_json' : 'DELETE'} ON chat_sessions
          WHEN OLD.session_id = 'game'
          BEGIN SELECT RAISE(ABORT, 'fixture rollback'); END
        ''');
          var retired = false;
          f.registry.subscribe((change) {
            if (change.phase == ChatSourceMutationPhase.began &&
                change.affects(sessionId: 'game', messageIds: ['old'])) {
              retired = true;
            }
          });
          final repo = f.container.read(sessionDeletionRepoProvider);
          // Same neutral interface used by existing remote delete injection.
          final SessionDeletionStore remoteStore = repo;
          final operation = clear
              ? repo.clearSession(
                  sessionId: 'game',
                  replacementMessages: const [],
                )
              : remoteStore.deleteSession('game');
          expect(retired, isTrue);
          expect(
            f.pending('old'),
            isTrue,
          ); // immediately, before any event-loop turn
          expect(f.pending('old', sessionId: 'control'), isFalse);
          await expectLater(operation, throwsA(anything));
          expect(f.pending('old'), isFalse);
          expect(retired, isTrue); // settlement does not un-retire old custody
          expect(
            (await f.container.read(chatRepoProvider).getById('game'))!
                .messages,
            _session.messages,
          );
          expect(
            await f.container
                .read(studioConfigRepoProvider)
                .getBySessionId('game'),
            isNotNull,
          );
          expect(f.events.map((event) => event.phase), [
            ChatSourceMutationPhase.began,
            ChatSourceMutationPhase.settled,
          ]);
        } finally {
          await f.close();
        }
      },
    );
  }

  test(
    'optional-hook-free repo preserves return/configuration and ordinary delete',
    () async {
      final f = await GameSourceFixture.create(observe: false);
      try {
        await f.seed(_session);
        final repo = SessionDeletionRepo(f.db);
        final cleared = await repo.clearSession(
          sessionId: 'game',
          replacementMessages: const [
            ChatMessage(id: 'greeting', role: 'assistant', content: 'Hello'),
          ],
          resetBranchStamp: true,
          countDeletedMessages: true,
        );
        expect(cleared!.id, 'game');
        expect(cleared.messages.single.id, 'greeting');
        expect(cleared.sessionVars['sessionName'], 'Retained');
        expect(cleared.sessionVars['branchedAt'], isNull);
        expect(cleared.deletedMessageCount, 1);
        await repo.deleteSession('game');
        expect(
          await f.container.read(chatRepoProvider).getById('game'),
          isNull,
        );
        expect(f.events, isEmpty);
      } finally {
        await f.close();
      }
    },
  );
}
