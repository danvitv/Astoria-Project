import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/models/session_repair.dart';
import 'package:glaze_flutter/core/db/repositories/session_repair_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';

import '../database_maintenance/maintenance_fixture.dart';
import 'session_repair_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  repairTest(
    'fresh parent Undo restores Ledger after genuine later USER and ordered reply',
    (f) async {
      final original = await f.db.select(f.db.trackerRows).get();
      final plan = (await f.correction())!;
      final applied = (await f.apply(plan))!;
      expect(applied.outcome, SessionRepairOutcome.applied);
      final journal =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      await _laterTurn(f);
      final untouched = await f.snapshotExcept({
        'tracker_rows',
        'support_mutation_journal',
      });
      var freshCurrent = true;
      final observation = (await f.repo.prepareUndo(
        receipt: applied,
        supportSessionId: MaintenanceFixture.sessionId,
        isCurrent: () => freshCurrent,
      ))!;
      expect(
        await f.snapshotExcept({'tracker_rows', 'support_mutation_journal'}),
        untouched,
      );
      // Later Undo owns fresh admission, not a revived old Apply callback.
      f.current = false;
      final undone = (await f.repo.undo(
        receipt: applied,
        parentObservation: observation,
        isCurrent: () => freshCurrent,
      ))!;
      expect(undone.outcome, SessionRepairOutcome.undone);
      final restored = await f.db.select(f.db.trackerRows).get();
      expect(
        restored.where(
          (r) => r.name != TrackerRepo.ledgerManualMutationRevisionName,
        ),
        original,
      );
      expect(
        await TrackerRepo(
          f.db,
        ).getLedgerManualMutationRevision(RepairFixture.session),
        2,
      );
      expect(
        await f.snapshotExcept({'tracker_rows', 'support_mutation_journal'}),
        untouched,
      );
      final latest =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      expect(latest.status, 'undone');
      expect(latest.beforeCiphertext, journal.beforeCiphertext);
      expect(latest.afterCiphertext, journal.afterCiphertext);
      _protected(observation, applied, undone, latest.beforeCiphertext);
      freshCurrent = false;
      expect(
        await f.repo.undo(
          receipt: applied,
          parentObservation: observation,
          isCurrent: () => freshCurrent,
        ),
        isNull,
      );
    },
  );

  repairTest(
    'fresh parent Undo restores Collector original without rolling back parent or messages',
    (f) async {
      await f.collector();
      final original =
          (await f.db.select(f.db.cardEvolutionCollectorRuns).get()).single;
      final target = (await f.inspect()).targets.singleWhere(
        (t) => t.kind == SessionRepairTargetKind.collectorAttempt,
      );
      final plan = (await f.repo.prepareDeleteUnusedCollectorAttempt(
        target: target,
        operationId: 'synthetic-fresh-collector',
        createdAt: 20,
        isCurrent: f.isCurrent,
      )).plan!;
      final applied = (await f.apply(plan))!;
      expect(await f.db.select(f.db.cardEvolutionCollectorRuns).get(), isEmpty);
      final journal =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      final native = jsonDecode(
        SupportMutationEvidence.decode(
          (await f.base.support.getMutationById(plan.operationId))!.beforeJson,
        )!,
      );
      expect(native['row']['failure_detail'], RepairFixture.canary);
      await _laterTurn(f);
      final untouched = await f.snapshotExcept({
        'card_evolution_collector_runs',
        'support_mutation_journal',
      });
      final beforePrepare = await f.base.snapshot();
      final observation = (await _observe(f, applied))!;
      expect(await f.base.snapshot(), beforePrepare);
      final undone = (await _undo(f, applied, observation))!;
      expect(undone.outcome, SessionRepairOutcome.undone);
      expect(
        (await f.db.select(f.db.cardEvolutionCollectorRuns).get()).single,
        original,
      );
      expect(
        await f.snapshotExcept({
          'card_evolution_collector_runs',
          'support_mutation_journal',
        }),
        untouched,
      );
      final latest =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      expect(latest.status, 'undone');
      expect(latest.beforeCiphertext, journal.beforeCiphertext);
      expect(latest.afterCiphertext, journal.afterCiphertext);
      _protected(observation, applied, undone, latest.beforeCiphertext);
      expect(await _undo(f, applied, observation), isNull);
    },
  );

  for (final entry in <String, Object>{
    'created_at': 9,
    'pinned': 1,
    'mode': 'local',
    'active_api_config_id': 'synthetic-other-api',
    'active_model_id': 'synthetic-other-model',
    'updated_at': 1,
  }.entries) {
    repairTest('fresh parent Undo refuses changed original ${entry.key}', (
      f,
    ) async {
      final applied = (await f.apply((await f.correction())!))!;
      await _laterTurn(f);
      await f.db.customStatement(
        'UPDATE support_sessions SET ${entry.key}=? WHERE id=?',
        [entry.value, MaintenanceFixture.sessionId],
      );
      final before = await f.base.snapshot();
      expect(await _observe(f, applied), isNull);
      expect(await f.base.snapshot(), before);
    });
  }

  repairTest('fresh parent Undo refuses re-encrypted SAME title', (f) async {
    final applied = (await f.apply((await f.correction())!))!;
    await _laterTurn(f);
    await f.base.support.renameSession(
      sessionId: MaintenanceFixture.sessionId,
      title: MaintenanceFixture.canary,
    );
    final before = await f.base.snapshot();
    expect(await _observe(f, applied), isNull);
    expect(await f.base.snapshot(), before);
  });

  repairTest('fresh parent Undo denies foreign parent and foreign core owner', (
    f,
  ) async {
    final applied = (await f.apply((await f.correction())!))!;
    await _laterTurn(f);
    await f.base.support.createSession(
      const SupportSession(
        id: 'synthetic-foreign-parent',
        title: 'Synthetic foreign',
        createdAt: 1,
        updatedAt: 2,
      ),
    );
    final observation = (await _observe(f, applied))!;
    final other = SessionRepairRepo(f.db, f.base.support);
    final before = await f.base.snapshot();
    expect(
      await f.repo.prepareUndo(
        receipt: applied,
        supportSessionId: 'synthetic-foreign-parent',
        isCurrent: f.isCurrent,
      ),
      isNull,
    );
    expect(
      await other.prepareUndo(
        receipt: applied,
        supportSessionId: MaintenanceFixture.sessionId,
        isCurrent: f.isCurrent,
      ),
      isNull,
    );
    expect(
      await other.undo(
        receipt: applied,
        parentObservation: observation,
        isCurrent: f.isCurrent,
      ),
      isNull,
    );
    expect(await f.base.snapshot(), before);
  });

  repairTest('fresh parent Undo denies missing original parent', (f) async {
    final applied = (await f.apply((await f.correction())!))!;
    await _laterTurn(f);
    await f.db.customStatement('DELETE FROM support_sessions WHERE id=?', [
      MaintenanceFixture.sessionId,
    ]);
    final before = await f.base.snapshot();
    expect(await _observe(f, applied), isNull);
    expect(await f.base.snapshot(), before);
  });

  for (final change in ['clock', 'model']) {
    repairTest('fresh parent Undo denies $change change after observation', (
      f,
    ) async {
      final applied = (await f.apply((await f.correction())!))!;
      await _laterTurn(f);
      final observation = (await _observe(f, applied))!;
      if (change == 'clock') {
        final later = await f.base.support.appendCurrentUser(
          message: const SupportMessage(
            id: 'synthetic-even-later-user',
            sessionId: MaintenanceFixture.sessionId,
            role: 'user',
            body: 'Another original native input',
            runId: 'synthetic-even-later-run',
            createdAt: 50,
          ),
          isCurrent: f.isCurrent,
        );
        expect(later, isNotNull);
      } else {
        await f.base.support.updateSessionMetadata(
          sessionId: MaintenanceFixture.sessionId,
          activeModelId: 'synthetic-changed-after-observation',
        );
      }
      final before = await f.base.snapshot();
      expect(await _undo(f, applied, observation), isNull);
      expect(await f.base.snapshot(), before);
    });
  }

  repairTest('fresh parent Undo keeps legacy full guard without observation', (
    f,
  ) async {
    final applied = (await f.apply((await f.correction())!))!;
    await _laterTurn(f);
    final before = await f.snapshotExcept({'support_mutation_journal'});
    expect((await f.undo(applied))!.outcome, SessionRepairOutcome.undoConflict);
    expect(await f.snapshotExcept({'support_mutation_journal'}), before);
  });

  for (final change in ['target', 'source', 'revision', 'head']) {
    repairTest('fresh parent Undo keeps exact latest $change conflict', (
      f,
    ) async {
      if (change == 'head') await f.collector();
      final applied = (await f.apply((await f.correction())!))!;
      await _laterTurn(f);
      final observation = (await _observe(f, applied))!;
      switch (change) {
        case 'target':
          await f.db.customStatement(
            'UPDATE tracker_rows SET value=? WHERE session_id=? AND name=?',
            [
              'Synthetic competing value',
              RepairFixture.session,
              'world:location',
            ],
          );
          break;
        case 'source':
          await f.db.customStatement(
            'UPDATE chat_sessions SET draft=? WHERE session_id=?',
            ['Synthetic latest draft', RepairFixture.session],
          );
          break;
        case 'revision':
          await f.db.transaction(
            () => TrackerRepo(
              f.db,
            ).bumpLedgerManualMutationRevision(RepairFixture.session),
          );
          break;
        case 'head':
          await f.advanceHead();
          break;
      }
      final before = await f.snapshotExcept({'support_mutation_journal'});
      expect(
        (await _undo(f, applied, observation))!.outcome,
        SessionRepairOutcome.undoConflict,
      );
      expect(await f.snapshotExcept({'support_mutation_journal'}), before);
      expect(
        (await f.db.select(f.db.supportMutationJournal).get()).single.status,
        'undo_conflict',
      );
    });
  }

  repairTest('fresh parent Undo cannot revive retired observation authority', (
    f,
  ) async {
    final applied = (await f.apply((await f.correction())!))!;
    await _laterTurn(f);
    var observationCurrent = true;
    final observation = (await f.repo.prepareUndo(
      receipt: applied,
      supportSessionId: MaintenanceFixture.sessionId,
      isCurrent: () => observationCurrent,
    ))!;
    observationCurrent = false;
    final before = await f.base.snapshot();
    expect(await _undo(f, applied, observation), isNull);
    expect(await f.base.snapshot(), before);
  });

  for (final change in ['clock', 'model']) {
    repairTest(
      'fresh parent Undo post-decrypt $change change rolls back all provisional writes',
      (f) async {
        final applied = (await f.apply((await f.correction())!))!;
        await _laterTurn(f);
        final observation = (await _observe(f, applied))!;
        final before = await f.base.snapshot();
        final originalDecrypted =
            'decrypt-after:astoria.support.v1|support_mutation_journal|'
            '${applied.operationId}|${MaintenanceFixture.sessionId}|before_ciphertext';
        var changed = false;
        f.base.hook = (event) async {
          if (changed || event != originalDecrypted) return;
          await f.db.customStatement(
            change == 'clock'
                ? 'UPDATE support_sessions SET updated_at=99 WHERE id=?'
                : 'UPDATE support_sessions SET active_model_id=? WHERE id=?',
            [
              if (change == 'model') 'synthetic-post-decrypt-model',
              MaintenanceFixture.sessionId,
            ],
          );
          changed = true;
        };
        final result = await _undo(f, applied, observation);
        f.base.hook = null;
        expect(
          changed,
          isTrue,
          reason:
              'Actual ORIGINAL post-decrypt hook must complete its parent write.',
        );
        expect(result, isNull);
        expect(await f.base.snapshot(), before);
      },
    );
  }
}

