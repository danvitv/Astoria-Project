/// Provider-reported counters for one request, never estimates or chat totals.
/// Cache/reasoning counters retain their provider meaning; they are not added
/// to input/output, and a missing total is never reconstructed.
final class ProviderTokenUsage {
  factory ProviderTokenUsage({
    int? inputTokens,
    int? outputTokens,
    int? totalTokens,
    int? cachedInputTokens,
    int? cacheCreationInputTokens,
    int? reasoningTokens,
  }) => ProviderTokenUsage._(
    inputTokens: _bounded(inputTokens),
    outputTokens: _bounded(outputTokens),
    totalTokens: _bounded(totalTokens),
    cachedInputTokens: _bounded(cachedInputTokens),
    cacheCreationInputTokens: _bounded(cacheCreationInputTokens),
    reasoningTokens: _bounded(reasoningTokens),
  );

  const ProviderTokenUsage._({
    this.inputTokens,
    this.outputTokens,
    this.totalTokens,
    this.cachedInputTokens,
    this.cacheCreationInputTokens,
    this.reasoningTokens,
  });

  /// Defensive ceiling, not the selected model's context or output limit.
  static const maxReportedTokens = 0x7fffffff;

  /// Last request's reported input, not accumulated assistant output. Some
  /// providers report cache input separately; do not silently add it here.
  final int? inputTokens;
  final int? outputTokens;
  final int? totalTokens;
  final int? cachedInputTokens;
  final int? cacheCreationInputTokens;
  final int? reasoningTokens;

  bool get hasReportedTokens =>
      inputTokens != null ||
      outputTokens != null ||
      totalTokens != null ||
      cachedInputTokens != null ||
      cacheCreationInputTokens != null ||
      reasoningTokens != null;

  /// Merge cumulative snapshots of this SAME request. The latest valid report
  /// replaces each field (including zero); missing fields keep prior evidence.
  /// Even a downward revision is preserved exactly, not replaced by a maximum.
  ProviderTokenUsage mergeSnapshot(ProviderTokenUsage newer) =>
      ProviderTokenUsage._(
        inputTokens: newer.inputTokens ?? inputTokens,
        outputTokens: newer.outputTokens ?? outputTokens,
        totalTokens: newer.totalTokens ?? totalTokens,
        cachedInputTokens: newer.cachedInputTokens ?? cachedInputTokens,
        cacheCreationInputTokens:
            newer.cacheCreationInputTokens ?? cacheCreationInputTokens,
        reasoningTokens: newer.reasoningTokens ?? reasoningTokens,
      );

  static int? _bounded(int? value) =>
      value != null && value >= 0 && value <= maxReportedTokens ? value : null;

  @override
  String toString() => 'ProviderTokenUsage';
}
