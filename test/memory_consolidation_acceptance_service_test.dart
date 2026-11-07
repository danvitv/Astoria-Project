import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_pack_builder.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_consolidation.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_acceptance_service.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_coordinator.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_service.dart';

void main() {
  late AppDatabase db;
  late MemoryConsolidationPackBuilder builder;
  late MemoryEventRegistryRepo registry;
  late MemoryConsolidationAcceptanceService acceptance;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    builder = MemoryConsolidationPackBuilder(db);
    registry = MemoryEventRegistryRepo(db);
    acceptance = MemoryConsolidationAcceptanceService(registry);
  });

  tearDown(() => db.close());

  MemoryEntry entry(String id, String content) {
    final messageId = 'message-$id';
    final message = ChatMessage(
      id: messageId,
      role: 'assistant',
      content: content,
      swipeId: 1,
      agentSwipeId: 2,
    );
    final manifest = MemorySourceManifest.capture(
      'session-1',
      [message],
      [messageId],
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
      sourceSwipeId: 1,
      sourceAgentSwipeId: 2,
      sourceManifest: manifest,
      activeRevisionId: revision.id,
      revisions: [revision],
    );
  }

  Future<void> seed() async {
    final requested = entry('requested', 'The key was returned.');
    final obligation = entry('obligation', 'The key had been promised.');
    final history = [
      for (final item in [requested, obligation])
        ChatMessage(
          id: item.messageIds.single,
          role: 'assistant',
          content: item.content,
          swipeId: item.sourceSwipeId,
          agentSwipeId: item.sourceAgentSwipeId,
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
              jsonEncode(
                [requested, obligation].map((item) => item.toJson()).toList(),
              ),
            ),
          ),
        );
    final revision = obligation.revisions.single;
    final source = MemoryEventSourceInput(
      id: 'obligation-source',
      memoryEntryId: obligation.id,
      revisionId: revision.id,
      fingerprint: MemoryEventRegistryRepo.sourceFingerprint(
        revision,
        sourceSwipeId: obligation.sourceSwipeId,
        sourceAgentSwipeId: obligation.sourceAgentSwipeId,
      ),
      messageIds: revision.messageIds,
      sourceSwipeId: obligation.sourceSwipeId,
      sourceAgentSwipeId: obligation.sourceAgentSwipeId,
    );
    expect(
      await registry.accept(
        event: MemoryEventInput(
          id: 'event-open',
          sessionId: 'session-1',
          branchId: 'session-1',
          kind: 'promise',
          description: 'The key will be returned.',
          state: 'open',
          sources: [source],
        ),
        isCurrent: () => true,
      ),
      isTrue,
    );
  }

  Future<MemoryConsolidationSourcePack> buildPack() async {
    final pack = await builder.build(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: const ['requested'],
    );
    expect(pack, isNotNull);
    return pack!;
  }

  String responseFor(
    MemoryConsolidationSourcePack pack, {
    required String outcome,
    Object? event = const {
      'eventId': 'event-new',
      'kind': 'result',
      'description': 'The key was returned.',
      'state': 'completed',
      'sourceRefs': ['entry:requested'],
      'boundary': null,
    },
    List<Object?> links = const [
      {
        'linkId': 'link-new-open',
        'fromEventId': 'event-new',
        'toEventId': 'event-open',
        'relation': 'fulfills',
      },
    ],
  }) => jsonEncode({
    'contract': 'memory_event_consolidation',
    'version': 1,
    'outcome': outcome,
    'event': event,
    'links': links,
    'unverifiedSourceRefs': const <String>[],
    'unexaminedOpenObligationIds': pack.unexaminedOpenObligationIds,
  });

  test('accepts one event and its link transactionally', () async {
    await seed();
    final pack = await buildPack();

    final draft = acceptance.parseDraft(
      rawResponse: responseFor(pack, outcome: 'confirmed'),
      pack: pack,
    );
    final result = await acceptance.acceptReviewed(
      response: draft,
      pack: pack,
      isCurrent: () => true,
      acceptedBy: 'reviewer',
    );

    expect(result, isTrue);
    expect(
      (await registry.getActiveEvents(
        sessionId: 'session-1',
        branchId: 'session-1',
      )).map((row) => row.id),
      ['event-open', 'event-new'],
    );
    expect(
      (await registry.getActiveLinks(
        sessionId: 'session-1',
        branchId: 'session-1',
      )).single.relation,
      'fulfills',
    );
  });

  test('runs pack, model draft, and reviewed acceptance end to end', () async {
    await seed();
    final service = MemoryConsolidationService(
      call:
          ({
            required AuxApiConfig config,
            required List<Map<String, String>> messages,
            required int maxTokens,
            required double temperature,
            required int timeoutMs,
            CancelToken? cancelToken,
          }) async {
            expect(messages.last['content'], contains('The key was returned.'));
            return jsonEncode({
              'contract': 'memory_event_consolidation',
              'version': 1,
              'outcome': 'confirmed',
              'event': {
                'eventId': 'event-new',
                'kind': 'result',
                'description': 'The key was returned.',
                'state': 'completed',
                'sourceRefs': ['entry:requested'],
                'boundary': null,
              },
              'links': [
                {
                  'linkId': 'link-new-open',
                  'fromEventId': 'event-new',
                  'toEventId': 'event-open',
                  'relation': 'fulfills',
                },
              ],
              'unverifiedSourceRefs': const <String>[],
              'unexaminedOpenObligationIds': const <String>[],
            });
          },
    );
    final coordinator = MemoryConsolidationCoordinator(
      packBuilder: builder,
      service: service,
      acceptance: acceptance,
    );
    const config = AuxApiConfig(
      endpoint: 'https://example.invalid/v1/chat/completions',
      apiKey: 'test-only',
      model: 'test-model',
      protocol: 'custom_chat_completion',
    );

    final draft = await coordinator.generateDraft(
      sessionId: 'session-1',
      branchId: 'session-1',
      proposedEventId: 'event-new',
      memoryEntryIds: const ['requested'],
      config: config,
      maxTokens: 512,
      temperature: 0.1,
      timeoutMs: 30000,
      isCurrent: () => true,
    );
    expect(draft, isNotNull);
    expect(draft!.response.event?.eventId, 'event-new');

    expect(
      await coordinator.acceptReviewed(draft: draft, isCurrent: () => true),
      isTrue,
    );
    expect(
      (await registry.getActiveLinks(
        sessionId: 'session-1',
        branchId: 'session-1',
      )).single.relation,
      'fulfills',
    );
  });

  test('unable to verify does not write registry rows', () async {
    await seed();
    final pack = await buildPack();

    final draft = acceptance.parseDraft(
      rawResponse: responseFor(
        pack,
        outcome: 'unable_to_verify',
        event: null,
        links: const [],
      ),
      pack: pack,
    );

    expect(
      await acceptance.acceptReviewed(
        response: draft,
        pack: pack,
        isCurrent: () => true,
      ),
      isFalse,
    );
    expect(
      (await registry.getActiveEvents(
        sessionId: 'session-1',
        branchId: 'session-1',
      )).map((row) => row.id),
      ['event-open'],
    );
    expect(
      await registry.getActiveLinks(
        sessionId: 'session-1',
        branchId: 'session-1',
      ),
      isEmpty,
    );
  });

  test('stale acceptance fails before inserting the new event', () async {
    await seed();
    final pack = await buildPack();

    await expectLater(
      acceptance.acceptReviewed(
        response: acceptance.parseDraft(
          rawResponse: responseFor(pack, outcome: 'confirmed'),
          pack: pack,
        ),
        pack: pack,
        isCurrent: () => false,
      ),
      throwsStateError,
    );
    expect(
      (await registry.getActiveEvents(
        sessionId: 'session-1',
        branchId: 'session-1',
      )).map((row) => row.id),
      ['event-open'],
    );
  });
}
