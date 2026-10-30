import 'dart:convert';

import 'card_evolution_target_policy.dart';
import 'card_rewriter_contracts.dart';

/// Explicit recovery of append-only card edits assigned to a unique lore entry.
/// Never guesses a destination or rewrites a fact. Unsupported edits require a
/// model repair instead. The output is a proposal, not an applied canon change.
abstract final class SavedCardLorebookRerouter {
  static List<LorebookRewriteOperationSnapshot> reroute({
    required List<CardRewriteOperationSnapshot> cardOperations,
    required List<LorebookRewriteOperationSnapshot> loreOperations,
    required String selectedInputJson,
  }) {
    final input = jsonDecode(selectedInputJson) as Map;
    final observations = input['accumulatedObservations'] as List;
    final targets = <String, Map<dynamic, dynamic>>{
      for (final raw in input['injectedLorebookEntries'] as List)
        if (raw is Map) '${raw['lorebookId']}:${raw['entryId']}': raw,
    };
    final result = <String, LorebookRewriteOperationSnapshot>{};
    for (final operation in loreOperations) {
      final key = '${operation.lorebookId}:${operation.entryId}';
      if (result.containsKey(key)) {
        throw const FormatException('Duplicate saved lore target');
      }
      result[key] = operation;
    }
    for (final operation in cardOperations) {
      if (CardEvolutionTargetPolicy.explainFailure([
            operation,
          ], selectedInputJson) ==
          null) {
        throw const FormatException(
          'Recovery cannot discard a valid card edit',
        );
      }
      final scope = CardEvolutionTargetPolicy.normalizeGroup(
        operation.transition.scopeKey,
      );
      final destinations = <String>{
        for (final observation in observations)
          if (observation is Map &&
              observation['targetKind'] == 'injected_lorebook_entry' &&
              observation['retrievalKeys'] is List &&
              (observation['retrievalKeys'] as List).contains(scope) &&
              observation['lorebookEntryId'] is String)
            observation['lorebookEntryId'] as String,
      };
      if (scope == null || destinations.length != 1) {
        throw const FormatException(
          'Ambiguous or missing saved card destination',
        );
      }
      final key = destinations.single;
      final target = targets[key];
      if (target == null ||
          target['content'] is! String ||
          target['expectedContentHash'] is! String) {
        throw const FormatException(
          'Destination is not selected lore evidence',
        );
      }
      final content = target['content'] as String;
      final hash = target['expectedContentHash'] as String;
      if (CardCanonicalizer.scalarSha256(content) != hash) {
        throw const FormatException(
          'Selected lore content fingerprint mismatch',
        );
      }
      final existing = result[key];
      if (existing != null &&
          (existing.expectedContentHash != hash ||
              existing.baseContent != (target['baseContent'] ?? content))) {
        throw const FormatException('Saved lore target differs from selected evidence');
      }
      var value = existing == null
          ? content
          : applySavedPatches(existing, content);
      for (final patch in operation.patches) {
        if (CardEvolutionTargetPolicy.normalizeGroup(patch.scopeKey) != scope ||
            !patch.value.startsWith(patch.anchor) ||
            !AnchoredScalarPatchValidator.preservesMacroTokens(
              patch.anchor,
              patch.value,
            )) {
          throw const FormatException('Saved card edit is not a safe append');
        }
        final addition = patch.value.substring(patch.anchor.length).trim();
        if (addition.isEmpty) {
          throw const FormatException('Saved card edit has no new text');
        }
        if (!value.contains(addition)) value = '$value\n\n$addition';
      }
      if (!AnchoredScalarPatchValidator.preservesMacroTokens(content, value)) {
        throw const FormatException('Reroute changed lore macro tokens');
      }
      result[key] = LorebookRewriteOperationSnapshot(
        lorebookId: target['lorebookId'] as String,
        entryId: target['entryId'] as String,
        baseContent: (target['baseContent'] ?? content) as String,
        expectedContentHash: hash,
        patches: [
          LorebookAnchoredPatch(
            anchor: content,
            anchorSha256: hash,
            value: value,
          ),
        ],
      );
    }
    // Unaffected saved targets remain byte-identical; no old response is edited.
    return result.values.toList(growable: false);
  }

  static String applySavedPatches(
    LorebookRewriteOperationSnapshot operation,
    String content,
  ) {
    final spans = <(int, int, String)>[];
    for (final patch in operation.patches) {
      final start = content.indexOf(patch.anchor);
      if (patch.anchor.isEmpty ||
          start < 0 ||
          content.indexOf(patch.anchor, start + 1) >= 0 ||
          CardCanonicalizer.scalarSha256(patch.anchor) != patch.anchorSha256 ||
          !AnchoredScalarPatchValidator.preservesMacroTokens(
            patch.anchor,
            patch.value,
          )) {
        throw const FormatException(
          'Saved lore anchor is invalid or ambiguous',
        );
      }
      spans.add((start, start + patch.anchor.length, patch.value));
    }
    spans.sort((a, b) => a.$1.compareTo(b.$1));
    for (var index = 1; index < spans.length; index++) {
      if (spans[index - 1].$2 > spans[index].$1) {
        throw const FormatException('Saved lore patches overlap');
      }
    }
    var value = content;
    for (final (start, end, replacement) in spans.reversed) {
      value = value.replaceRange(start, end, replacement);
    }
    return value;
  }
}
