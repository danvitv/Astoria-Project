import '../models/api_config.dart';
import 'context_calculator.dart';

/// Keep explicit unlimited output (0/-1) semantics; cap only positive budgets.
int clampMaxOutputTokens(int maxTokens, int contextSize) =>
    contextSize > 0 && maxTokens > contextSize ? contextSize : maxTokens;

bool promptFitsContext(
  ApiConfig config,
  TokenBreakdown breakdown, {
  String? requiredMessageId,
}) {
  if (config.contextSize <= 0) return true;
  final available = config.contextSize - config.maxTokens;
  if (available <= 0 ||
      breakdown.fixedTotal > available ||
      breakdown.totalTokens > available) {
    return false;
  }
  return requiredMessageId == null ||
      breakdown.trimmedHistory.any(
        (message) => message.sourceMessageId == requiredMessageId,
      );
}
