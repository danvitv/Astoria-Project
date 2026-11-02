import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/chat_message_embedding_service.dart';
import 'package:glaze_flutter/core/llm/message_recall_selection.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';

void main() {
  test(
    'selects diverse groups then a second independent excerpt, deduplicated',
    () {
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
      final counters = {
        'dimensionMismatch': 0,
        'aboveThreshold': 0,
        'duplicate': 0,
        'oversized': 0,
        'selectedChars': 0,
      };
      final selected = MessageRecallSelection.select(
        candidates: candidates,
        queryVectors: [
          [1, 0],
        ],
        threshold: .25,
        topK: 8,
        maxChars: 6000,
        counters: counters,
      );
      expect(selected.map((match) => '${match.entryId}:${match.chunkIndex}'), [
        'a:0',
        'b:0',
        'a:1',
      ]);
      expect(counters['duplicate'], 1);
      expect(selected.first.text, contains('source role/offsets unverified'));
    },
  );

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
}
