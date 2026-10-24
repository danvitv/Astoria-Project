part of 'native_tool_transport.dart';

/// Pure provider controls, independent of visible reasoning. Never drop an
/// assistant tool envelope/prefill or increase the user's output token bound.
Map<String, Object?> _toolReasoning(ApiConfig c, _ToolProtocol protocol) {
  if (!c.requestReasoning || c.omitReasoning) return const {};
  _ntRequire(
    isValidReasoningEffort(c.reasoningEffort),
    NativeToolReason.invalidRequest,
  );
  final effort = c.omitReasoningEffort
      ? null
      : resolveReasoningEffort(
          protocol: c.protocol,
          effort: c.reasoningEffort,
          model: c.model,
        );
  if (protocol == _ToolProtocol.chat) {
    return {'reasoning_effort': ?effort};
  }
  if (protocol == _ToolProtocol.responses) {
    return {
      'reasoning': {
        'effort': ?effort,
        if (c.showNativeReasoning) 'summary': 'auto',
      },
      // Stateless private replay needs provider-owned encrypted reasoning items.
      'include': ['reasoning.encrypted_content'],
    };
  }
  if (protocol == _ToolProtocol.anthropic) {
    final budget = calculateClaudeBudgetTokens(
      maxTokens: c.maxTokens,
      reasoningEffort: effort ?? 'auto',
      stream: false,
      isAdaptiveModel: isAdaptiveClaudeModel(c.model),
    );
    if (budget is String) {
      return {
        'thinking': {'type': 'adaptive'},
        'output_config': {'effort': budget},
      };
    }
    if (budget is int) {
      _ntRequire(budget < c.maxTokens, NativeToolReason.invalidRequest);
      return {
        'thinking': {'type': 'enabled', 'budget_tokens': budget},
      };
    }
    return const {};
  }
  final budget = calculateGoogleBudgetTokens(
    maxTokens: c.maxTokens,
    reasoningEffort: effort ?? 'auto',
    model: c.model,
  );
  return {
    'thinkingConfig': {
      'includeThoughts': true,
      if (budget is int) 'thinkingBudget': budget,
      if (budget is String) 'thinkingLevel': budget,
    },
  };
}
