import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/models/memory_consolidation.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_service.dart';

void main() {
  final source = MemoryConsolidationSource(
    ref: 'source-1',
    sessionId: 'session-1',
    branchId: 'session-1',
    memoryEntryId: 'entry-1',
    revisionId: 'entry-1:r1',
    fingerprint: 'a' * 64,
    title: 'Return promise',
    content: 'The key was promised and later returned.',
    messageIds: const ['message-1'],
    sceneTime: '13.04.2026 · RP_Day 3 · 16:38',
    sourceSwipeId: 1,
    sourceAgentSwipeId: 2,
    sourceManifest: MemorySourceManifest(
      originSessionId: 'session-1',
      messages: const [
        MemorySourceStamp(
          messageId: 'message-1',
          swipeId: 1,
          agentSwipeId: 2,
          contentHash: 'content-hash',
        ),
      ],
    ),
  );

  final pack = MemoryConsolidationSourcePack(
    packId: 'pack-1',
    sessionId: 'session-1',
    branchId: 'session-1',
    proposedEventId: 'event-new',
    sources: [source],
    candidates: const [],
    unexaminedOpenObligationIds: const [],
  );

  const config = AuxApiConfig(
    endpoint: 'https://example.invalid/v1/chat/completions',
    apiKey: 'test-key',
    model: 'test-model',
    protocol: 'custom_chat_completion',
  );

  test('package prompt fences scene-scoped conditions in story time', () {
    final messages = MemoryConsolidationService.buildPackageMessages(
      pack,
      gameTime: const GameTimeState(time: '17:52', date: '23.04.2026', day: 13),
    );

    expect(
      messages.first['content'],
      contains('Current story point: day 13 | 23.04.2026 | 17:52'),
    );
    expect(messages.first['content'], contains('scene-scoped condition'));
    expect(messages.first['content'], contains('similarity alone is not'));
    expect(messages.last['content'], contains('13.04.2026 · RP_Day 3 · 16:38'));
  });

  String validResponse() => '''{
    "contract":"memory_event_consolidation",
    "version":1,
    "outcome":"confirmed",
    "event": {
      "eventId":"event-new",
      "kind":"result",
      "description":"The key was returned.",
      "state":"completed",
      "sourceRefs":["source-1"],
      "boundary":null
    },
    "links":[],
    "unverifiedSourceRefs":[],
    "unexaminedOpenObligationIds":[]
  }''';

  test('sends the complete pack through the injected LLM boundary', () async {
    List<Map<String, String>>? sentMessages;
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
            sentMessages = messages;
            expect(config.model, 'test-model');
            expect(maxTokens, 512);
            expect(temperature, 0.1);
            expect(timeoutMs, 30000);
            return validResponse();
          },
    );

    final result = await service.generateDraft(
      pack: pack,
      config: config,
      maxTokens: 512,
      temperature: 0.1,
      timeoutMs: 30000,
      isCurrent: () => true,
    );

    expect(result.event?.eventId, 'event-new');
    expect(sentMessages, hasLength(2));
    expect(sentMessages!.first['role'], 'system');
    expect(sentMessages!.first['content'], contains('untrusted data'));
    expect(sentMessages!.last['content'], contains('The key was promised'));
    expect(sentMessages!.last['content'], contains('entry-1:r1'));
  });

  test('rejects a late response after current state changes', () async {
    var current = true;
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
            current = false;
            return validResponse();
          },
    );

    await expectLater(
      service.generateDraft(
        pack: pack,
        config: config,
        maxTokens: 512,
        temperature: 0.1,
        timeoutMs: 30000,
        isCurrent: () => current,
      ),
      throwsStateError,
    );
  });

  test('rejects invalid request bounds before calling transport', () async {
    var called = false;
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
            called = true;
            return validResponse();
          },
    );

    await expectLater(
      service.generateDraft(
        pack: pack,
        config: config,
        maxTokens: 0,
        temperature: 0.1,
        timeoutMs: 30000,
        isCurrent: () => true,
      ),
      throwsArgumentError,
    );
    expect(called, isFalse);
  });
}
