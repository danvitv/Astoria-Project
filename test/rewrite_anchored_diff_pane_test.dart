import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_provider.dart';
import 'package:glaze_flutter/features/card_rewrite/widgets/rewrite_anchored_diff_pane.dart';

import 'helpers/pump_localized.dart';

void main() {
  const patch = AnchoredScalarPatch(
    scopeKey: 'npc:hero',
    field: CardRewriteField.description,
    anchor: 'Old description fragment',
    anchorSha256: 'hash',
    value: 'New description fragment',
  );

  const snapshot = CardRewriteOperationSnapshot(
    field: CardRewriteField.description,
    patches: [patch],
    transition: CardRewriteTransitionSnapshot(
      id: 'transition',
      scopeKey: 'npc:hero',
      canonicalClaim: 'claim',
      promotionDestination: 'card',
      affectedTrackerKeys: [],
    ),
  );

  ManualRewriteOperationView operation(String status) =>
      ManualRewriteOperationView(
        operation: RewriteOperationRow(
          id: 'operation',
          rewriteJobId: 'job',
          chatSessionId: 'session',
          operationJson: '',
          status: status,
          currentRevision: 1,
          decision: 'approved',
          validationStatus: 'valid',
          decisionRevision: 1,
          appliedCharacterRevision: 2,
          appliedCharacterRevisionHash: 'hash',
          createdAt: 1,
          updatedAt: 2,
        ),
        currentSnapshotJson: '',
        evidenceCount: 0,
      );

  test('committed patches never get live-card advisory warnings', () {
    const card = Character(
      id: 'hero',
      name: 'Hero',
      description: 'New description fragment',
    );
    expect(
      reviewOperationViolations(operation('applied'), snapshot, card),
      isEmpty,
    );
    expect(
      reviewOperationViolations(operation('reviewable'), snapshot, card),
      contains(CardPatchViolation.staleAnchor),
    );
  });

  testWidgets('applied patch shows saved before/after without live anchor', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const RewriteAnchoredDiffPane(
        patch: patch,
        fieldValue: 'New description fragment',
        historical: true,
      ),
    );

    expect(find.text('Фрагмент до применения'), findsOneWidget);
    expect(find.text('Фрагмент после применения'), findsOneWidget);
    expect(find.textContaining('Якорь больше не найден'), findsNothing);
    expect(find.textContaining('Old description fragment'), findsWidgets);
    expect(find.textContaining('New description fragment'), findsWidgets);
  });

  testWidgets('pending patch still reports missing live anchor', (
    tester,
  ) async {
    await pumpLocalized(
      tester,
      const RewriteAnchoredDiffPane(
        patch: patch,
        fieldValue: 'New description fragment',
      ),
    );

    expect(find.textContaining('Якорь больше не найден'), findsOneWidget);
  });
}
