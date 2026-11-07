import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_prompt_annotation_loader.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';

void main() {
  late AppDatabase db;
  late MemoryEventRegistryRepo registry;
  late MemoryEventPromptAnnotationLoader loader;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    registry = MemoryEventRegistryRepo(db);
    loader = MemoryEventPromptAnnotationLoader(db);
  });

  tearDown(() => db.close());

  Future<(MemoryEntry, List<ChatMessage>)> seed() async {
    final history = [
      const ChatMessage(
        id: 'message-1',
        role: 'assistant',
        content: 'We agreed to return the key.',
        swipeId: 2,
        agentSwipeId: 3,
      ),
    ];
    final manifest = MemorySourceManifest.capture('session-1', history, const [
      'message-1',
    ]);
    final revision = MemoryEntryRevision(
      id: 'memory-1:r1',
      version: 1,
      title: 'Key agreement',
      content: 'The key will be returned tomorrow.',
      messageIds: const ['message-1'],
      sourceManifest: manifest,
      createdAt: 1,
    );
    final entry = MemoryEntry(
      id: 'memory-1',
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
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: 'session-1',
            characterId: 'character-1',
            sessionIndex: 0,
            messagesJson: jsonEncode(
              history.map((item) => item.toJson()).toList(),
            ),
          ),
        );
    await db
        .into(db.memoryBookRows)
        .insert(
          MemoryBookRowsCompanion.insert(
            sessionId: 'session-1',
            entriesJson: Value(jsonEncode([entry.toJson()])),
          ),
        );
    return (entry, history);
  }

  MemoryEventSourceInput source(MemoryEntry entry, String id) {
    final revision = entry.revisions.single;
    return MemoryEventSourceInput(
      id: '$id-source',
      memoryEntryId: entry.id,
      revisionId: revision.id,
      fingerprint: MemoryEventRegistryRepo.sourceFingerprint(
        revision,
        sourceSwipeId: entry.sourceSwipeId,
        sourceAgentSwipeId: entry.sourceAgentSwipeId,
      ),
      messageIds: revision.messageIds,
      sourceSwipeId: entry.sourceSwipeId,
      sourceAgentSwipeId: entry.sourceAgentSwipeId,
    );
  }

  Future<void> acceptLinkedEvents(MemoryEntry entry) async {
    final firstSource = source(entry, 'event-old');
    expect(
      await registry.accept(
        event: MemoryEventInput(
          id: 'event-old',
          sessionId: 'session-1',
          branchId: 'session-1',
          kind: 'promise',
          description: 'Return the key.',
          state: 'open',
          sources: [firstSource],
        ),
        isCurrent: () => true,
      ),
      isTrue,
    );
    final secondSource = source(entry, 'event-new');
    expect(
      await registry.accept(
        event: MemoryEventInput(
          id: 'event-new',
          sessionId: 'session-1',
          branchId: 'session-1',
          kind: 'result',
          description: 'The key was returned.',
          state: 'completed',
          sources: [secondSource],
        ),
        links: const [
          MemoryEventLinkInput(
            id: 'link-1',
            fromEventId: 'event-new',
            toEventId: 'event-old',
            relation: 'fulfills',
          ),
        ],
        isCurrent: () => true,
      ),
      isTrue,
    );
  }

  test('loads only linked events with exact live source provenance', () async {
    final (entry, history) = await seed();
    await acceptLinkedEvents(entry);

    final annotations = await loader.load(
      sessionId: 'session-1',
      branchId: 'session-1',
      entries: [entry],
      history: history,
    );

    expect(annotations.keys, ['memory-1']);
    expect(annotations['memory-1'], hasLength(2));
    expect(annotations['memory-1']!.map((item) => item.eventId), [
      'event-new',
      'event-old',
    ]);
    expect(
      annotations['memory-1']!.every((item) => item.relation == 'fulfills'),
      isTrue,
    );
  });

  test('does not load an event after its source swipe becomes stale', () async {
    final (entry, history) = await seed();
    await acceptLinkedEvents(entry);
    final staleHistory = [history.single.copyWith(swipeId: 4)];

    final annotations = await loader.load(
      sessionId: 'session-1',
      branchId: 'session-1',
      entries: [entry],
      history: staleHistory,
    );

    expect(annotations, isEmpty);
  });

  test('does not annotate a stale in-memory selection snapshot', () async {
    final (entry, history) = await seed();
    await acceptLinkedEvents(entry);
    final staleSelection = entry.copyWith(content: 'A prior revision.');

    final annotations = await loader.load(
      sessionId: 'session-1',
      branchId: 'session-1',
      entries: [staleSelection],
      history: history,
    );

    expect(annotations, isEmpty);
  });

  test(
    'does not follow a link to an event with stale source evidence',
    () async {
      final (entry, history) = await seed();
      await acceptLinkedEvents(entry);
      await (db.update(
        db.memoryEventSourceRows,
      )..where((row) => row.id.equals('event-old-source'))).write(
        const MemoryEventSourceRowsCompanion(fingerprint: Value('stale')),
      );

      final annotations = await loader.load(
        sessionId: 'session-1',
        branchId: 'session-1',
        entries: [entry],
        history: history,
      );

      expect(annotations, isEmpty);
      final invalidations = await db
          .select(db.memoryEventInvalidationRows)
          .get();
      expect(
        invalidations
            .where((row) => row.targetType == 'event')
            .map((row) => row.targetId),
        contains('event-old'),
      );
      expect(
        invalidations
            .where((row) => row.targetType == 'event')
            .map((row) => row.targetId),
        isNot(contains('event-new')),
      );
      expect(
        invalidations
            .where((row) => row.targetType == 'link')
            .map((row) => row.targetId),
        contains('link-1'),
      );
    },
  );

  test('keeps stale-event invalidation append-only and idempotent', () async {
    final (entry, history) = await seed();
    await acceptLinkedEvents(entry);
    final staleHistory = [history.single.copyWith(swipeId: 4)];

    for (var i = 0; i < 2; i++) {
      await loader.load(
        sessionId: 'session-1',
        branchId: 'session-1',
        entries: [entry],
        history: staleHistory,
      );
    }

    final invalidations = await db.select(db.memoryEventInvalidationRows).get();
    expect(invalidations, hasLength(3));
    expect(
      (await db.select(db.memoryEventRows).get()).every(
        (row) => row.status == 'active',
      ),
      isTrue,
    );
    expect(
      (await db.select(db.memoryEventLinkRows).get()).every(
        (row) => row.status == 'active',
      ),
      isTrue,
    );
  });
}
