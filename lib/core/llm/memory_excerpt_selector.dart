import '../models/memory_book.dart';
import 'memory/memory_chunker.dart';
import 'memory/excerpt_scorer.dart';
import 'memory_selector.dart';
import 'tokenizer.dart';

export 'memory/memory_chunker.dart' show ExcerptChunk, MemoryChunker;
export 'memory/excerpt_scorer.dart'
    show ScoredChunk, GlobalChunkCandidate, ExcerptScorer;

const defaultMemoryExcerptTokensPerEntry = 500;
const defaultMemoryExcerptChunksPerEntry = 2;

class MemoryInjectionItem {
  final MemoryEntry entry;
  final bool excerpt;
  final String text;
  final int tokenCost;
  final int originalTokenCost;
  final List<int> chunkIndexes;
  final List<String> matchedTerms;
  final String reason;
  final List<MemoryEventPromptAnnotation> eventAnnotations;

  const MemoryInjectionItem({
    required this.entry,
    required this.excerpt,
    required this.text,
    required this.tokenCost,
    required this.originalTokenCost,
    this.chunkIndexes = const [],
    this.matchedTerms = const [],
    this.reason = 'full_entry',
    this.eventAnnotations = const [],
  });

  MemoryInjectionItem withEventAnnotations(
    List<MemoryEventPromptAnnotation> annotations,
  ) => MemoryInjectionItem(
    entry: entry,
    excerpt: excerpt,
    text: text,
    tokenCost: tokenCost,
    originalTokenCost: originalTokenCost,
    chunkIndexes: chunkIndexes,
    matchedTerms: matchedTerms,
    reason: reason,
    eventAnnotations: List.unmodifiable(annotations),
  );
}

class MemoryExcerptSelection {
  final List<MemoryInjectionItem> items;
  final int totalTokens;
  final bool budgetTrimmed;

  const MemoryExcerptSelection({
    this.items = const [],
    this.totalTokens = 0,
    this.budgetTrimmed = false,
  });

  List<MemoryEntry> get entries => items.map((item) => item.entry).toList();
}

class MemoryExcerptSelector {
  const MemoryExcerptSelector._();

  static MemoryExcerptSelection fullEntries(
    MemorySelection selection, {
    int Function(String text)? tokenCounter,
  }) {
    final tokenFn = tokenCounter ?? estimateTokens;
    final items = selection.entries
        .map(
          (entry) => MemoryInjectionItem(
            entry: entry,
            excerpt: false,
            text: entry.content.trim(),
            tokenCost: tokenFn(entry.content.trim()),
            originalTokenCost: tokenFn(entry.content),
          ),
        )
        .toList(growable: false);
    return MemoryExcerptSelection(
      items: items,
      totalTokens: items.fold<int>(0, (sum, item) => sum + item.tokenCost),
      budgetTrimmed: selection.budgetTrimmed,
    );
  }

