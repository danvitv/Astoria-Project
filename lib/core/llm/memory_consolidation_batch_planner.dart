import 'dart:convert';

import '../models/api_config.dart';
import '../models/memory_book.dart';
import '../models/memory_book_api_settings.dart';
import 'memory_book_api_config_resolver.dart';
import 'tokenizer.dart';

/// Conservative context used when a custom MemoryBook endpoint cannot report
/// its model context window. Custom endpoints must never inherit the old,
/// effectively unbounded 120K-character pack default.
const int kMemoryConsolidationCustomContextFallback = 16384;

/// Prompt roles, instructions, JSON wrapper and provider message framing.
/// This is intentionally conservative: source text is never shortened to fit.
const int kMemoryConsolidationFramingReserveTokens = 1024;

final class MemoryConsolidationRequestBudget {
  const MemoryConsolidationRequestBudget({
    required this.contextTokens,
    required this.outputReserveTokens,
    this.framingReserveTokens = kMemoryConsolidationFramingReserveTokens,
  });

  factory MemoryConsolidationRequestBudget.forApi({
    required MemoryBookApiSettings settings,
    required ApiConfig? config,
  }) {
    final context =
        config?.contextSize ?? kMemoryConsolidationCustomContextFallback;
    final output = MemoryBookApiConfigResolver.maxTokensFor(settings, config);
    return MemoryConsolidationRequestBudget(
      contextTokens: context,
      outputReserveTokens: output,
    );
  }

  final int contextTokens;
  final int outputReserveTokens;
  final int framingReserveTokens;

  int get packTokenLimit =>
      contextTokens - outputReserveTokens - framingReserveTokens;
}

final class MemoryConsolidationPlannedPackage {
  const MemoryConsolidationPlannedPackage({
    required this.entries,
    required this.estimatedTokens,
    required this.oversized,
  });

  final List<MemoryEntry> entries;
  final int estimatedTokens;
  final bool oversized;
}

/// Shared deterministic package boundary algorithm for threshold enqueue and
/// the initial-book dry run. Entries are always oldest-first and indivisible.
final class MemoryConsolidationBatchPlanner {
  const MemoryConsolidationBatchPlanner();

  List<MemoryConsolidationPlannedPackage> plan({
    required Iterable<MemoryEntry> entries,
    required MemoryConsolidationRequestBudget budget,
    int maxEntriesPerPackage = 10,
  }) {
    if (maxEntriesPerPackage < 1) {
      throw ArgumentError.value(
        maxEntriesPerPackage,
        'maxEntriesPerPackage',
        'must be at least 1',
      );
    }
    if (budget.contextTokens < 1 ||
        budget.outputReserveTokens < 1 ||
        budget.framingReserveTokens < 0) {
      throw ArgumentError('Invalid consolidation request budget.');
    }

    final ordered = entries.toList()
      ..sort((a, b) {
        final byCreated = (a.createdAt ?? 0).compareTo(b.createdAt ?? 0);
        return byCreated != 0 ? byCreated : a.id.compareTo(b.id);
      });
    final packages = <MemoryConsolidationPlannedPackage>[];
    var current = <MemoryEntry>[];
    var currentTokens = 0;

    void flush() {
      if (current.isEmpty) return;
      packages.add(
        MemoryConsolidationPlannedPackage(
          entries: List.unmodifiable(current),
          estimatedTokens: currentTokens,
          oversized:
              current.length == 1 && currentTokens > budget.packTokenLimit,
        ),
      );
      current = <MemoryEntry>[];
      currentTokens = 0;
    }

    for (final entry in ordered) {
      final tokens = estimatedEntryTokens(entry);
      if (current.isNotEmpty &&
          (current.length >= maxEntriesPerPackage ||
              currentTokens + tokens > budget.packTokenLimit)) {
        flush();
      }
      current.add(entry);
      currentTokens += tokens;
      // An indivisible source that cannot fit is retained as a singleton. The
      // durable job records a pre-network failure instead of truncating it.
      if (tokens > budget.packTokenLimit) flush();
    }
    flush();
    return List.unmodifiable(packages);
  }

  static int estimatedEntryTokens(MemoryEntry entry) {
    final revision = entry.revisions
        .where((candidate) => candidate.id == entry.activeRevisionId)
        .firstOrNull;
    final payload = revision == null
        ? entry.toJson()
        : {
            'ref': 'entry:${entry.id}',
            'memoryEntryId': entry.id,
            'revisionId': revision.id,
            'fingerprint': '0' * 64,
            'title': revision.title,
            'content': revision.content,
            'messageIds': revision.messageIds,
            'sourceSwipeId': entry.sourceSwipeId,
            'sourceAgentSwipeId': entry.sourceAgentSwipeId,
            'sourceManifest': revision.sourceManifest?.toJson(),
          };
    // Per-source event IDs and surrounding arrays add small fixed JSON costs.
    return estimateTokens(jsonEncode(payload)) + 64;
  }
}
