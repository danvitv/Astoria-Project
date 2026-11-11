import '../models/chat_message.dart';

/// A compact window of recent turns used as the vector retrieval query.
///
/// Both the live injection service and the isolate worker can build this
/// without touching each other. The output is plain text (no roles, no
/// metadata) so the embedding API sees only the actual retrieval cue.
class RetrievalQueryBuilder {
  const RetrievalQueryBuilder._();

  static const _emotionalPatterns = <String, List<String>>{
    'grief': ['grief', 'grieved', 'mourning', 'mourn', 'sorrow', 'lament'],
    'betrayal': ['betray', 'betrayed', 'betrayal', 'backstab'],
    'tension': ['tension', 'tense', 'suspicion', 'suspicious', 'distrust'],
    'dread': ['dread', 'dreaded', 'horror', 'terror', 'afraid', 'fear'],
    'joy': ['joy', 'joyful', 'happiness', 'happy', 'elated', 'triumph'],
    'resolve': ['resolve', 'resolved', 'determination', 'determined'],
    'humor': ['humor', 'humorous', 'laugh', 'laughed', 'amused', 'witty'],
    'intimacy': ['intimacy', 'intimate', 'tender', 'caress', 'embrace'],
  };

  /// Extract emotional context tags from a text string (Phase G2).
  ///
  /// Uses the same regex vocabulary as [MemorySalienceScorer] so that
  /// emotional recall in fusion can match entry salience tags.
  static List<String> extractEmotionalContext(String text) {
    final lower = text.toLowerCase();
    final tags = <String>[];
    for (final entry in _emotionalPatterns.entries) {
      if (entry.value.any((p) => lower.contains(p))) {
        tags.add(entry.key);
      }
    }
    return tags;
  }

  /// Build the retrieval query from the most recent turns.
  ///
  /// Rules:
  /// - Always include [currentText] (latest user/edited message) first.
  /// - If [includeAssistant] is true (default), include the most recent
  ///   assistant turn that is not hidden/typing/empty.
  /// - Then walk backwards through the [history] collecting up to
  ///   [recentTurns] user/assistant turns (each counts as 1 turn).
  /// - Stop once the accumulated text exceeds [maxChars]; the cap is
  ///   inclusive of the prefix/current text.
  /// - Hidden/typing/empty messages are skipped.
  /// - Output is single-line, trimmed, ready to embed.
  static String build({
    required String currentText,
    required List<ChatMessage> history,
    bool includeAssistant = true,
    int recentTurns = 6,
    int maxChars = 1500,
  }) {
    if (maxChars <= 0) return currentText.trim();
    final buffer = StringBuffer();
    var used = 0;
    final includedHistoryIds = <String>{};

    bool append(String chunk) {
      chunk = chunk.trim();
      if (chunk.isEmpty) return false;
      final separatorLength = used == 0 ? 0 : 1;
      final available = maxChars - used - separatorLength;
      if (available <= 0) return false;
      final fitted = _fitChunk(chunk, available);
      if (fitted.isEmpty) return false;
      if (used == 0) {
        buffer.write(fitted);
      } else {
        buffer.write('\n$fitted');
      }
      used += fitted.length + separatorLength;
      return true;
    }

    append(currentText.trim());

    if (includeAssistant) {
      for (int i = history.length - 1; i >= 0; i--) {
        final msg = history[i];
        if (msg.isHidden || msg.isTyping) continue;
        if (msg.role != 'assistant') continue;
        if (msg.content.trim().isEmpty) continue;
        if (append(msg.content)) includedHistoryIds.add(msg.id);
        break;
      }
    }

    if (recentTurns > 0) {
      var turns = 0;
      for (int i = history.length - 1; i >= 0; i--) {
        if (turns >= recentTurns) break;
        final msg = history[i];
        if (msg.isHidden || msg.isTyping) continue;
        if (includedHistoryIds.contains(msg.id)) continue;
        // When includeAssistant is false, restrict the recent window to
        // user turns only — the assistant was already a noisy signal in
        // the current build's vector search.
        if (!includeAssistant && msg.role != 'user') continue;
        if (msg.role != 'user' && msg.role != 'assistant') continue;
        if (msg.content.trim().isEmpty) continue;
        if (append(msg.content)) includedHistoryIds.add(msg.id);
        turns++;
      }
    }

    return buffer.toString().trim();
  }

  /// Fits an oversized turn without dropping it entirely. Keeping both ends
  /// preserves the setup and the latest conclusions, which commonly contain
  /// the entities and state changes needed by retrieval.
  static String _fitChunk(String chunk, int available) {
    if (available <= 0) return '';
    if (chunk.length <= available) return chunk;
    if (available < 7) return chunk.substring(0, available);

    const separator = ' … ';
    final payload = available - separator.length;
    final headLength = (payload + 1) ~/ 2;
    final tailLength = payload - headLength;
    return '${chunk.substring(0, headLength)}$separator'
        '${chunk.substring(chunk.length - tailLength)}';
  }
}