  static MemoryExcerptSelection select(
    MemorySelection selection, {
    String packingMode = 'hybrid',
    int maxExcerptTokensPerEntry = defaultMemoryExcerptTokensPerEntry,
    int maxExcerptChunksPerEntry = defaultMemoryExcerptChunksPerEntry,
    int chunkFirstTopEntries = 3,
    int chunkFirstTopChunks = 1,
    int Function(String text)? tokenCounter,
  }) {
    final tokenFn = tokenCounter ?? estimateTokens;
    final budget = selection.budgetTokens;
    final normalizedPackingMode = _normalizePackingMode(packingMode);
    final selectedFullTokens = selection.entries.fold<int>(
      0,
      (sum, entry) => sum + tokenFn(entry.content),
    );

    if (normalizedPackingMode == 'chunk_first') {
      return selectChunkFirstGlobal(
        selection,
        maxExcerptTokensPerChunk: maxExcerptTokensPerEntry,
        maxExcerptChunksPerEntry: maxExcerptChunksPerEntry,
        topEntries: chunkFirstTopEntries,
        topChunks: chunkFirstTopChunks,
        tokenCounter: tokenFn,
      );
    }

    final hasScopedEntries = selection.allScores.any(
      (score) => _scopedParagraphs(score) != null,
    );
    if (normalizedPackingMode == 'full' ||
        (budget == null && !hasScopedEntries) ||
        (normalizedPackingMode == 'hybrid' &&
            budget != null &&
            selectedFullTokens <= budget &&
            !selection.budgetTrimmed &&
            !hasScopedEntries)) {
      return fullEntries(selection, tokenCounter: tokenFn);
    }

    final cap = selection.entryCap > 0
        ? selection.entryCap
        : selection.entries.length;
    final items = <MemoryInjectionItem>[];
    final packingBudget = budget ?? selectedFullTokens;
    var usedTokens = 0;
    var trimmed = selection.budgetTrimmed;

    for (final score in selection.allScores) {
      if (score.excludedBySourceWindow) continue;
      if (items.length >= cap) break;
      final entry = score.entry;
      final fullText = entry.content.trim();
      if (fullText.isEmpty) continue;
      final fullTokens = tokenFn(fullText);
      final scopedParagraphs = _scopedParagraphs(score);

      if (normalizedPackingMode == 'hybrid' &&
          scopedParagraphs == null &&
          usedTokens + fullTokens <= packingBudget) {
        items.add(
          MemoryInjectionItem(
            entry: entry,
            excerpt: false,
            text: fullText,
            tokenCost: fullTokens,
            originalTokenCost: tokenFn(entry.content),
          ),
        );
        usedTokens += fullTokens;
        continue;
      }

      final remaining = packingBudget - usedTokens;
      if (remaining <= 0 && items.isNotEmpty) {
        trimmed = true;
        continue;
      }

      final perEntryBudget = maxExcerptTokensPerEntry > 0 && remaining > 0
          ? maxExcerptTokensPerEntry.clamp(1, remaining)
          : 0;
      final excerpt = _buildExcerpt(
        score,
        maxTokens: perEntryBudget,
        chunkTokens: maxExcerptTokensPerEntry,
        maxChunks: maxExcerptChunksPerEntry,
        tokenCounter: tokenFn,
      );

      if (excerpt == null) {
        trimmed = true;
        continue;
      }

      if (usedTokens + excerpt.tokenCost <= packingBudget) {
        items.add(excerpt);
        usedTokens += excerpt.tokenCost;
      } else {
        trimmed = true;
      }
    }

    return MemoryExcerptSelection(
      items: _chronologicalItems(items),
      totalTokens: usedTokens,
      budgetTrimmed: trimmed,
    );
  }

  /// Ranks anchors globally, then packs atomic forward-context windows by
  /// their actual injected cost (not full-entry cost). One query embedding
  /// still compares against all stored chunk vectors upstream.
  static MemoryExcerptSelection selectChunkFirstGlobal(
    MemorySelection selection, {
    int maxExcerptTokensPerChunk = defaultMemoryExcerptTokensPerEntry,
    int maxExcerptChunksPerEntry = defaultMemoryExcerptChunksPerEntry,
    int topEntries = 3,
    int topChunks = 1,
    int Function(String text)? tokenCounter,
  }) {
    final tokenFn = tokenCounter ?? estimateTokens;
    final budget = selection.budgetTokens;
    final ranked = <_WindowCandidate>[];

    for (final score in selection.allScores) {
      if (score.excludedBySourceWindow) continue;
      final fullText = score.entry.content.trim();
      if (fullText.isEmpty) continue;

      ranked.addAll(_rankWindows(score, maxExcerptTokensPerChunk, tokenFn));
    }

    ranked.sort((a, b) {
      final byRel = b.relevance.compareTo(a.relevance);
      if (byRel != 0) return byRel;
      final byEntry = b.score.score.compareTo(a.score.score);
      if (byEntry != 0) return byEntry;
      return a.anchorIndex.compareTo(b.anchorIndex);
    });

    final packing = _WindowPacking(
      maxWindowsPerEntry: maxExcerptChunksPerEntry,
      maxWindowTokens: maxExcerptTokensPerChunk * 2,
      budget: budget,
      tokenCounter: tokenFn,
    );

    // Phase 1: top entries each get up to [topChunks] best anchor windows
    // so recency / vector-implied relevance is not drowned out by keyword-heavy
    // older arcs.
    final rankedByEntry = <String, List<_WindowCandidate>>{};
    for (final candidate in ranked) {
      rankedByEntry
          .putIfAbsent(candidate.score.entry.id, () => <_WindowCandidate>[])
          .add(candidate);
    }
    final entryFloorCap = topEntries.clamp(0, 64);
    final chunksPerGuaranteedEntry = topChunks.clamp(
      0,
      maxExcerptChunksPerEntry.clamp(0, 64),
    );
    if (entryFloorCap > 0) {
      var floorEntriesProcessed = 0;
      for (final score in selection.allScores) {
        if (score.excludedBySourceWindow) continue;
        final entryChunks = rankedByEntry[score.entry.id];
        if (entryChunks == null || entryChunks.isEmpty) continue;
        if (floorEntriesProcessed >= entryFloorCap) break;
        floorEntriesProcessed++;

        var addedForEntry = 0;
        for (final candidate in entryChunks) {
          if (addedForEntry >= chunksPerGuaranteedEntry) break;
          if (packing.tryAdd(candidate)) {
            addedForEntry++;
          }
        }
      }
    }

    // Phase 2: fill remaining budget with globally ranked anchor windows.
    for (final candidate in ranked) {
      packing.tryAdd(candidate);
    }

    return MemoryExcerptSelection(
      items: _chronologicalItems(packing.items('chunk_first_global')),
      totalTokens: packing.usedTokens,
      budgetTrimmed: selection.budgetTrimmed || packing.trimmed,
    );
  }

