import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_reconciliation.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_service.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_context_loader.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

final _bookProvider = Provider<MemoryBookRepo>(
  (ref) => throw UnimplementedError(),
);

const _assistant = ChatMessage(
  id: 'a1',
  role: 'assistant',
  content: 'Alice enters the courtyard.',
);
const _messages = [
  ChatMessage(id: 'u1', role: 'user', content: 'Continue.'),
  _assistant,
];
const _plan = LedgerReconciliationPlan(
  messages: _messages,
  endMessage: _assistant,
  rangeHash: 'synthetic-range',
);

// Same real service/repos/SQLite fixture as studio_ledger_transaction_test,
// replacing only the provider call with deterministic, network-free output.
void main() {
  late AppDatabase db;
  late ProviderContainer container;
  late TrackerRepo trackers;
  late TrackerSnapshotRepo snapshots;
  late LedgerReconciliationRunRepo runs;
  late LedgerReconciliationCheckpointRepo checkpoints;
  late CardEvolutionJobRepo jobs;
  late _SyntheticLlm llm;
  late StudioLedgerService service;
  late TrackerSnapshot initialSnapshot;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final characters = CharacterRepo(db);
    final chats = ChatRepo(db);
    trackers = TrackerRepo(db);
    snapshots = TrackerSnapshotRepo(db);
    runs = LedgerReconciliationRunRepo(db);
    checkpoints = LedgerReconciliationCheckpointRepo(db);
    jobs = CardEvolutionJobRepo(db);
    final facts = CharacterKnowledgeFactRepo(db);
    container = ProviderContainer(
      overrides: [_bookProvider.overrideWith((ref) => MemoryBookRepo(db, ref))],
    );
    await characters.put(const Character(id: 'char', name: 'Alice'));
    await chats.put(
      const ChatSession(
        id: 'session',
        characterId: 'char',
        sessionIndex: 0,
        messages: _messages,
      ),
    );
    initialSnapshot = const TrackerSnapshot(
      sessionId: 'session',
      messageId: 'a1',
      swipeId: 0,
      agentSwipeId: 0,
      trackers: [],
      committed: true,
      createdAt: 1,
    );
    await snapshots.upsert(initialSnapshot);
    llm = _SyntheticLlm();
    service = StudioLedgerService(
      llm: llm,
      trackerRepo: trackers,
      bookRepo: container.read(_bookProvider),
      snapshotRepo: snapshots,
      knowledgeFactRepo: facts,
      reconciliationCheckpointRepo: checkpoints,
      reconciliationRunRepo: runs,
      characterRepo: characters,
      chatRepo: chats,
      canonContextLoader: EffectiveCanonContextLoader(
        db: db,
        characterRepo: characters,
        characterRevisionRepo: CharacterRevisionRepo(db),
        baselineRepo: CharacterSessionBaselineRepo(db),
        factRepo: facts,
        transitionRepo: AppliedCanonTransitionRepo(db),
        transitionFactRefRepo: CanonTransitionFactRefRepo(db),
        loadRawTrackerState: LedgerRawTrackerStateReader(db).read,
      ),
    );
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<LedgerRunResult> reconcile({
    Future<void> Function(LedgerReconciliationSuccessfulRunRow run)? reserve,
    CancelToken? token,
  }) => service.reconcile(
    sessionId: 'session',
    settings: const PipelineSettings(),
    config: const AuxApiConfig(
      endpoint: 'https://offline.invalid',
      apiKey: '',
      model: 'synthetic',
      protocol: 'openai',
    ),
    plan: _plan,
    cancelToken: token,
    reserveEvolutionJob: reserve,
  );

  Future<void> enqueue(LedgerReconciliationSuccessfulRunRow run) async {
    await jobs.enqueue(
      sessionId: run.sessionId,
      characterId: 'char',
      reconciliationRunId: run.id,
      routingSnapshotJson: '{"version":1}',
      routingSnapshotHash: 'synthetic-route',
      now: 100,
    );
  }

  Future<void> expectRolledBack() async {
    expect(await runs.readPhysicalSession('session'), isEmpty);
    expect(await runs.readEffects('session'), isEmpty);
    expect(await runs.readCursors('session'), isEmpty);
    expect(await checkpoints.get('session'), isNull);
    expect(await trackers.get('session', 'world:location'), isNull);
    expect(await jobs.listUnfinished(), isEmpty);
    expect(await db.select(db.cardEvolutionJobs).get(), isEmpty);
    expect(await db.select(db.ledgerReconciliationLeases).get(), isEmpty);
    final snapshot = await snapshots.getByAnchor(
      sessionId: 'session',
      messageId: 'a1',
      swipeId: 0,
      agentSwipeId: 0,
    );
    expect(snapshot?.toJson(), initialSnapshot.toJson());
  }

  test('reservation sees exact staged run, effect and checkpoint', () async {
    LedgerReconciliationSuccessfulRunRow? reserved;
    final result = await reconcile(
      reserve: (run) async {
        reserved = run;
        expect(
          await runs.getByContentHash(run.sessionId, run.contentHash),
          run,
        );
        expect(
          await runs.validateEffect(run),
          isA<ReconciliationEffectValid>(),
        );
        expect((await checkpoints.get('session'))?.rangeHash, _plan.rangeHash);
        expect(
          (await trackers.get('session', 'world:location'))?.value,
          'courtyard',
        );
        await enqueue(run);
      },
    );
    expect(result.status, 'ok');
    final run = (await runs.readPhysicalSession('session')).single;
    expect(reserved, run);
    final job = (await jobs.listUnfinished()).single;
    expect(job.reconciliationRunId, run.id);
    expect(job.reconciliationChainHash, run.chainHash);
    expect(job.availableAt, 102);
    expect(await db.select(db.ledgerReconciliationLeases).get(), isEmpty);
  });

  test('callback failure rolls back every staged canonical write', () async {
    var called = false;
    final result = await reconcile(
      reserve: (run) async {
        called = true;
        expect(await runs.readEffect(run.id), isNotNull);
        throw StateError('synthetic reservation failure');
      },
    );
    expect(called, isTrue);
    expect(result.status, 'error');
    expect(result.error, contains('synthetic reservation failure'));
    await expectRolledBack();
  });

  test(
    'completed nested enqueue rolls back with outer callback failure',
    () async {
      final result = await reconcile(
        reserve: (run) async {
          await enqueue(run);
          expect(await jobs.listUnfinished(), hasLength(1));
          throw StateError('failure after nested enqueue');
        },
      );
      expect(result.status, 'error');
      await expectRolledBack();
    },
  );

  test(
    'queue insert failure rolls back reconciliation and allows retry',
    () async {
      await db.customStatement('''
CREATE TRIGGER fail_evolution_enqueue BEFORE INSERT ON card_evolution_jobs
BEGIN SELECT RAISE(ABORT, 'synthetic queue failure'); END
''');
      final result = await reconcile(reserve: enqueue);
      expect(result.status, 'error');
      expect(result.error, contains('synthetic queue failure'));
      await expectRolledBack();

      await db.customStatement('DROP TRIGGER fail_evolution_enqueue');
      expect((await reconcile(reserve: enqueue)).status, 'ok');
      expect(await runs.readPhysicalSession('session'), hasLength(1));
      expect(await jobs.listUnfinished(), hasLength(1));
    },
  );

  test('cancellation at reservation cannot leave a committed job', () async {
    final token = CancelToken();
    final result = await reconcile(
      token: token,
      reserve: (run) async {
        await enqueue(run);
        // Fault injection only: production callbacks are repository-only.
        token.cancel('synthetic cancellation at reservation');
      },
    );
    expect(result.status, 'aborted');
    await expectRolledBack();
  });

  test('replay reserves original exact row rather than a later head', () async {
    llm.withOp = false;
    expect((await reconcile()).status, 'ok');
    final first = (await runs.readPhysicalSession('session')).single;
    final checkpoint = await db
        .select(db.ledgerReconciliationCheckpoints)
        .getSingle();
    final effect = await runs.readEffect(first.id);
    final later = LedgerReconciliationRun(
      id: 'later',
      sessionId: first.sessionId,
      ordinal: 2,
      anchors: [
        for (final message in _messages)
          ReconciliationAnchor(
            messageId: message.id,
            swipeId: message.swipeId,
            agentSwipeId: message.agentSwipeId,
            role: message.role,
            contentHash: computeHash(message.content),
          ),
      ],
      acceptedManifestRefs: const [],
      effectiveCanonStamp: first.effectiveCanonStamp,
      effectiveCanonRevision: first.effectiveCanonRevision,
      effectiveCanonHash: first.effectiveCanonHash,
      canonicalResult: const {'synthetic': 'later run'},
      predecessorChainHash: first.chainHash,
      contractVersion: first.contractVersion,
      opsApplied: const [],
      createdAt: first.createdAt + 1,
    );
    expect(await runs.appendCandidate(later), isA<ReconciliationRunAppended>());
    expect((await runs.getHead('session'))?.ordinal, 2);

    final failedReplay = await reconcile(
      reserve: (run) async {
        expect(run, first);
        await enqueue(run);
        throw StateError('synthetic replay reservation failure');
      },
    );
    expect(failedReplay.status, 'error');
    expect(await jobs.listUnfinished(), isEmpty);
    expect(await runs.readPhysicalSession('session'), hasLength(2));
    expect(await runs.readEffect(first.id), effect);
    expect(
      await db.select(db.ledgerReconciliationCheckpoints).getSingle(),
      checkpoint,
    );
    expect(await db.select(db.ledgerReconciliationLeases).get(), isEmpty);

    final seen = <LedgerReconciliationSuccessfulRunRow>[];
    Future<void> reserve(LedgerReconciliationSuccessfulRunRow run) async {
      seen.add(run);
      await enqueue(run);
    }

    expect((await reconcile(reserve: reserve)).status, 'ok');
    expect((await reconcile(reserve: reserve)).status, 'ok');
    expect(seen, [first, first]);
    expect(await runs.readPhysicalSession('session'), hasLength(2));
    expect(await runs.readEffect(first.id), effect);
    expect(
      await db.select(db.ledgerReconciliationCheckpoints).getSingle(),
      checkpoint,
    );
    expect((await jobs.listUnfinished()).single.reconciliationRunId, first.id);
  });
}

class _SyntheticLlm extends AuxLlmClient {
  bool withOp = true;

  @override
  Future<AuxCallOutcome> callStreamWithLog({
    required AuxApiConfig config,
    required String prompt,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    void Function(String accumulatedText)? onChunk,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
    LlmCaptureContext? captureContext,
  }) async => AuxCallOutcome(
    status: AgentOperationStatus.ok,
    text:
        '''
<glaze_memory_export>
${jsonEncode({
          'ops': [
            if (withOp) {'op': 'set', 'key': 'world:location', 'value': 'courtyard', 'evidence': 'Alice enters the courtyard.', 'eventState': 'completed'},
          ],
          'knowledgeFacts': <Object?>[],
        })}
</glaze_memory_export>
<studio_ledger>reviewed</studio_ledger>
<glaze_knowledge_cleanup>{"ops":[]}</glaze_knowledge_cleanup>
''',
  );
}
