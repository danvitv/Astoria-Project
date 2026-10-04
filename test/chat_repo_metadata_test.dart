import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  late AppDatabase db;
  late ChatRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = ChatRepo(db);
  });

  tearDown(() => db.close());

  test(
    'metadata watch ignores drafts but delivers same-stamp changes',
    () async {
      const session = ChatSession(
        id: 'session',
        characterId: 'character',
        sessionIndex: 0,
        updatedAt: 42,
        messages: [
          ChatMessage(
            id: 'a',
            role: 'assistant',
            content: 'Opening. Continuation.',
            continuationOffset: 9,
            timestamp: 1000,
          ),
        ],
      );
      await repo.put(session);
      final events = <List<SessionMetadata>>[];
      var next = Completer<List<SessionMetadata>>();
      final sub = repo.watchAllSessionMetadata().listen((metadata) {
        events.add(metadata);
        if (!next.isCompleted) next.complete(metadata);
      });
      addTearDown(sub.cancel);
      final initial = (await next.future).single;
      expect(initial.lastMessageContent, 'Continuation.');
      await repo.updateDraftIfMessageCount(
        sessionId: session.id,
        draft: 'Typing',
        expectedMessageCount: 1,
      );
      // Drain invalidated queries while keeping the stream subscribed.
      await repo.getAllSessionMetadata();
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(events, hasLength(1));

      next = Completer<List<SessionMetadata>>();
      await repo.put(
        session.copyWith(
          messages: [
            session.messages.single.copyWith(
              content: 'Edited without changing timestamp',
              continuationOffset: 0,
            ),
          ],
        ),
      );
      final edited = (await next.future).single;
      expect(edited.updatedAt, 42);
      expect(edited.messageCount, 1);
      expect(edited.lastMessageContent, 'Edited without changing timestamp');

      next = Completer<List<SessionMetadata>>();
      await repo.put(
        session.copyWith(
          characterId: 'other',
          sessionIndex: 3,
          sessionVars: {'sessionName': 'Branch', 'branchedAt': '3000'},
        ),
      );
      final branched = (await next.future).single;
      expect(branched.characterId, 'other');
      expect(branched.sessionIndex, 3);
      expect(branched.sessionName, 'Branch');
      expect(branched.originTimestamp, 3000);
      expect(branched.originKind, 'branched');
    },
  );

  test('metadata watch emits the initial empty list', () async {
    expect(await repo.watchAllSessionMetadata().first, isEmpty);
  });

  test('large unrelated payloads do not enter metadata decoding', () async {
    final payload = List.filled(
      10000,
      'Studio state with quotes " and 🐈',
    ).join();
    await repo.put(
      ChatSession(
        id: 'large',
        characterId: 'character',
        sessionIndex: 0,
        sessionVars: {'sessionName': 'Named', 'unrelated': payload},
        messages: [
          ChatMessage(
            id: 'a',
            role: 'assistant',
            content: '🐈 Earlier.\n\nNew scene.',
            continuationOffset: '🐈 Earlier.\n\n'.length,
            timestamp: 123,
            swipes: [payload],
            reasoning: payload,
          ),
        ],
      ),
    );
    final metadata = (await repo.getAllSessionMetadata()).single;
    expect(metadata.lastMessageContent, 'New scene.');
    expect(metadata.lastMessageTimestamp, 123);
    expect(metadata.sessionName, 'Named');
    final watched = (await repo.watchAllSessionMetadata().first).single;
    expect(watched.lastMessageContent, metadata.lastMessageContent);
    expect(watched.sessionName, metadata.sessionName);
  });

  test(
    'legacy multimodal preview keeps only ordered string text parts',
    () async {
      await repo.put(
        const ChatSession(
          id: 'legacy',
          characterId: 'character',
          sessionIndex: 0,
        ),
      );
      await db.customStatement(
        '''UPDATE chat_sessions SET messages_json = ? WHERE session_id = ?''',
        [
          '[{"content":[{"type":"text","text":"First 🐈"},'
              '{"type":"image_url","image_url":{"url":"data:image/png;base64,x"}},'
              '"ignored",{"type":"text","text":12},'
              '{"type":"text","text":"Second"}],"timestamp":99}]',
          'legacy',
        ],
      );
      final metadata = (await repo.getAllSessionMetadata()).single;
      expect(metadata.lastMessageContent, 'First 🐈 Second');
      expect(metadata.lastMessageTimestamp, 99);
      expect(metadata.messageCount, 1);
    },
  );

  test('invalid optional session variables do not prevent listing', () async {
    await repo.put(
      const ChatSession(
        id: 'legacy',
        characterId: 'character',
        sessionIndex: 0,
      ),
    );
    for (final vars in [
      '',
      '{broken',
      '{"sessionName":42,"branchedAt":3000}',
    ]) {
      await db.customStatement(
        'UPDATE chat_sessions SET session_vars_json = ? WHERE session_id = ?',
        [vars, 'legacy'],
      );
      final metadata = (await repo.getAllSessionMetadata()).single;
      expect(metadata.sessionName, isNull);
      expect(metadata.originKind, isNull);
    }
  });

  test('cleaned sub-swipe keeps the Think reasoning when selected', () async {
    const thinking = '<thinking>Completed controller analysis</thinking>';
    await repo.put(
      const ChatSession(
        id: 'thinking-session',
        characterId: 'character',
        sessionIndex: 0,
        messages: [
          ChatMessage(
            id: 'assistant',
            role: 'assistant',
            content: 'Original reply',
            reasoning: thinking,
            agentSwipes: [
              AgentSwipe(
                content: 'Original reply',
                kind: 'final',
                reasoning: thinking,
              ),
            ],
          ),
        ],
      ),
    );

    expect(
      await repo.appendAgentSwipe(
        sessionId: 'thinking-session',
        messageId: 'assistant',
        content: 'Rewritten reply',
        kind: 'cleaned',
      ),
      isTrue,
    );
    final saved = (await repo.getById('thinking-session'))!.messages.single;
    expect(saved.agentSwipes.last.reasoning, thinking);
    expect(saved.swipesMeta.first['agentSwipes'], isNotNull);
  });

  test(
    'all-session metadata is projected without changing its values',
    () async {
      await repo.put(
        const ChatSession(
          id: 'session',
          characterId: 'character',
          sessionIndex: 3,
          updatedAt: 42,
          sessionVars: {'sessionName': 'Branch', 'branchedAt': '3000'},
          messages: [
            ChatMessage(
              id: 'first',
              role: 'user',
              content: 'First',
              timestamp: 1000,
            ),
            ChatMessage(
              id: 'last',
              role: 'assistant',
              content: 'Last',
              timestamp: 2000,
            ),
          ],
        ),
      );

      final metadata = (await repo.getAllSessionMetadata()).single;

      expect(metadata.sessionId, 'session');
      expect(metadata.characterId, 'character');
      expect(metadata.sessionIndex, 3);
      expect(metadata.updatedAt, 42);
      expect(metadata.messageCount, 2);
      expect(metadata.lastMessageContent, 'Last');
      expect(metadata.lastMessageTimestamp, 2000);
      expect(metadata.sessionName, 'Branch');
      expect(metadata.originTimestamp, 3000);
      expect(metadata.originKind, 'branched');
    },
  );

  // The chat-list row truncates from the front, so a message a Continue run
  // extended would keep previewing the opening the user already read
  // (INV-CM7). Both projections have to slice at the boundary — the
  // json_extract one behind getAllSessionMetadata and the string-scanning one
  // behind getMetadataByCharacterId — or the list goes stale on exactly the
  // messages that just changed.
  group('a continued message previews its continuation', () {
    const continued = ChatSession(
      id: 'session',
      characterId: 'character',
      sessionIndex: 0,
      updatedAt: 42,
      messages: [
        ChatMessage(id: 'u', role: 'user', content: 'Go on', timestamp: 1000),
        ChatMessage(
          id: 'a',
          role: 'assistant',
          content: 'The opening line.\n\nThe continuation.',
          continuationOffset: 19,
          timestamp: 2000,
        ),
      ],
    );

    test('in the json_extract projection', () async {
      await repo.put(continued);
      final metadata = (await repo.getAllSessionMetadata()).single;
      expect(metadata.lastMessageContent, 'The continuation.');
    });

    test('in the string-scanning projection', () async {
      await repo.put(continued);
      final metadata = await repo.getMetadataByCharacterId('character');
      expect(metadata.single.lastMessageContent, 'The continuation.');
    });

    test('a message that was never continued is previewed whole', () async {
      await repo.put(
        const ChatSession(
          id: 'plain',
          characterId: 'character',
          sessionIndex: 1,
          updatedAt: 42,
          messages: [
            ChatMessage(
              id: 'a',
              role: 'assistant',
              content: 'The opening line.\n\nThe continuation.',
              timestamp: 2000,
            ),
          ],
        ),
      );

      final metadata = (await repo.getAllSessionMetadata()).single;
      expect(
        metadata.lastMessageContent,
        'The opening line.\n\nThe continuation.',
      );
    });
  });
}
