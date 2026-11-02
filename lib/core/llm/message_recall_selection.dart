import 'dart:math' as math;

import '../models/chat_message.dart';
import 'message_recall_result.dart';
import 'vector_math.dart';

class MessageRecallCandidate {
  final String entryId;
  final int chunkIndex;
  final String text;
  final List<double> vector;
  final List<String> messageIds;
  final List<MessageRecallSourceSpan> sourceSpans;

  const MessageRecallCandidate({
    required this.entryId,
    required this.chunkIndex,
    required this.text,
    required this.vector,
    required this.messageIds,
    this.sourceSpans = const [],
  });
}

/// Scores indexed substrings independently. One pass covers distinct groups;
/// a second permits at most one additional excerpt per group, without changing
/// similarity scores, thresholds, top-K or the prompt character budget.
abstract final class MessageRecallSelection {
  static List<MessageRecallMatch> select({
    required List<MessageRecallCandidate> candidates,
    required List<List<double>> queryVectors,
    required double threshold,
    required int topK,
    required int maxChars,
    required Map<String, int> counters,
  }) {
    final scored = <({MessageRecallCandidate candidate, double score})>[];
    for (final candidate in candidates) {
      if (candidate.vector.length != queryVectors.first.length) {
        counters['dimensionMismatch'] = counters['dimensionMismatch']! + 1;
        continue;
      }
      var score = -1.0;
      for (final query in queryVectors) {
        score = math.max(score, cosineSimilarity(query, candidate.vector));
      }
      if (!score.isFinite || score < threshold) continue;
      scored.add((candidate: candidate, score: score));
    }
    counters['aboveThreshold'] = scored.length;
    scored.sort((a, b) {
      final byScore = b.score.compareTo(a.score);
      if (byScore != 0) return byScore;
      final byId = a.candidate.entryId.compareTo(b.candidate.entryId);
      return byId != 0
          ? byId
          : a.candidate.chunkIndex.compareTo(b.candidate.chunkIndex);
    });
    final matches = <MessageRecallMatch>[];
    final counts = <String, int>{};
    final seenTexts = <String>{};
    final processed = <MessageRecallCandidate>{};
    var chars = 0;
    for (var pass = 1; pass <= 2; pass++) {
      for (final item in scored) {
        final candidate = item.candidate;
        if (processed.contains(candidate)) continue;
        if ((counts[candidate.entryId] ?? 0) >= pass) continue;
        processed.add(candidate);
        final fingerprint = candidate.text
            .replaceAll(RegExp(r'\s+'), ' ')
            .trim();
        if (seenTexts.contains(fingerprint)) {
          counters['duplicate'] = counters['duplicate']! + 1;
          continue;
        }
        final text = _attributedText(candidate);
        if (chars + text.length > maxChars) {
          counters['oversized'] = counters['oversized']! + 1;
          continue;
        }
        seenTexts.add(fingerprint);
        matches.add(
          MessageRecallMatch(
            entryId: candidate.entryId,
            chunkIndex: candidate.chunkIndex,
            text: text,
            rawText: candidate.text,
            score: item.score,
            messageIds: candidate.messageIds,
            sourceSpans: candidate.sourceSpans,
          ),
        );
        counts[candidate.entryId] = (counts[candidate.entryId] ?? 0) + 1;
        chars += text.length;
        if (matches.length >= topK) {
          counters['selectedChars'] = chars;
          return matches;
        }
      }
    }
    counters['selectedChars'] = chars;
    return matches;
  }

  static String _attributedText(MessageRecallCandidate candidate) {
    if (candidate.sourceSpans.isEmpty) {
      return '[Raw excerpt; source role/offsets unverified]\n${candidate.text}';
    }
    final sources = candidate.sourceSpans.map(
      (span) =>
          '${span.role} message=${span.messageId} '
          'source=${span.sourceStart}..${span.sourceEnd} '
          'excerpt=${span.excerptStart}..${span.excerptEnd}',
    );
    return '[Verified raw source: ${sources.join('; ')}]\n${candidate.text}';
  }

  /// Called only after the complete formatted group passes its exact textHash
  /// guard. Repeated substrings are ambiguous: never guess their source role.
  static List<MessageRecallSourceSpan> recoverSources(
    String groupedText,
    String excerpt,
    List<ChatMessage> messages,
  ) {
    final start = groupedText.indexOf(excerpt);
    if (start < 0 || groupedText.indexOf(excerpt, start + 1) >= 0) {
      return const [];
    }
    final end = start + excerpt.length;
    final spans = <MessageRecallSourceSpan>[];
    var offset = 0;
    for (final message in messages) {
      final contentStart = offset + message.role.length + 2;
      final contentEnd = contentStart + message.content.length;
      final overlapStart = math.max(start, contentStart);
      final overlapEnd = math.min(end, contentEnd);
      if (overlapStart < overlapEnd) {
        spans.add(
          MessageRecallSourceSpan(
            messageId: message.id,
            role: message.role,
            sourceStart: overlapStart - contentStart,
            sourceEnd: overlapEnd - contentStart,
            excerptStart: overlapStart - start,
            excerptEnd: overlapEnd - start,
          ),
        );
      }
      offset = contentEnd + 2;
    }
    return spans;
  }
}
