part of '../session_repair_repo.dart';

/// One owner outer transaction: raw rechecks -> exact encrypted originals ->
/// post-AEAD rechecks -> full-row CAS/narrow effect -> durable fence -> actual
/// journal fact -> exact postcondition. No reservation or effect escapes alone.
final class _RepairMutationStore {
  const _RepairMutationStore(this.owner);
  final SessionRepairRepo owner;
  AppDatabase get db => owner._db;
  _RepairRawStore get raw => owner._raw;
  static Map<String, Object?>? targetRow(
    SessionRepairPlan plan, {
    required bool after,
  }) {
    final target = plan._target;
    final slice = (after ? plan._after : plan._before).slices[target._setIndex];
    final column = target.kind == SessionRepairTargetKind.liveLedger
        ? 'name'
        : 'id';
    final found = slice.rows
        .where((r) => r[column] == target._row[column])
        .toList();
    return found.isEmpty ? null : found.single;
  }

  Map<String, Object?>? fence(_RepairImage image) {
    final found = image
        .rows(db.trackerRows)
        .where((r) => r['name'] == TrackerRepo.ledgerManualMutationRevisionName)
        .toList();
    return found.isEmpty ? null : found.single;
  }

  _RepairImage advanceFence(_RepairImage image, int now) {
    final next = _RepairLedgerValidation(db).revision(image) + 1;
    final row = <String, Object?>{
      'session_id': image.targetSession,
      'name': TrackerRepo.ledgerManualMutationRevisionName,
      'value': '$next',
      'scope': 'system',
      'provenance': 'manual_ledger_mutation',
      'basis_revision': 0,
      'basis_revision_hash': '',
      'updated_at': now,
    };
    return image.replacing(db.trackerRows, [
      for (final r in image.rows(db.trackerRows))
        if (r['name'] != row['name']) r,
      row,
    ]);
  }

  String evidence(SessionRepairPlan plan, {required bool after}) {
    // This envelope is encrypted native ORIGINAL custody, not an outward
    // evidence report. Never sanitize/truncate the row: doing so destroys Undo.
    // SupportMutationEvidence is just a bounded canonical envelope; its String
    // never leaves this private owner except under explicit native body lease.
    final native = jsonEncode({
      'v': 1,
      'kind': plan.kind.name,
      'targetSession': plan._before.targetSession,
      'row': targetRow(plan, after: after),
      'manualRevisionRow': fence(after ? plan._after : plan._before),
      'dependencyStamp': (after ? plan._after : plan._before).stamp,
    });
    _repairRequire(
      utf8.encode(native).length <= SupportMutationEvidence.maxNativeBytes,
      SessionRepairIssue.oversized,
    );
    return SupportMutationEvidence.encode(native);
  }

  void quietLedgerDependencies(_RepairImage image) {
    // Without exact per-proposal invalidation originals the effect is not
    // admitted. We do not reset/cancel every downstream lane as collateral.
    for (final table in <TableInfo>[
      db.rewriteJobs,
      db.rewriteOperations,
      db.cardEvolutionClaims,
      db.cardEvolutionProposalRuns,
      db.cardEvolutionWriterCalls,
      db.ledgerReconciliationLeases,
    ]) {
      _repairRequire(
        image.rows(table).isEmpty,
        SessionRepairIssue.dependentEffectUnsupported,
      );
    }
    _repairRequire(
      !image
          .rows(db.cardEvolutionCollectorRuns)
          .any((r) => r['status'] == 'claimed'),
      SessionRepairIssue.dependentEffectUnsupported,
    );
    // Applied transitions can protect keys through older owner contracts. Until
    // an exact transition/canon adapter exists, do not guess how to invalidate it.
    _repairRequire(
      image.rows(db.appliedCanonTransitionRows).isEmpty,
      SessionRepairIssue.dependentEffectUnsupported,
    );
  }

