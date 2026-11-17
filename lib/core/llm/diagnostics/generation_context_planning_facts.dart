import '../context_calculator.dart';

/// Finite prompt-budget and history-window facts. No message ids or text leave
/// the prompt builder through this projection.
abstract final class GenerationContextPlanningFacts {
  static const estimatorModes = {
    'o200k_with_item_fallback',
    'heuristic_4_code_units',
  };
  static const trimModes = {'sliding', 'stepped'};
  static const reductionReasons = {
    'none',
    'fixed_context_exhausted',
    'sliding_budget_limit',
    'stepped_window_policy',
  };
  static const _countLimit = 16777216;

  static Map<String, Object?> fromBreakdown({
    required TokenBreakdown breakdown,
    required int contextSize,
    required int outputReserve,
    required String historyTrimMode,
  }) {
    final reduced =
        breakdown.historyInputMessageCount > breakdown.trimmedHistory.length;
    final reason = !reduced
        ? 'none'
        : breakdown.historyBudget <= 0
        ? 'fixed_context_exhausted'
        : historyTrimMode == 'stepped'
        ? 'stepped_window_policy'
        : 'sliding_budget_limit';
    return Map.unmodifiable({
      'configuredContextWindow': contextSize,
      'configuredOutputReserve': outputReserve,
      'promptBudget': (contextSize - outputReserve).clamp(0, contextSize),
      'historyBudget': breakdown.historyBudget,
      'estimatedPromptTokens': breakdown.totalTokens,
      'estimatedRemainingTokens': breakdown.remaining,
      'estimatorMode': breakdown.tokenEstimatorMode,
      'historyTrimMode': historyTrimMode,
      'historyMessagesBefore': breakdown.historyInputMessageCount,
      'historyMessagesAfter': breakdown.trimmedHistory.length,
      'historyTextCodeUnitsBefore': breakdown.historyInputTextCodeUnits,
      'historyTextCodeUnitsAfter': breakdown.historyKeptTextCodeUnits,
      'historyCutoffCount': breakdown.cutoffIndex,
      'reductionReason': reason,
    });
  }

  static Map<String, Object?>? validate(Object? value) {
    if (value is! Map<String, Object?> || value.length != 14) return null;
    for (final key in const {
      'configuredContextWindow',
      'configuredOutputReserve',
      'promptBudget',
      'historyMessagesBefore',
      'historyMessagesAfter',
      'historyTextCodeUnitsBefore',
      'historyTextCodeUnitsAfter',
      'historyCutoffCount',
    }) {
      final number = value[key];
      if (number is! int || number < 0 || number > _countLimit) return null;
    }
    for (final key in const {
      'historyBudget',
      'estimatedPromptTokens',
      'estimatedRemainingTokens',
    }) {
      final number = value[key];
      if (number is! int || number < -_countLimit || number > _countLimit) {
        return null;
      }
    }
    if (!estimatorModes.contains(value['estimatorMode']) ||
        !trimModes.contains(value['historyTrimMode']) ||
        !reductionReasons.contains(value['reductionReason'])) {
      return null;
    }
    final before = value['historyMessagesBefore'] as int;
    final after = value['historyMessagesAfter'] as int;
    final cutoff = value['historyCutoffCount'] as int;
    final charsBefore = value['historyTextCodeUnitsBefore'] as int;
    final charsAfter = value['historyTextCodeUnitsAfter'] as int;
    final expectedReason = before == after
        ? 'none'
        : (value['historyBudget'] as int) <= 0
        ? 'fixed_context_exhausted'
        : value['historyTrimMode'] == 'stepped'
        ? 'stepped_window_policy'
        : 'sliding_budget_limit';
    if (after > before ||
        charsAfter > charsBefore ||
        cutoff != before - after ||
        value['reductionReason'] != expectedReason) {
      return null;
    }
    return Map<String, Object?>.unmodifiable(value);
  }
}
