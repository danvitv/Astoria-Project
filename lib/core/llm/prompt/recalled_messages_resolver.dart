import '../game_time.dart';
import '../memory_temporal_context.dart';
import '../tokenizer.dart';
import 'recalled_message_chunk.dart';

/// Packs original source text before outbound macros/regexes change its spaces.
/// The budget is estimated tokens, not a promise about a provider's tokenizer.
final class RecalledMessagesResolver {
  static const defaultMaxTokens = 5000;
  static const defaultTopK = 8;

  const RecalledMessagesResolver();

  String? resolve({
    required List<RecalledMessageChunk> chunks,
    required Set<String> visibleMessageIds,
    String? fallbackContent,
    bool disableSourceWindowExclusion = false,
    GameTimeState gameTime = const GameTimeState(),
    int maxTokens = defaultMaxTokens,
    int topK = defaultTopK,
  }) => resolveWithDiagnostics(
    chunks: chunks,
    visibleMessageIds: visibleMessageIds,
    fallbackContent: fallbackContent,
    disableSourceWindowExclusion: disableSourceWindowExclusion,
    gameTime: gameTime,
    maxTokens: maxTokens,
    topK: topK,
  ).content;

  RecalledMessagesResolution resolveWithDiagnostics({
    required List<RecalledMessageChunk> chunks,
    required Set<String> visibleMessageIds,
    String? fallbackContent,
    bool disableSourceWindowExclusion = false,
    GameTimeState gameTime = const GameTimeState(),
    int maxTokens = defaultMaxTokens,
    int topK = defaultTopK,
    int Function(String)? tokenCounter,
  }) {
    final countTokens = tokenCounter ?? estimateTokens;
    final counterKind = tokenCounter != null
        ? 'custom'
        : o200kBaseLoaded
        ? 'o200k_base_estimate'
        : 'approx_chars_per_4';
    var visibleRejected = 0;
    var duplicates = 0;
    var budgetRejected = 0;
    var tokens = 0;
    final selected = <RecalledMessageChunk>[];
    RecalledMessagesResolution finish(String? content, String reason) =>
        RecalledMessagesResolution(
          content: content,
          diagnostics: {
            'stage': 'prompt_context_packing',
            'budgetBasis': 'source_before_prompt_transforms',
            'tokenCounter': counterKind,
            'budgetTokens': maxTokens,
            'estimatedTokens': tokens,
            'reason': reason,
            'candidates': chunks.length,
            'visibleRejected': visibleRejected,
            'duplicates': duplicates,
            'budgetRejected': budgetRejected,
            'selected': [
              for (final chunk in selected)
                {
                  'entryId': chunk.entryId,
                  'chunkIndex': chunk.chunkIndex,
                  'score': chunk.score,
                  'sourceIds': chunk.messageIds,
                  'chars': chunk.text.length,
                },
            ],
          },
        );
    if (maxTokens <= 0 || topK <= 0) return finish(null, 'invalidLimits');
    if (chunks.isEmpty) {
      if (fallbackContent == null || fallbackContent.trim().isEmpty) {
        return finish(null, 'empty');
      }
      final content =
          '${historicalMemoryHeader(gameTime)}\n'
          '${memoryOccurrence(null)}\n$fallbackContent';
      final cost = countTokens(content);
      if (cost > maxTokens) {
        budgetRejected++;
        return finish(null, 'budgetExhausted');
      }
      tokens = cost;
      return finish(content, 'legacyContent');
    }

    // Retain the whole ranked pool until this consumer's history is known.
    // Source-window exclusions must not consume top-K or the token budget.
    final eligible = <({RecalledMessageChunk chunk, int ordinal})>[];
    for (final (ordinal, chunk) in chunks.indexed) {
      if (!disableSourceWindowExclusion &&
          chunk.messageIds.any(visibleMessageIds.contains)) {
        visibleRejected++;
        continue;
      }
      if (chunk.text.trim().isNotEmpty) {
        eligible.add((chunk: chunk, ordinal: ordinal));
      }
    }
    eligible.sort((a, b) {
      final score = (b.chunk.score ?? 0).compareTo(a.chunk.score ?? 0);
      return score != 0 ? score : a.ordinal.compareTo(b.ordinal);
    });
    final groupCounts = <String, int>{};
    final seenTexts = <String>{};
    final processed = <int>{};
    for (var pass = 1; pass <= 2; pass++) {
      for (final item in eligible) {
        if (processed.contains(item.ordinal)) continue;
        final chunk = item.chunk;
        final group =
            chunk.entryId ??
            (chunk.messageIds.isEmpty
                ? 'legacy:${item.ordinal}'
                : chunk.messageIds.join('\u001f'));
        if ((groupCounts[group] ?? 0) >= pass) continue;
        processed.add(item.ordinal);
        final fingerprint = (chunk.rawText ?? chunk.text)
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (seenTexts.contains(fingerprint)) {
          duplicates++;
          continue;
        }
        // Count the exact entire source block, including attribution, occurrence
        // headers and wrapper. No truncated evidence and no transformed spaces.
        final proposed = _render([...selected, chunk], gameTime);
        final cost = countTokens(proposed);
        if (cost > maxTokens) {
          budgetRejected++;
          continue; // A smaller, lower-ranked fragment can still fit.
        }
        selected.add(chunk);
        seenTexts.add(fingerprint);
        groupCounts[group] = (groupCounts[group] ?? 0) + 1;
        tokens = cost;
        if (selected.length >= topK) {
          return finish(proposed, 'success');
        }
      }
    }
    return finish(
      selected.isEmpty ? null : _render(selected, gameTime),
      selected.isNotEmpty
          ? 'success'
          : budgetRejected > 0
          ? 'budgetExhausted'
          : 'empty',
    );
  }

  String _render(List<RecalledMessageChunk> chunks, GameTimeState gameTime) {
    final block = StringBuffer();
    block.writeln('<recalled_messages>');
    block.writeln(historicalMemoryHeader(gameTime));
    block.writeln(
      'Semantically relevant raw message chunks from earlier in this chat. '
      'Use them as historical source text, preserving speaker perspective.',
    );
    for (final chunk in chunks) {
      final text = chunk.text.trim();
      if (text.isEmpty) continue;
      block.writeln('---');
      block.writeln(memoryOccurrence(chunk.ledgerRange));
      block.writeln(text);
    }
    block.writeln('</recalled_messages>');
    return block.toString().trim();
  }
}

class RecalledMessagesResolution {
  final String? content;
  final Map<String, dynamic> diagnostics;

  const RecalledMessagesResolution({this.content, required this.diagnostics});

  Map<String, dynamic> withCoverage(Map<String, dynamic> coverage) {
    final rawRecall = coverage['rawRecall'];
    return {
      ...coverage,
      'rawRecall': {
        if (rawRecall is Map) ...Map<String, dynamic>.from(rawRecall),
        'finalPacking': diagnostics,
      },
    };
  }
}
