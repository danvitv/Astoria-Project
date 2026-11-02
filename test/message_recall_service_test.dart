import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/message_recall_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

class _FakeEmbeddingService extends EmbeddingService {
  List<String> lastTexts = const [];
  Object? error;
  Future<void> Function()? beforeResponse;
  List<EmbeddingChunk> response = const [
    EmbeddingChunk(text: 'query', vector: [1, 0]),
  ];

  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    lastTexts = texts;
    await beforeResponse?.call();
    if (error != null) throw error!;
    return response;
  }
}

void main() {
  group('MessageRecallService', () {
    late AppDatabase db;
    late EmbeddingRepo repo;
    late MessageRecallService service;
    late _FakeEmbeddingService embedder;

    setUp(() {
      db = AppDatabase.forTesting(NativeDatabase.memory());
      repo = EmbeddingRepo(db);
      embedder = _FakeEmbeddingService();
      service = MessageRecallService(repo, embedder);
    });

    tearDown(() async {
      await db.close();
    });

    Future<void> putChunk({
      required String entryId,
      String sourceType = 'chat_message',
      String sourceId = 's1',
      required List<String> messageIds,
      required String text,
      required List<double> vector,
      String? indexedGroupText,
    }) {
      return repo.putEmbeddingVector(
        entryId: entryId,
        sourceType: sourceType,
        sourceId: sourceId,
        vectors: [vector],
        textHash: computeHash(indexedGroupText ?? text),
        retrievalMetadata: {
          'messageIds': messageIds,
          'chunks': [
            {'index': 0, 'text': text},
          ],
        },
      );
    }

    test('excludes chunks overlapping visible message ids', () async {
      await putChunk(
        entryId: 'visible',
        messageIds: ['m10'],
        text: 'visible chunk',
        vector: [1, 0],
      );
      await putChunk(
        entryId: 'older',
        messageIds: ['m1'],
        text: 'older chunk',
        vector: [0.9, 0.1],
      );

      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
        visibleMessageIds: {'m10'},
        threshold: 0,
      );

      expect(result.matches.map((m) => m.entryId), ['older']);
    });

    test('keeps non-overlapping chunks', () async {
      await putChunk(
        entryId: 'older',
        messageIds: ['m1'],
        text: 'older chunk',
        vector: [1, 0],
      );

      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
        visibleMessageIds: {'m10'},
        threshold: 0,
      );

      expect(result.matches.single.entryId, 'older');
      expect(result.matches.single.messageIds, ['m1']);
    });

    test(
      'rejects future sources and obsolete selected content before recall',
      () async {
        for (final id in ['old', 'changed', 'future']) {
          await putChunk(
            entryId: id,
            messageIds: [id],
            text: 'assistant: $id',
            vector: [1, 0],
          );
        }
        final result = await service.recall(
          sessionId: 's1',
          currentText: 'query',
          config: const EmbeddingConfig(endpoint: 'test'),
          allowedSourceMessageIds: {'old', 'changed'},
          sourceMessages: const {
            'old': ChatMessage(id: 'old', role: 'assistant', content: 'old'),
            'changed': ChatMessage(
              id: 'changed',
              role: 'assistant',
              content: 'selected replacement',
              swipes: ['changed', 'selected replacement'],
              swipeId: 1,
            ),
            'future': ChatMessage(
              id: 'future',
              role: 'assistant',
              content: 'future',
            ),
          },
        );
        expect(result.matches.map((match) => match.entryId), ['old']);
      },
    );

    test('isolates recall rows by source type and session', () async {
      await putChunk(
        entryId: 'current-session',
        messageIds: ['m1'],
        text: 'current session chunk',
        vector: [1, 0],
      );
      await putChunk(
        entryId: 'other-session',
        sourceId: 's2',
        messageIds: ['m2'],
        text: 'other session chunk',
        vector: [1, 0],
      );
      await putChunk(
        entryId: 'other-source',
        sourceType: 'memory_entry',
        messageIds: ['m3'],
        text: 'other source chunk',
        vector: [1, 0],
      );

      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
        threshold: 0,
      );

      expect(result.matches.map((match) => match.entryId), ['current-session']);
    });

    test(
      'query embeds bounded history and preserves user correction',
      () async {
        await putChunk(
          entryId: 'old',
          messageIds: ['old'],
          text: 'old report',
          vector: [1, 0],
        );
        const history = [
          ChatMessage(
            id: 'u1',
            role: 'user',
            content: '[OOC: Report was disputed.]',
          ),
          ChatMessage(
            id: 'a1',
            role: 'assistant',
            content:
                '<lumiaooc>Tomorrow all women will agree.</lumiaooc>'
                'She put the report beside the coffee.',
          ),
          ChatMessage(id: 'u2', role: 'user', content: 'I take a sip.'),
        ];
        final result = await service.recall(
          sessionId: 's1',
          currentText: 'I take a sip.',
          recentHistory: history,
          config: const EmbeddingConfig(endpoint: 'test'),
        );
        expect(embedder.lastTexts.single, result.query);
        expect(result.query, contains('Report was disputed'));
        expect(result.query, contains('report beside the coffee'));
        expect(result.query, isNot(contains('all women')));
        expect(result.toJson()['reason'], 'success');
        expect((result.toJson()['selected'] as List).single['sourceIds'], [
          'old',
        ]);
      },
    );

    test(
      'recovers role and original offsets for valid old partial evidence',
      () async {
        const messages = [
          ChatMessage(
            id: 'u1',
            role: 'user',
            content: 'The report is disputed.',
          ),
          ChatMessage(
            id: 'a1',
            role: 'assistant',
            content: 'She refuses to sign it.',
          ),
        ];
        final groupText = ChatMessageEmbeddingService.formatChunk(messages);
        const text = 'report is disputed.\n\nassistant: She refuses';
        await putChunk(
          entryId: 'group',
          messageIds: ['u1', 'a1'],
          text: text,
          indexedGroupText: groupText,
          vector: [1, 0],
        );
        final result = await service.recall(
          sessionId: 's1',
          currentText: 'report',
          config: const EmbeddingConfig(endpoint: 'test'),
          sourceMessages: {for (final message in messages) message.id: message},
        );
        final match = result.matches.single;
        expect(match.rawText, text);
        expect(match.text, endsWith(text));
        expect(match.sourceSpans.map((span) => span.role), [
          'user',
          'assistant',
        ]);
        for (final span in match.sourceSpans) {
          final original = messages.firstWhere(
            (message) => message.id == span.messageId,
          );
          expect(
            original.content.substring(span.sourceStart, span.sourceEnd),
            text.substring(span.excerptStart, span.excerptEnd),
          );
        }
        expect(match.toJson()['attribution'], 'exact_source_offsets');
      },
    );

    test('requires every source allowed, available and visible', () async {
      const sources = {
        'old': ChatMessage(id: 'old', role: 'user', content: 'old'),
        'hidden': ChatMessage(
          id: 'hidden',
          role: 'assistant',
          content: 'hidden',
          isHidden: true,
        ),
        'typing': ChatMessage(
          id: 'typing',
          role: 'assistant',
          content: 'typing',
          isTyping: true,
        ),
        'error': ChatMessage(
          id: 'error',
          role: 'assistant',
          content: 'error',
          isError: true,
        ),
      };
      for (final other in ['future', 'missing', 'hidden', 'typing', 'error']) {
        await putChunk(
          entryId: other,
          messageIds: ['old', other],
          text: 'user: old\n\nassistant: $other',
          vector: [1, 0],
        );
      }
      final result = await service.recall(
        sessionId: 's1',
        currentText: 'old',
        config: const EmbeddingConfig(endpoint: 'test'),
        allowedSourceMessageIds: {
          'old',
          'missing',
          'hidden',
          'typing',
          'error',
        },
        sourceMessages: sources,
      );
      expect(result.reason, MessageRecallReason.noUsableCandidates);
      expect(result.counters['sourceRejected'], 5);
      expect(embedder.lastTexts, isEmpty);
    });

    test('rejects metadata text not present in hash-verified group', () async {
      await putChunk(
        entryId: 'bad-text',
        messageIds: ['old'],
        text: 'invented excerpt',
        indexedGroupText: 'user: old',
        vector: [1, 0],
      );
      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
        sourceMessages: const {
          'old': ChatMessage(id: 'old', role: 'user', content: 'old'),
        },
      );
      expect(result.reason, MessageRecallReason.noUsableCandidates);
      expect(result.counters['invalidText'], 1);
    });

    test('oversized first candidate does not hide smaller evidence', () async {
      await putChunk(
        entryId: 'large',
        messageIds: ['large'],
        text: 'x' * 7000,
        vector: [1, 0],
      );
      await putChunk(
        entryId: 'small',
        messageIds: ['small'],
        text: 'disputed report',
        vector: [0.9, 0.1],
      );
      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
      );
      expect(result.matches.single.entryId, 'small');
      expect(result.counters['oversized'], 1);
      expect(result.counters['selectedChars'], lessThanOrEqualTo(6000));
    });

    test(
      'empty index, API error, embedding empty and timeout differ',
      () async {
        Future<MessageRecallResult> recall() => service.recall(
          sessionId: 's1',
          currentText: 'query',
          config: const EmbeddingConfig(endpoint: 'test'),
        );
        expect((await recall()).reason, MessageRecallReason.emptyIndex);
        await putChunk(
          entryId: 'old',
          messageIds: ['old'],
          text: 'old',
          vector: [1, 0],
        );
        embedder.error = StateError(
          'endpoint / key must never appear in diagnostics',
        );
        final failed = await recall();
        expect(failed.reason, MessageRecallReason.error);
        expect(failed.toJson().toString(), isNot(contains('key must never')));
        embedder.error = TimeoutException('not logged');
        expect((await recall()).reason, MessageRecallReason.timeout);
        embedder.error = null;
        embedder.response = const [];
        expect((await recall()).reason, MessageRecallReason.embeddingEmpty);
      },
    );

    test('failed index rows are distinct from an empty index', () async {
      await repo.putEmbeddingError(
        entryId: 'failed',
        sourceType: 'chat_message',
        sourceId: 's1',
        textHash: computeHash('old'),
        error: const {'type': 'api_error', 'message': 'never log this'},
        retrievalMetadata: const {
          'messageIds': ['old'],
        },
      );
      final result = await service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
      );
      expect(result.reason, MessageRecallReason.noUsableCandidates);
      expect(result.counters['rows'], 1);
      expect(result.counters['indexErrors'], 1);
      expect(result.counters['unusableVectors'], 1);
      expect(result.toJson().toString(), isNot(contains('never log this')));
    });

    test('dimension mismatch and below-threshold are explicit', () async {
      await putChunk(
        entryId: 'old',
        messageIds: ['old'],
        text: 'old',
        vector: [1, 0, 0],
      );
      Future<MessageRecallResult> recall() => service.recall(
        sessionId: 's1',
        currentText: 'query',
        config: const EmbeddingConfig(endpoint: 'test'),
      );
      expect((await recall()).reason, MessageRecallReason.dimensionMismatch);
      await putChunk(
        entryId: 'old',
        messageIds: ['old'],
        text: 'old',
        vector: [0, 1],
      );
      expect((await recall()).reason, MessageRecallReason.belowThreshold);
    });

    test(
      'cancel token and ownership loss after embedding both reject results',
      () async {
        await putChunk(
          entryId: 'old',
          messageIds: ['old'],
          text: 'old',
          vector: [1, 0],
        );
        final token = CancelToken()..cancel();
        final cancelled = await service.recall(
          sessionId: 's1',
          currentText: 'query',
          cancelToken: token,
          config: const EmbeddingConfig(endpoint: 'test'),
        );
        expect(cancelled.reason, MessageRecallReason.cancelled);
        expect(embedder.lastTexts, isEmpty);
        var stale = false;
        embedder.beforeResponse = () async {
          stale = true;
        };
        final staleResult = await service.recall(
          sessionId: 's1',
          currentText: 'query',
          shouldAbort: () => stale,
          config: const EmbeddingConfig(endpoint: 'test'),
        );
        expect(staleResult.reason, MessageRecallReason.cancelled);
        expect(staleResult.matches, isEmpty);
        stale = false;
        final activeToken = CancelToken();
        embedder.beforeResponse = () async {
          activeToken.cancel();
        };
        final lateCancel = await service.recall(
          sessionId: 's1',
          currentText: 'query',
          cancelToken: activeToken,
          config: const EmbeddingConfig(endpoint: 'test'),
        );
        expect(lateCancel.reason, MessageRecallReason.cancelled);
      },
    );
  });
}