Future<void> _laterTurn(RepairFixture f) async {
  final parent = (await f.db.select(f.db.supportSessions).get()).single;
  final user = (await f.base.support.appendCurrentUser(
    message: const SupportMessage(
      id: 'synthetic-later-user',
      sessionId: MaintenanceFixture.sessionId,
      role: 'user',
      body: 'Original native later Undo request',
      runId: 'synthetic-later-run',
      createdAt: 50,
    ),
    isCurrent: f.isCurrent,
  ))!;
  expect(user.createdAt, 51);
  final reply = (await f.base.support.reserveOrderedReply(
    message: const SupportMessage(
      id: 'synthetic-later-reply',
      sessionId: MaintenanceFixture.sessionId,
      role: 'assistant',
      body: '',
      runId: 'synthetic-later-run',
      status: 'preparing',
      createdAt: 50,
    ),
    originatingUser: user,
    provenanceJson: '{"kind":"synthetic-native-undo-request"}',
    isCurrent: f.isCurrent,
  ))!;
  expect(reply.message.createdAt, 52);
  expect(
    await f.base.support.settleReply(
      expected: reply,
      status: 'complete',
      body: 'Fixed synthetic native reply',
      isCurrent: f.isCurrent,
    ),
    isNotNull,
  );
  final latest = (await f.db.select(f.db.supportSessions).get()).single;
  expect(latest.updatedAt, greaterThan(parent.updatedAt));
  expect(latest.copyWith(updatedAt: parent.updatedAt), parent);
}

Future<SessionRepairUndoObservation?> _observe(
  RepairFixture f,
  SessionRepairReceipt receipt,
) => f.repo.prepareUndo(
  receipt: receipt,
  supportSessionId: MaintenanceFixture.sessionId,
  isCurrent: f.isCurrent,
);

Future<SessionRepairReceipt?> _undo(
  RepairFixture f,
  SessionRepairReceipt receipt,
  SessionRepairUndoObservation observation,
) => f.repo.undo(
  receipt: receipt,
  parentObservation: observation,
  isCurrent: f.isCurrent,
);

void _protected(
  SessionRepairUndoObservation observation,
  SessionRepairReceipt applied,
  SessionRepairReceipt undone,
  String encryptedOriginal,
) {
  expect(encryptedOriginal, isNot(contains(RepairFixture.canary)));
  expect(encryptedOriginal, isNot(contains('world:')));
  expect(
    '$observation $applied $undone',
    isNot(contains(RepairFixture.canary)),
  );
  expect('$observation $applied $undone', isNot(contains('world:')));
}
