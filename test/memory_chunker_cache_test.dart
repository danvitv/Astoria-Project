import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory/memory_chunker.dart';
import 'package:glaze_flutter/core/llm/tokenizer.dart';

List<Object> _values(List<ExcerptChunk> chunks) => [
  for (final chunk in chunks)
    [chunk.index, chunk.paragraphIndex, chunk.text, chunk.tokenCost],
];

void main() {
  setUp(MemoryChunker.clearCache);
  tearDown(MemoryChunker.clearCache);

  test(
    'default chunking and counting reuse immutable chunks with exact parity',
    () {
      const content = 'one two three four five six.\n\nSeven eight nine ten.';
      final first = MemoryChunker.chunk(content, 3, estimateTokens);
      final uncached = MemoryChunker.chunk(
        content,
        3,
        (text) => estimateTokens(text),
      );
      expect(_values(first), _values(uncached));
      expect(MemoryChunker.countChunks(content, 3), first.length);
      expect(
        identical(
          first,
          MemoryChunker.chunk('  $content  ', 3, estimateTokens),
        ),
        isTrue,
      );
      expect(() => first.clear(), throwsUnsupportedError);
    },
  );

  test('changed text or budget never receives old chunks', () {
    final first = MemoryChunker.chunk(
      'one two three four five six',
      3,
      estimateTokens,
    );
    final changedText = MemoryChunker.chunk('new content', 3, estimateTokens);
    final changedBudget = MemoryChunker.chunk(
      'one two three four five six',
      30,
      estimateTokens,
    );
    expect(changedText.single.text, 'new content');
    expect(identical(changedText, first), isFalse);
    expect(identical(changedBudget, first), isFalse);
    expect(changedBudget.single.text, 'one two three four five six');
    MemoryChunker.clearCache();
    expect(
      identical(
        first,
        MemoryChunker.chunk('one two three four five six', 3, estimateTokens),
      ),
      isFalse,
    );
  });

  test('custom counters bypass default and same-function mutable caches', () {
    const content = 'one two three four five six';
    MemoryChunker.countChunks(content, 3);
    var multiplier = 1;
    var calls = 0;
    int count(String text) {
      calls++;
      return text.split(RegExp(r'\s+')).length * multiplier;
    }

    final first = MemoryChunker.chunk(content, 3, count);
    expect(first, hasLength(2));
    final previousCalls = calls;
    expect(MemoryChunker.countChunks(content, 3, tokenCounter: count), 2);
    expect(calls, greaterThan(previousCalls));
    multiplier = 2;
    expect(MemoryChunker.countChunks(content, 3, tokenCounter: count), 6);
    expect(
      MemoryChunker.chunk(content, 3, count).every((c) => c.tokenCost == 2),
      isTrue,
    );
    expect(MemoryChunker.countChunks(content, 3, tokenCounter: (_) => 1), 1);
  });

  test('LRU cache is bounded and hits keep a frequently reused entry', () {
    final first = MemoryChunker.chunk('kept', 10, estimateTokens);
    for (var i = 0; i < 127; i++) {
      MemoryChunker.chunk('entry $i', 10, estimateTokens);
    }
    expect(
      identical(first, MemoryChunker.chunk('kept', 10, estimateTokens)),
      isTrue,
    );
    final oldest = MemoryChunker.chunk('entry 0', 10, estimateTokens);
    MemoryChunker.chunk('extra 1', 10, estimateTokens);
    MemoryChunker.chunk('extra 2', 10, estimateTokens);
    expect(
      identical(first, MemoryChunker.chunk('kept', 10, estimateTokens)),
      isTrue,
    );
    expect(
      identical(oldest, MemoryChunker.chunk('entry 0', 10, estimateTokens)),
      isTrue,
    );
    final evicted = MemoryChunker.chunk('entry 1', 10, estimateTokens);
    for (var i = 0; i < 128; i++) {
      MemoryChunker.chunk('replacement $i', 10, estimateTokens);
    }
    expect(
      identical(evicted, MemoryChunker.chunk('entry 1', 10, estimateTokens)),
      isFalse,
    );
  });

  test('empty content and nonpositive counting budgets keep their meaning', () {
    expect(MemoryChunker.countChunks(' \n ', 5), 0);
    expect(MemoryChunker.countChunks('text', 0), 0);
    expect(MemoryChunker.countChunks('text', -1), 0);
  });
}
