import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_evolution_target_policy.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';

void main() {
  String input(List<String> keys) => jsonEncode({
    'accumulatedObservations': [
      {'targetKind': 'injected_lorebook_entry', 'retrievalKeys': keys},
      {
        'targetKind': 'card_field',
        'retrievalKeys': ['npc:allowed'],
      },
    ],
  });

  CardRewriteOperationSnapshot operation({
    String scope = 'npc:allowed',
    String? patchScope,
    List<String> trackers = const [],
  }) => CardRewriteOperationSnapshot(
    field: CardRewriteField.description,
    patches: [
      AnchoredScalarPatch(
        scopeKey: patchScope ?? scope,
        field: CardRewriteField.description,
        anchor: 'old description',
        anchorSha256: CardCanonicalizer.scalarSha256('old description'),
        value: 'new description',
      ),
    ],
    transition: CardRewriteTransitionSnapshot(
      id: 'transition',
      scopeKey: scope,
      canonicalClaim: 'new description',
      promotionDestination: 'description',
      affectedTrackerKeys: trackers,
    ),
  );

  test('extracts only exact selected lore observation retrieval keys', () {
    expect(CardEvolutionTargetPolicy.targetKeys(input(['npc:алиса'])), {
      'npc:алиса',
    });
    expect(CardEvolutionTargetPolicy.targetKeys('{}'), isEmpty);
    expect(CardEvolutionTargetPolicy.targetKeys('not json'), isEmpty);
  });

  test('normalizes Ledger groups without changing RP identities', () {
    for (final (key, group) in <(String, String?)>[
      ('npc:алиса.attitude', 'npc:алиса'),
      ('arc:engagement.status', 'arc:engagement'),
      ('relationship:алиса:борис.trust', 'relationship:алиса:борис'),
      ('world:setting', 'world:setting'),
      ('scene.current.location', 'scene.current.location'),
      ('npc:Алиса', 'npc:Алиса'),
      ('npc:bad.identity.field', null),
      ('world:setting.status', null),
      ('relationship:алиса.status', null),
    ]) {
      expect(CardEvolutionTargetPolicy.normalizeGroup(key), group, reason: key);
    }
  });

  test('screens transition, affected trackers, and patch destinations', () {
    final context = input(['npc:алиса', 'relationship:алиса:борис']);
    expect(
      CardEvolutionTargetPolicy.explainFailure([
        operation(scope: 'npc:алиса'),
      ], context),
      allOf(
        contains('invalidCardObservationTarget'),
        contains('transition.scopeKey'),
      ),
    );
    expect(
      CardEvolutionTargetPolicy.explainFailure([
        operation(trackers: ['relationship:алиса:борис.trust']),
      ], context),
      allOf(
        contains('transition.affectedTrackerKeys'),
        contains('relationship:алиса:борис'),
      ),
    );
    expect(
      CardEvolutionTargetPolicy.explainFailure([
        operation(patchScope: 'npc:алиса'),
      ], context),
      contains('patch.scopeKey'),
    );
    expect(
      CardEvolutionTargetPolicy.explainFailure([operation()], context),
      isNull,
    );
    expect(CardEvolutionTargetPolicy.explainFailure([], context), isNull);
  });

  test('does not case-fold or broaden selected retrieval keys', () {
    expect(
      CardEvolutionTargetPolicy.explainFailure([
        operation(scope: 'npc:Алиса'),
      ], input(['npc:алиса'])),
      isNull,
    );
    // Selected input already groups observation keys. Do not add an alternate
    // matching rule that would disagree with the fail-closed finalizer.
    expect(
      CardEvolutionTargetPolicy.explainFailure([
        operation(scope: 'npc:алиса'),
      ], input(['npc:алиса.attitude'])),
      isNull,
    );
  });
}
