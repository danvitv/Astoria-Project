import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/message_recall_compute.dart';
import 'package:glaze_flutter/core/llm/message_recall_service.dart';
import 'package:glaze_flutter/core/llm/vector_math.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

class _Embedder extends EmbeddingService {
  int calls = 0;
  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    cancelToken,
    captureContext,
  }) async {
    calls++;
    return [
      EmbeddingChunk(text: texts.single, vector: [1, 0]),
    ];
  }
}

EmbeddingRow _row(String id, String text, {String? hash}) => EmbeddingRow(
  entryId: id,
  sourceType: 'chat_message',
  sourceId: 'session',
  vectorsBlob: vectorListToBytes([
    [1, 0],
  ]),
  textHash: hash ?? computeHash(text),
  retrievalHintsJson: jsonEncode({
    'messageIds': [id],
    'chunks': [
      {'index': 0, 'text': text},
    ],
  }),
  updatedAt: 1,
);

void main() {
  test(
    'worker preserves source proofs, counters, ranking and attribution',
    () async {
      const selected = ChatMessage(
        id: 'old',
        role: 'assistant',
        content: 'selected source',
        swipes: ['rejected source', 'selected source'],
        swipeId: 1,
        studioOutputs: [
          {'content': 'large private audit'},
        ],
        memoryCoverage: {'nested': 'not part of evidence'},
      );
      final input = RecallPreparationInput(
        rows: [
          _row('old', 'assistant: selected source'),
          _row('bad', 'assistant: obsolete'),
        ],
        sources: {
          'old': selected,
          'bad': const ChatMessage(
            id: 'bad',
            role: 'assistant',
            content: 'changed',
          ),
        },
        allowedIds: {'old', 'bad'},
      );
      expect(input.sources!['old']!.content, selected.content);
      expect(input.sources!['old']!.swipes, isEmpty);
      expect(input.sources!['old']!.studioOutputs, isEmpty);
      expect(input.sources!['old']!.memoryCoverage, isEmpty);
      final expected = prepareRecallCandidates(input);
      final actual = await prepareRecallInIsolate(input);
      expect(actual.counters, expected.counters);
      expect(actual.counters['hashRejected'], 1);
      final ranking = RecallRankingInput(
        actual.candidates,
        [
          [1, 0],
        ],
        0.25,
        actual.counters,
      );
      final synchronous = rankRecallCandidates(ranking);
      final isolated = await rankRecallInIsolate(ranking);
      expect(isolated.counters, synchronous.counters);
      expect(
        isolated.matches.map((m) => m.toJson()).toList(),
        synchronous.matches.map((m) => m.toJson()).toList(),
      );
      expect(isolated.matches.single.text, contains('assistant message=old'));
      expect(isolated.matches.single.text, isNot(contains('rejected source')));
    },
  );

  for (final cancelDuring in ['prepare', 'rank']) {
    test(
      'late $cancelDuring worker cannot publish or continue a retired turn',
      () async {
        final db = AppDatabase.forTesting(NativeDatabase.memory());
        addTearDown(db.close);
        final repo = EmbeddingRepo(db);
        await repo.putEmbeddingVector(
          entryId: 'old',
          sourceType: 'chat_message',
          sourceId: 'session',
          vectors: [
            [1, 0],
          ],
          textHash: computeHash('assistant: source'),
          retrievalMetadata: {
            'messageIds': ['old'],
            'chunks': [
              {'index': 0, 'text': 'assistant: source'},
            ],
          },
        );
        final entered = Completer<void>();
        final release = Completer<void>();
        final embedder = _Embedder();
        final token = CancelToken();
        final service = MessageRecallService(
          repo,
          embedder,
          prepare: (input) async {
            if (cancelDuring == 'prepare') {
              entered.complete();
              await release.future;
            }
            return prepareRecallCandidates(input);
          },
          rank: (input) async {
            if (cancelDuring == 'rank') {
              entered.complete();
              await release.future;
            }
            return rankRecallCandidates(input);
          },
        );
        final pending = service.recall(
          sessionId: 'session',
          currentText: 'source',
          config: const EmbeddingConfig(endpoint: 'fake'),
          cancelToken: token,
          sourceMessages: {
            'old': const ChatMessage(
              id: 'old',
              role: 'assistant',
              content: 'source',
            ),
          },
        );
        await entered.future;
        token.cancel();
        release.complete();
        final result = await pending;
        expect(result.reason, MessageRecallReason.cancelled);
        expect(result.matches, isEmpty);
        expect(embedder.calls, cancelDuring == 'prepare' ? 0 : 1);
      },
    );
  }
}
