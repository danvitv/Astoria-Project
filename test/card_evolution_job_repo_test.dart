import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_job_repo.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

void main() {
  late AppDatabase db;
  late CardEvolutionJobRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = CardEvolutionJobRepo(db);
  });
  tearDown(() => db.close());

  Future<void> source({
    String session = 'session',
    String character = 'character',
    String run = 'run',
    int ordinal = 1,
  }) async {
    await db
        .into(db.characters)
        .insertOnConflictUpdate(
          CharactersCompanion.insert(charId: character, name: character),
        );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: session,
            characterId: character,
            sessionIndex: 0,
            messagesJson: '[]',
          ),
          mode: InsertMode.insertOrIgnore,
        );
    await db
        .into(db.ledgerReconciliationSuccessfulRuns)
        .insert(
          LedgerReconciliationSuccessfulRunsCompanion.insert(
            id: run,
            sessionId: session,
            ordinal: ordinal,
            startMessageId: 'assistant-$run',
            startSwipeId: 0,
            startAgentSwipeId: 0,
            endMessageId: 'assistant-$run',
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
  }

  Future<CardEvolutionJobRow> enqueue({
    String session = 'session',
    String character = 'character',
    String run = 'run',
    int now = 100,
    String routing = '{"apiConfigId":"route"}',
  }) => repo.enqueue(
    sessionId: session,
    characterId: character,
    reconciliationRunId: run,
    routingSnapshotJson: routing,
    routingSnapshotHash: 'routing-hash',
    now: now,
  );

  test(
    'exact run reservation is idempotent and preserves routing/delay',
    () async {
      await source();
      final first = await enqueue();
      final duplicate = await enqueue(now: 200, routing: '{}');
      expect(duplicate.id, first.id);
      expect(duplicate.sessionId, 'session');
      expect(duplicate.characterId, 'character');
      expect(duplicate.reconciliationRunId, 'run');
      expect(duplicate.reconciliationChainHash, 'chain-run');
      expect(duplicate.routingSnapshotJson, first.routingSnapshotJson);
      expect(duplicate.routingSnapshotHash, 'routing-hash');
      expect(duplicate.availableAt, 102);
      expect(await repo.claim(id: first.id, now: 101), isNull);
      final claimed = await repo.claim(id: first.id, now: 102);
      expect(claimed?.status, 'running');
      expect(claimed?.ownerNonce, isNotEmpty);
      expect(claimed?.leaseUntil, 162);
      expect((await repo.listUnfinished()), hasLength(1));
    },
  );

  test(
    'unfinished and recovery reads include future jobs in stable order',
    () async {
      await source(run: 'a');
      await source(run: 'b', ordinal: 2);
      final later = await enqueue(run: 'b', now: 110);
      final earlier = await enqueue(run: 'a');
      expect((await repo.listUnfinished()).map((row) => row.id), [
        earlier.id,
        later.id,
      ]);
      expect(await repo.watchUnfinished().first, hasLength(2));
      expect(await repo.listRecoverable(now: 100), hasLength(2));
      await repo.claim(id: earlier.id, now: 102, leaseSeconds: 10);
      expect((await repo.listRecoverable(now: 111)).single.id, later.id);
      expect(await repo.listRecoverable(now: 112), hasLength(2));
    },
  );

  test('claim CAS serializes a session but not other sessions', () async {
    await source(run: 'a');
    await source(run: 'b', ordinal: 2);
    await source(session: 'other', run: 'c');
    final a = await enqueue(run: 'a');
    final b = await enqueue(run: 'b');
    final c = await enqueue(session: 'other', run: 'c');
    final otherRepo = CardEvolutionJobRepo(db);
    final claims = await Future.wait([
      repo.claim(id: a.id, now: 102),
      otherRepo.claim(id: b.id, now: 102),
    ]);
    expect(claims.whereType<CardEvolutionJobRow>(), hasLength(1));
    final live = claims.whereType<CardEvolutionJobRow>().single;
    expect(await otherRepo.claim(id: live.id, now: 103), isNull);
    expect(await repo.claim(id: c.id, now: 102), isNotNull);
    await repo.cancel(id: live.id, now: 103);
    final blocked = live.id == a.id ? b : a;
    expect(await otherRepo.claim(id: blocked.id, now: 103), isNotNull);
  });

  test(
    'cancel rejects late finish and heartbeat without reviving job',
    () async {
      await source();
      final job = await enqueue();
      final claim = (await repo.claim(id: job.id, now: 102))!;
      expect(
        await repo.isOwned(id: job.id, ownerNonce: claim.ownerNonce!, now: 103),
        isTrue,
      );
      expect(
        await repo.cancel(id: job.id, now: 104, resultDetail: 'user'),
        isTrue,
      );
      expect(
        await repo.finish(
          id: job.id,
          ownerNonce: claim.ownerNonce!,
          now: 105,
          status: CardEvolutionJobStatus.completed,
        ),
        isFalse,
      );
      expect(
        await repo.heartbeat(
          id: job.id,
          ownerNonce: claim.ownerNonce!,
          now: 105,
        ),
        isFalse,
      );
      expect(
        await repo.isOwned(id: job.id, ownerNonce: claim.ownerNonce!, now: 105),
        isFalse,
      );
      expect((await enqueue()).status, 'cancelled');
      expect(await repo.recoverExpiredLeases(now: 500), 0);
      expect((await repo.getById(job.id))?.resultDetail, 'user');
      expect(await repo.listUnfinished(), isEmpty);
    },
  );

  test('heartbeat is exact nonce and expiry bounded', () async {
    await source();
    final job = await enqueue();
    final claim = (await repo.claim(id: job.id, now: 102, leaseSeconds: 10))!;
    expect(
      await repo.heartbeat(id: job.id, ownerNonce: 'wrong', now: 103),
      isFalse,
    );
    expect(
      await repo.heartbeat(
        id: job.id,
        ownerNonce: claim.ownerNonce!,
        now: 110,
        leaseSeconds: 10,
      ),
      isTrue,
    );
    expect((await repo.getById(job.id))?.leaseUntil, 120);
    expect(
      await repo.isOwned(id: job.id, ownerNonce: claim.ownerNonce!, now: 120),
      isFalse,
    );
    expect(
      await repo.heartbeat(id: job.id, ownerNonce: claim.ownerNonce!, now: 120),
      isFalse,
    );
  });

  test(
    'expired claim can be replaced directly without accepting old owner',
    () async {
      await source();
      final job = await enqueue();
      final old = (await repo.claim(id: job.id, now: 102, leaseSeconds: 10))!;
      final next = (await repo.claim(id: job.id, now: 112))!;
      expect(next.ownerNonce, isNot(old.ownerNonce));
      expect(
        await repo.finish(
          id: job.id,
          ownerNonce: old.ownerNonce!,
          now: 113,
          status: CardEvolutionJobStatus.completed,
        ),
        isFalse,
      );
      expect(
        await repo.isOwned(id: job.id, ownerNonce: next.ownerNonce!, now: 113),
        isTrue,
      );
    },
  );

  test('recovery stales invalid sources instead of requeuing them', () async {
    await source();
    final job = await enqueue();
    await repo.claim(id: job.id, now: 102, leaseSeconds: 10);
    await db
        .into(db.ledgerReconciliationRunInvalidations)
        .insert(
          LedgerReconciliationRunInvalidationsCompanion.insert(
            sessionId: 'session',
            runId: 'run',
            causeMessageId: 'removed',
            reason: 'rollback',
            createdAt: 103,
          ),
        );
    expect(await repo.recoverExpiredLeases(now: 112), 1);
    expect((await repo.getById(job.id))?.status, 'stale');
    expect(await repo.recoverExpiredLeases(now: 200), 0);
  });

  test(
    'bounded expired recovery invalidates old nonce before and after re-claim',
    () async {
      await source(run: 'a');
      await source(session: 'other', run: 'b');
      final a = await enqueue(run: 'a');
      final b = await enqueue(session: 'other', run: 'b');
      final old = (await repo.claim(id: a.id, now: 102, leaseSeconds: 10))!;
      await repo.claim(id: b.id, now: 102, leaseSeconds: 10);
      expect(
        await repo.finish(
          id: a.id,
          ownerNonce: old.ownerNonce!,
          now: 112,
          status: CardEvolutionJobStatus.completed,
        ),
        isFalse,
      );
      expect(await repo.recoverExpiredLeases(now: 112, limit: 1), 1);
      expect((await repo.getById(a.id))?.status, 'pending');
      expect(
        await repo.finish(
          id: a.id,
          ownerNonce: old.ownerNonce!,
          now: 112,
          status: CardEvolutionJobStatus.completed,
        ),
        isFalse,
      );
      final current = (await repo.claim(id: a.id, now: 112))!;
      expect(current.ownerNonce, isNot(old.ownerNonce));
      expect(
        await repo.finish(
          id: a.id,
          ownerNonce: old.ownerNonce!,
          now: 113,
          status: CardEvolutionJobStatus.completed,
        ),
        isFalse,
      );
      expect(
        await repo.finish(
          id: a.id,
          ownerNonce: current.ownerNonce!,
          now: 113,
          status: CardEvolutionJobStatus.completed,
          resultDetail: 'review-ready',
        ),
        isTrue,
      );
      expect((await repo.getById(a.id))?.resultDetail, 'review-ready');
    },
  );

  for (final terminal in CardEvolutionJobStatus.values.where(
    (s) => s.isTerminal,
  )) {
    test('${terminal.name} is never automatically revived', () async {
      await source();
      final job = await enqueue();
      final claim = (await repo.claim(id: job.id, now: 102))!;
      expect(
        await repo.finish(
          id: job.id,
          ownerNonce: claim.ownerNonce!,
          now: 103,
          status: terminal,
        ),
        isTrue,
      );
      expect((await enqueue(now: 1000)).status, terminal.name);
      expect(await repo.recoverExpiredLeases(now: 1000), 0);
      expect(await repo.claim(id: job.id, now: 1000), isNull);
      expect(await repo.cancel(id: job.id, now: 1000), isFalse);
    });
  }

  test(
    'enqueue refuses missing run, mismatched session and character',
    () async {
      await expectLater(enqueue(), throwsStateError);
      await source();
      await expectLater(enqueue(session: 'other'), throwsStateError);
      await expectLater(enqueue(character: 'other'), throwsStateError);
      expect(await repo.listUnfinished(), isEmpty);
    },
  );

  test(
    'character fork permanently stales work and rejects late owner',
    () async {
      await source();
      final job = await enqueue();
      final claim = (await repo.claim(id: job.id, now: 102))!;
      await (db.update(db.chatSessions)
            ..where((s) => s.sessionId.equals('session')))
          .write(const ChatSessionsCompanion(characterId: Value('fork')));
      await (db.update(db.chatSessions)
            ..where((s) => s.sessionId.equals('session')))
          .write(const ChatSessionsCompanion(characterId: Value('character')));
      expect((await repo.getById(job.id))?.status, 'stale');
      expect(
        await repo.isOwned(id: job.id, ownerNonce: claim.ownerNonce!, now: 103),
        isFalse,
      );
      expect(
        await repo.finish(
          id: job.id,
          ownerNonce: claim.ownerNonce!,
          now: 103,
          status: CardEvolutionJobStatus.completed,
        ),
        isFalse,
      );
      expect(await repo.claim(id: job.id, now: 103), isNull);
    },
  );

  test(
    'source run deletion retains stale reservation, not replayable work',
    () async {
      await source();
      final job = await enqueue();
      await db.delete(db.ledgerReconciliationSuccessfulRuns).go();
      expect(await repo.claim(id: job.id, now: 102), isNull);
      expect((await repo.getById(job.id))?.status, 'stale');
      await source();
      expect((await enqueue()).status, 'stale');
    },
  );

  test(
    'invalidated source fails closed at enqueue/claim/owned guard',
    () async {
      await source(run: 'a');
      await source(session: 'other', run: 'b');
      final a = await enqueue(run: 'a');
      final b = await enqueue(session: 'other', run: 'b');
      final live = (await repo.claim(id: b.id, now: 102))!;
      for (final (session, run) in [('session', 'a'), ('other', 'b')]) {
        await db
            .into(db.ledgerReconciliationRunInvalidations)
            .insert(
              LedgerReconciliationRunInvalidationsCompanion.insert(
                sessionId: session,
                runId: run,
                causeMessageId: 'removed',
                reason: 'rollback',
                createdAt: 103,
              ),
            );
      }
      expect(await repo.claim(id: a.id, now: 103), isNull);
      expect((await repo.getById(a.id))?.status, 'stale');
      expect(
        await repo.isOwned(id: b.id, ownerNonce: live.ownerNonce!, now: 103),
        isFalse,
      );
      expect((await repo.getById(b.id))?.status, 'stale');
      await source(run: 'c', ordinal: 2);
      await db
          .into(db.ledgerReconciliationRunInvalidations)
          .insert(
            LedgerReconciliationRunInvalidationsCompanion.insert(
              sessionId: 'session',
              runId: 'c',
              causeMessageId: 'removed',
              reason: 'rollback',
              createdAt: 103,
            ),
          );
      await expectLater(enqueue(run: 'c'), throwsStateError);
    },
  );

  test('session deletion cascades even with foreign keys disabled', () async {
    await source();
    final job = await enqueue();
    await db.customStatement('PRAGMA foreign_keys = OFF');
    await db.delete(db.chatSessions).go();
    expect(await repo.getById(job.id), isNull);
    expect(await repo.claim(id: job.id, now: 102), isNull);
  });

  test(
    'v144 upgrade creates queue, indexes and lifecycle triggers in memory',
    () async {
      final raw = sqlite.sqlite3.openInMemory();
      final old = AppDatabase.forTesting(
        NativeDatabase.opened(raw, closeUnderlyingOnClose: false),
      );
      await old.customSelect('SELECT 1').get();
      await old.customStatement('DROP TABLE card_evolution_jobs');
      // DROP TABLE removes its indexes, but not triggers attached to source tables.
      for (final name in ['session_delete', 'session_fork', 'source_delete']) {
        await old.customStatement('DROP TRIGGER card_evolution_jobs_$name');
      }
      await old.customStatement('PRAGMA user_version = 143');
      await old.close();
      final upgraded = AppDatabase.forTesting(NativeDatabase.opened(raw));
      addTearDown(upgraded.close);
      expect(await CardEvolutionJobRepo(upgraded).listUnfinished(), isEmpty);
      final version = await upgraded
          .customSelect('PRAGMA user_version')
          .getSingle();
      expect(version.read<int>('user_version'), 144);
      final indexes =
          (await upgraded
                  .customSelect(
                    "SELECT name FROM sqlite_master WHERE type = 'index' AND tbl_name = 'card_evolution_jobs'",
                  )
                  .get())
              .map((row) => row.read<String>('name'));
      expect(
        indexes,
        containsAll([
          'idx_card_evolution_job_reconciliation',
          'idx_card_evolution_job_recoverable',
          'idx_card_evolution_job_session',
        ]),
      );
      final triggers = await upgraded
          .customSelect(
            "SELECT name FROM sqlite_master WHERE type = 'trigger' AND name LIKE 'card_evolution_jobs_%'",
          )
          .get();
      expect(triggers, hasLength(3));
    },
  );
}
