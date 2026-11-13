import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_reconciliation.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_service.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/agent_operation_record.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/card_rewriter_settings.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/state/card_evolution_worker_provider.dart';
import 'package:glaze_flutter/core/state/character_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_agent_providers.dart';
import 'package:glaze_flutter/core/state/persona_resolution.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/ledger_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';
import 'package:glaze_flutter/features/chat/state/agent_operations_log_provider.dart';
import 'package:glaze_flutter/features/chat/state/post_gen_status_provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('LedgerStage commits exact evolution reservation and finishes foreground '
      'Ledger while background admission is pending', () async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final jobs = _HeldAdmissionJobRepo(db);
    final llm = _SyntheticLedgerLlm(jobs.started.future);
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        cardEvolutionJobRepoProvider.overrideWithValue(jobs),
        studioLedgerServiceProvider.overrideWith(
          (ref) => StudioLedgerService(
            llm: llm,
            trackerRepo: ref.read(trackerRepoProvider),
            bookRepo: ref.read(memoryBookRepoProvider),
            snapshotRepo: ref.read(trackerSnapshotRepoProvider),
            knowledgeFactRepo: ref.read(characterKnowledgeFactRepoProvider),
            reconciliationCheckpointRepo: ref.read(
              ledgerReconciliationCheckpointRepoProvider,
            ),
            reconciliationRunRepo: ref.read(
              ledgerReconciliationRunRepoProvider,
            ),
            characterRepo: ref.read(characterRepoProvider),
            chatRepo: ref.read(chatRepoProvider),
            canonContextLoader: ref.read(effectiveCanonContextLoaderProvider),
          ),
        ),
        characterByIdProvider(
          'char',
        ).overrideWith((ref) => const Character(id: 'char', name: 'Alice')),
        effectivePersonaForChatProvider((
          charId: 'char',
          sessionId: 'session',
        )).overrideWith((ref) => null),
      ],
    );
    final background = container.read(cardEvolutionBackgroundProvider);
    addTearDown(() async {
      // Join the outstanding drain before closing SQLite. Returning false at
      // the held fence prevents any real collector/provider call on release.
      final draining = background.worker.notifyPending();
      background.dispose();
      jobs.release.complete();
      await draining;
      container.dispose();
      await db.close();
    });

    final messages = <ChatMessage>[
      const ChatMessage(
        id: 'opening',
        role: 'assistant',
        content: 'Alice enters the courtyard.',
      ),
      for (var i = 1; i <= 6; i++) ...[
        ChatMessage(id: 'u$i', role: 'user', content: 'Continue.'),
        ChatMessage(
          id: 'a$i',
          role: 'assistant',
          content: i == 1
              ? 'Alice enters the courtyard.'
              : 'Alice waits in the courtyard.',
        ),
      ],
    ];
    final target = messages.last;
    final session = ChatSession(
      id: 'session',
      characterId: 'char',
      sessionIndex: 0,
      messages: messages,
    );
    await container
        .read(characterRepoProvider)
        .put(const Character(id: 'char', name: 'Alice'));
    await container.read(chatRepoProvider).put(session);
    await container
        .read(trackerSnapshotRepoProvider)
        .upsert(
          const TrackerSnapshot(
            sessionId: 'session',
            messageId: 'a5',
            swipeId: 0,
            agentSwipeId: 0,
            trackers: [],
            committed: true,
            createdAt: 1,
          ),
        );
    late AsyncValue<ChatState> state = AsyncData(ChatState(session: session));
    final stageProvider = Provider<LedgerStage>((ref) {
      final abort = AbortHandler(
        ref: ref,
        charId: 'char',
        setState: (next) => state = next,
        getState: () => state,
        mutateSession: (_, _) async => null,
        loadSession: (_) async => null,
      );
      return LedgerStage(
        StageContext(
          ref: ref,
          charId: 'char',
          abortHandler: abort,
          setState: (next) => state = next,
          getState: () => state,
        ),
      );
    });
    final turn = StudioTurnConfigSnapshot(
      config: const StudioConfig(sessionId: 'session', enabled: true),
      preset: const StudioPreset(id: 'preset'),
      pipelineSettings: const PipelineSettings(
        cardRewriter: CardRewriterSettings(enabled: true),
      ),
      apiConfigs: const [],
      activeApiConfig: const ApiConfig(
        id: 'api',
        endpoint: 'https://example.invalid/v1/chat/completions',
        model: 'synthetic',
      ),
    );

    // Use automatic cadence (not manual rerun): five accepted chunks are
    // reconciled when a6 arrives. The real worker retains its two-second
    // delay, then claims the real job and blocks at its first ownership fence.
    await container
        .read(stageProvider)
        .run(
          sessionId: session.id,
          messages: messages,
          genId: 0,
          finalAssistantText: target.content,
          targetMessage: target,
          studioTurnConfig: turn,
        )
        .timeout(const Duration(seconds: 10));

    expect(llm.reconciliationCalls, 1);
    expect(llm.ordinaryCalls, 1);
    expect(jobs.started.isCompleted, isTrue);
    expect(jobs.release.isCompleted, isFalse);
    final records = container.read(agentOperationsLogProvider).records;
    for (final kind in [
      AgentOperationKind.studioLedgerReconciliation,
      AgentOperationKind.studioLedger,
    ]) {
      final record = records.where((record) => record.kind == kind).single;
      expect(record.status, AgentOperationStatus.ok);
    }
    final status = container.read(postGenStatusProvider);
    expect(status.isActive, isFalse);
    expect(status.detail, 'Ledger ok (ops=0)');

    final runs = container.read(ledgerReconciliationRunRepoProvider);
    final run = (await runs.readPhysicalSession(session.id)).single;
    final plan = const LedgerReconciliationPlanner().plan(
      messages: messages,
      currentAssistantMessageId: target.id,
    )!;
    expect(run.endMessageId, 'a5');
    expect(await runs.validateEffect(run), isA<ReconciliationEffectValid>());
    expect(
      (await container
              .read(ledgerReconciliationCheckpointRepoProvider)
              .get(session.id))
          ?.rangeHash,
      plan.rangeHash,
    );
    expect(
      (await container
              .read(trackerRepoProvider)
              .get(session.id, 'world:location'))
          ?.value,
      'courtyard',
    );
    final job = (await jobs.listUnfinished()).single;
    expect(job.status, 'running');
    expect(job.ownerNonce, isNotNull);
    expect(job.sessionId, session.id);
    expect(job.characterId, session.characterId);
    expect(job.reconciliationRunId, run.id);
    expect(job.reconciliationChainHash, run.chainHash);
    expect(job.routingSnapshotHash, computeHash(job.routingSnapshotJson));
    expect(job.availableAt - job.createdAt, 2);
    expect(await db.select(db.ledgerReconciliationLeases).get(), isEmpty);
  });
}

