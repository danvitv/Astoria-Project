import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/backup_export_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_message_storage_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_message_storage_sql.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  late AppDatabase db;
  late ChatRepo chats;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chats = ChatRepo(db);
  });

  tearDown(() async => db.close());

  test('insertIfAbsent creates an exact row-backed session', () async {
    final session = _session();

    expect(await chats.insertIfAbsent(session), isTrue);
    expect(await chats.insertIfAbsent(session), isFalse);

    final parent = await (db.select(
      db.chatSessions,
    )..where((table) => table.sessionId.equals(session.id))).getSingle();
    final state = await (db.select(
      db.chatMessageStorageRows,
    )..where((table) => table.sessionId.equals(session.id))).getSingle();
    final rows =
        await (db.select(db.chatMessageRows)
              ..where((table) => table.sessionId.equals(session.id))
              ..orderBy([(table) => OrderingTerm.asc(table.positionKey)]))
            .get();

    expect(parent.messagesJson, '[]');
    expect(state.messageCount, session.messages.length);
    expect(rows.map((row) => row.messageId), ['', '']);
    expect(rows.map((row) => row.positionKey), [1024, 2048]);
    expect(
      jsonEncode((await chats.getById(session.id))?.toJson()),
      jsonEncode(session.toJson()),
    );
  });

  test(
    'row-backed append edit and suffix delete retain unaffected rows',
    () async {
      final session = _session();
      await chats.insertIfAbsent(session);
      final before = await _rows(db, session.id);

      final appended = await chats.appendUserMessageAndClearDraft(
        sessionId: session.id,
        message: const ChatMessage(id: 'tail', role: 'user', content: 'tail'),
        updatedAt: 10,
      );
      expect(appended?.messages.length, 3);
      final afterAppend = await _rows(db, session.id);
      expect(
        afterAppend.take(2).map((row) => row.rowId),
        before.map((row) => row.rowId),
      );

      final edited = await chats.mutateMessage(
        sessionId: session.id,
        messageId: 'tail',
        updatedAt: 11,
        mutate: (message) => message.copyWith(content: 'edited'),
      );
      expect(edited?.messages.last.content, 'edited');
      final afterEdit = await _rows(db, session.id);
      expect(
        afterEdit.map((row) => row.rowId),
        afterAppend.map((row) => row.rowId),
      );

      final shortened = await chats.mutateMessages(
        sessionId: session.id,
        updatedAt: 12,
        mutate: (messages) => messages.sublist(0, 2),
      );
      expect(shortened?.messages.length, 2);
      final afterDelete = await _rows(db, session.id);
      expect(
        afterDelete.map((row) => row.rowId),
        before.map((row) => row.rowId),
      );
      expect(
        (await (db.select(db.chatSessions)
                  ..where((table) => table.sessionId.equals(session.id)))
                .getSingle())
            .messagesJson,
        '[]',
      );
    },
  );

  test(
    'generation commit appends through the row backend atomically',
    () async {
      await chats.insertIfAbsent(_session());
      final base = (await chats.getById('session'))!;
      final assistant = const ChatMessage(
        id: 'generated',
        role: 'assistant',
        content: 'generated',
        timestamp: 3000,
      );

      final committed = await chats.commitGenerationResult(
        baseSession: base,
        generatedSession: base.copyWith(
          messages: [...base.messages, assistant],
        ),
        regenTargetId: null,
      );

      expect(committed?.messages.last, assistant);
      expect((await _rows(db, 'session')).map((row) => row.messageId), [
        '',
        '',
        'generated',
      ]);
      expect(
        (await (db.select(
              db.chatSessions,
            )..where((table) => table.sessionId.equals('session'))).getSingle())
            .messagesJson,
        '[]',
      );
    },
  );

  test('metadata and draft count guards are backend neutral', () async {
    final rowSession = _session(id: 'row');
    final legacySession = _session(id: 'legacy');
    await chats.insertIfAbsent(rowSession);
    await chats.put(legacySession);

    final metadata = await chats.getAllSessionMetadata();
    for (final item in metadata) {
      expect(item.messageCount, 2);
      expect(item.lastMessageContent, 'second');
      expect(item.lastMessageTimestamp, 2000);
      expect(item.originTimestamp, 1000);
    }

    expect(
      await chats.updateDraftIfMessageCount(
        sessionId: rowSession.id,
        draft: 'kept',
        expectedMessageCount: 2,
      ),
      'kept',
    );
    expect(
      await chats.updateDraftIfMessageCount(
        sessionId: rowSession.id,
        draft: 'rejected',
        expectedMessageCount: 1,
      ),
      isNull,
    );
    expect((await chats.getById(rowSession.id))?.draft, 'kept');
  });

  test(
    'backup projection materializes rows into the legacy chat payload',
    () async {
      final session = _session();
      await chats.insertIfAbsent(session);

      final pages = await BackupExportRepo(db).pages('chat_sessions').toList();
      final exported = pages.expand((page) => page).single;
      final messages = jsonDecode(exported['messages_json'] as String) as List;

      expect(messages.length, session.messages.length);
      expect(messages.first['content'], 'first');
      expect(messages.last['studioOutputs'], isNotEmpty);
      expect(exported.keys, isNot(contains('export_messages_json')));
    },
  );

  test(
    'compatibility SQL projection exposes the active row generation',
    () async {
      final session = _session();
      await chats.insertIfAbsent(session);

      final row = await db
          .customSelect(
            '''
       WITH ${ChatMessageStorageSql.targetPayloadCte('?')}
       SELECT messages_json FROM chat_message_payloads
    ''',
            variables: [Variable.withString(session.id)],
          )
          .getSingle();
      final messages = jsonDecode(row.read<String>('messages_json')) as List;

      expect(messages.map((message) => message['content']), [
        'first',
        'second',
      ]);
      expect(messages.last['agentSwipes'], isNotEmpty);

      final metadata = await db
          .customSelect(
            '''
            WITH ${ChatMessageStorageSql.metadataCte}
            SELECT integrity_ok, message_count, first_timestamp, last_timestamp
            FROM chat_message_payloads WHERE session_id = ?
            ''',
            variables: [Variable.withString(session.id)],
          )
          .getSingle();
      expect(metadata.read<int>('integrity_ok'), 1);
      expect(metadata.read<int>('message_count'), 2);
      expect(metadata.read<int>('first_timestamp'), 1000);
      expect(metadata.read<int>('last_timestamp'), 2000);
    },
  );

  test('backend-neutral reads and SQL projections reject damaged rows', () async {
    final session = _session();
    await chats.insertIfAbsent(session);
    final storage = ChatMessageStorageRepo(db);

    expect(
      (await storage.loadMessagesBySessionId(session.id))!
          .map((message) => message.content),
      ['first', 'second'],
    );
    await (db.update(db.chatMessageRows)
          ..where((row) => row.sessionId.equals(session.id))
          ..where((row) => row.positionKey.equals(2048)))
        .write(const ChatMessageRowsCompanion(role: Value('system')));

    await expectLater(
      storage.loadMessagesBySessionId(session.id),
      throwsA(isA<StateError>()),
    );
    final projected = await db
        .customSelect(
          '''
          WITH ${ChatMessageStorageSql.targetPayloadCte('?')}
          SELECT integrity_ok, messages_json FROM chat_message_payloads
          ''',
          variables: [Variable.withString(session.id)],
        )
        .getSingle();
    expect(projected.read<int>('integrity_ok'), 0);
    expect(projected.readNullable<String>('messages_json'), isNull);
  });
}

ChatSession _session({String id = 'session'}) => ChatSession(
  id: id,
  characterId: 'character',
  sessionIndex: 0,
  updatedAt: 1,
  messages: const [
    ChatMessage(
      id: '',
      role: 'user',
      content: 'first',
      timestamp: 1000,
      extraImagePaths: ['/two.png'],
      contextRefs: ['memory'],
    ),
    ChatMessage(
      id: '',
      role: 'assistant',
      content: 'second',
      timestamp: 2000,
      swipes: ['draft', 'second'],
      swipeId: 1,
      studioOutputs: [
        {'agent': 'writer', 'content': 'kept'},
      ],
      agentSwipes: [AgentSwipe(content: 'second', kind: 'final')],
    ),
  ],
);

Future<List<ChatMessageRow>> _rows(AppDatabase db, String sessionId) =>
    (db.select(db.chatMessageRows)
          ..where((table) => table.sessionId.equals(sessionId))
          ..orderBy([(table) => OrderingTerm.asc(table.positionKey)]))
        .get();
