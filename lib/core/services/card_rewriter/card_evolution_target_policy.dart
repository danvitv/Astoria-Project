import 'dart:convert';

import 'card_rewriter_contracts.dart';

/// Shared destination fence for writer checkpoints and durable finalization.
/// The input must retain every selected observation, including lore-only ones.
abstract final class CardEvolutionTargetPolicy {
  /// Exact retrieval keys already materialized in the selected input. Only
  /// operation keys are normalized when matching, as in the finalizer fence.
  static Set<String> targetKeys(String selectedInputJson) {
    try {
      final input = jsonDecode(selectedInputJson) as Map;
      final observations = input['accumulatedObservations'];
      if (observations is! List) return const {};
      return {
        for (final observation in observations)
          if (observation is Map &&
              observation['targetKind'] == 'injected_lorebook_entry' &&
              observation['retrievalKeys'] is List)
            for (final key in observation['retrievalKeys'] as List)
              if (key is String) key,
      };
    } catch (_) {
      return const {};
    }
  }

  /// Exactly the Ledger group grammar used for selected observation identities.
  /// No case folding, translation, or fallback to a different identity.
  static String? normalizeGroup(String key) {
    if (key.startsWith('npc:') || key.startsWith('arc:')) {
      final dot = key.lastIndexOf('.');
      final group = dot > key.indexOf(':') + 1 ? key.substring(0, dot) : key;
      return CardRewriteScope.tryParse(group)?.key;
    }
    if (key.startsWith('relationship:')) {
      final dot = key.lastIndexOf('.');
      final group = dot > 'relationship:'.length ? key.substring(0, dot) : key;
      return CardRewriteScope.tryParse(group)?.key;
    }
    return CardRewriteScope.tryParse(key)?.key;
  }

  /// A lore-only identity cannot be promoted by a card patch, even when its
  /// tracker or knowledge fact remains available as factual writer context.
  static String? explainFailure(
    Iterable<CardRewriteOperationSnapshot> operations,
    String selectedInputJson,
  ) {
    final forbidden = targetKeys(selectedInputJson);
    for (final operation in operations) {
      final keys = <(String, String)>[
        ('transition.scopeKey', operation.transition.scopeKey),
        for (final key in operation.transition.affectedTrackerKeys)
          ('transition.affectedTrackerKeys', key),
        for (final patch in operation.patches)
          ('patch.scopeKey', patch.scopeKey),
      ];
      for (final (path, key) in keys) {
        final group = normalizeGroup(key);
        if (forbidden.contains(group)) {
          return '${operation.field.wireName}: invalidCardObservationTarget: '
              '$path "$key" resolves to lore-only retrieval target "$group". '
              'This target belongs to an injected lorebook entry, not a card '
              'field; remove the card operation and leave its facts for the '
              'lorebook writer.';
        }
      }
    }
    return null;
  }
}
