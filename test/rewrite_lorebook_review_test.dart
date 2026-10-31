import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_lorebook_evolution_repo.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_provider.dart';
import 'package:glaze_flutter/features/card_rewrite/rewrite_review_screen.dart';

import 'helpers/pump_localized.dart';

const _session = 'operation-session';
const _base = 'Original shared lore content.';
const _current = 'Session-local lore content.\nAlready evolved once.';
const _proposed = 'Session-local lore content.\nEvolved again.';

LorebookRewriteOperationSnapshot _snapshot({
  String entryId = 'entry-047',
  String content = _current,
  String base = _base,
}) => LorebookRewriteOperationSnapshot(
  lorebookId: 'book',
  entryId: entryId,
  baseContent: base,
  expectedContentHash: CardCanonicalizer.scalarSha256(content),
  patches: [
    LorebookAnchoredPatch(
      anchor: content,
      anchorSha256: CardCanonicalizer.scalarSha256(content),
      value: _proposed,
    ),
  ],
);

ManualRewriteOperationView _view(
  LorebookRewriteOperationSnapshot snapshot, {
  String status = 'reviewable',
}) => ManualRewriteOperationView(
  operation: RewriteOperationRow(
    id: snapshot.entryId,
    rewriteJobId: 'job',
    chatSessionId: _session,
    operationJson: RewriteOperationSnapshotCodec.encode(snapshot),
    status: status,
    currentRevision: 1,
    decision: status == 'applied' ? 'approved' : 'pending',
    validationStatus: 'valid',
    decisionRevision: status == 'applied' ? 1 : 0,
    appliedCharacterRevision: status == 'applied' ? 2 : 0,
    appliedCharacterRevisionHash: status == 'applied' ? 'applied-hash' : '',
    createdAt: 1,
    updatedAt: 2,
  ),
  currentSnapshotJson: RewriteOperationSnapshotCodec.encode(snapshot),
  evidenceCount: 0,
);

SessionLorebookEvolutionRow _overlay({
  String sessionId = _session,
  String lorebookId = 'book',
  String entryId = 'entry-047',
  String content = _current,
}) => SessionLorebookEvolutionRow(
  chatSessionId: sessionId,
  lorebookId: lorebookId,
  entryId: entryId,
  baseContent: 'Overlay rollback provenance, not the current source.',
  baseContentHash: 'rollback-hash',
  content: content,
  contentHash: CardCanonicalizer.scalarSha256(content),
  createdAt: 1,
  updatedAt: 2,
);

// Synthetic streams and decision recording only: no database is opened.
class _OverlayRepo implements SessionLorebookEvolutionRepo {
  final changes =
      StreamController<List<SessionLorebookEvolutionRow>>.broadcast();
  final watchedSessions = <String>[];

  Future<void> close() => changes.close();

