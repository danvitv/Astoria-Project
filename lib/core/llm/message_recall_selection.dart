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
  final int sourceOrdinal;

  const MessageRecallCandidate({
    required this.entryId,
    required this.chunkIndex,
    required this.text,
    required this.vector,
    required this.messageIds,
    this.sourceSpans = const [],
    this.sourceOrdinal = -1,
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
    String queryText = '',
    Set<String> participantAliases = const {},
  }) {
    final querySignals = _ContinuitySignals.from(queryText, participantAliases);
    final maxOrdinal = candidates.fold<int>(
      -1,
      (max, candidate) => math.max(max, candidate.sourceOrdinal),
    );
    final scored =
        <
          ({MessageRecallCandidate candidate, double score, double continuity})
        >[];
    for (final candidate in candidates) {
      if (candidate.vector.length != queryVectors.first.length) {
        counters['dimensionMismatch'] = counters['dimensionMismatch']! + 1;
        continue;
      }
      var semanticScore = -1.0;
      for (final query in queryVectors) {
        semanticScore = math.max(
          semanticScore,
          cosineSimilarity(query, candidate.vector),
        );
      }
      if (!semanticScore.isFinite) continue;
      final continuity = querySignals.score(candidate.text);
      if (semanticScore < threshold && continuity < 0.45) continue;
      final recency = maxOrdinal <= 0 || candidate.sourceOrdinal < 0
          ? 0.0
          : candidate.sourceOrdinal / maxOrdinal;
      // Semantic similarity remains the primary signal. Strong same-actor,
      // same-action lexical evidence can lift a source above merely topical
      // matches, while recency only breaks otherwise-close candidates.
      final score = semanticScore + continuity * 0.45 + recency * 0.025;
      scored.add((candidate: candidate, score: score, continuity: continuity));
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
          continuityScore: item.continuity,
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

  static final _wordPattern = RegExp(r'[\p{L}\p{N}]+', unicode: true);
}

final class _ContinuitySignals {
  final Set<String> terms;
  final Set<String> ngrams;
  final Set<String> aliases;

  const _ContinuitySignals(this.terms, this.ngrams, this.aliases);

  factory _ContinuitySignals.from(String text, Set<String> knownAliases) {
    final lower = text.toLowerCase();
    final aliases = knownAliases
        .map((alias) => alias.trim().toLowerCase())
        .where((alias) => alias.length >= 2 && _containsWhole(lower, alias))
        .toSet();
    final terms = MessageRecallSelection._wordPattern
        .allMatches(lower)
        .map((match) => _stem(match.group(0)!))
        .where((term) => term.length >= 4 && !_stopwords.contains(term))
        .toSet();
    return _ContinuitySignals(terms, _ngrams(terms), aliases);
  }

  double score(String candidateText) {
    if (terms.isEmpty && aliases.isEmpty) return 0;
    final lower = candidateText.toLowerCase();
    final candidateTerms = MessageRecallSelection._wordPattern
        .allMatches(lower)
        .map((match) => _stem(match.group(0)!))
        .where((term) => term.length >= 4 && !_stopwords.contains(term))
        .toSet();
    final termOverlap = terms.intersection(candidateTerms).length;
    final queryNgrams = ngrams;
    final candidateNgrams = _ngrams(candidateTerms);
    final ngramOverlap = queryNgrams.isEmpty
        ? 0.0
        : queryNgrams.intersection(candidateNgrams).length / queryNgrams.length;
    final aliasHits = aliases
        .where((alias) => _containsWhole(lower, alias))
        .length;
    final aliasCoverage = aliases.isEmpty ? 0.0 : aliasHits / aliases.length;
    final termCoverage = terms.isEmpty
        ? 0.0
        : termOverlap / math.min(terms.length, 6);
    return (aliasCoverage * 0.45 +
            termCoverage.clamp(0.0, 1.0) * 0.25 +
            ngramOverlap.clamp(0.0, 1.0) * 0.30)
        .clamp(0.0, 1.0);
  }

  static bool _containsWhole(String text, String value) => RegExp(
    '(^|[^\\p{L}\\p{N}_])${RegExp.escape(value)}([^\\p{L}\\p{N}_]|\$)',
    unicode: true,
  ).hasMatch(text);

  static String _stem(String value) {
    var out = value.toLowerCase().replaceAll('ё', 'е');
    // Deliberately modest normalization: enough for common Russian inflection
    // (`шлепая`/`шлепнул`) without pretending to be a full morphological model.
    for (final suffix in _suffixes) {
      if (out.length - suffix.length >= 4 && out.endsWith(suffix)) {
        out = out.substring(0, out.length - suffix.length);
        break;
      }
    }
    return out;
  }

  static Set<String> _ngrams(Set<String> terms) {
    final result = <String>{};
    for (final term in terms) {
      if (term.length < 3) continue;
      for (var i = 0; i <= term.length - 3; i++) {
        result.add(term.substring(i, i + 3));
      }
    }
    return result;
  }

  static const _suffixes = <String>[
    'иями',
    'ями',
    'ами',
    'ого',
    'ему',
    'ому',
    'ыми',
    'ими',
    'ая',
    'яя',
    'ую',
    'юю',
    'ый',
    'ий',
    'ой',
    'ое',
    'ее',
    'ые',
    'ие',
    'нул',
    'нула',
    'нули',
    'ать',
    'ять',
    'ить',
    'еть',
    'ая',
    'яя',
    'ами',
    'ями',
    'ах',
    'ях',
    'ом',
    'ем',
    'ов',
    'ев',
    'ей',
    'а',
    'я',
    'ы',
    'и',
    'у',
    'ю',
    'е',
    'о',
  ];

  static const _stopwords = <String>{
    'этот',
    'того',
    'котор',
    'свой',
    'тебя',
    'меня',
    'было',
    'будет',
    'просто',
    'когда',
    'после',
    'тогда',
    'здесь',
    'очень',
    'снова',
    'with',
    'that',
    'this',
    'from',
    'have',
    'were',
    'when',
    'then',
  };
}
