import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/memory_selector.dart';
import 'package:glaze_flutter/core/llm/prompt/memory_prompt_packer.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';

void main() {
  test('a fully reclaimed Memory budget emits no Memory items', () {
    const entry = MemoryEntry(
      id: 'memory',
      title: 'Relevant memory',
      content: 'This lower-priority memory would otherwise be injected.',
      keys: ['relevant'],
    );
    final selection = MemorySelection(
      entries: const [entry],
      allScores: const [
        MemoryCandidateScore(
          entry: entry,
          score: 10,
          matchedKeys: ['relevant'],
        ),
      ],
      budgetTokens: 0,
      entryCap: 1,
    );

    final packed = const MemoryPromptPacker().pack(
      selection: selection,
      excerptingEnabled: true,
      packingMode: 'hybrid',
      excerptTokensPerChunk: 200,
      excerptChunksPerEntry: 1,
      chunkFirstTopEntries: 1,
      chunkFirstTopChunks: 1,
    );

    expect(packed.items, isEmpty);
    expect(packed.totalTokens, 0);
    expect(packed.budgetTrimmed, isTrue);
  });
}
