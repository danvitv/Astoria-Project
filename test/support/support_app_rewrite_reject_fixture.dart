import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_native_owner.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_provider.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_screen.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';

import 'support_app_domain_loop_fixture.dart' hide domainLoopTest;
import 'support_app_domain_loop_fixture.dart' as original;
export 'support_app_domain_loop_fixture.dart' hide domainLoopTest;

/// A genuine original file from first construction, not replacement authority.
void domainLoopTest(
  String name,
  Future<void> Function(WidgetTester, DomainLoopFixture) body,
) => original.domainLoopTest(name, body, nativeSourceFile: true);

const rewriteJobId = 'native-rewrite-job';
const rewriteOperationId = 'native-rewrite-operation';

Map<String, Object?> rewriteRejectArguments() => {
  'jobId': rewriteJobId,
  'operationId': rewriteOperationId,
};

/// Only new cases reuse the actual DomainLoop DB/AEAD/ROOT/native screen and
/// tripwires. No replacement owner, test approval driver or forged journal.
Future<void> seedNativeRewrite(
  WidgetTester tester,
  DomainLoopFixture f, {
  String jobId = rewriteJobId,
  String operationId = rewriteOperationId,
}) async {
  final c = f.screen.core.container, db = f.screen.core.native.db;
  f.screen.core.isolation.extraAllowed.addAll({
    manualRewriteJobRepoProvider,
    sessionLorebookEvolutionRepoProvider,
    rewriteJobSnapshotProvider(jobId),
    rewriteReviewUiProvider(jobId),
    rewriteSessionIndexProvider(DomainLoopFixture.session),
    rewriteCharacterProvider(DomainLoopFixture.character),
    rewriteManualControlsProvider(DomainLoopFixture.session),
  });
  final snapshot = ManualRewriteOperationSnapshotCodec.encode(
    CardRewriteOperationSnapshot(
      field: CardRewriteField.description,
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'character:description',
          field: CardRewriteField.description,
          anchor: DomainLoopFixture.private,
          anchorSha256: CardCanonicalizer.scalarSha256(
            DomainLoopFixture.private,
          ),
          value: 'SYNTHETIC_REWRITE_MODEL_TEXT',
        ),
      ],
      transition: const CardRewriteTransitionSnapshot(
        id: 'native-transition',
        scopeKey: 'character:description',
        canonicalClaim: 'SYNTHETIC_REWRITE_CLAIM',
        promotionDestination: 'card',
        affectedTrackerKeys: [],
      ),
    ),
  );
  await configurationAction(
    tester,
    () => db.transaction(() async {
      await c
          .read(manualRewriteJobRepoProvider)
          .insertPendingInTransaction(
            jobId: jobId,
            chatSessionId: DomainLoopFixture.session,
            characterId: DomainLoopFixture.character,
            requestJson: jsonEncode({
              'field': 'description',
              'instruction': DomainLoopFixture.private,
            }),
            requestKey: 'native-request-$jobId',
            basisRevision: 4,
            basisRevisionHash: 'SYNTHETIC_REWRITE_BASIS',
            canonStamp: 'SYNTHETIC_REWRITE_CANON',
            operations: [
              ManualRewriteOperationDraft(
                id: operationId,
                snapshotJson: snapshot.replaceFirst(
                  '"field":',
                  '"unknownNative":{"rawNumber":1.2300e+02,"private":"${f.screen.core.boundSyntheticSecret}"},"field":',
                ),
                evidence: const [
                  ManualRewriteEvidenceDraft(
                    id: 'native-rewrite-evidence',
                    evidenceJson: '{"private":"SYNTHETIC_REWRITE_EVIDENCE"}',
                  ),
                ],
              ),
            ],
            now: 11,
          );
    }),
  );
}

