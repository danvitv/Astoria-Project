part of '../database_maintenance_repo.dart';

/// Composes existing support-journal contracts in the SAME outer transaction as
/// the scalar effect. No durable reservation precedes effect admission here.
final class _MaintenanceRepairStore {
  _MaintenanceRepairStore(this.owner)
    : targets = _MaintenanceTargetStore(owner._db);
  final DatabaseMaintenanceRepo owner;
  final _MaintenanceTargetStore targets;
  static const domain = 'database.maintenance';

  Future<T?> transaction<T>(
    bool Function() current,
    Future<T> Function() action,
  ) async {
    try {
      _maintenanceRequire(current());
      // A caller-owned outer transaction would make our returned custody merely
      // provisional. Only this owner may choose the actual commit boundary.
      return await outsideDatabaseTransaction(owner._db, () {
        _maintenanceRequire(current());
        return owner._db.transaction(() async {
          _maintenanceRequire(current());
          final result = await action();
          _maintenanceRequire(current());
          return result;
        });
      }, onRejected: () => const _MaintenanceRefused());
    } on _MaintenanceRefused {
      return null;
    } catch (_) {
      // Unknown commit delivery failure is not fabricated cancellation/no-effect.
      // Caller must observe original journal custody; NEVER automatically replay.
      throw const DatabaseMaintenanceException();
    }
  }

  Future<DatabaseMaintenancePlan?> prepare(
    DatabaseMaintenanceTarget target,
    String operationId,
    String sessionId,
    int createdAt,
    bool Function() current,
  ) async {
    if (!_maintenanceSafeId(target.id) ||
        (target.folderId != null && !_maintenanceSafeId(target.folderId!)) ||
        !_maintenanceSafeId(operationId) ||
        !_maintenanceSafeId(sessionId) ||
        createdAt < 0 ||
        createdAt > 9007199254740991) {
      return null;
    }
    return transaction(current, () async {
      final guards = await targets.prepare(target, current);
      _maintenanceRequire(current());
      final parent = await targets.capture(owner._db.supportSessions, {
        'id': sessionId,
      }, current);
      _maintenanceRequire(current() && parent.row != null);
      // Safe public hash binds the exact private guard bytes without leaking
      // row identities, content, paths, names, JSON or source dependency prose.
      final stamp = sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'v': 1,
                'operation': operationId,
                'session': sessionId,
                'kind': target.kind.name,
                'id': target.id,
                'folder': target.folderId,
                'presetKind': target.presetKind?.name,
                'guards': guards.map((g) => g.row).toList(),
                'parent': parent.row,
              }),
            ),
          )
          .toString();
      final plan = DatabaseMaintenancePlan._(
        owner,
        target,
        List.unmodifiable(guards),
        parent,
        operationId,
        sessionId,
        createdAt,
        current,
        'dbrepair-$stamp',
      );
      _maintenanceRequire(await targets.allMatch(plan, current));
      _maintenanceRequire(await targets.matches(parent, current));
      _maintenanceRequire(current());
      return plan;
    });
  }

  Future<DatabaseMaintenanceReceipt?> apply(
    DatabaseMaintenancePlan plan,
    bool Function() admission,
  ) {
    bool current() =>
        identical(plan._owner, owner) &&
        owner._support.usesDatabase(owner._db) &&
        plan._current() &&
        admission();
    return transaction(current, () async {
      _maintenanceRequire(await targets.matches(plan._parentGuard, current));
      _maintenanceRequire(await targets.allMatch(plan, current));
      _maintenanceRequire(current());
      final reservation = await owner._support.reserveMutation(
        record: SupportMutationRecord(
          id: plan.operationId,
          sessionId: plan._sessionId,
          domain: domain,
          targetId: plan.previewIdentity,
          beforeJson: _maintenanceEvidence(plan, after: false),
          afterJson: _maintenanceEvidence(plan, after: true),
          status: 'pending',
          createdAt: plan._createdAt,
        ),
        isCurrent: current,
      );
      _maintenanceRequire(current() && reservation != null);
      // Encryption and journal readback have awaits: raw rows AND missing-source
      // evidence are rechecked after them, before the admitted narrow write.
      _maintenanceRequire(await targets.allMatch(plan, current));
      _maintenanceRequire(await targets.matches(plan._parentGuard, current));
      _maintenanceRequire(current());
      await targets.effect(plan, current);
      _maintenanceRequire(current());
      final settled = await owner._support.settleMutation(
        expected: reservation!,
        fact: SupportMutationFact.applied,
        hasOriginalDbCustody: current,
      );
      _maintenanceRequire(current() && settled != null);
      // Support returns the exact encrypted durable reread, not a status copy.
      _maintenanceRequire(await targets.allMatch(plan, current, after: true));
      _maintenanceRequire(current());
      return DatabaseMaintenanceReceipt._(
        plan,
        settled!,
        DatabaseMaintenanceMutationOutcome.applied,
      );
    });
  }

  Future<DatabaseMaintenanceReceipt?> undo(
    DatabaseMaintenanceReceipt receipt,
    bool Function() admission,
  ) {
    final plan = receipt._plan;
    bool current() =>
        identical(plan._owner, owner) &&
        owner._support.usesDatabase(owner._db) &&
        admission();
    if (receipt.outcome != DatabaseMaintenanceMutationOutcome.applied) {
      return Future.value(null);
    }
    return transaction(current, () async {
      final pending = await owner._support.reserveMutationUndo(
        expected: receipt._journal,
        isCurrent: current,
      );
      _maintenanceRequire(current() && pending != null);
      final matches = await targets.allMatch(plan, current, after: true);
      _maintenanceRequire(current());
      if (!matches) {
        final conflict = await owner._support.settleMutation(
          expected: pending!,
          fact: SupportMutationFact.undoConflict,
          hasOriginalDbCustody: current,
        );
        _maintenanceRequire(current() && conflict != null);
        return DatabaseMaintenanceReceipt._(
          plan,
          conflict!,
          DatabaseMaintenanceMutationOutcome.undoConflict,
        );
      }
      await targets.effect(plan, current, undo: true);
      _maintenanceRequire(current());
      final settled = await owner._support.settleMutation(
        expected: pending!,
        fact: SupportMutationFact.undone,
        hasOriginalDbCustody: current,
      );
      _maintenanceRequire(current() && settled != null);
      _maintenanceRequire(await targets.allMatch(plan, current));
      _maintenanceRequire(current());
      return DatabaseMaintenanceReceipt._(
        plan,
        settled!,
        DatabaseMaintenanceMutationOutcome.undone,
      );
    });
  }
}
