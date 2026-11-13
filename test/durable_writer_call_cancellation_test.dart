import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_writer_call_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_evolution_diagnostics.dart';
import 'package:glaze_flutter/core/services/card_rewriter/durable_writer_call_runner.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_read_repository.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/core/utils/time_helpers.dart';

const _config = AuxApiConfig(
  endpoint: 'https://example.invalid/completions',
  apiKey: 'test',
  model: 'test',
  protocol: 'openai',
  maxTokens: 1000,
);

void main() {
  late AppDatabase db;
  late CardEvolutionRepo repo;
  late _BlockingCallRepo calls;
  late CardEvolutionClaim claim;
  LlmCallEventSink? previousSink;

  setUp(() async {
    previousSink = LlmCallEventCapture.sink;
    LlmCallEventCapture.sink = null;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardEvolutionRepo(
      db: db,
      canonReader: EffectiveCanonReadRepository(
        db: db,
        characterRepo: CharacterRepo(db),
        revisionRepo: CharacterRevisionRepo(db),
        baselineRepo: CharacterSessionBaselineRepo(db),
        factRepo: CharacterKnowledgeFactRepo(db),
        transitionRepo: AppliedCanonTransitionRepo(db),
        transitionFactRefRepo: CanonTransitionFactRefRepo(db),
      ),
      jobRepo: ManualRewriteJobRepo(
        db: db,
        rawTrackerStateReader: LedgerRawTrackerStateReader(db),
      ),
    );
    calls = _BlockingCallRepo(db);
    final now = currentTimestampSeconds();
    await db
        .into(db.cardEvolutionClaims)
        .insert(
          CardEvolutionClaimsCompanion.insert(
            id: 'claim',
            sessionId: 'session',
            characterId: 'character',
            ownerId: 'owner',
            status: 'claimed',
            leaseExpiresAt: now + 600,
            chatHistoryHash: 'history',
            effectiveCanonIdentity: 'canon',
            predecessorCursorHash: 'cursor',
            predecessorRunOrdinal: 1,
            inputHash: computeHash('{}'),
            selectedInputJson: const Value('{}'),
            createdAt: now,
          ),
        );
    claim = CardEvolutionClaim(
      row: await db.select(db.cardEvolutionClaims).getSingle(),
      selectedInputJson: '{}',
    );
  });
  tearDown(() async {
    LlmCallEventCapture.sink = previousSink;
    await db.close();
  });

  DurableWriterCallRunner runner({void Function()? onTransport}) =>
      DurableWriterCallRunner(
        repo: repo,
        writerCallRepo: calls,
        diagnostics: CardEvolutionDiagnostics(repo),
        timeoutMs: 1000,
        leaseSeconds: 600,
        executor:
            ({
              required config,
              required prompt,
              required maxTokens,
              required temperature,
              required timeoutMs,
              cancelToken,
              captureContext,
            }) async {
              onTransport?.call();
              return const AuxCallOutcome(
                status: AgentOperationStatus.ok,
                text: 'immutable handoff',
              );
            },
      );

  Future<DurableWriterCallResult> runText(
    DurableWriterCallRunner lane,
    CancelToken token, {
    LazyWriterModel? model,
    int ordinal = 1,
    List<CardEvolutionWriterCallRow> chain = const [],
  }) => lane.runTextCall(
    claim: claim,
    owner: 'owner',
    model: model ?? LazyWriterModel(() async => _config),
    token: token,
    chain: chain,
    chainIndex: ordinal - 1,
    ordinal: ordinal,
    stage: 'history_consolidation',
    stageOrdinal: ordinal,
    captureStage: 'card.history_consolidation',
    prompt: 'immutable prompt $ordinal',
    parentCallId: ordinal == 1 ? null : 'prefix-call',
    manualCallId: null,
    manualResponse: null,
  );

  Future<void> expectFailedCheckpoint(int ordinal) async {
    final chain = await calls.readChain('claim');
    final call = chain.singleWhere((row) => row.ordinal == ordinal);
    expect(call.status, 'failed');
    expect(call.failureCode, 'cancelled');
    expect(call.completedAt, isNull);
    expect(call.resultJson, isNull);
    expect(call.promptHash, computeHash(call.prompt));
    final writer = await db.select(db.cardEvolutionClaims).getSingle();
    expect(writer.status, 'failed');
    expect(writer.failureCode, 'cancelled');
  }

  test('already cancelled entry creates no checkpoint or transport', () async {
    var transports = 0;
    final token = CancelToken()..cancel('Stop');
    final result = await runText(
      runner(onTransport: () => transports++),
      token,
    );
    expect(result.failure?.kind, 'cancelled');
    expect(transports, 0);
    expect(await calls.readChain('claim'), isEmpty);
  });

  test(
    'cancel during model resolution retains failed call, no transport',
    () async {
      final entered = Completer<void>();
      final release = Completer<AuxApiConfig>();
      final token = CancelToken();
      var transports = 0;
      final pending = runText(
        runner(onTransport: () => transports++),
        token,
        model: LazyWriterModel(() {
          entered.complete();
          return release.future;
        }),
      );
      await entered.future;
      token.cancel('Stop');
      release.complete(_config);
      expect((await pending).failure?.kind, 'cancelled');
      expect(transports, 0);
      await expectFailedCheckpoint(1);
    },
  );

  test('cancel after manual parser verdict cannot accept checkpoint', () async {
    final prepared = await calls.prepareNextCall(
      claimId: 'claim',
      ownerId: 'owner',
      now: currentTimestampSeconds(),
      ordinal: 1,
      stage: 'card_writer',
      stageOrdinal: 1,
      prompt: 'manual prompt',
    );
    final sink = _BlockingParserSink();
    LlmCallEventCapture.sink = sink;
    final token = CancelToken();
    var transports = 0;
    final pending = runner(onTransport: () => transports++).runOperationCall(
      claim: claim,
      owner: 'owner',
      model: LazyWriterModel(() => throw StateError('manual: no resolver')),
      token: token,
      chain: [prepared.row!],
      chainIndex: 0,
      ordinal: 1,
      stage: 'card_writer',
      captureStage: 'card.writer',
      prompt: 'manual prompt',
      parentCallId: null,
      cardContext: '{}',
      targetContext: '{}',
      manualCallId: prepared.row!.id,
      manualResponse: '{"operations":[]}',
    );
    await sink.entered.future;
    token.cancel('Stop');
    sink.release.complete();
    expect((await pending).failure?.kind, 'cancelled');
    expect(transports, 0);
    expect(calls.completionAttempts, 0);
    expect(sink.event?.kind, 'parser_accepted');
    await expectFailedCheckpoint(1);
    expect((await calls.getById(prepared.row!.id))?.id, prepared.row!.id);
  });

  test(
    'cancel during completion rolls it back and preserves completed prefix',
    () async {
      final prefix = await calls.prepareNextCall(
        claimId: 'claim',
        ownerId: 'owner',
        now: currentTimestampSeconds(),
        ordinal: 1,
        stage: 'history_consolidation',
        stageOrdinal: 1,
        prompt: 'immutable prompt 1',
      );
      expect(
        await calls.completeCall(
          id: prefix.row!.id,
          claimId: 'claim',
          ownerId: 'owner',
          now: currentTimestampSeconds(),
          responseText: 'accepted prefix',
          resultJson: '{"handoff":"accepted prefix"}',
          source: 'model',
          parserCode: 'accepted',
          lastCallId: 'prefix-call',
        ),
        isTrue,
      );
      final prefixBefore = await calls.getById(prefix.row!.id);
      calls.blockCompletion = true;
      final token = CancelToken();
      final pending = runText(
        runner(),
        token,
        ordinal: 2,
        chain: [prefixBefore!],
      );
      await calls.completionEntered.future;
      token.cancel('Stop');
      calls.completionRelease.complete();
      expect((await pending).failure?.kind, 'cancelled');
      await expectFailedCheckpoint(2);
      final prefixAfter = await calls.getById(prefix.row!.id);
      expect(prefixAfter, prefixBefore);
      expect((await calls.readChain('claim')), hasLength(2));
    },
  );
}

final class _BlockingParserSink implements LlmCallEventSink {
  final entered = Completer<void>();
  final release = Completer<void>();
  LlmCallEvent? event;

  @override
  Future<void> recordCallEvent(LlmCallEvent event) async {
    this.event = event;
    entered.complete();
    await release.future;
  }
}

final class _BlockingCallRepo extends CardEvolutionWriterCallRepo {
  _BlockingCallRepo(super.db);

  bool blockCompletion = false;
  int completionAttempts = 0;
  final completionEntered = Completer<void>();
  final completionRelease = Completer<void>();

  @override
  Future<bool> completeCall({
    required String id,
    required String claimId,
    required String ownerId,
    required int now,
    required String responseText,
    required String resultJson,
    required String source,
    required String parserCode,
    String? parserDetail,
    String? lastCallId,
  }) async {
    completionAttempts++;
    final completed = await super.completeCall(
      id: id,
      claimId: claimId,
      ownerId: ownerId,
      now: now,
      responseText: responseText,
      resultJson: resultJson,
      source: source,
      parserCode: parserCode,
      parserDetail: parserDetail,
      lastCallId: lastCallId,
    );
    if (blockCompletion) {
      completionEntered.complete();
      await completionRelease.future;
    }
    return completed;
  }
}
