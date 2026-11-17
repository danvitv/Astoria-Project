import '../tokenizer.dart';
import '../transport/chat_transport_request.dart';

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
      'historyWindowDecision': 'unknown_upstream_not_reconstructed',
    });
  }

  static Map<String, Object?>? validate(Object? value) {
    if (value is! Map<String, Object?> || value.length != 9) return null;
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
        value['imageCost'] != 'unknown_excluded_from_estimate' ||
        value['historyWindowDecision'] !=
            'unknown_upstream_not_reconstructed') {
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
}
