/// One stage in the Studio pipeline: a tracker brief or the final generator
/// response. Carries cache metadata so the orchestrator can decide whether to
/// skip the LLM call for a cached tracker.
///
/// Pure DTO — no dependencies. Extracted from `memory_studio_service.dart` so
/// the brief cache, deduper, and service can all reference it without import
/// cycles.
class StudioStageBrief {
  final String agentId;
  final String agentName;
  final String brief;
  final String status;
  final String? error;
  final String refreshPolicy;
  final String? cacheKey;
  final bool cacheHit;

  /// True when this brief is a `think-replacement` controller's raw
  /// `<thinking>` block. Such a brief is seeded as the final generator's
  /// reasoning rather than injected as an ordinary brief, and must not be
  /// sanitized down to a compact controller summary.
  final bool isThinkReplacement;

  /// Provider-native reasoning from the Think controller, when available.
  /// Kept separate from [brief], the visible block seeded into the writer.
  final String nativeReasoning;

  const StudioStageBrief({
    required this.agentId,
    required this.agentName,
    required this.brief,
    this.status = 'ok',
    this.error,
    this.refreshPolicy = 'turn',
    this.cacheKey,
    this.cacheHit = false,
    this.isThinkReplacement = false,
    this.nativeReasoning = '',
  });

  StudioStageBrief copyWithCacheMetadata({
    required String refreshPolicy,
    String? cacheKey,
    bool cacheHit = false,
  }) {
    return StudioStageBrief(
      agentId: agentId,
      agentName: agentName,
      brief: brief,
      status: status,
      error: error,
      refreshPolicy: refreshPolicy,
      cacheKey: cacheKey,
      cacheHit: cacheHit,
      isThinkReplacement: isThinkReplacement,
      nativeReasoning: nativeReasoning,
    );
  }
}