  @override
  Stream<List<SessionLorebookEvolutionRow>> watchBySessionId(String sessionId) {
    watchedSessions.add(sessionId);
    return changes.stream;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

class _DecisionRepo implements ManualRewriteJobRepo {
  final decisions = <String>[];

  @override
  Future<RewriteOperationMutationOutcome> setDecision({
    required String operationId,
    required int expectedCurrentRevision,
    required String expectedDecision,
    required String decision,
  }) async {
    decisions.add('$operationId:$decision');
    return RewriteOperationMutationOutcome.updated(
      _view(_snapshot(entryId: operationId)).operation.copyWith(
        decision: decision,
        decisionRevision: expectedCurrentRevision,
      ),
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => throw UnimplementedError();
}

void main() {
  test(
    'three evolved whole-entry anchors resolve the exact session targets',
    () async {
      final repo = _OverlayRepo();
      final container = ProviderContainer(
        overrides: [
          sessionLorebookEvolutionRepoProvider.overrideWithValue(repo),
        ],
      );
      addTearDown(repo.changes.close);
      addTearDown(container.dispose);
      final snapshots = [
        for (final id in ['entry-047', 'entry-048', 'entry-050'])
          _snapshot(entryId: id),
      ];
      final views = snapshots.map(_view).toList();
      for (final view in views) {
        container.listen(rewriteLorebookReviewProvider(view), (_, _) {});
        expect(
          container.read(rewriteLorebookReviewProvider(view)).canApprove,
          isFalse,
        );
      }

      repo.changes.add([
        _overlay(sessionId: 'another-session', content: 'Wrong session'),
        _overlay(lorebookId: 'another-book', content: 'Wrong book'),
        _overlay(entryId: 'another-entry', content: 'Wrong entry'),
        for (final snapshot in snapshots) _overlay(entryId: snapshot.entryId),
      ]);
      await container.read(
        rewriteSessionLorebookOverlaysProvider(_session).future,
      );
      await container.pump();

      expect(repo.watchedSessions, [_session]);
      for (final view in views) {
        final review = container.read(rewriteLorebookReviewProvider(view));
        expect(review.content, _current);
        expect(review.status, RewriteLorebookSourceStatus.current);
        expect(review.violations, isEmpty);
        expect(review.canApprove, isTrue);
        expect(
          decodeRewriteOperationSnapshot(view.currentSnapshotJson),
          isA<LorebookRewriteOperationSnapshot>(),
        );
      }
      expect(
        snapshots.every((snapshot) => snapshot.baseContent == _base),
        isTrue,
      );
    },
  );

  test(
    'live drift blocks both direct and bulk approval, even with an anchor',
    () async {
      final repo = _OverlayRepo();
      final decisions = _DecisionRepo();
      final container = ProviderContainer(
        overrides: [
          sessionLorebookEvolutionRepoProvider.overrideWithValue(repo),
          manualRewriteJobRepoProvider.overrideWithValue(decisions),
        ],
      );
      addTearDown(repo.changes.close);
      addTearDown(container.dispose);
      final view = _view(_snapshot());
      container.listen(rewriteLorebookReviewProvider(view), (_, _) {});
      final controller = container.read(
        rewriteReviewUiProvider('job').notifier,
      );
      Future<int> approveAll() =>
          controller.approveAllValid(ops: [view], manualControlNames: const {});

      expect(
        await controller.decide(view, 'approved'),
        'lorebookSourceUnavailable',
      );
      expect(await approveAll(), 0);
      expect(decisions.decisions, isEmpty);

      repo.changes.add([_overlay()]);
      await container.read(
        rewriteSessionLorebookOverlaysProvider(_session).future,
      );
      await container.pump();
      expect(await controller.decide(view, 'approved'), 'updated');
      expect(await approveAll(), 1);
      decisions.decisions.clear();

      repo.changes.add([_overlay(content: 'Changed context.\n$_current')]);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      final changed = container.read(rewriteLorebookReviewProvider(view));
      expect(changed.status, RewriteLorebookSourceStatus.stale);
      expect(changed.violations, isEmpty); // Anchor still occurs exactly once.
      expect(await controller.decide(view, 'approved'), 'staleLorebookEntry');
      expect(await approveAll(), 0);

      repo.changes.add([_overlay(content: 'The anchor was replaced.')]);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      expect(
        container.read(rewriteLorebookReviewProvider(view)).violations,
        contains(CardPatchViolation.staleAnchor),
      );
      expect(await approveAll(), 0);

      repo.changes.add([]);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      final absent = container.read(rewriteLorebookReviewProvider(view));
      expect(absent.content, _base);
      expect(absent.status, RewriteLorebookSourceStatus.stale);
      expect(await approveAll(), 0);
      expect(decisions.decisions, isEmpty);

      // Rejection is still available when the current source is stale.
      expect(await controller.decide(view, 'rejected'), 'updated');
    },
  );

  test(
    'refresh/error never reuse old validity; absent overlay uses saved base',
    () async {
      final view = _view(_snapshot(content: _base));
      final source = rewriteSessionLorebookOverlaysProvider(_session);
      final repo = _OverlayRepo();
      addTearDown(repo.close);
      final decisions = _DecisionRepo();
      final container = ProviderContainer(
        overrides: [
          sessionLorebookEvolutionRepoProvider.overrideWithValue(repo),
          manualRewriteJobRepoProvider.overrideWithValue(decisions),
        ],
      );
      addTearDown(container.dispose);
      container.listen(rewriteLorebookReviewProvider(view), (_, _) {});
      final controller = container.read(
        rewriteReviewUiProvider('job').notifier,
      );
      await container.pump();
      repo.changes.add([_overlay(content: _base)]);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      expect(
        container.read(rewriteLorebookReviewProvider(view)).canApprove,
        isTrue,
      );

      Future<void> expectBlocked(RewriteLorebookSourceStatus status) async {
        final review = container.read(rewriteLorebookReviewProvider(view));
        expect(review.content, isNull);
        expect(review.canApprove, isFalse);
        expect(review.status, status);
        expect(
          await controller.decide(view, 'approved'),
          'lorebookSourceUnavailable',
        );
        expect(
          await controller.approveAllValid(
            ops: [view],
            manualControlNames: const {},
          ),
          0,
        );
      }

      // Public provider refresh retains previous data while loading. Approval
      // must still wait for a fresh source rather than reusing that old value.
      container.invalidate(source);
      await container.pump();
      expect(container.read(source).hasValue, isTrue);
      await expectBlocked(RewriteLorebookSourceStatus.loading);
      repo.changes.addError(StateError('Source unavailable'));
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      await expectBlocked(RewriteLorebookSourceStatus.unavailable);
      expect(decisions.decisions, isEmpty);

      repo.changes.add([]);
      await Future<void>.delayed(Duration.zero);
      await container.pump();
      final fallback = container.read(rewriteLorebookReviewProvider(view));
      expect(fallback.content, _base);
      expect(fallback.canApprove, isTrue);
      expect(await controller.decide(view, 'approved'), 'updated');
    },
  );

  test(
    'lorebook advisory mirrors exact-once, duplicate, hash and macro guards',
    () {
      final snapshot = _snapshot();
      expect(
        advisoryLorebookViolations(snapshot, '$_current\n$_current'),
        contains(CardPatchViolation.ambiguousAnchor),
      );
      expect(
        advisoryLorebookViolations(snapshot, _base),
        contains(CardPatchViolation.staleAnchor),
      );
      LorebookRewriteOperationSnapshot withPatches(
        List<LorebookAnchoredPatch> patches,
      ) => LorebookRewriteOperationSnapshot(
        lorebookId: snapshot.lorebookId,
        entryId: snapshot.entryId,
        baseContent: snapshot.baseContent,
        expectedContentHash: snapshot.expectedContentHash,
        patches: patches,
      );
      expect(
        advisoryLorebookViolations(
          withPatches([snapshot.patches.single, snapshot.patches.single]),
          _current,
        ),
        contains(CardPatchViolation.duplicateAnchor),
      );
      expect(
        advisoryLorebookViolations(
          withPatches([
            const LorebookAnchoredPatch(
              anchor: _current,
              anchorSha256: 'wrong',
              value: _proposed,
            ),
          ]),
          _current,
        ),
        contains(CardPatchViolation.staleAnchor),
      );
      expect(
        advisoryLorebookViolations(
          withPatches([
            LorebookAnchoredPatch(
              anchor: '{{char}} knows the lore.',
              anchorSha256: CardCanonicalizer.scalarSha256(
                '{{char}} knows the lore.',
              ),
              value: 'Someone knows the lore.',
            ),
          ]),
          '{{char}} knows the lore.',
        ),
        contains(CardPatchViolation.macroTokensChanged),
      );
    },
  );

  test('applied lorebook review does not subscribe to live content', () {
    final view = _view(_snapshot(), status: 'applied');
    final container = ProviderContainer();
    addTearDown(container.dispose);
    final review = container.read(rewriteLorebookReviewProvider(view));
    expect(review.status, RewriteLorebookSourceStatus.historical);
    expect(review.content, isNull);
    expect(review.violations, isEmpty);
    expect(review.canApprove, isFalse);
  });

  testWidgets(
    'review screen reacts from loading to current, stale and historical',
    (tester) async {
      final repo = _OverlayRepo();
      addTearDown(repo.changes.close);
      final view = _view(_snapshot());
      final job = RewriteJobRow(
        id: 'job',
        chatSessionId: 'job-session',
        characterId: 'hero',
        status: 'pending',
        requestJson: '{}',
        basisRevision: 1,
        basisRevisionHash: 'basis',
        canonStamp: 'canon',
        version: 1,
        appliedCharacterRevision: 0,
        appliedCharacterRevisionHash: '',
        createdAt: 1,
        updatedAt: 2,
      );
      final router = GoRouter(
        routes: [
          GoRoute(
            path: '/',
            builder: (_, _) =>
                const RewriteReviewScreen(charId: 'hero', jobId: 'job'),
          ),
        ],
      );
      addTearDown(router.dispose);
      final routedScreen = Router(
        routerDelegate: router.routerDelegate,
        routeInformationParser: router.routeInformationParser,
        routeInformationProvider: router.routeInformationProvider,
      );
      final screenOverrides = [
        rewriteCharacterProvider('hero').overrideWith((_) async => null),
        rewriteSessionIndexProvider('job-session').overrideWith((_) async => 0),
        rewriteManualControlsProvider(
          'job-session',
        ).overrideWith((_) async => const {}),
        sessionLorebookEvolutionRepoProvider.overrideWithValue(repo),
      ];
      await pumpLocalized(
        tester,
        routedScreen,
        surfaceSize: const Size(900, 1000),
        overrides: [
          rewriteJobSnapshotProvider('job').overrideWithValue(
            AsyncData(ManualRewriteJobSnapshot(job: job, operations: [view])),
          ),
          ...screenOverrides,
        ],
      );
      final approve = find.byKey(
        const Key('rewrite-lorebook-approve-entry-047'),
      );
      final bulk = find.byKey(const Key('rewrite-approve-all-button'));
      expect(tester.widget<TextButton>(approve).onPressed, isNull);
      expect(tester.widget<TextButton>(bulk).onPressed, isNull);
      expect(find.textContaining('Якорь больше не найден'), findsNothing);

      repo.changes.add([_overlay()]);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<TextButton>(approve).onPressed, isNotNull);
      expect(tester.widget<TextButton>(bulk).onPressed, isNotNull);
      expect(find.textContaining('Already evolved once.'), findsWidgets);
      expect(find.textContaining('Evolved again.'), findsWidgets);
      expect(find.textContaining('Якорь больше не найден'), findsNothing);
      expect(repo.watchedSessions, [
        _session,
      ]); // Operation session, not job session.

      repo.changes.add([_overlay(content: 'A genuinely newer entry.')]);
      await tester.pump();
      await tester.pump();
      expect(tester.widget<TextButton>(approve).onPressed, isNull);
      expect(tester.widget<TextButton>(bulk).onPressed, isNull);
      expect(find.textContaining('Якорь больше не найден'), findsOneWidget);

      await pumpLocalized(
        tester,
        routedScreen,
        surfaceSize: const Size(900, 1000),
        overrides: [
          rewriteJobSnapshotProvider('job').overrideWithValue(
            AsyncData(
              ManualRewriteJobSnapshot(
                job: job.copyWith(status: 'applied'),
                operations: [_view(_snapshot(), status: 'applied')],
              ),
            ),
          ),
          ...screenOverrides,
        ],
      );
      expect(find.text('Фрагмент до применения'), findsOneWidget);
      expect(find.text('Фрагмент после применения'), findsOneWidget);
      expect(find.textContaining('Якорь больше не найден'), findsNothing);
      expect(find.textContaining('Already evolved once.'), findsWidgets);
      expect(find.textContaining('Evolved again.'), findsWidgets);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
