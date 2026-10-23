import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_message_service.dart';
import 'package:glaze_flutter/features/chat_history/chat_history_provider.dart';

import 'helpers/chat_source_mutation_fixture.dart';

const _session = ChatSession(
  id: 'game',
  characterId: 'character',
  sessionIndex: 0,
  messages: [
    ChatMessage(
      id: 'a',
      role: 'assistant',
      content: 'A',
      swipes: ['A', 'A2'],
      agentSwipes: [
        AgentSwipe(content: 'A'),
        AgentSwipe(content: 'A blue'),
      ],
    ),
    ChatMessage(id: 'b', role: 'assistant', content: 'B', swipes: ['B', 'B2']),
    ChatMessage(id: 'c', role: 'user', content: 'C'),
  ],
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'history single/bulk admission precedes paused Studio first await',
    () async {
      final gate = Completer<StudioConfig?>();
      final f = await GameSourceFixture.create(studioGate: gate);
      try {
        await f.seed(_session);
        await f.container.read(chatHistoryProvider.future);
        final history = f.container.read(chatHistoryProvider.notifier);
        final work = history.deleteSessions(['game', 'later']);
        expect(f.pending('a'), isTrue);
        expect(f.pending('a', sessionId: 'later'), isTrue);
        expect(f.pending('a', sessionId: 'unrelated'), isFalse);
        expect(f.events.take(2).map((event) => event.sessionId), [
          'game',
          'later',
        ]);
        expect(
          await f.container.read(chatRepoProvider).getById('game'),
          isNotNull,
        );
        gate.completeError(StateError('prerequisite failed'));
        await expectLater(work, throwsStateError);
        expect(f.pending('a'), isFalse);
        expect(f.pending('a', sessionId: 'later'), isFalse);
        expect(
          await f.container.read(chatRepoProvider).getById('game'),
          isNotNull,
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'direct clear service fences before paused character prerequisite and finally',
    () async {
      final gate = Completer<Character?>();
      final f = await GameSourceFixture.create(characterGate: gate);
      try {
        await f.seed(_session);
        final before = await _durableSessionSnapshot(f);
        final work = f.harness.sessions.clearChat('character', _session);
        expect(f.pending('a'), isTrue);
        expect(f.events.single.messageIds, isNull);
        gate.completeError(StateError('character read failed'));
        await expectLater(work, throwsStateError);
        expect(f.pending('a'), isFalse);
        expect(await _durableSessionSnapshot(f), before);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'pure suffix planning and invalid controller actions emit nothing',
    () async {
      final f = await GameSourceFixture.create();
      try {
        await f.seed(_session);
        expect(f.harness.messages.planDeleteMessages(_session, {}), isNull);
        expect(f.harness.messages.planDeleteMessages(_session, {0}), isNull);
        await f.harness.ops.deleteMessages({0, 2});
        await f.harness.ops.deleteMessages({99});
        await f.harness.ops.moveMessage(1, 1);
        await f.harness.ops.toggleMessageHidden(99);
        await f.harness.ops.toggleImageHidden(0);
        await f.harness.ops.hideTopMessages(0);
        await f.harness.ops.unhideAllMessages();
        await f.harness.swipes.setSwipe(0, 99);
        await f.harness.swipes.setSwipe(0, 0);
        await f.harness.swipes.setAgentSwipe(0, 0);
        await f.harness.swipes.changeSwipe(0, -1);
        await f.harness.swipes.changeSwipe(0, 0);
        await f.harness.swipes.changeAgentSwipe(0, 0);
        await f.harness.swipes.deleteActiveSwipe(2);
        await f.harness.swipes.deleteActiveAgentSwipe(1);
        await f.harness.swipes.setGreeting(1, 1);
        await f.harness.swipes.setGreeting(0, -1);
        expect(
          ChatMessageService.removeActiveSwipe(_session.messages[2]),
          isNull,
        );
        expect(f.events, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'suffix IDs fence before optimistic paint and remain pending through queued commit',
    () async {
      final f = await GameSourceFixture.create();
      final gate = Completer<void>();
      try {
        await f.seed(_session);
        final blocker = f.harness.queue.run(() => gate.future);
        f.harness.onPublish = (_) {
          expect(f.pending('b'), isTrue);
          expect(f.pending('c'), isTrue);
          expect(f.pending('a'), isFalse);
        };
        final work = f.harness.ops.deleteMessages({1, 2});
        expect(f.events.single.messageIds, {'b', 'c'});
        expect(f.harness.state.messages.map((message) => message.id), ['a']);
        expect(
          (await f.container.read(chatRepoProvider).getById('game'))!
              .messages
              .length,
          3,
        );
        expect(f.pending('b'), isTrue);
        gate.complete();
        await blocker;
        await work;
        expect(f.pending('b'), isFalse);
        expect(
          (await f.container.read(chatRepoProvider).getById('game'))!.messages
              .map((m) => m.id),
          ['a'],
        );
      } finally {
        if (!gate.isCompleted) gate.complete();
        await f.harness.queue.settle();
        await f.close();
      }
    },
  );

  test(
    'edit admission precedes regex await, failure settles and leaves durable row',
    () async {
      final regexes = Completer<List<PresetRegex>>();
      final f = await GameSourceFixture.create(regexes: regexes.future);
      try {
        await f.seed(_session);
        final work = f.harness.ops.editMessage(0, 'Edited');
        expect(f.pending('a'), isTrue);
        expect(f.pending('b'), isFalse);
        regexes.completeError(StateError('regex failed'));
        await expectLater(work, throwsStateError);
        expect(f.pending('a'), isFalse);
        expect(
          (await f.container.read(chatRepoProvider).getById('game'))!
              .messages
              .first
              .content,
          'A',
        );
      } finally {
        await f.close();
      }
    },
  );

  test(
    'direct message service begins before transaction and settles failed suffix',
    () async {
      final f = await GameSourceFixture.create();
      try {
        await f.seed(_session);
        await f.db.customStatement('''
        CREATE TRIGGER reject_fixture_suffix
        BEFORE UPDATE OF messages_json ON chat_sessions
        WHEN OLD.session_id = 'game'
        BEGIN SELECT RAISE(ABORT, 'fixture suffix failure'); END
      ''');
        final before = await _durableSessionSnapshot(f);
        final work = f.harness.messages.deleteMessages(_session, {1, 2});
        expect(f.events.single.messageIds, {'b', 'c'});
        expect(f.pending('b'), isTrue);
        expect(f.pending('a'), isFalse);
        await expectLater(work, throwsA(anything));
        expect(f.pending('b'), isFalse);
        expect(await _durableSessionSnapshot(f), before);
      } finally {
        await f.close();
      }
    },
  );

  test(
    'accepted greeting stays pending through queue and failed prerequisite',
    () async {
      final character = Completer<Character?>();
      final characterStarted = Completer<void>();
      final f = await GameSourceFixture.create(
        characterGate: character,
        characterReadStarted: characterStarted,
      );
      final gate = Completer<void>();
      try {
        await f.seed(_session);
        final before = await _durableSessionSnapshot(f);
        final blocker = f.harness.queue.run(() => gate.future);
        final work = f.harness.swipes.setGreeting(0, 1);
        expect(f.events.single.messageIds, {'a'});
        expect(f.pending('a'), isTrue);
        final failure = expectLater(work, throwsStateError);
        gate.complete();
        await blocker;
        await characterStarted.future;
        expect(f.pending('a'), isTrue);
        character.completeError(StateError('greeting prerequisite failure'));
        await failure;
        expect(f.pending('a'), isFalse);
        expect(await _durableSessionSnapshot(f), before);
      } finally {
        if (!gate.isCompleted) gate.complete();
        if (!character.isCompleted) character.complete(null);
        await f.harness.queue.settle();
        await f.close();
      }
    },
  );

  test(
    'bulk unhide fences entire session before queued eligibility change',
    () async {
      final f = await GameSourceFixture.create();
      final gate = Completer<void>();
      try {
        await f.seed(
          _session.copyWith(
            messages: [
              _session.messages[0].copyWith(isHidden: true),
              ..._session.messages.skip(1),
            ],
          ),
        );
        final blocker = f.harness.queue.run(() => gate.future);
        final work = f.harness.ops.unhideAllMessages();
        expect(f.events.single.messageIds, isNull);
        expect(f.pending('a'), isTrue);
        expect(f.pending('c'), isTrue);
        gate.complete();
        await blocker;
        await work;
        expect(f.pending('a'), isFalse);
        expect(f.harness.state.messages.first.isHidden, isFalse);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await f.harness.queue.settle();
        await f.close();
      }
    },
  );

  test(
    'queued variation delete never retargets when original ID disappeared',
    () async {
      final f = await GameSourceFixture.create();
      final gate = Completer<void>();
      try {
        await f.seed(_session);
        final blocker = f.harness.queue.run(() async {
          await gate.future;
          final remaining = await f.container
              .read(chatRepoProvider)
              .mutateMessages(
                sessionId: 'game',
                updatedAt: 1,
                mutate: (messages) =>
                    messages.where((message) => message.id != 'a').toList(),
              );
          f.harness.state = f.harness.state.copyWith(session: remaining);
        });
        final work = f.harness.swipes.deleteActiveSwipe(0);
        expect(f.events.single.messageIds, {'a'});
        gate.complete();
        await blocker;
        await work;
        final row = (await f.container.read(chatRepoProvider).getById('game'))!;
        expect(row.messages.first.id, 'b');
        expect(row.messages.first.swipes, ['B', 'B2']);
        expect(f.pending('a'), isFalse);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await f.harness.queue.settle();
        await f.close();
      }
    },
  );

  final actions = <String, Future<void> Function(GameSourceHarness)>{
    'clear': (h) => h.ops.clearChat(),
    'single suffix delete': (h) => h.ops.deleteMessage(2),
    'order': (h) => h.ops.moveMessage(0, 1),
    'hide': (h) => h.ops.toggleMessageHidden(0),
    'bulk hide': (h) => h.ops.hideTopMessages(1),
    'set swipe': (h) => h.swipes.setSwipe(0, 1),
    'change swipe': (h) => h.swipes.changeSwipe(0, 1),
    'set agent': (h) => h.swipes.setAgentSwipe(0, 1),
    'change agent': (h) => h.swipes.changeAgentSwipe(0, 1),
    'delete swipe': (h) => h.swipes.deleteActiveSwipe(0),
    'delete agent': (h) => h.swipes.deleteActiveAgentSwipe(0),
    'greeting': (h) => h.swipes.setGreeting(0, 1),
  };
  for (final action in actions.entries) {
    test(
      '${action.key} fences at acceptance while previous write is paused',
      () async {
        final f = await GameSourceFixture.create(
          characterGate: action.key == 'greeting'
              ? (Completer<Character?>()..complete(
                  const Character(
                    id: 'character',
                    name: 'Fixture character',
                    firstMes: 'Fixture greeting',
                    alternateGreetings: ['Fixture alternate'],
                  ),
                ))
              : null,
        );
        final gate = Completer<void>();
        try {
          await f.seed(_session);
          final blocker = f.harness.queue.run(() => gate.future);
          var published = false;
          f.harness.onPublish = (_) {
            published = true;
            expect(f.events.first.phase, ChatSourceMutationPhase.began);
          };
          final work = action.value(f.harness);
          expect(f.events.first.phase, ChatSourceMutationPhase.began);
          final ids = f.events.first.messageIds;
          expect(f.pending(ids?.first ?? 'a'), isTrue);
          expect(f.pending('a', sessionId: 'unrelated'), isFalse);
          if (action.key == 'set swipe' ||
              action.key == 'change swipe' ||
              action.key == 'set agent' ||
              action.key == 'change agent') {
            expect(
              published,
              isTrue,
            ); // beginning preceded actual optimistic paint
          }
          gate.complete();
          await blocker;
          await work;
          expect(f.pending('a'), isFalse);
          expect(f.pending('c'), isFalse);
          if (action.key == 'greeting') {
            expect(f.harness.state.messages.first.content, 'Fixture alternate');
            expect(f.harness.state.messages.first.greetingIndex, 1);
          }
        } finally {
          if (!gate.isCompleted) gate.complete();
          await f.harness.queue.settle();
          await f.close();
        }
      },
    );
  }

  test(
    'queued variation deletion re-resolves original ID after index shift',
    () async {
      final f = await GameSourceFixture.create();
      final gate = Completer<void>();
      try {
        await f.seed(_session);
        final blocker = f.harness.queue.run(() async {
          await gate.future;
          final shifted = await f.container
              .read(chatRepoProvider)
              .mutateMessages(
                sessionId: 'game',
                updatedAt: 1,
                mutate: (messages) => [
                  const ChatMessage(
                    id: 'inserted',
                    role: 'assistant',
                    content: 'I',
                    swipes: ['I', 'I2'],
                  ),
                  ...messages,
                ],
              );
          f.harness.state = f.harness.state.copyWith(session: shifted);
        });
        final work = f.harness.swipes.deleteActiveSwipe(0);
        expect(f.events.single.messageIds, {'a'});
        expect(f.pending('a'), isTrue);
        gate.complete();
        await blocker;
        await work;
        final row = (await f.container.read(chatRepoProvider).getById('game'))!;
        expect(row.messages.first.id, 'inserted');
        expect(row.messages.first.swipes, ['I', 'I2']);
        expect(
          row.messages.singleWhere((message) => message.id == 'a').swipes,
          ['A2'],
        );
        expect(f.pending('a'), isFalse);
      } finally {
        if (!gate.isCompleted) gate.complete();
        await f.harness.queue.settle();
        await f.close();
      }
    },
  );

  test(
    'unhide bulk and history clear use session fence, no observer loads a feature',
    () async {
      final f = await GameSourceFixture.create(observe: false);
      try {
        await f.seed(
          _session.copyWith(
            messages: [
              _session.messages[0].copyWith(isHidden: true),
              ..._session.messages.skip(1),
            ],
          ),
        );
        await f.harness.ops.unhideAllMessages();
        expect(f.harness.state.messages.first.isHidden, isFalse);
        await f.container.read(chatHistoryProvider.future);
        await f.container.read(chatHistoryProvider.notifier).clearChat('game');
        expect(
          (await f.container.read(chatRepoProvider).getById('game'))!.messages,
          isEmpty,
        );
        expect(f.events, isEmpty);
        // Strict before-evaluation core overrides and after-evaluation allowlist
        // plus blanket native-channel tripwire are asserted THROUGH f.close().
      } finally {
        await f.close();
      }
    },
  );
}

/// Snapshot every durable column AFTER seed encoding, not seed-object identity.
/// messagesJson retains every message/AgentSwipe field and nested payload byte;
/// AgentSwipe has no value equality, so comparing decoded objects is not valid.
Future<Map<String, dynamic>> _durableSessionSnapshot(
  GameSourceFixture f,
) async {
  final row = await (f.db.select(
    f.db.chatSessions,
  )..where((table) => table.sessionId.equals(_session.id))).getSingle();
  return row.toJson();
}
