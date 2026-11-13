import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/macro_engine.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_reconciliation.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_service.dart';
import 'package:glaze_flutter/core/llm/studio_turn_config_snapshot.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/services/generation_notification_service.dart';
import 'package:glaze_flutter/core/state/session_mutation_gate.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';
import 'package:glaze_flutter/features/chat/services/manual_studio_ledger_service.dart';

enum _Operation { rerun, reconcile, regenerate, recoverMissing }

void main() {
  late AppDatabase db;
  late _ObservedChatRepo chatRepo;
  late _ObservedTrackerRepo trackerRepo;
  late TrackerSnapshotRepo snapshotRepo;
  late LedgerReconciliationRunRepo runRepo;
  late _Executor executor;
  late _NotificationLease notificationLease;
  late SessionMutationGate gate;
  late ManualStudioLedgerService service;
  var preparationReads = 0;
  var expectedRunId = 'not-yet-prepared';
  final messages = <ChatMessage>[
    const ChatMessage(id: 'a1', role: 'assistant', content: 'Assistant 1'),
    for (var i = 2; i <= 7; i++) ...[
      ChatMessage(id: 'u$i', role: 'user', content: 'User $i'),
      ChatMessage(id: 'a$i', role: 'assistant', content: 'Assistant $i'),
    ],
  ];
  final endpoint = messages[10];

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    chatRepo = _ObservedChatRepo(db);
    trackerRepo = _ObservedTrackerRepo(db);
    snapshotRepo = TrackerSnapshotRepo(db);
    runRepo = LedgerReconciliationRunRepo(db);
    executor = _Executor();
    notificationLease = _NotificationLease();
    gate = SessionMutationGate();
    preparationReads = 0;
    expectedRunId = 'not-yet-prepared';
    final presetRepo = StudioPresetRepo(db);
    final characterRepo = CharacterRepo(db);
    await characterRepo.put(const Character(id: 'char', name: 'Character'));
    await presetRepo.put(
      const StudioPreset(
        id: 'preset',
        blocks: [StudioPresetBlock(id: 'ledger', section: 'ledger')],
      ),
    );
    await chatRepo.put(
      ChatSession(
        id: 'session',
        characterId: 'char',
        sessionIndex: 0,
        messages: messages,
      ),
    );
    service = ManualStudioLedgerService(
      chatRepo: chatRepo,
      snapshotRepo: snapshotRepo,
      trackerRepo: trackerRepo,
      presetRepo: presetRepo,
      characterRepo: characterRepo,
      reconciliationRunRepo: runRepo,
      reconciliationCheckpointRepo: LedgerReconciliationCheckpointRepo(db),
      ledger: executor,
      sessionMutationGate: gate,
      loadApiConfigs: () async => const [],
      readActiveApiConfig: () => const ApiConfig(
        id: 'api',
        endpoint: 'https://offline.invalid/v1/chat/completions',
        model: 'synthetic',
      ),
      readPipelineSettings: () {
        preparationReads++;
        return const PipelineSettings();
      },
      loadActivePresetId: () async => 'preset',
      acquireForegroundLease: () async => notificationLease,
    );
    chatRepo.reads = 0;
  });

  tearDown(() async {
    gate.dispose();
    await db.close();
  });

  Future<void> seed(_Operation operation) async {
    if (operation == _Operation.reconcile ||
        operation == _Operation.regenerate) {
      await snapshotRepo.upsert(
        TrackerSnapshot(
          sessionId: 'session',
          messageId: endpoint.id,
          swipeId: endpoint.swipeId,
          agentSwipeId: endpoint.agentSwipeId,
          trackers: const [],
          committed: true,
          createdAt: 1,
        ),
      );
    }
    if (operation == _Operation.regenerate) {
      final result = await runRepo.appendCandidate(
        LedgerReconciliationRun(
          id: 'run',
          sessionId: 'session',
          ordinal: 1,
          anchors: [
            for (final message in messages.take(11))
              ReconciliationAnchor(
                messageId: message.id,
                swipeId: message.swipeId,
                agentSwipeId: message.agentSwipeId,
                role: message.role,
                contentHash: computeHash(message.content),
              ),
          ],
          acceptedManifestRefs: const [],
          effectiveCanonStamp: 'stamp',
          effectiveCanonRevision: 1,
          effectiveCanonHash: 'hash',
          canonicalResult: const {'export': <String, dynamic>{}},
          predecessorChainHash: '',
          contractVersion: 1,
          opsApplied: const [],
          createdAt: 1,
        ),
      );
      expect(result, isA<ReconciliationRunAppended>());
      expectedRunId = (await runRepo.getHead('session'))!.id;
    }
  }

  Future<ManualStudioLedgerResult> invoke(_Operation operation) =>
      switch (operation) {
        _Operation.rerun => service.rerun(
          sessionId: 'session',
          target: endpoint,
        ),
        _Operation.reconcile => service.reconcile('session'),
        _Operation.regenerate => service.regenerateLatest(
          sessionId: 'session',
          expectedRunId: expectedRunId,
        ),
        _Operation.recoverMissing => service.rerunMissingForReconciliation(
          'session',
        ),
      };

  void expectApplyAvailable(String sessionId) {
    final lease = gate.tryApply(sessionId);
    expect(lease, isNotNull);
    lease?.release();
  }

  for (final operation in _Operation.values) {
    test('${operation.name} rejects Apply before any preparation', () async {
      final apply = gate.tryApply('session')!;
      await expectLater(
        invoke(operation),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Session Apply is in progress'),
          ),
        ),
      );
      expect(preparationReads, 0);
      expect(chatRepo.reads, 0);
      expect(executor.calls, 0);
      expectApplyAvailable('other');
      apply.release();
      expectApplyAvailable('session');
    });

    test(
      '${operation.name} holds lease through preparation, executor and diagnostics',
      () async {
        await seed(operation);
        final readStarted = Completer<void>();
        final releaseRead = Completer<void>();
        chatRepo.beforeRead = () async {
          if (!readStarted.isCompleted) readStarted.complete();
          await releaseRead.future;
        };
        final execute = Completer<LedgerRunResult>();
        executor.action = () => execute.future;
        final diagnosticStarted = Completer<void>();
        final releaseDiagnostic = Completer<void>();
        trackerRepo.beforeDiagnostic = () async {
          diagnosticStarted.complete();
          await releaseDiagnostic.future;
        };

        final future = invoke(operation);
        // Acquisition is synchronous, even before the first read settles.
        expect(gate.tryApply('session'), isNull);
        await readStarted.future;
        expect(gate.tryApply('session'), isNull);
        releaseRead.complete();
        await executor.started.future;
        expect(gate.tryApply('session'), isNull);
        expectApplyAvailable('other');
        // A non-ok result skips timestamp sync, isolating the diagnostic fence.
        execute.complete(const LedgerRunResult(status: 'error', opsApplied: 0));
        await diagnosticStarted.future;
        expect(gate.tryApply('session'), isNull);
        releaseDiagnostic.complete();
        expect((await future).result.status, 'error');
        expectApplyAvailable('session');
      },
    );
  }

  test(
    'executor failure retains lease until its async cleanup settles',
    () async {
      final fail = Completer<void>();
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      executor.action = () async {
        try {
          await fail.future;
          throw StateError('synthetic executor failure');
        } finally {
          cleanupStarted.complete();
          await releaseCleanup.future;
        }
      };
      final future = invoke(_Operation.rerun);
      final assertion = expectLater(future, throwsStateError);
      await executor.started.future;
      fail.complete();
      await cleanupStarted.future;
      expect(gate.tryApply('session'), isNull);
      expectApplyAvailable('other');
      releaseCleanup.complete();
      await assertion;
      expectApplyAvailable('session');
    },
  );

  test(
    'diagnostic failure releases the lease without hiding the error',
    () async {
      trackerRepo.beforeDiagnostic = () async {
        expect(gate.tryApply('session'), isNull);
        throw StateError('synthetic diagnostic failure');
      };
      await expectLater(invoke(_Operation.rerun), throwsStateError);
      expectApplyAvailable('session');
    },
  );

  test(
    'foreground cleanup failure retains then releases the mutation lease',
    () async {
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      notificationLease.onRelease = () async {
        cleanupStarted.complete();
        await releaseCleanup.future;
        throw StateError('synthetic foreground cleanup failure');
      };
      final future = invoke(_Operation.rerun);
      final assertion = expectLater(future, throwsStateError);
      await cleanupStarted.future;
      expect(gate.tryApply('session'), isNull);
      expectApplyAvailable('other');
      releaseCleanup.complete();
      await assertion;
      expectApplyAvailable('session');
    },
  );
}

