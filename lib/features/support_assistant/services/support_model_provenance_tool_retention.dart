part of 'support_model_provenance_codec.dart';

/// Bounded metadata retention, independent of the unchanged v1 range DAG.
abstract final class _ProvenanceToolRetention {
  static List<SupportModelToolDisclosure>? retain(
    List<SupportModelProvenance> recipes,
  ) {
    if (recipes.length >= SupportModelProvenanceLimits.maxRecipeNodes) {
      _reject(SupportModelProvenanceFailure.limitExceeded);
    }
    var aware = false, occurrences = 0;
    final result = <SupportModelToolDisclosure>[];
    final seen =
        <
          (SupportModelToolDisclosureDomain, String, String),
          SupportModelToolDisclosure
        >{};
    for (final recipe in recipes) {
      if (recipe.toolDisclosures == null) continue;
      aware = true;
      // Explicit v4 always requires current-conversation metadata, including an
      // empty list. Unknown versions/shape are rejected by the strict codec.
      if (recipe.currentConversationMessageIds == null) {
        _reject(SupportModelProvenanceFailure.invalidSource);
      }
      for (final item in recipe.toolDisclosures!) {
        occurrences += item.orderedSourceIds.length;
        if (occurrences > SupportModelProvenanceLimits.maxSourceIdOccurrences) {
          _reject(SupportModelProvenanceFailure.limitExceeded);
        }
        final key = (item.domain, item.sourceId, item.snapshotDigest);
        final old = seen[key];
        if (old != null) {
          if (old.operation != item.operation ||
              old.extent != item.extent ||
              old.orderedSourceIds.length != item.orderedSourceIds.length ||
              Iterable<int>.generate(old.orderedSourceIds.length).any(
                (i) => old.orderedSourceIds[i] != item.orderedSourceIds[i],
              )) {
            _reject(SupportModelProvenanceFailure.invalidSource);
          }
          continue;
        }
        if (result.length == SupportModelProvenanceLimits.maxToolDisclosures) {
          _reject(SupportModelProvenanceFailure.limitExceeded);
        }
        seen[key] = item;
        result.add(item);
      }
    }
    return aware ? List.unmodifiable(result) : null;
  }
}