/// Keep real enqueue, source validation and claim SQL. Only pause the first
/// execution-admission fence, outside any transaction, so foreground writes
/// remain free to finish. No background model is invoked by this test.
class _HeldAdmissionJobRepo extends CardEvolutionJobRepo {
  _HeldAdmissionJobRepo(super.db);

  final started = Completer<void>();
  final release = Completer<void>();

  @override
  Future<bool> isOwned({
    required String id,
    required String ownerNonce,
    required int now,
  }) async {
    if (!await super.isOwned(id: id, ownerNonce: ownerNonce, now: now)) {
      return false;
    }
    if (!started.isCompleted) started.complete();
    await release.future;
    return false;
  }
}

class _SyntheticLedgerLlm extends AuxLlmClient {
  _SyntheticLedgerLlm(this.backgroundStarted);

  final Future<void> backgroundStarted;
  var reconciliationCalls = 0;
  var ordinaryCalls = 0;

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
  }) async {
    reconciliationCalls++;
    return AuxCallOutcome(
      status: AgentOperationStatus.ok,
      text: '''
<glaze_memory_export>
{"ops":[{"op":"set","key":"world:location","value":"courtyard","evidence":"Alice enters the courtyard.","eventState":"completed"}],"knowledgeFacts":[]}
</glaze_memory_export>
<studio_ledger>reviewed</studio_ledger>
<glaze_knowledge_cleanup>{"ops":[]}</glaze_knowledge_cleanup>
''',
    );
  }

  @override
  Future<AuxCallOutcome> callOnceWithLog({
    required AuxApiConfig config,
    String prompt = '',
    List<Map<String, String>>? messages,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
    bool omitReasoning = false,
    bool omitReasoningEffort = true,
    bool requestReasoning = false,
    bool omitTopP = true,
    LlmCaptureContext? captureContext,
    AuxRawResponseSink? onRawResponse,
    FutureOr<void> Function(int attempt, int maxAttempts)? onAttemptStart,
  }) async {
    ordinaryCalls++;
    await backgroundStarted;
    return AuxCallOutcome(
      status: AgentOperationStatus.ok,
      text: '''
<glaze_memory_export>{"ops":[],"knowledgeFacts":[]}</glaze_memory_export>
<studio_ledger>reviewed</studio_ledger>
<glaze_knowledge_cleanup>{"ops":[]}</glaze_knowledge_cleanup>
''',
    );
  }
}
