import 'package:flutter_test/flutter_test.dart';

import 'package:glaze_flutter/core/llm/prompt/recalled_message_chunk.dart';
import 'package:glaze_flutter/core/llm/prompt/recalled_messages_resolver.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';

void main() {
  const resolver = RecalledMessagesResolver();

  test('uses legacy content only when structured chunks are absent', () {
    expect(
      resolver.resolve(
        chunks: const [],
        visibleMessageIds: const {},
        fallbackContent: '<recalled>legacy</recalled>',
      ),
      allOf(
        contains('Historical evidence'),
        contains('Occurred: story time unknown'),
        endsWith('<recalled>legacy</recalled>'),
      ),
    );
    expect(
      resolver.resolve(
        chunks: const [
          RecalledMessageChunk(text: 'structured', messageIds: ['visible']),
        ],
        visibleMessageIds: const {'visible'},
        fallbackContent: '<recalled>legacy</recalled>',
      ),
      isNull,
    );
  });

  test('excludes a chunk when any source message is visible', () {
    final content = resolver.resolve(
      chunks: const [
        RecalledMessageChunk(
          text: 'overlapping',
          messageIds: ['hidden', 'visible'],
        ),
        RecalledMessageChunk(text: 'retained', messageIds: ['other']),
        RecalledMessageChunk(text: 'no provenance'),
      ],
      visibleMessageIds: const {'visible'},
    );

    expect(content, isNot(contains('overlapping')));
    expect(content, contains('retained'));
    expect(content, contains('no provenance'));
  });

  test('formats retained chunks with the canonical wrapper', () {
    final content = resolver.resolve(
      chunks: const [
        RecalledMessageChunk(text: '  first  '),
        RecalledMessageChunk(text: 'second'),
      ],
      visibleMessageIds: const {},
    );

    expect(
      content,
      allOf(
        startsWith(
          '<recalled_messages>\n[Historical evidence, not current state]',
        ),
        contains('Current story point: unknown'),
        contains('preserving speaker perspective'),
        endsWith(
          '---\nOccurred: story time unknown\nfirst\n---\nOccurred: story time unknown\nsecond\n</recalled_messages>',
        ),
        isNot(contains('ground truth context')),
      ),
    );
  });

  test('bypass retains chunks that overlap the source window', () {
    final content = resolver.resolve(
      chunks: const [
        RecalledMessageChunk(text: 'retained', messageIds: ['visible']),
      ],
      visibleMessageIds: const {'visible'},
      disableSourceWindowExclusion: true,
    );

    expect(content, contains('retained'));
  });

  test('blank structured chunks do not resurrect fallback content', () {
    final content = resolver.resolve(
      chunks: const [RecalledMessageChunk(text: '   ')],
      visibleMessageIds: const {},
      fallbackContent: '<recalled>legacy</recalled>',
    );

    expect(content, isNot(contains('legacy')));
  });

  test('5000-token budget counts the complete block, not character length', () {
    expect(RecalledMessagesResolver.defaultMaxTokens, 5000);
    final longButCheap = RecalledMessageChunk(
      entryId: 'cheap',
      text: 'cheap ' * 2000,
      score: .9,
    );
    const shortButExpensive = RecalledMessageChunk(
      entryId: 'expensive',
      text: 'expensive',
      score: 1,
    );
    final original = longButCheap.text;
    final result = resolver.resolveWithDiagnostics(
      chunks: [shortButExpensive, longButCheap],
      visibleMessageIds: const {},
      tokenCounter: (block) {
        expect(block, startsWith('<recalled_messages>'));
        expect(block, endsWith('</recalled_messages>'));
        // A deterministic tokenizer fixture: 200 envelope tokens, cheap text
        // 4800 tokens; the shorter expensive text exceeds the total budget.
        return 200 + (block.contains('expensive') ? 5000 : 4800);
      },
    );
    expect(result.diagnostics['estimatedTokens'], 5000);
    expect(result.diagnostics['budgetRejected'], 1);
    expect(result.content, contains(original.trim()));
    expect(result.content!.length, greaterThan(6000));
    expect(result.content, isNot(contains('expensive')));
    expect(longButCheap.text, original);
  });

  test('excludes visible sources before top-K, budget and group diversity', () {
    final result = resolver.resolveWithDiagnostics(
      chunks: [
        for (var i = 0; i < 10; i++)
          RecalledMessageChunk(
            entryId: 'visible$i',
            messageIds: ['visible$i', 'boundary'],
            score: 1,
            text: 'visible $i',
          ),
        for (var i = 0; i < 4; i++)
          RecalledMessageChunk(
            entryId: 'old$i',
            messageIds: ['old$i'],
            score: .9,
            text: 'old evidence $i',
          ),
      ],
      visibleMessageIds: const {'boundary'},
      topK: 3,
      tokenCounter: (block) =>
          100 + 1000 * 'old evidence'.allMatches(block).length,
    );
    expect(result.diagnostics['visibleRejected'], 10);
    expect(result.diagnostics['estimatedTokens'], 3100);
    expect(result.diagnostics['selected'], hasLength(3));
    expect(result.content, isNot(contains('visible')));
    expect(result.content, contains('old evidence 2'));
  });

  test('diverse groups, exact-text deduplication, at most two per group', () {
    final result = resolver.resolveWithDiagnostics(
      chunks: const [
        RecalledMessageChunk(
          entryId: 'a',
          chunkIndex: 0,
          text: 'first',
          score: 1,
        ),
        RecalledMessageChunk(
          entryId: 'a',
          chunkIndex: 1,
          text: 'second',
          score: .99,
        ),
        RecalledMessageChunk(
          entryId: 'a',
          chunkIndex: 2,
          text: 'third',
          score: .98,
        ),
        RecalledMessageChunk(entryId: 'b', text: 'independent', score: .97),
        RecalledMessageChunk(entryId: 'c', text: ' first ', score: .96),
      ],
      visibleMessageIds: const {},
    );
    expect(
      (result.diagnostics['selected'] as List).map((item) => item['entryId']),
      ['a', 'b', 'a'],
    );
    expect(result.diagnostics['duplicates'], 1);
    expect(result.content, isNot(contains('third')));
    expect(
      result.diagnostics['estimatedTokens'],
      estimateTokens(result.content!),
    );
  });

  test('legacy fallback and invalid budgets cannot bypass the token cap', () {
    expect(
      resolver.resolve(
        chunks: const [],
        visibleMessageIds: const {},
        fallbackContent: 'old evidence',
        maxTokens: 1,
      ),
      isNull,
    );
    expect(
      resolver.resolve(
        chunks: const [RecalledMessageChunk(text: 'old evidence')],
        visibleMessageIds: const {},
        maxTokens: 0,
      ),
      isNull,
    );
  });

  test('rank and raw-text metadata survive worker serialization', () {
    const source = RecalledMessageChunk(
      entryId: 'group',
      chunkIndex: 3,
      text: '[Verified source]\noriginal text',
      rawText: 'original text',
      messageIds: ['a', 'b'],
      ledgerRange: '1..2',
      score: .87,
    );
    expect(
      RecalledMessageChunk.fromJson(source.toJson()).toJson(),
      source.toJson(),
    );
  });
}