  Future<SessionRepairPreparation> prepare(
    SessionRepairTarget target,
    String operation,
    int now,
    bool Function() admission,
    String? value,
  ) async {
    try {
      bool current() =>
          identical(target._owner, owner) &&
          owner._support.usesDatabase(db) &&
          target._current() &&
          admission();
      final result = await _repairTransaction(db, current, () async {
        _repairRequire(
          _repairId(operation) && now >= 0 && now <= 9007199254740991,
          SessionRepairIssue.authorityDenied,
        );
        _repairRequire(
          target.kind ==
              (value == null
                  ? SessionRepairTargetKind.collectorAttempt
                  : SessionRepairTargetKind.liveLedger),
          target.kind == SessionRepairTargetKind.observation
              ? SessionRepairIssue.aggregateOriginalUnavailable
              : SessionRepairIssue.unsupportedTarget,
        );
        _repairRequire(await raw.matches(target._image, current));
        final reader = _RepairInspectionReader(owner);
        _repairRequire(
          reader.sessionMetadataIssues(target._image).isEmpty,
          SessionRepairIssue.incompleteEvidence,
        );
        reader.messages(target._image);
        _repairRequire(
          (await reader.validateReconciliation(target._image, current)).isEmpty,
          SessionRepairIssue.incompleteEvidence,
        );
        _RepairImage after;
        if (value == null) {
          reader.unusedAttempt(target._image, target._row);
          await raw.narrowSchema(db.cardEvolutionCollectorRuns, current);
          after = target._image.replacing(
            db.cardEvolutionCollectorRuns,
            target._image
                .rows(db.cardEvolutionCollectorRuns)
                .where((r) => r['id'] != target._row['id'])
                .toList(),
          );
        } else {
          quietLedgerDependencies(target._image);
          _RepairLedgerValidation(
            db,
          ).validate(target._image, target._row, value);
          await raw.narrowSchema(db.trackerRows, current);
          after = target._image.replacing(db.trackerRows, [
            for (final row in target._image.rows(db.trackerRows))
              if (row['name'] == target._row['name'])
                {
                  ...row,
                  'value': value,
                  'provenance': 'manual_session_repair',
                  'updated_at': now,
                }
              else
                row,
          ]);
          after = advanceFence(after, now);
        }
        final plan = SessionRepairPlan._(
          owner,
          target,
          target._image,
          after,
          operation,
          'srp-${_repairHash([operation, target._image.stamp, after.stamp])}',
          now,
          current,
        );
        evidence(plan, after: false);
        evidence(plan, after: true);
        _repairRequire(await raw.matches(target._image, current));
        return SessionRepairPreparation._(plan, null);
      });
      return result!;
    } on _RepairRefused catch (e) {
      return SessionRepairPreparation._(null, e.issue);
    }
  }

  Future<SessionRepairReceipt?> apply(
    SessionRepairPlan plan,
    bool Function() admission,
  ) async {
    try {
      bool current() =>
          identical(plan._owner, owner) &&
          owner._support.usesDatabase(db) &&
          plan._current() &&
          admission();
      return await _repairTransaction(db, current, () async {
        _repairRequire(await raw.matches(plan._before, current));
        final reservation = await owner._support.reserveMutation(
          record: SupportMutationRecord(
            id: plan.operationId,
            sessionId: plan._before.supportSession,
            domain: SessionRepairRepo.journalDomain,
            targetId: plan.previewIdentity,
            beforeJson: evidence(plan, after: false),
            afterJson: evidence(plan, after: true),
            status: 'pending',
            createdAt: plan._createdAt,
          ),
          isCurrent: current,
        );
        _repairRequire(reservation != null);
        // Exact original ASTORIA parent/session, source transcript, logical
        // frontier/canon/dependencies/manual revision and row AFTER AEAD awaits.
        _repairRequire(await raw.matches(plan._before, current));
        await effect(plan, plan._before, plan._after, current);
        _repairRequire(await raw.matches(plan._after, current));
        final settled = await owner._support.settleMutation(
          expected: reservation!,
          fact: SupportMutationFact.applied,
          hasOriginalDbCustody: current,
        );
        _repairRequire(settled != null);
        _repairRequire(await raw.matches(plan._after, current));
        return SessionRepairReceipt._(
          plan,
          settled!,
          plan._after,
          SessionRepairOutcome.applied,
        );
      });
    } on _RepairRefused {
      return null;
    }
  }

