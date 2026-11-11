import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_pack_builder.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';

void main() {
  late AppDatabase db;
  late MemoryConsolidationPackBuilder builder;
  late MemoryEventRegistryRepo registry;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    builder = MemoryConsolidationPackBuilder(db);
    registry = MemoryEventRegistryRepo(db);
  });

  tearDown(() => db.close());

  Future<void> seedBook(List<MemoryEntry> entries) async {
    final history = [
      for (final entry in entries)
        ChatMessage(
          id: entry.messageIds.single,
          role: 'assistant',
          content: 'Source for ${entry.id}',
          swipeId: 2,
          agentSwipeId: 3,
          time: '05.04.2026 · RP_Day 0 · 19:45',
        ),
    ];
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
            entriesJson: Value(
              jsonEncode(entries.map((entry) => entry.toJson()).toList()),
            ),
          ),
        );
  }

  MemoryEntry entry(
    String id, {
    String content = 'A verified memory.',
    List<String> keys = const [],
  }) {
    final messageId = 'message-$id';
    final sourceMessage = ChatMessage(
      id: messageId,
      role: 'assistant',
      content: 'Source for $id',
      swipeId: 2,
      agentSwipeId: 3,
      time: '05.04.2026 · RP_Day 0 · 19:45',
    );
    final manifest = MemorySourceManifest.capture(
      'session-1',
      [sourceMessage],
      [messageId],
    );
    final revision = MemoryEntryRevision(
      id: '$id:r1',
      version: 1,
      title: 'Memory $id',
      content: content,
      keys: keys,
      messageIds: [messageId],
      sourceManifest: manifest,
      createdAt: 1,
    );
    return MemoryEntry(
      id: id,
      title: revision.title,
      content: revision.content,
      keys: keys,
      messageIds: revision.messageIds,
      sourceSwipeId: 2,
      sourceAgentSwipeId: 3,
      sourceManifest: manifest,
      activeRevisionId: revision.id,
      revisions: [revision],
    );
  }

  MemoryEventSourceInput sourceFor(MemoryEntry value, String eventId) {
    final revision = value.revisions.single;
    return MemoryEventSourceInput(
      id: '$eventId-source',
      memoryEntryId: value.id,
      revisionId: revision.id,
      fingerprint: MemoryEventRegistryRepo.sourceFingerprint(
        revision,
        sourceSwipeId: value.sourceSwipeId,
        sourceAgentSwipeId: value.sourceAgentSwipeId,
      ),
      messageIds: revision.messageIds,
      sourceSwipeId: value.sourceSwipeId,
      sourceAgentSwipeId: value.sourceAgentSwipeId,
    );
  }

  Future<void> acceptOpenEvent(MemoryEntry value, String eventId) async {
    final source = sourceFor(value, eventId);
    expect(
      await registry.accept(
        event: MemoryEventInput(
          id: eventId,
          sessionId: 'session-1',
          branchId: 'session-1',
          kind: 'promise',
          description: 'Open obligation $eventId.',
          state: 'open',
          sources: [source],
        ),
        isCurrent: () => true,
      ),
      isTrue,
    );
  }

  Future<void> acceptCompletedEvent(MemoryEntry value, String eventId) async {
    final source = sourceFor(value, eventId);
    expect(
      await registry.accept(
        event: MemoryEventInput(
          id: eventId,
          sessionId: 'session-1',
          branchId: 'session-1',
          kind: 'result',
          description: 'Completed event $eventId.',
          state: 'completed',
          sources: [source],
        ),
        isCurrent: () => true,
      ),
      isTrue,
    );
  }

  Future<void> seedVector(MemoryEntry value, List<double> vector) async {
    await EmbeddingRepo(db).putEmbeddingVector(
      entryId: value.id,
      sourceType: 'memory_entry',
      sourceId: 'memorybook_character-1_session-1',
      vectors: [vector],
      textHash: 'hash-${value.id}',
    );
  }

  test(
    'builds a pack from requested memory and verified open obligations',
    () async {
      final requested = entry('requested');
      final obligation = entry('obligation');
      await seedBook([requested, obligation]);
      await acceptOpenEvent(obligation, 'event-open');

      final pack = await builder.build(
        sessionId: 'session-1',
        branchId: 'session-1',
        proposedEventId: 'event-new',
        memoryEntryIds: [requested.id],
      );

      expect(pack, isNotNull);
      expect(
        pack!.sources.map((source) => source.memoryEntryId),
        containsAll(<String>['requested', 'obligation']),
      );
      expect(pack.candidates.map((candidate) => candidate.id), ['event-open']);
      expect(pack.unexaminedOpenObligationIds, isEmpty);
      expect(pack.proposedEventId, 'event-new');
      expect(pack.sources.map((source) => source.sceneTime).toSet(), {
        '05.04.2026 · RP_Day 0 · 19:45',
      });
    },
  );

  test(
    'marks open obligations beyond the candidate bound as unexamined',
    () async {
      final requested = entry('requested');
      final first = entry('first');
      final second = entry('second');
      await seedBook([requested, first, second]);
      await acceptOpenEvent(first, 'event-first');
      await acceptOpenEvent(second, 'event-second');

      final pack = await builder.build(
        sessionId: 'session-1',
        branchId: 'session-1',
        proposedEventId: 'event-new',
        memoryEntryIds: [requested.id],
        maxCandidates: 1,
      );

      expect(pack, isNotNull);
      expect(pack!.candidates, hasLength(1));
      expect(
        pack.unexaminedOpenObligationIds,
        containsAll(
          <String>{'event-first', 'event-second'}.difference(
            pack.candidates.map((candidate) => candidate.id).toSet(),
          ),
        ),
      );
    },
  );

  test('reallocates a proposed ID that already belongs to an event', () async {
    final requested = entry('requested');
    final existing = entry('existing');
    await seedBook([requested, existing]);
    await acceptCompletedEvent(existing, 'event-new');

    final pack = await builder.build(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: [requested.id],
    );

    expect(pack, isNotNull);
    expect(pack!.proposedEventId, 'event-new-r1');
    expect(pack.proposedEventIds, ['event-new-r1']);
    expect(pack.candidates.map((candidate) => candidate.id), ['event-new']);
    expect(pack.toJson()['proposedEventAllocations'], [
      {'eventId': 'event-new-r1', 'sourceRef': 'entry:requested'},
    ]);
  });

  test('does not include an obligation whose source became stale', () async {
    final requested = entry('requested');
    final obligation = entry('obligation');
    await seedBook([requested, obligation]);
    await acceptOpenEvent(obligation, 'event-open');

    final invalidatedManifest = obligation.sourceManifest!.invalidate();
    final staleRevision = obligation.revisions.single.copyWith(
      sourceManifest: invalidatedManifest,
    );
    final stale = obligation.copyWith(
      sourceManifest: invalidatedManifest,
      revisions: [staleRevision],
    );
    await (db.update(
      db.memoryBookRows,
    )..where((row) => row.sessionId.equals('session-1'))).write(
      MemoryBookRowsCompanion(
        entriesJson: Value(
          jsonEncode([requested, stale].map((item) => item.toJson()).toList()),
        ),
      ),
    );

    final pack = await builder.build(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: [requested.id],
    );

    expect(pack, isNotNull);
    expect(pack!.candidates, isEmpty);
    expect(pack.unexaminedOpenObligationIds, ['event-open']);
  });

  test('rejects a requested source that exceeds the context budget', () async {
    await seedBook([entry('requested', content: '0123456789')]);

    await expectLater(
      builder.build(
        sessionId: 'session-1',
        branchId: 'session-1',
        proposedEventId: 'event-new',
        memoryEntryIds: ['requested'],
        maxContextCharacters: 5,
      ),
      throwsA(isA<MemoryConsolidationPackTooLargeException>()),
    );
  });

  test('participant overlap outranks unrelated open obligations', () async {
    final requested = entry('requested', keys: const ['Mira', 'brass key']);
    final obligation = entry('obligation');
    final participant = entry('participant', keys: const ['Mira']);
    await seedBook([requested, obligation, participant]);
    await acceptOpenEvent(obligation, 'event-open');
    await acceptCompletedEvent(participant, 'event-participant');

    final pack = await builder.build(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: [requested.id],
      maxCandidates: 1,
    );

    expect(pack, isNotNull);
    expect(pack!.candidates.map((candidate) => candidate.id), [
      'event-participant',
    ]);
    expect(pack.unexaminedOpenObligationIds, ['event-open']);
  });

  test('full-text overlap promotes an otherwise unrelated event', () async {
    final requested = entry('requested', keys: const ['brass key']);
    final textHit = entry(
      'text-hit',
      content: 'The brass key was polished and returned.',
    );
    final quiet = entry('quiet', content: 'A calm evening by the fire.');
    await seedBook([requested, textHit, quiet]);
    await acceptCompletedEvent(textHit, 'event-text-hit');
    await acceptCompletedEvent(quiet, 'event-quiet');

    final pack = await builder.build(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: [requested.id],
      maxCandidates: 1,
    );

    expect(pack, isNotNull);
    expect(pack!.candidates.map((candidate) => candidate.id), [
      'event-text-hit',
    ]);
  });

  test('vector similarity promotes events with close embeddings', () async {
    final requested = entry('requested', content: 'The key was returned.');
    final similar = entry('similar', content: 'The key came back to us.');
    final distant = entry('distant', content: 'A distant harvest report.');
    await seedBook([requested, similar, distant]);
    await seedVector(requested, [1.0, 0.0]);
    await seedVector(similar, [0.99, 0.14]);
    await seedVector(distant, [0.0, 1.0]);
    await acceptCompletedEvent(similar, 'event-similar');
    await acceptCompletedEvent(distant, 'event-distant');

    final pack = await builder.build(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: [requested.id],
      maxCandidates: 1,
    );

    expect(pack, isNotNull);
    expect(pack!.candidates.map((candidate) => candidate.id), [
      'event-similar',
    ]);
  });

  test(
    'events below the vector threshold remain low-priority candidates',
    () async {
      final requested = entry('requested', content: 'The key was returned.');
      final distant = entry('distant', content: 'A distant harvest report.');
      await seedBook([requested, distant]);
      await seedVector(requested, [1.0, 0.0]);
      await seedVector(distant, [0.0, 1.0]);
      await acceptCompletedEvent(distant, 'event-distant');

      final pack = await builder.build(
        sessionId: 'session-1',
        branchId: 'session-1',
        proposedEventId: 'event-new',
        memoryEntryIds: [requested.id],
        maxCandidates: 1,
      );

      expect(pack, isNotNull);
      expect(pack!.candidates.map((candidate) => candidate.id), [
        'event-distant',
      ]);
    },
  );
}
