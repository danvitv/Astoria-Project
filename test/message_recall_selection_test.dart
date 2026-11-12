import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/message_recall_selection.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  test('retains all ranked candidates until final-window packing', () {
    final candidates = [
      for (final (id, index, text, vector) in [
        ('a', 0, 'first report', [1.0, 0.0]),
        ('a', 1, 'second report', [0.99, 0.01]),
        ('a', 2, 'third report', [0.98, 0.02]),
        ('b', 0, 'independent source', [0.95, 0.05]),
        ('c', 0, 'first  report', [0.94, 0.06]),
      ])
        MessageRecallCandidate(
          entryId: id,
          chunkIndex: index,
          text: text,
          vector: vector,
          messageIds: [id],
        ),
    ];
    final counters = {'dimensionMismatch': 0, 'aboveThreshold': 0};
    final selected = MessageRecallSelection.rank(
      candidates: candidates,
      queryVectors: [
        [1, 0],
      ],
      threshold: .25,
      counters: counters,
    );
    expect(selected.map((match) => '${match.entryId}:${match.chunkIndex}'), [
      'a:0',
      'a:1',
      'a:2',
      'b:0',
      'c:0',
    ]);
    expect(counters['aboveThreshold'], 5);
    expect(selected.first.text, contains('source role/offsets unverified'));
  });

  test('identical source substrings cannot prove a role or offset', () {
    const messages = [
      ChatMessage(id: 'u', role: 'user', content: 'same evidence'),
      ChatMessage(id: 'a', role: 'assistant', content: 'same evidence'),
    ];
    final text = ChatMessageEmbeddingService.formatChunk(messages);
    expect(
      MessageRecallSelection.recoverSources(text, 'same evidence', messages),
      isEmpty,
    );
    final spans = MessageRecallSelection.recoverSources(
      text,
      'assistant: same evidence',
      messages,
    );
    expect(spans.single.role, 'assistant');
    expect(spans.single.messageId, 'a');
    expect(spans.single.sourceStart, 0);
  });

  test('hybrid continuity ranks same-actor inflected action above topic', () {
    final counters = {'dimensionMismatch': 0, 'aboveThreshold': 0};
    final selected = MessageRecallSelection.rank(
      candidates: const [
        MessageRecallCandidate(
          entryId: 'recent-topic',
          chunkIndex: 0,
          text: 'Фейт поправила футболку и подошла к ванной.',
          vector: [1, 0],
          messageIds: ['recent'],
          sourceOrdinal: 90,
        ),
        MessageRecallCandidate(
          entryId: 'older-action',
          chunkIndex: 0,
          text: 'Он шлепнул Фейт по ягодице и рассмеялся.',
          vector: [0.99, 0.01],
          messageIds: ['older'],
          sourceOrdinal: 40,
        ),
      ],
      queryVectors: const [
        [1, 0],
      ],
      threshold: .25,
      counters: counters,
      queryText: 'Подхожу к Фейт, неосознанно шлепая ее по ягодице.',
      participantAliases: const {'Фейт'},
    );

    expect(selected.first.entryId, 'older-action');
    expect(selected.first.continuityScore, greaterThanOrEqualTo(.45));
  });

  test('participant aliases cannot admit an unrelated episode', () {
    final counters = {'dimensionMismatch': 0, 'aboveThreshold': 0};
    final selected = MessageRecallSelection.rank(
      candidates: const [
        MessageRecallCandidate(
          entryId: 'unrelated-intimacy',
          chunkIndex: 0,
          text: 'Фейт и Чисато обсуждали ванну и прикосновения прошлой ночью.',
          vector: [0, 1],
          messageIds: ['old'],
        ),
      ],
      queryVectors: const [
        [1, 0],
      ],
      threshold: .25,
      counters: counters,
      queryText: 'Нужно развезти Фейт и Чисато по домам на машине.',
      participantAliases: const {'Фейт', 'Чисато'},
    );

    expect(selected, isEmpty);
    expect(counters['aboveThreshold'], 0);
  });

  test('same action can still lift a weak semantic match', () {
    final counters = {'dimensionMismatch': 0, 'aboveThreshold': 0};
    final selected = MessageRecallSelection.rank(
      candidates: const [
        MessageRecallCandidate(
          entryId: 'matching-transport',
          chunkIndex: 0,
          text: 'В прошлый раз Данви отвёз Фейт домой на машине.',
          vector: [0.1, 0.9],
          messageIds: ['old'],
        ),
      ],
      queryVectors: const [
        [1, 0],
      ],
      threshold: .25,
      counters: counters,
      queryText: 'Данви отвезёт Фейт домой на машине.',
      participantAliases: const {'Фейт'},
    );

    expect(selected.single.entryId, 'matching-transport');
    expect(selected.single.continuityScore, greaterThan(.45));
  });
}
