import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/models/session_repair.dart';
import 'package:glaze_flutter/core/db/repositories/session_repair_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';

import '../database_maintenance/maintenance_fixture.dart';
import 'session_repair_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  repairTest(
    'malformed Collector payload stays visible with fixed issue codes',
    (f) async {
      await f.collector();
      await f.observation(malformed: true);
      final before = await f.base.snapshot();
      final inspection = await f.inspect();
      final observation = inspection.targets.singleWhere(
        (t) => t.kind == SessionRepairTargetKind.observation,
      );
      expect(observation.issues, contains(SessionRepairIssue.malformedPayload));
      expect(observation.availability, SessionRepairAvailability.unavailable);
      expect(
        jsonEncode(inspection.toMetadata()),
        isNot(contains(RepairFixture.canary)),
      );
      expect(
        jsonEncode(inspection.toMetadata()),
        isNot(contains('world:location')),
      );
      expect(jsonEncode(inspection.toMetadata()), isNot(contains('SQL')));
      expect(await f.base.snapshot(), before);
    },
  );

  repairTest(
    'unused failed attempt deletes one row and recovers exact encrypted original',
    (f) async {
      await f.collector();
      final untouched = await f.snapshotExcept({
        'card_evolution_collector_runs',
        'support_mutation_journal',
      });
      final original =
          (await f.db.select(f.db.cardEvolutionCollectorRuns).get()).single;
      final target = (await f.inspect()).targets.singleWhere(
        (t) => t.kind == SessionRepairTargetKind.collectorAttempt,
      );
      expect(
        target.availability,
        SessionRepairAvailability.deleteUnusedAttempt,
      );
      final plan = (await f.repo.prepareDeleteUnusedCollectorAttempt(
        target: target,
        operationId: 'synthetic-delete-one',
        createdAt: 21,
        isCurrent: f.isCurrent,
      )).plan!;
      final receipt = (await f.apply(plan))!;
      expect(receipt.outcome, SessionRepairOutcome.applied);
      expect(await f.db.select(f.db.cardEvolutionCollectorRuns).get(), isEmpty);
      expect(
        await f.snapshotExcept({
          'card_evolution_collector_runs',
          'support_mutation_journal',
        }),
        untouched,
      );
      final encrypted =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      expect(encrypted.beforeCiphertext, isNot(contains(RepairFixture.canary)));
      final record = (await f.base.support.getMutationById(plan.operationId))!;
      final native = jsonDecode(
        SupportMutationEvidence.decode(record.beforeJson)!,
      );
      expect(native['row']['failure_detail'], RepairFixture.canary);
      expect(await f.apply(plan), isNull);
      expect((await f.undo(receipt))!.outcome, SessionRepairOutcome.undone);
      expect(
        (await f.db.select(f.db.cardEvolutionCollectorRuns).get()).single,
        original,
      );
      expect(await f.undo(receipt), isNull);
      expect(await f.apply(plan), isNull);
      expect(
        (await f.db.select(f.db.trackerSnapshots).get()).single.messageId,
        '',
      );
    },
  );

  for (final status in ['active', 'promoted', 'consumed']) {
    repairTest(
      '$status observation is not subtraction of aggregate or immutable history',
      (f) async {
        await f.collector();
        await f.observation(status: status);
        final before = await f.base.snapshot();
        final inspected = await f.inspect();
        final candidate = inspected.targets.singleWhere(
          (t) => t.kind == SessionRepairTargetKind.observation,
        );
        expect(candidate.availability, SessionRepairAvailability.unavailable);
        final refused = await f.repo.prepareDeleteUnusedCollectorAttempt(
          target: candidate,
          operationId: 'synthetic-not-subtraction',
          createdAt: 25,
          isCurrent: f.isCurrent,
        );
        expect(refused.plan, isNull);
        final run = inspected.targets.singleWhere(
          (t) => t.kind == SessionRepairTargetKind.collectorAttempt,
        );
        expect(
          (await f.repo.prepareDeleteUnusedCollectorAttempt(
            target: run,
            operationId: 'synthetic-used-attempt',
            createdAt: 25,
            isCurrent: f.isCurrent,
          )).plan,
          isNull,
        );
        final history = inspected.targets.firstWhere(
          (t) => t.kind == SessionRepairTargetKind.reconciliation,
        );
        expect(
          (await f.repo.prepareCorrectExistingLedgerValue(
            target: history,
            value: 'not-history',
            operationId: 'synthetic-history',
            createdAt: 25,
            isCurrent: f.isCurrent,
          )).plan,
          isNull,
        );
        expect(await f.base.snapshot(), before);
      },
    );
  }

  repairTest(
    'existing live Ledger correction CAS, durable fence, exact Undo and no collateral',
    (f) async {
      final unrelated = await f.row('world:location');
      final untouched = await f.snapshotExcept({
        'tracker_rows',
        'support_mutation_journal',
      });
      final before = await f.base.snapshot();
      final plan = (await f.correction())!;
      expect(await f.base.snapshot(), before);
      expect(plan.affectedRecords, 1);
      expect(plan.collateralManualRevisionBumps, 1);
      expect(
        await f.repo.readNativePreview(
          plan: plan,
          hasExactBodySourceLease: () => false,
        ),
        isNull,
      );
      final preview = (await f.repo.readNativePreview(
        plan: plan,
        hasExactBodySourceLease: f.isCurrent,
      ))!;
      final key = preview.before['name'] as String;
      final original = await f.row(key);
      expect(preview.before['value'], RepairFixture.canary);
      expect(preview.toString(), isNot(contains(RepairFixture.canary)));
      final applied = (await f.apply(plan))!;
      expect((await f.row(key))['value'], 'SYNTHETIC_NATIVE_CORRECTION');
      expect((await f.row(key))['provenance'], 'manual_session_repair');
      expect(
        await TrackerRepo(
          f.db,
        ).getLedgerManualMutationRevision(RepairFixture.session),
        1,
      );
      if (key != 'world:location') {
        expect(await f.row('world:location'), unrelated);
      }
      expect(
        await f.snapshotExcept({'tracker_rows', 'support_mutation_journal'}),
        untouched,
      );
      final raw = (await f.db.select(f.db.supportMutationJournal).get()).single;
      expect(raw.status, 'applied');
      expect(raw.beforeCiphertext, isNot(contains('world:')));
      final decrypted = (await f.base.support.getMutationById(
        plan.operationId,
      ))!;
      expect(
        jsonDecode(
          SupportMutationEvidence.decode(decrypted.beforeJson)!,
        )['row'],
        original,
      );
      expect(await f.apply(plan), isNull);
      expect((await f.undo(applied))!.outcome, SessionRepairOutcome.undone);
      expect(await f.row(key), original);
      expect(
        await TrackerRepo(
          f.db,
        ).getLedgerManualMutationRevision(RepairFixture.session),
        2,
      );
      expect(await f.undo(applied), isNull);
      expect(await f.apply(plan), isNull);
    },
  );

  repairTest(
    'invalid/partial/empty values and unknown/protected keys have no effect',
    (f) async {
      for (final name in [
        'world:unknown',
        'canon_override:world:location',
        'npc:{{user}}.current_goal',
      ]) {
        await f.db
            .into(f.db.trackerRows)
            .insert(
              TrackerRowsCompanion.insert(
                sessionId: RepairFixture.session,
                name: name,
                value: const Value('protected'),
                scope: const Value('ledger'),
                provenance: const Value('synthetic'),
              ),
            );
      }
      final before = await f.base.snapshot();
      final inspection = await f.inspect();
      for (final target in inspection.targets.where(
        (t) => t.availability == SessionRepairAvailability.unavailable,
      )) {
        expect(
          (await f.repo.prepareCorrectExistingLedgerValue(
            target: target,
            value: 'new',
            operationId: 'synthetic-invalid',
            createdAt: 20,
            isCurrent: f.isCurrent,
          )).plan,
          isNull,
        );
      }
      for (final value in ['', '  partial  ', 'x' * 1201, '\u0000']) {
        expect(await f.correction(value: value), isNull);
      }
      expect(await f.base.snapshot(), before);
    },
  );

  repairTest('canon locked live key cannot be corrected', (f) async {
    final target = await f.ledgerTarget();
    final plan = (await f.repo.prepareCorrectExistingLedgerValue(
      target: target,
      value: 'new',
      operationId: 'synthetic-lock-before',
      createdAt: 20,
      isCurrent: f.isCurrent,
    )).plan!;
    await f.db
        .into(f.db.trackerRows)
        .insert(
          TrackerRowsCompanion.insert(
            sessionId: RepairFixture.session,
            name: 'canon_lock:world:active_threats',
            value: const Value('true'),
            scope: const Value('ledger'),
          ),
        );
    final before = await f.base.snapshot();
    expect(await f.apply(plan), isNull);
    expect(await f.base.snapshot(), before);
    final inspection = await f.inspect();
    expect(
      inspection.targets.any(
        (t) => t.issues.contains(SessionRepairIssue.lockedTarget),
      ),
      isTrue,
    );
  });

  repairTest('conditional Undo refuses changed exact after or dependency', (
    f,
  ) async {
    final plan = (await f.correction())!;
    final receipt = (await f.apply(plan))!;
    await f.db.customStatement(
      'UPDATE chat_sessions SET draft=? WHERE session_id=?',
      ['synthetic-new-source', RepairFixture.session],
    );
    final before = await f.snapshotExcept({'support_mutation_journal'});
    expect((await f.undo(receipt))!.outcome, SessionRepairOutcome.undoConflict);
    expect(await f.snapshotExcept({'support_mutation_journal'}), before);
    expect(
      (await f.db.select(f.db.supportMutationJournal).get()).single.status,
      'undo_conflict',
    );
  });

  for (final change in [
    'target',
    'session',
    'revision',
    'parent',
    'sourceCancel',
  ]) {
    repairTest('post-AEAD $change retirement rolls back journal and effect', (
      f,
    ) async {
      final plan = (await f.correction())!;
      final before = await f.base.snapshot();
      var changed = false;
      f.base.hook = (event) async {
        if (changed ||
            !event.startsWith('encrypt:') ||
            !event.contains('before_ciphertext')) {
          return;
        }
        changed = true;
        if (change == 'sourceCancel') {
          f.current = false;
          return;
        }
        if (change == 'target') {
          await f.db.customStatement(
            'UPDATE tracker_rows SET value=? WHERE session_id=? AND name=?',
            ['synthetic-changed', RepairFixture.session, 'world:location'],
          );
        }
        if (change == 'session') {
          await f.db.customStatement(
            'UPDATE chat_sessions SET updated_at=99 WHERE session_id=?',
            [RepairFixture.session],
          );
        }
        if (change == 'revision') {
          await f.db
              .into(f.db.trackerRows)
              .insert(
                TrackerRowsCompanion.insert(
                  sessionId: RepairFixture.session,
                  name: TrackerRepo.ledgerManualMutationRevisionName,
                  value: const Value('1'),
                  scope: const Value('system'),
                  provenance: const Value('manual_ledger_mutation'),
                ),
              );
        }
        if (change == 'parent') {
          await f.db.customStatement(
            'UPDATE support_sessions SET updated_at=99 WHERE id=?',
            [MaintenanceFixture.sessionId],
          );
        }
      };
      expect(await f.apply(plan), isNull);
      f.base.hook = null;
      f.current = true;
      expect(changed, isTrue);
      expect(await f.base.snapshot(), before);
    });
  }

  repairTest(
    'storage write-then-fail rolls back original and hides raw error',
    (f) async {
      final plan = (await f.correction())!;
      final before = await f.base.snapshot();
      f.base.hook = (event) async {
        if (event.startsWith('update:UPDATE "tracker_rows"')) {
          throw StateError('SqlError ${RepairFixture.canary} world:location');
        }
      };
      Object? failure;
      try {
        await f.apply(plan);
      } catch (error) {
        failure = error;
      }
      f.base.hook = null;
      expect(failure, isA<SessionRepairStorageException>());
      expect('$failure', isNot(contains('SqlError')));
      expect('$failure', isNot(contains(RepairFixture.canary)));
      expect(await f.base.snapshot(), before);
    },
  );

  repairTest(
    'missing parent, original repo identity and retired original session deny',
    (f) async {
      expect(
        (await f.inspect(parent: 'synthetic-missing-parent')).issues,
        contains(SessionRepairIssue.authorityDenied),
      );
      final plan = (await f.correction())!;
      final otherOwner = SessionRepairRepo(f.db, f.base.support);
      final before = await f.base.snapshot();
      expect(
        await otherOwner.apply(plan: plan, isCurrent: f.isCurrent),
        isNull,
      );
      f.current = false;
      expect(await f.apply(plan), isNull);
      f.current = true;
      expect(await f.base.snapshot(), before);
    },
  );

  repairTest(
    'oversized original refuses without truncation or plaintext journal',
    (f) async {
      await f.collector();
      await f.db.customStatement(
        'UPDATE card_evolution_collector_runs SET failure_detail=? WHERE id=?',
        ['x' * 9000, 'synthetic-failed-collector'],
      );
      final target = (await f.inspect()).targets.singleWhere(
        (t) => t.kind == SessionRepairTargetKind.collectorAttempt,
      );
      final before = await f.base.snapshot();
      final result = await f.repo.prepareDeleteUnusedCollectorAttempt(
        target: target,
        operationId: 'synthetic-oversized',
        createdAt: 20,
        isCurrent: f.isCurrent,
      );
      expect(result.issue, SessionRepairIssue.oversized);
      expect(await f.base.snapshot(), before);
    },
  );

  for (final afterAead in [false, true]) {
    repairTest(
      'logical head changes ${afterAead ? 'after AEAD' : 'before admission'} deny old basis',
      (f) async {
        await f.collector();
        final plan = (await f.correction())!;
        var changed = false;
        if (!afterAead) {
          await f.advanceHead();
          changed = true;
        }
        final before = await f.base.snapshot();
        if (afterAead) {
          f.base.hook = (event) async {
            if (!changed &&
                event.startsWith('encrypt:') &&
                event.contains('before_ciphertext')) {
              changed = true;
              await f.advanceHead();
            }
          };
        }
        expect(await f.apply(plan), isNull);
        f.base.hook = null;
        expect(changed, isTrue);
        expect(await f.base.snapshot(), before);
      },
    );
  }

  repairTest(
    'canonical complete clock validator rejects backward/invalid/partial tuples',
    (f) async {
      await f.db.customStatement(
        'DELETE FROM tracker_rows WHERE session_id=?',
        [RepairFixture.session],
      );
      for (final entry in {
        'world:time': '12:00',
        'world:date': '24.10.2026',
        'world:day': '0',
      }.entries) {
        await f.db
            .into(f.db.trackerRows)
            .insert(
              TrackerRowsCompanion.insert(
                sessionId: RepairFixture.session,
                name: entry.key,
                value: Value(entry.value),
                scope: const Value('ledger'),
                provenance: const Value('game_time_seed'),
              ),
            );
      }
      final inspected = await f.inspect();
      SessionRepairTarget? timeTarget;
      for (final target in inspected.targets) {
        final prepared = await f.repo.prepareCorrectExistingLedgerValue(
          target: target,
          value: '13:00',
          operationId: 'synthetic-clock-find',
          createdAt: 20,
          isCurrent: f.isCurrent,
        );
        if (prepared.plan != null) timeTarget = target;
      }
      expect(timeTarget, isNotNull);
      final before = await f.base.snapshot();
      for (final value in ['11:59', '25:00', '13:0', '00:00']) {
        expect(
          (await f.repo.prepareCorrectExistingLedgerValue(
            target: timeTarget!,
            value: value,
            operationId: 'synthetic-clock-invalid',
            createdAt: 20,
            isCurrent: f.isCurrent,
          )).plan,
          isNull,
        );
      }
      expect(await f.base.snapshot(), before);
      final plan = (await f.repo.prepareCorrectExistingLedgerValue(
        target: timeTarget!,
        value: '13:00',
        operationId: 'synthetic-clock-valid',
        createdAt: 20,
        isCurrent: f.isCurrent,
      )).plan!;
      expect((await f.apply(plan))!.outcome, SessionRepairOutcome.applied);
      expect((await f.row('world:time'))['value'], '13:00');
      expect((await f.row('world:date'))['value'], '24.10.2026');
      expect((await f.row('world:day'))['value'], '0');
    },
  );

  repairTest(
    'incomplete clock and related rewrite require refusal, not hidden reset',
    (f) async {
      await f.db
          .into(f.db.trackerRows)
          .insert(
            TrackerRowsCompanion.insert(
              sessionId: RepairFixture.session,
              name: 'world:time',
              value: const Value('12:00'),
              scope: const Value('ledger'),
              provenance: const Value('game_time_seed'),
            ),
          );
      final inspected = await f.inspect();
      final before = await f.base.snapshot();
      var sawClockRefusal = false;
      for (final target in inspected.targets) {
        final result = await f.repo.prepareCorrectExistingLedgerValue(
          target: target,
          value: '13:00',
          operationId: 'synthetic-partial-clock',
          createdAt: 20,
          isCurrent: f.isCurrent,
        );
        if (result.plan == null &&
            result.issue == SessionRepairIssue.incompleteEvidence) {
          sawClockRefusal = true;
        }
      }
      expect(
        sawClockRefusal,
        isTrue,
        reason: 'The incomplete clock target was refused explicitly.',
      );
      expect(await f.base.snapshot(), before);
      final target = await f.ledgerTarget();
      await f.db
          .into(f.db.rewriteJobs)
          .insert(
            RewriteJobsCompanion.insert(
              id: 'synthetic-pending-job',
              chatSessionId: RepairFixture.session,
              characterId: 'legacy',
            ),
          );
      final pendingBefore = await f.base.snapshot();
      expect(
        (await f.repo.prepareCorrectExistingLedgerValue(
          target: target,
          value: 'new',
          operationId: 'synthetic-no-reset',
          createdAt: 20,
          isCurrent: f.isCurrent,
        )).plan,
        isNull,
      );
      expect(
        (await f.inspect()).targets
            .where((t) => t.kind == SessionRepairTargetKind.liveLedger)
            .every(
              (t) => t.availability == SessionRepairAvailability.unavailable,
            ),
        isTrue,
      );
      expect(await f.base.snapshot(), pendingBefore);
    },
  );

  repairTest(
    'durable receipt remains an applied fact after native source cancellation',
    (f) async {
      final plan = (await f.correction())!;
      final receipt = await f.apply(plan).then((value) {
        f.current = false;
        return value;
      });
      expect(receipt!.outcome, SessionRepairOutcome.applied);
      expect(
        (await f.db.select(f.db.supportMutationJournal).get()).single.status,
        'applied',
      );
      f.current = true;
      expect(await f.apply(plan), isNull);
    },
  );
}
