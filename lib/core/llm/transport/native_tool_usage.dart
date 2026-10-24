part of 'native_tool_transport.dart';

/// Same exported numeric DTO as private text, extracted only from returned JSON.
/// Invalid/absent individual counters remain unknown; no arithmetic inference.
ProviderTokenUsage? _toolUsage(
  _ToolProtocol protocol,
  Map<String, Object?> root,
) {
  final raw =
      root[protocol == _ToolProtocol.gemini ? 'usageMetadata' : 'usage'];
  if (raw is! Map) return null;
  int? counter(Object? value) =>
      value is int &&
          value >= 0 &&
          value <= ProviderTokenUsage.maxReportedTokens
      ? value
      : null;
  Object? nested(String field, String child) =>
      raw[field] is Map ? (raw[field] as Map)[child] : null;
  final usage = switch (protocol) {
    _ToolProtocol.chat => ProviderTokenUsage(
      inputTokens: counter(raw['prompt_tokens']),
      outputTokens: counter(raw['completion_tokens']),
      totalTokens: counter(raw['total_tokens']),
      cachedInputTokens: counter(
        nested('prompt_tokens_details', 'cached_tokens'),
      ),
      reasoningTokens: counter(
        nested('completion_tokens_details', 'reasoning_tokens'),
      ),
    ),
    _ToolProtocol.responses => ProviderTokenUsage(
      inputTokens: counter(raw['input_tokens']),
      outputTokens: counter(raw['output_tokens']),
      totalTokens: counter(raw['total_tokens']),
      cachedInputTokens: counter(
        nested('input_tokens_details', 'cached_tokens'),
      ),
      reasoningTokens: counter(
        nested('output_tokens_details', 'reasoning_tokens'),
      ),
    ),
    _ToolProtocol.anthropic => ProviderTokenUsage(
      inputTokens: counter(raw['input_tokens']),
      outputTokens: counter(raw['output_tokens']),
      totalTokens: counter(raw['total_tokens']),
      cachedInputTokens: counter(raw['cache_read_input_tokens']),
      cacheCreationInputTokens: counter(raw['cache_creation_input_tokens']),
    ),
    _ToolProtocol.gemini => ProviderTokenUsage(
      inputTokens: counter(raw['promptTokenCount']),
      outputTokens: counter(raw['candidatesTokenCount']),
      totalTokens: counter(raw['totalTokenCount']),
      cachedInputTokens: counter(raw['cachedContentTokenCount']),
      reasoningTokens: counter(raw['thoughtsTokenCount']),
    ),
  };
  return usage.hasReportedTokens ? usage : null;
}