  static int countChunks(
    String content,
    int maxTokensPerChunk, {
    int Function(String text)? tokenCounter,
  }) {
    return MemoryChunker.countChunks(
      content,
      maxTokensPerChunk,
      tokenCounter: tokenCounter,
    );
  }

  static String _normalizePackingMode(String raw) {
    if (raw == 'full' || raw == 'chunk_first') return raw;
    return 'hybrid';
  }

  static List<MemoryInjectionItem> _chronologicalItems(
    List<MemoryInjectionItem> items,
  ) {
    final out = [...items];
    out.sort((a, b) {
      final ar = a.entry.messageRange;
      final br = b.entry.messageRange;
      final as = ar?.start ?? 1 << 30;
      final bs = br?.start ?? 1 << 30;
      if (as != bs) return as.compareTo(bs);
      final ae = ar?.end ?? as;
      final be = br?.end ?? bs;
      if (ae != be) return ae.compareTo(be);
      return a.entry.id.compareTo(b.entry.id);
    });
    return out;
  }

  static MemoryInjectionItem? _buildExcerpt(
    MemoryCandidateScore score, {
    required int maxTokens,
    required int chunkTokens,
    required int maxChunks,
    required int Function(String text) tokenCounter,
  }) {
    if (maxTokens <= 0 || maxChunks <= 0) return null;
    final ranked = _rankWindows(score, chunkTokens, tokenCounter)
      ..sort((a, b) {
        final byScore = b.relevance.compareTo(a.relevance);
        return byScore != 0 ? byScore : a.anchorIndex.compareTo(b.anchorIndex);
      });
    final packing = _WindowPacking(
      maxWindowsPerEntry: maxChunks,
      maxWindowTokens: maxTokens,
      budget: maxTokens,
      tokenCounter: tokenCounter,
    );
    for (final candidate in ranked) {
      packing.tryAdd(candidate);
    }
    final items = packing.items('over_budget_excerpt');
    return items.isEmpty ? null : items.single;
  }

  /// One bounded chunk immediately after each anchor is context, even when
  /// its relevance/key mapping is weaker. A split paragraph adds only its next
  /// chunk, not its entire tail. Limits count anchor windows (at most twice as
  /// many source chunks); overlapping windows are rendered once, in raw order.
  /// Chunk boundaries use the configured limit, never the shrinking budget.
  static List<_WindowCandidate> _rankWindows(
    MemoryCandidateScore score,
    int chunkTokens,
    int Function(String) tokenCounter,
  ) {
    if (chunkTokens <= 0 || score.excludedBySourceWindow) return [];
    final source = score.entry.content;
    final chunks = MemoryChunker.chunk(source, chunkTokens, tokenCounter);
    final spans = <(int, int)>[];
    var cursor = 0;
    for (final chunk in chunks) {
      // The chunker normalizes whitespace when splitting long paragraphs.
      // Locate those words back in the source rather than injecting rewritten
      // text or artificial blank lines inside a paragraph.
      final pattern = chunk.text
          .split(RegExp(r'\s+'))
          .map(RegExp.escape)
          .join(r'\s+');
      final match = RegExp(pattern).allMatches(source, cursor).firstOrNull;
      // Fail closed if chunk/source alignment ever changes upstream.
      if (match == null) return [];
      spans.add((match.start, match.end));
      cursor = match.end;
    }
    final scoped = _scopedParagraphs(score);
    final terms = ExcerptScorer.termsFor(score);
    return [
      for (var i = 0; i < chunks.length; i++)
        if (scoped == null || scoped.contains(chunks[i].paragraphIndex))
          _WindowCandidate(
            score: score,
            anchorIndex: chunks[i].index,
            start: spans[i].$1,
            end: spans[i + 1 < chunks.length ? i + 1 : i].$2,
            chunkIndexes: [
              chunks[i].index,
              if (i + 1 < chunks.length) chunks[i + 1].index,
            ],
            relevance: ExcerptScorer.chunkRelevance(
              chunks[i].text,
              score,
              terms,
            ),
          ),
    ];
  }