Future<NavigatorState> mountNativeRewrite(
  WidgetTester tester,
  DomainLoopFixture f, {
  String jobId = rewriteJobId,
  String operationId = rewriteOperationId,
  bool select = true,
  bool handoff = true,
}) async {
  final context = tester.element(find.byType(SupportAssistantScreen));
  final navigator = Navigator.of(context, rootNavigator: true);
  await configurationAction(
    tester,
    () async => (
      navigator.push<void>(
        MaterialPageRoute(
          builder: (_) => RewriteReviewScreen(
            charId: DomainLoopFixture.character,
            jobId: jobId,
          ),
        ),
      ),
    ),
  );
  final originalSnapshot = await configurationAction(
    tester,
    () => (
      future: f.screen.core.container.read(
        rewriteJobSnapshotProvider(jobId).future,
      ),
    ),
  );
  // The mounted Riverpod scope may schedule the original stream through test
  // frames. Keep its exact future; runAsync alone cannot drain those frames.
  await f.screen.join(tester, originalSnapshot.future);
  await tester.pumpAndSettle();
  final open = find.byKey(const Key('rewrite-open-astoria'));
  expect(
    tester.widget<IconButton>(open).onPressed,
    isNull,
    reason: 'Desktop fallback-first is display ONLY, not explicit selection.',
  );
  if (select) {
    await tester.tap(find.byKey(Key('rewrite-select-$operationId')));
    await tester.pump();
    expect(tester.widget<IconButton>(open).onPressed, isNotNull);
  }
  if (handoff) {
    expect(select, true);
    await tester.tap(open);
    await tester.pumpAndSettle();
    expect(find.byType(SupportAssistantScreen), findsOneWidget);
  }
  return navigator;
}

RewriteNativeReviewOwner nativeRewriteOwner(
  DomainLoopFixture f, [
  String jobId = rewriteJobId,
]) => f.screen.core.container
    .read(rewriteNativeReviewOwnerRegistryProvider)
    .existing(jobId, f.screen.core.container)!;

Future<void> closeNativeRewrite(
  WidgetTester tester,
  NavigatorState navigator,
) async {
  await configurationAction(tester, () async {
    navigator.popUntil((route) => route.isFirst);
  });
  await tester.pumpAndSettle();
}

Future<void> startRewriteReject(
  WidgetTester tester,
  DomainLoopFixture f, {
  bool confirmation = true,
  bool undo = false,
}) => f.start(
  tester,
  confirmation: confirmation,
  instruction: undo
      ? 'Отмени отклонение операции переписывания'
      : 'Отклони операцию переписывания',
);

Future<ManualRewriteJobSnapshot> nativeRewriteRow(
  WidgetTester tester,
  DomainLoopFixture f, [
  String id = rewriteJobId,
]) async => (await configurationAction<ManualRewriteJobSnapshot?>(
  tester,
  () => f.screen.core.container
      .read(manualRewriteJobRepoProvider)
      .getJobSnapshot(id),
))!;

void scriptRewriteUndo(DomainLoopFixture f, {void Function(String)? handle}) =>
    f.script(
      f.screen.core.call('astoria_rewrite_review_receipts', {
        'operation': 'receipts',
      }),
      next: (round) {
        if (round != 2)
          return f.screen.core.answer('Exact original rejection Undo settled.');
        final records = f.lastData()['records'] as List;
        expect(records, hasLength(1));
        final receipt = (records.single as Map)['receipt'] as String;
        handle?.call(receipt);
        return f.screen.core.call('astoria_rewrite_reject_undo', {
          'receipt': receipt,
        }, id: 'fresh_rewrite_undo');
      },
    );

Future<void> noRewriteJournal(WidgetTester tester, DomainLoopFixture f) async {
  expect(
    await configurationAction(
      tester,
      () => f.screen.core.native.db
          .select(f.screen.core.native.db.supportMutationJournal)
          .get(),
    ),
    isEmpty,
  );
}

void rewriteNoEgress(DomainLoopFixture f, [String text = '']) {
  f.noEgress(text);
  final outward =
      '${jsonEncode(f.screen.core.wire)}${jsonEncode(f.results)}$text';
  for (final canary in [
    'SYNTHETIC_REWRITE_MODEL_TEXT',
    'SYNTHETIC_REWRITE_CLAIM',
    'SYNTHETIC_REWRITE_EVIDENCE',
    'SYNTHETIC_REWRITE_BASIS',
    'SYNTHETIC_REWRITE_CANON',
    'unknownNative',
  ]) {
    expect(outward, isNot(contains(canary)));
  }
}