  Future<SessionRepairReceipt?> undo(
    SessionRepairReceipt receipt,
    bool Function() admission,
  ) async {
    if (receipt.outcome != SessionRepairOutcome.applied) return null;
    final plan = receipt._plan;
    try {
      bool current() =>
          identical(plan._owner, owner) &&
          owner._support.usesDatabase(db) &&
          admission();
      return await _repairTransaction(db, current, () async {
        final pending = await owner._support.reserveMutationUndo(
          expected: receipt._journal,
          isCurrent: current,
        );
        _repairRequire(pending != null);
        // The actual encrypted original is read/decrypted by SupportRepo's
        // guarded reservation. Neither metadata nor a matching value can mint it.
        _repairRequire(
          pending!.record.beforeJson == evidence(plan, after: false) &&
              pending.record.afterJson == evidence(plan, after: true),
          SessionRepairIssue.incompleteEvidence,
        );
        if (!await raw.matches(receipt._durable, current)) {
          final conflict = await owner._support.settleMutation(
            expected: pending,
            fact: SupportMutationFact.undoConflict,
            hasOriginalDbCustody: current,
          );
          _repairRequire(conflict != null);
          return SessionRepairReceipt._(
            plan,
            conflict!,
            receipt._durable,
            SessionRepairOutcome.undoConflict,
          );
        }
        var restored = plan._before;
        if (plan.kind == SessionRepairTargetKind.liveLedger) {
          // Restore the exact target original but NEVER roll back the durable
          // retirement fence: old in-flight Ledger bases must remain retired.
          restored = receipt._durable.replacing(db.trackerRows, [
            for (final r in receipt._durable.rows(db.trackerRows))
              if (r['name'] == plan._target._row['name'])
                plan._target._row
              else
                r,
          ]);
          restored = advanceFence(restored, plan._createdAt);
        }
        await effect(plan, receipt._durable, restored, current, undo: true);
        _repairRequire(await raw.matches(restored, current));
        final settled = await owner._support.settleMutation(
          expected: pending,
          fact: SupportMutationFact.undone,
          hasOriginalDbCustody: current,
        );
        _repairRequire(settled != null);
        _repairRequire(await raw.matches(restored, current));
        return SessionRepairReceipt._(
          plan,
          settled!,
          restored,
          SessionRepairOutcome.undone,
        );
      });
    } on _RepairRefused {
      return null;
    }
  }

  Future<void> updateExact(
    TableInfo table,
    Map<String, Object?> before,
    Map<String, Object?> values,
    bool Function() current,
  ) async {
    final where = raw.exact(before);
    final count = await raw.checked(
      current,
      () => db.customUpdate(
        'UPDATE ${raw.q(table.actualTableName)} SET ${values.keys.map((k) => '${raw.q(k)} = ?').join(',')} WHERE ${where.$1}',
        variables: [...values.values.map(raw.variable), ...where.$2],
        updates: {table},
      ),
    );
    _repairRequire(count == 1);
  }

  Future<void> insertExact(
    TableInfo table,
    Map<String, Object?> row,
    bool Function() current,
  ) async {
    await raw.checked(
      current,
      () => db.customInsert(
        'INSERT INTO ${raw.q(table.actualTableName)} (${row.keys.map(raw.q).join(',')}) VALUES (${row.keys.map((_) => '?').join(',')})',
        variables: row.values.map(raw.variable).toList(),
        updates: {table},
      ),
    );
  }

  Future<void> effect(
    SessionRepairPlan plan,
    _RepairImage before,
    _RepairImage after,
    bool Function() current, {
    bool undo = false,
  }) async {
    final ledger = plan.kind == SessionRepairTargetKind.liveLedger;
    final TableInfo table = ledger
        ? db.trackerRows
        : db.cardEvolutionCollectorRuns;
    await raw.narrowSchema(table, current);
    _repairRequire(await raw.matches(before, current));
    if (ledger) {
      final key = plan._target._row['name'];
      final old = before.rows(table).singleWhere((r) => r['name'] == key);
      final next = after.rows(table).singleWhere((r) => r['name'] == key);
      await updateExact(table, old, {
        'value': next['value'],
        'provenance': next['provenance'],
        'updated_at': next['updated_at'],
      }, current);
      final oldFence = fence(before), nextFence = fence(after)!;
      if (oldFence == null) {
        await insertExact(table, nextFence, current);
      } else {
        await updateExact(table, oldFence, {
          'value': nextFence['value'],
          'updated_at': nextFence['updated_at'],
        }, current);
      }
    } else if (undo) {
      await insertExact(table, plan._target._row, current);
    } else {
      final where = raw.exact(plan._target._row);
      final count = await raw.checked(
        current,
        () => db.customUpdate(
          'DELETE FROM ${raw.q(table.actualTableName)} WHERE ${where.$1}',
          variables: where.$2,
          updates: {table},
        ),
      );
      _repairRequire(count == 1);
    }
    _repairRequire(current());
  }
}