class _NotificationLease implements PostGenerationForegroundLease {
  Future<void> Function()? onRelease;

  @override
  Future<void> release() async {
    await onRelease?.call();
  }
}

class _ObservedChatRepo extends ChatRepo {
  _ObservedChatRepo(super.db);

  int reads = 0;
  Future<void> Function()? beforeRead;

  @override
  Future<ChatSession?> getById(String sessionId) async {
    reads++;
    await beforeRead?.call();
    return super.getById(sessionId);
  }
}

class _ObservedTrackerRepo extends TrackerRepo {
  _ObservedTrackerRepo(super.db);

  Future<void> Function()? beforeDiagnostic;

  @override
  Future<void> upsertValue(
    String sessionId,
    String name,
    String value, {
    String scope = 'chat',
    String provenance = '',
    int basisRevisionNumber = 0,
    String basisRevisionHash = '',
  }) async {
    if (scope == 'ledger_diagnostic') await beforeDiagnostic?.call();
    await super.upsertValue(
      sessionId,
      name,
      value,
      scope: scope,
      provenance: provenance,
      basisRevisionNumber: basisRevisionNumber,
      basisRevisionHash: basisRevisionHash,
    );
  }
}

class _Executor implements StudioLedgerExecutor {
  int calls = 0;
  final started = Completer<void>();
  Future<LedgerRunResult> Function()? action;

  Future<LedgerRunResult> _execute() async {
    calls++;
    if (!started.isCompleted) started.complete();
    return await action?.call() ??
        const LedgerRunResult(status: 'error', opsApplied: 0);
  }

  @override
  Future<LedgerRunResult> run({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required String finalAssistantText,
    required String recentHistoryText,
    required ChatMessage target,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
    required StudioLedgerEngine engine,
  }) => _execute();

  @override
  Future<LedgerRunResult> reconcile({
    required String sessionId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required LedgerReconciliationPlan plan,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  }) => _execute();

  @override
  Future<LedgerRunResult> replaceLatestReconciliation({
    required String sessionId,
    required String expectedRunId,
    required StudioTurnConfigSnapshot turnConfig,
    required AuxApiConfig config,
    required MacroContext macroCtx,
    required FutureOr<bool> Function() isStillCurrent,
  }) => _execute();
}
