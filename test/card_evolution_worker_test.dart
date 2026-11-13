import 'dart:async';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_repo.dart';
import 'package:glaze_flutter/core/services/card_rewriter/automated_card_evolution_service.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_evolution_worker.dart';

class _Execution implements CardEvolutionJobExecution {
  final entered = Completer<void>();
  final result = Completer<CardEvolutionFinalizeOutcome>();
  bool disposed = false;
  @override
  Future<CardEvolutionFinalizeOutcome> run(
    void Function(AutomatedCardEvolutionStage) onStage,
  ) {
    entered.complete();
    return result.future;
  }

  @override
  void dispose() => disposed = true;
}

void main() {
  late AppDatabase db;
  late CardEvolutionJobRepo repo;
  late CardEvolutionWorker worker;
  late _Execution execution;
  late int now;
  late int starts;
  late int finishes;
  late bool Function() current;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardEvolutionJobRepo(db);
    execution = _Execution();
    now = 100;
    starts = finishes = 0;
    worker = CardEvolutionWorker(
      repo: repo,
      now: () => now,
      createExecution: (job, isCurrent) async {
        starts++;
        current = isCurrent;
        return execution;
      },
      onFinished: (_, _) => finishes++,
    );
    await db
        .into(db.characters)
        .insert(CharactersCompanion.insert(charId: 'c', name: 'C'));
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: 's',
            characterId: 'c',
            sessionIndex: 0,
            messagesJson: '[]',
          ),
        );
  });
  tearDown(() async {
    worker.dispose();
    await db.close();
  });

  Future<CardEvolutionJobRow> enqueue({
    String run = 'r',
    int ordinal = 1,
  }) async {
    await db
        .into(db.ledgerReconciliationSuccessfulRuns)
        .insert(
          LedgerReconciliationSuccessfulRunsCompanion.insert(
            id: run,
            sessionId: 's',
            ordinal: ordinal,
            startMessageId: run,
            startSwipeId: 0,
            startAgentSwipeId: 0,
            endMessageId: run,
            endSwipeId: 0,
            endAgentSwipeId: 0,
            anchorsJson: '[]',
            rangeHash: 'range-$run',
            acceptedManifestRefsJson: '[]',
            effectiveCanonStamp: 'stamp',
            effectiveCanonRevision: 1,
            effectiveCanonHash: 'canon',
            canonicalResultJson: '{}',
            contentHash: 'content-$run',
            predecessorChainHash: '',
            chainHash: 'chain-$run',
            contractVersion: 1,
            opsAppliedJson: '[]',
            createdAt: 90,
          ),
        );
    return repo.enqueue(
      sessionId: 's',
      characterId: 'c',
      reconciliationRunId: run,
      routingSnapshotJson: '{}',
      routingSnapshotHash: 'hash',
      now: 100,
    );
  }

  test(
    'two-second reservation delay does not execute or hold caller',
    () async {
      final job = await enqueue();
      await worker.notifyPending();
      expect(starts, 0);
      expect((await repo.getById(job.id))!.status, 'pending');
      now = 102;
      final drain = worker.notifyPending();
      await execution.entered.future;
      expect(current(), isTrue);
      expect((await repo.getById(job.id))!.status, 'running');
      execution.result.complete(
        const CardEvolutionFinalizeOutcome('collectorCompleted'),
      );
      await drain;
      expect((await repo.getById(job.id))!.status, 'completed');
      expect(finishes, 1);
      expect(execution.disposed, isTrue);
    },
  );

  test(
    'cancel exact running job invalidates lifetime and rejects late success',
    () async {
      final job = await enqueue();
      now = 102;
      final drain = worker.notifyPending();
      await execution.entered.future;
      await worker.cancel(job.id);
      expect(current(), isFalse);
      expect(execution.disposed, isTrue);
      execution.result.complete(
        const CardEvolutionFinalizeOutcome('persisted'),
      );
      await drain;
      expect((await repo.getById(job.id))!.status, 'cancelled');
      expect(finishes, 0);
    },
  );

  test(
    'cancel delayed job never creates execution and startup does not revive it',
    () async {
      final job = await enqueue();
      await worker.cancel(job.id);
      now = 1000;
      await worker.recoverAndDrain();
      expect(starts, 0);
      expect((await repo.getById(job.id))!.status, 'cancelled');
    },
  );

  test(
    'source rebind rejects result and suppresses navigation callback',
    () async {
      final job = await enqueue();
      now = 102;
      final drain = worker.notifyPending();
      await execution.entered.future;
      await db
          .into(db.characters)
          .insert(CharactersCompanion.insert(charId: 'fork', name: 'Fork'));
      await (db.update(db.chatSessions)..where((s) => s.sessionId.equals('s')))
          .write(const ChatSessionsCompanion(characterId: Value('fork')));
      execution.result.complete(
        const CardEvolutionFinalizeOutcome('persisted'),
      );
      await drain;
      expect((await repo.getById(job.id))!.status, 'stale');
      expect(finishes, 0);
    },
  );

  test(
    'a restarted worker reclaims expired lease but not the old owner',
    () async {
      final job = await enqueue();
      now = 102;
      final oldDrain = worker.notifyPending();
      await execution.entered.future;
      final old = execution;
      final oldCurrent = current;
      worker.dispose();
      expect(oldCurrent(), isFalse);
      old.result.complete(
        const CardEvolutionFinalizeOutcome('collectorCompleted'),
      );
      await oldDrain;
      execution = _Execution();
      worker = CardEvolutionWorker(
        repo: repo,
        now: () => now,
        createExecution: (_, isCurrent) async {
          current = isCurrent;
          return execution;
        },
      );
      now = 1003;
      final recovered = worker.recoverAndDrain();
      await execution.entered.future;
      expect(current(), isTrue);
      expect(oldCurrent(), isFalse);
      execution.result.complete(
        const CardEvolutionFinalizeOutcome('collectorCompleted'),
      );
      await recovered;
      expect((await repo.getById(job.id))!.status, 'completed');
    },
  );

  test(
    'different routing after restart is stale, never silently rerouted',
    () async {
      final job = await enqueue();
      worker.dispose();
      worker = CardEvolutionWorker(
        repo: repo,
        now: () => now,
        createExecution: (_, _) async => throw const StaleCardEvolutionJob(),
      );
      now = 102;
      await worker.recoverAndDrain();
      expect((await repo.getById(job.id))!.status, 'stale');
      expect(starts, 0);
      await worker.recoverAndDrain();
      expect((await repo.getById(job.id))!.status, 'stale');
    },
  );
}