  static Set<int>? _scopedParagraphs(MemoryCandidateScore score) {
    if ((score.matchedKeys.isEmpty && score.catalogMatchedTerms.isEmpty) ||
        score.entry.keyParagraphs.isEmpty) {
      return null;
    }
    final normalized = {
      for (final entry in score.entry.keyParagraphs.entries)
        entry.key.trim().toLowerCase(): entry.value,
    };
    final resolved = <int>{};
    for (final key in score.matchedKeys) {
      final indexes = normalized[key.trim().toLowerCase()];
      if (indexes == null || indexes.isEmpty) return null;
      resolved.addAll(indexes);
    }
    // Catalog terms may be entities, locations, or topics rather than entry
    // keys. Use the ones that have paragraph provenance without allowing an
    // unrelated catalog term to disable valid key scoping.
    for (final term in score.catalogMatchedTerms) {
      final indexes = normalized[term.trim().toLowerCase()];
      if (indexes != null) resolved.addAll(indexes);
    }
    final paragraphCount = MemoryChunker.paragraphs(score.entry.content).length;
    resolved.removeWhere((index) => index < 0 || index >= paragraphCount);
    return resolved.isEmpty ? null : resolved;
  }
}

class _WindowCandidate {
  final MemoryCandidateScore score;
  final int anchorIndex;
  final int start;
  final int end;
  final List<int> chunkIndexes;
  final double relevance;

  const _WindowCandidate({
    required this.score,
    required this.anchorIndex,
    required this.start,
    required this.end,
    required this.chunkIndexes,
    required this.relevance,
  });
}

/// Shared atomic admission for hybrid and global packing. Count the rendered
/// union, including separators, rather than adding independent chunk counts.
class _WindowPacking {
  final int maxWindowsPerEntry;
  final int maxWindowTokens;
  final int? budget;
  final int Function(String) tokenCounter;
  final _picked = <String, List<_WindowCandidate>>{};
  final _costs = <String, int>{};
  var usedTokens = 0;
  var trimmed = false;

  _WindowPacking({
    required int maxWindowsPerEntry,
    required this.maxWindowTokens,
    required this.budget,
    required this.tokenCounter,
  }) : maxWindowsPerEntry = maxWindowsPerEntry.clamp(0, 64);

  bool tryAdd(_WindowCandidate candidate) {
    final id = candidate.score.entry.id;
    final picked = _picked[id] ?? const <_WindowCandidate>[];
    if (picked.any(
      (c) => c.start <= candidate.start && c.end >= candidate.end,
    )) {
      return false;
    }
    if (picked.length >= maxWindowsPerEntry) {
      trimmed = true;
      return false;
    }
    if (tokenCounter(
          candidate.score.entry.content.substring(
            candidate.start,
            candidate.end,
          ),
        ) >
        maxWindowTokens) {
      trimmed = true;
      return false;
    }
    final next = [...picked, candidate];
    final cost = tokenCounter(_text(next));
    final total = usedTokens - (_costs[id] ?? 0) + cost;
    if (budget != null && total > budget!) {
      trimmed = true;
      return false;
    }
    _picked[id] = next;
    _costs[id] = cost;
    usedTokens = total;
    return true;
  }

  List<MemoryInjectionItem> items(String reason) {
    return _picked.values
        .map((picked) {
          final text = _text(picked);
          return MemoryInjectionItem(
            entry: picked.first.score.entry,
            excerpt: true,
            text: text,
            tokenCost: _costs[picked.first.score.entry.id]!,
            originalTokenCost: tokenCounter(picked.first.score.entry.content),
            chunkIndexes: (picked.expand((c) => c.chunkIndexes).toSet().toList()
              ..sort()),
            matchedTerms: ExcerptScorer.termsFor(picked.first.score)
                .where((term) => text.toLowerCase().contains(term))
                .toList(growable: false),
            reason: reason,
          );
        })
        .toList(growable: false);
  }

  static String _text(List<_WindowCandidate> picked) {
    final ordered = [...picked]..sort((a, b) => a.start.compareTo(b.start));
    final source = ordered.first.score.entry.content;
    final parts = <String>[];
    var start = ordered.first.start;
    var end = ordered.first.end;
    for (final candidate in ordered.skip(1)) {
      if (candidate.start <= end ||
          source.substring(end, candidate.start).trim().isEmpty) {
        if (candidate.end > end) end = candidate.end;
      } else {
        parts.add(source.substring(start, end));
        start = candidate.start;
        end = candidate.end;
      }
    }
    parts.add(source.substring(start, end));
    return parts.join('\n\n');
  }
}
