import '../tokenizer.dart';
import '../transport/chat_transport_request.dart';
import '../studio/studio_history_limiter.dart';

/// Bounded local budget estimate over the constructed Studio request. This is
/// not provider token accounting and cannot reconstruct upstream history-window
/// decisions from the finished message list.
abstract final class StudioRequestBudgetFacts {
  static const _countLimit = 16777216;
  static const estimatorModes = {
    'o200k_with_item_fallback',
    'heuristic_4_code_units',
  };

  static Map<String, Object?>? fromRequest(
    ChatTransportRequest request, {
    required int contextSize,
    StudioHistorySelectionPlan? historySelection,
  }) {
    if (request.messages.length > 4096 ||
        request.maxTokens < 0 ||
        request.maxTokens > _countLimit ||
        contextSize < 0 ||
        contextSize > _countLimit) {
      return null;
    }
    var estimatedTokens = 0;
    for (final message in request.messages) {
      final content = message['content'];
      if (content is String) {
        estimatedTokens += estimateTokens(content);
      } else if (content is List && content.length <= 65536) {
        for (final part in content) {
          if (part is Map && part['type'] == 'text' && part['text'] is String) {
            estimatedTokens += estimateTokens(part['text'] as String);
          } else if (part is! Map || part['type'] != 'image_url') {
            return null;
          }
        }
      } else {
        return null;
      }
      if (estimatedTokens > _countLimit) return null;
    }
    final promptBudget = (contextSize - request.maxTokens).clamp(
      0,
      contextSize,
    );
    return Map.unmodifiable({
      'configuredContextWindow': contextSize,
      'configuredOutputReserve': request.maxTokens,
      'promptBudget': promptBudget,
      'estimatedRequestTokens': estimatedTokens,
      'estimatedRemainingTokens': promptBudget - estimatedTokens,
      'estimatorMode': o200kBaseLoaded
          ? 'o200k_with_item_fallback'
          : 'heuristic_4_code_units',
      'scope': 'constructed_studio_request_text_only',
      'imageCost': 'unknown_excluded_from_estimate',
      'historyWindowDecision': historySelection == null
          ? 'unknown_upstream_not_reconstructed'
          : 'recorded_exact_local_selection',
      if (historySelection != null) ..._historySelection(historySelection),
    });
  }

  static Map<String, Object?>? validate(Object? value) {
    if (value is! Map<String, Object?> ||
        (value.length != 9 && value.length != 21)) {
      return null;
    }
    for (final key in const {
      'configuredContextWindow',
      'configuredOutputReserve',
      'promptBudget',
      'estimatedRequestTokens',
    }) {
      final number = value[key];
      if (number is! int || number < 0 || number > _countLimit) return null;
    }
    final remaining = value['estimatedRemainingTokens'];
    if (remaining is! int ||
        remaining < -_countLimit ||
        remaining > _countLimit ||
        !estimatorModes.contains(value['estimatorMode']) ||
        value['scope'] != 'constructed_studio_request_text_only' ||
        value['imageCost'] != 'unknown_excluded_from_estimate') {
      return null;
    }
    if ((value.length == 21 &&
            (value['historyWindowDecision'] !=
                    'recorded_exact_local_selection' ||
                !_validateHistorySelection(value))) ||
        (value.length == 9 &&
            (value['historyWindowDecision'] !=
                    'unknown_upstream_not_reconstructed' ||
                value.containsKey('historySelectionPolicy')))) {
      return null;
    }
    final context = value['configuredContextWindow'] as int;
    final reserve = value['configuredOutputReserve'] as int;
    final prompt = value['promptBudget'] as int;
    final estimated = value['estimatedRequestTokens'] as int;
    if (prompt != (context - reserve).clamp(0, context) ||
        remaining != prompt - estimated) {
      return null;
    }
    return Map<String, Object?>.unmodifiable(value);
  }

  static Map<String, Object?> _historySelection(
    StudioHistorySelectionPlan plan,
  ) => Map.unmodifiable({
    'historySelectionPolicy': plan.selectionPolicy,
    'historyConfiguredMessageLimit': plan.configuredMessageLimit,
    'historyTokenBudget': plan.tokenBudget,
    'historyInputMessageCount': plan.inputMessageCount,
    'historySelectedMessageCount': plan.messages.length,
    'historyDroppedMessageCount': plan.inputMessageCount - plan.messages.length,
    'historyInputTextCodeUnits': plan.inputTextCodeUnits,
    'historySelectedTextCodeUnits': plan.selectedTextCodeUnits,
    'historyEstimatedInputTokens': plan.estimatedInputTokens,
    'historyEstimatedSelectedTokens': plan.estimatedSelectedTokens,
    'historyReductionReason': plan.reductionReason,
    'historyContentTransform': 'studio_history_sanitization',
  });

  static bool _validateHistorySelection(Map<String, Object?> value) {
    if (!const {
          'final_stable_window',
          'tracker_tail_window',
          'batch_tail_window',
        }.contains(value['historySelectionPolicy']) ||
        !const {
          'none',
          'message_high_water',
          'token_high_water',
          'message_and_token_high_water',
          'persisted_window_boundary',
        }.contains(value['historyReductionReason']) ||
        value['historyContentTransform'] != 'studio_history_sanitization') {
      return false;
    }
    for (final key in const {
      'historyConfiguredMessageLimit',
      'historyTokenBudget',
      'historyInputMessageCount',
      'historySelectedMessageCount',
      'historyDroppedMessageCount',
      'historyInputTextCodeUnits',
      'historySelectedTextCodeUnits',
      'historyEstimatedInputTokens',
      'historyEstimatedSelectedTokens',
    }) {
      final number = value[key];
      if (number is! int || number < 0 || number > _countLimit) return false;
    }
    final input = value['historyInputMessageCount'] as int;
    final selected = value['historySelectedMessageCount'] as int;
    final dropped = value['historyDroppedMessageCount'] as int;
    final reason = value['historyReductionReason'];
    if (selected > input || dropped != input - selected) return false;
    if ((dropped == 0) != (reason == 'none')) return false;
    if (value['historySelectionPolicy'] != 'final_stable_window' &&
        value['historyTokenBudget'] != 0) {
      return false;
    }
    return true;
  }
}
