/// Finite outcomes: an empty index is not an embedding failure or a cancellation.
enum MessageRecallReason {
  notRequested,
  success,
  remoteDisabled,
  endpointNotConfigured,
  emptyQuery,
  emptyIndex,
  noUsableCandidates,
  belowThreshold,
  budgetExhausted,
  dimensionMismatch,
  embeddingEmpty,
  timeout,
  cancelled,
  error,
  invalidLimits,
}

/// Offsets are UTF-16 character offsets into the original message content and
/// the exact indexed excerpt. No character/speaker name is inferred from prose.
class MessageRecallSourceSpan {
  final String messageId;
  final String role;
  final int sourceStart;
  final int sourceEnd;
  final int excerptStart;
  final int excerptEnd;

  const MessageRecallSourceSpan({
    required this.messageId,
    required this.role,
    required this.sourceStart,
    required this.sourceEnd,
    required this.excerptStart,
    required this.excerptEnd,
  });

  Map<String, dynamic> toJson() => {
    'messageId': messageId,
    'role': role,
    'sourceStart': sourceStart,
    'sourceEnd': sourceEnd,
    'excerptStart': excerptStart,
    'excerptEnd': excerptEnd,
  };
}

class MessageRecallMatch {
  final String entryId;

  /// Prompt-facing attribution header followed by the unchanged raw excerpt.
  final String text;
  final String? rawText;
  final double score;

  /// Whole indexed group, retained for conservative final-window exclusion.
  final List<String> messageIds;
  final int chunkIndex;
  final List<MessageRecallSourceSpan> sourceSpans;

  const MessageRecallMatch({
    required this.entryId,
    required this.text,
    required this.score,
    this.rawText,
    this.messageIds = const [],
    this.chunkIndex = 0,
    this.sourceSpans = const [],
  });

  Map<String, dynamic> toJson() => {
    'entryId': entryId,
    'chunkIndex': chunkIndex,
    'score': score,
    'sourceIds': messageIds,
    'attribution': sourceSpans.isEmpty ? 'unverified' : 'exact_source_offsets',
    'sourceSpans': sourceSpans.map((span) => span.toJson()).toList(),
    'chars': text.length,
  };
}

class MessageRecallResult {
  /// All ranked candidates, not an already budget-limited prompt selection.
  /// The consumer must exclude its visible window before packing these.
  final List<MessageRecallMatch> matches;
  final MessageRecallReason reason;

  /// Local diagnostic only: never contains config endpoints or credentials.
  final String query;
  final Map<String, int> counters;

  const MessageRecallResult({
    this.matches = const [],
    this.reason = MessageRecallReason.notRequested,
    this.query = '',
    this.counters = const {},
  });

  bool get isEmpty => matches.isEmpty;

  Map<String, dynamic> toJson() => {
    'stage': 'retrieval_candidates',
    'reason': reason.name,
    'query': query,
    'counters': counters,
    // Do not persist every raw candidate or claim they were all injected.
    'candidateCount': matches.length,
  };
}
