import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_pack_builder.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
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
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: 'session-1',
            characterId: 'character-1',
            sessionIndex: 0,
            messagesJson: '[]',
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

  MemoryEntry entry(String id, {String content = 'A verified memory.'}) {
    final messageId = 'message-$id';
    final manifest = MemorySourceManifest(
      originSessionId: 'session-1',
      messages: [
        MemorySourceStamp(
          messageId: messageId,
          swipeId: 2,
          agentSwipeId: 3,
          contentHash: 'hash-$id',
        ),
      ],
    );
    final revision = MemoryEntryRevision(
      id: '$id:r1',
      version: 1,
      title: 'Memory $id',
      content: content,
      messageIds: [messageId],
      sourceManifest: manifest,
      createdAt: 1,
    );
    return MemoryEntry(
      id: id,
      title: revision.title,
      content: revision.content,
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

    final pack = await builder.build(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: ['requested'],
      maxContextCharacters: 5,
    );

    expect(pack, isNull);
  });
}
