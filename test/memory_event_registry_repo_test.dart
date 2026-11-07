import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_deletion_queries.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';

void main() {
  late AppDatabase db;
  late MemoryEventRegistryRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = MemoryEventRegistryRepo(db);
  });

  tearDown(() => db.close());

  Future<MemoryEventSourceInput> seedSessionAndMemory() async {
    const message = ChatMessage(
      id: 'message-1',
      role: 'assistant',
      content: 'Mira agreed to return the key tomorrow.',
      swipeId: 2,
      agentSwipeId: 3,
    );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: 'session-1',
            characterId: 'character-1',
            sessionIndex: 0,
            messagesJson: jsonEncode([message.toJson()]),
          ),
        );
    final manifest = MemorySourceManifest.capture(
      'session-1',
      const [message],
      const ['message-1'],
    );
    final revision = MemoryEntryRevision(
      id: 'entry-1:r1',
      version: 1,
      title: 'Agreed to return',
      content: 'Mira agreed to return the key tomorrow.',
      messageIds: ['message-1'],
      sourceManifest: manifest,
      createdAt: 1,
    );
    final entry = MemoryEntry(
      id: 'entry-1',
      title: revision.title,
      content: revision.content,
      messageIds: revision.messageIds,
      sourceSwipeId: 2,
      sourceAgentSwipeId: 3,
      sourceManifest: manifest,
      activeRevisionId: revision.id,
      revisions: [revision],
    );
    await db
        .into(db.memoryBookRows)
        .insert(
          MemoryBookRowsCompanion.insert(
            sessionId: 'session-1',
            entriesJson: Value(jsonEncode([entry.toJson()])),
          ),
        );
    return MemoryEventSourceInput(
      id: 'source-1',
      memoryEntryId: entry.id,
      revisionId: revision.id,
      fingerprint: MemoryEventRegistryRepo.sourceFingerprint(
        revision,
        sourceSwipeId: 2,
        sourceAgentSwipeId: 3,
      ),
      messageIds: revision.messageIds,
      sourceSwipeId: 2,
      sourceAgentSwipeId: 3,
    );
  }

  MemoryEventInput event(
    MemoryEventSourceInput source, {
    String id = 'event-1',
  }) => MemoryEventInput(
    id: id,
    sessionId: 'session-1',
    branchId: 'session-1',
    kind: 'promise',
    description: 'Mira will return the key tomorrow.',
    state: 'open',
    sources: [source],
  );

  test(
    'accepts exact active source and reads it back branch-locally',
    () async {
      final source = await seedSessionAndMemory();

      expect(
        await repo.accept(event: event(source), isCurrent: () => true),
        isTrue,
      );
      expect(
        (await repo.getActiveEvents(
          sessionId: 'session-1',
          branchId: 'session-1',
        )).map((row) => row.id),
        ['event-1'],
      );
      expect(
        (await db.select(db.memoryEventSourceRows).get()).single.fingerprint,
        source.fingerprint,
      );
    },
  );

  test('rejects stale fingerprint and does not write partial rows', () async {
    final source = await seedSessionAndMemory();
    final stale = MemoryEventSourceInput(
      id: source.id,
      memoryEntryId: source.memoryEntryId,
      revisionId: source.revisionId,
      fingerprint: sha256.convert(utf8.encode('stale')).toString(),
      messageIds: source.messageIds,
      sourceSwipeId: source.sourceSwipeId,
      sourceAgentSwipeId: source.sourceAgentSwipeId,
    );

    expect(
      await repo.accept(event: event(stale), isCurrent: () => true),
      isFalse,
    );
    expect(await db.select(db.memoryEventRows).get(), isEmpty);
    expect(await db.select(db.memoryEventSourceRows).get(), isEmpty);
  });

  test('rejects a relation that does not touch the new event', () async {
    final source = await seedSessionAndMemory();
    final invalidLink = MemoryEventLinkInput(
      id: 'link-1',
      fromEventId: 'unrelated-1',
      toEventId: 'unrelated-2',
      relation: 'continues',
    );

    await expectLater(
      repo.accept(
        event: event(source),
        links: [invalidLink],
        isCurrent: () => true,
      ),
      throwsArgumentError,
    );
    expect(await db.select(db.memoryEventRows).get(), isEmpty);
  });

  test('rejects linking to an active event without verified sources', () async {
    final source = await seedSessionAndMemory();
    expect(
      await repo.accept(
        event: event(source, id: 'event-old'),
        isCurrent: () => true,
      ),
      isTrue,
    );
    await (db.delete(
      db.memoryEventSourceRows,
    )..where((row) => row.eventId.equals('event-old'))).go();

    final newSource = MemoryEventSourceInput(
      id: 'source-new',
      memoryEntryId: source.memoryEntryId,
      revisionId: source.revisionId,
      fingerprint: source.fingerprint,
      messageIds: source.messageIds,
      sourceSwipeId: source.sourceSwipeId,
      sourceAgentSwipeId: source.sourceAgentSwipeId,
    );
    final accepted = await repo.accept(
      event: event(newSource, id: 'event-new'),
      links: const [
        MemoryEventLinkInput(
          id: 'link-new',
          fromEventId: 'event-new',
          toEventId: 'event-old',
          relation: 'continues',
        ),
      ],
      isCurrent: () => true,
    );

    expect(accepted, isFalse);
    expect(
      await (db.select(
        db.memoryEventRows,
      )..where((row) => row.id.equals('event-new'))).get(),
      isEmpty,
    );
    expect(await db.select(db.memoryEventLinkRows).get(), isEmpty);
  });

  test(
    'session cleanup removes registry rows with child-first ordering',
    () async {
      final source = await seedSessionAndMemory();
      expect(
        await repo.accept(event: event(source), isCurrent: () => true),
        isTrue,
      );

      await SessionDeletionQueries(db).deleteMessageDerivedRows(
        sessionId: 'session-1',
        characterId: 'character-1',
        preserveMemoryBookSettings: false,
      );

      expect(await db.select(db.memoryEventRows).get(), isEmpty);
      expect(await db.select(db.memoryEventSourceRows).get(), isEmpty);
      expect(await db.select(db.memoryEventLinkRows).get(), isEmpty);
    },
  );
}
