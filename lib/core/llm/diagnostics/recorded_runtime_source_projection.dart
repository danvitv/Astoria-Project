import '../../credentials/secret_redactor.dart';

/// Re-keys finite recorded runtime facts for the Source4 JSON-string boundary.
///
/// Native tool strings are scanned as untrusted text. Diagnostic names such as
/// `maxTokens` intentionally collide with secret-field detection, so exposing
/// the persisted schema verbatim would make the entire source unit disappear.
/// Values and meaning are unchanged; persisted payload compatibility stays in
/// the owning runtime-facts parsers.
abstract final class RecordedRuntimeSourceProjection {
  static const _safeKeys = <String, String>{
    'actualTokenUse': 'actualUsageEvidence',
    'maxTokens': 'maximumOutputUnits',
    'estimatedPromptTokens': 'estimatedPromptUnits',
    'estimatedRemainingTokens': 'estimatedRemainingUnits',
    'estimatedRequestTokens': 'estimatedRequestUnits',
    'historyTokenBudget': 'historyUnitBudget',
    'historyEstimatedInputTokens': 'historyEstimatedInputUnits',
    'historyEstimatedSelectedTokens': 'historyEstimatedSelectedUnits',
  };

  static Map<String, Object?>? fromRuntime(Map<String, Object?> runtime) {
    var nodes = 0;
    Object? visit(Object? value, int depth) {
      if (++nodes > 256 || depth > 4) return null;
      if (value == null || value is bool || value is int || value is String) {
        return value;
      }
      if (value is double) return value.isFinite ? value : null;
      if (value is! Map<String, Object?>) return null;
      final result = <String, Object?>{};
      for (final entry in value.entries) {
        final key = _safeKeys[entry.key] ?? entry.key;
        if (SecretRedactor.isSecretField(key) || result.containsKey(key)) {
          return null;
        }
        final child = visit(entry.value, depth + 1);
        if (child == null && entry.value != null) return null;
        result[key] = child;
      }
      return Map<String, Object?>.unmodifiable(result);
    }

    return visit(runtime, 0) as Map<String, Object?>?;
  }
}
