/// Provider-neutral deterministic context policy. Estimates are trigger inputs,
/// not request usage. Tool payload rows do not exist in Astoria yet.
abstract final class SupportContextPolicy {
  static bool shouldCompact({
    required int contextSize,
    required int outputReserve,
    required int requestCharacters,
    required int suffixMessages,
    int? measuredInputTokens,
  }) {
    final available = contextSize - outputReserve;
    if (available <= 0) return true;
    return (measuredInputTokens != null &&
            measuredInputTokens >= available * 0.8) ||
        (requestCharacters + 2) ~/ 3 >= available * 0.8 ||
        // Recipe metadata has its own finite context pressure, independent of
        // model tokenization. Rotate before cumulative v2 recipes hit that cap.
        suffixMessages >= 32;
  }

  /// Future payload-pruning seam, separate from LLM summarization. An owning
  /// caller supplies bounded payloads with stable identity; later exact duplicate
  /// evidence supersedes earlier copies, while differing content is retained.
  /// Not connected to imaginary tool-result rows in today's conversation.
  static List<SupportContextPayload> pruneExactDuplicates(
    List<SupportContextPayload> payloads,
  ) {
    final seen = <(String, String)>{};
    return List.unmodifiable(
      payloads.reversed
          .where((p) => seen.add((p.identity, p.text)))
          .toList()
          .reversed,
    );
  }
}

final class SupportContextPayload {
  const SupportContextPayload({required this.identity, required this.text});
  final String identity, text;
}
