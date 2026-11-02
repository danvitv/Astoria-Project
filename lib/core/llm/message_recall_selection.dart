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

/// Scores indexed substrings independently, without spending the request budget.
/// Packing belongs to the consumer, after its visible history window is frozen.
abstract final class MessageRecallSelection {
  static List<MessageRecallMatch> rank({
    required List<MessageRecallCandidate> candidates,
    required List<List<double>> queryVectors,
    required double threshold,
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
    return [
      for (final item in scored)
        MessageRecallMatch(
          entryId: item.candidate.entryId,
          chunkIndex: item.candidate.chunkIndex,
          text: _attributedText(item.candidate),
          rawText: item.candidate.text,
          score: item.score,
          messageIds: item.candidate.messageIds,
          sourceSpans: item.candidate.sourceSpans,
        ),
    ];
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
    List<ChatMessage> messages, {
    int? groupStart,
  }) {
    final start = groupStart ?? groupedText.indexOf(excerpt);
    if (start < 0 ||
        start + excerpt.length > groupedText.length ||
        groupedText.substring(start, start + excerpt.length) != excerpt ||
        (groupStart == null && groupedText.indexOf(excerpt, start + 1) >= 0)) {
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
