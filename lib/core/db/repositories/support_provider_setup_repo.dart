part of 'api_config_repo.dart';

/// DB-only composition. Preferences and vault writes are deliberately absent.
/// Calls own the OUTER Drift transaction: do not nest them in caller transactions.
final class SupportProviderSetupRepo {
  SupportProviderSetupRepo({
    required AppDatabase db,
    required ApiConfigRepo apiRepo,
    required SupportRepo supportRepo,
  }) : _api = apiRepo,
       _support = supportRepo {
    if (!identical(apiRepo._db, db) || !supportRepo.usesDatabase(db)) {
      throw ArgumentError('Provider setup requires the same database.');
    }
  }
  static const domain = 'provider.setup';
  final ApiConfigRepo _api;
  final SupportRepo _support;

  Future<SupportProviderSetupReceipt?> create({
    required KeylessApiConfigDraft draft,
    required SupportMutationRecord pendingEvidence,
    required bool Function() isCurrent,
  }) {
    if (!SupportProviderSetupEvidence.matches(
      pendingEvidence,
      SupportProviderSetupAction.create,
      draft.view.connectionId,
      null,
      draft.view,
    )) {
      return Future.value(null);
    }
    return _api._runKeyless(
      draft.view.connectionId,
      isCurrent,
      (current, stamp, operation) async {
        final pending = await _support.reserveMutation(
          record: pendingEvidence,
          isCurrent: current,
        );
        _requireKeyless(current() && pending != null);
        final effect = await _api._createKeyless(draft, current, stamp);
        _requireKeyless(current());
        return _settle(
          SupportProviderSetupAction.create,
          effect,
          pending!,
          current,
        );
      },
      (receipt, revision) => _api._publishKeyless(receipt._effect, revision),
    );
  }

  Future<SupportProviderSetupReceipt?> update({
    required KeylessApiConfigObservation expected,
    required KeylessApiConfigPatch patch,
    required SupportMutationRecord pendingEvidence,
    required bool Function() isCurrent,
  }) {
    KeylessApiConfigView after;
    try {
      after = patch.applyTo(expected.view);
    } on FormatException {
      return Future.value(null);
    }
    if (!SupportProviderSetupEvidence.matches(
      pendingEvidence,
      SupportProviderSetupAction.update,
      expected.view.connectionId,
      expected.view,
      after,
    )) {
      return Future.value(null);
    }
    return _api._runKeyless(
      expected.view.connectionId,
      isCurrent,
      (current, stamp, operation) async {
        final pending = await _support.reserveMutation(
          record: pendingEvidence,
          isCurrent: current,
        );
        _requireKeyless(current() && pending != null);
        final effect = await _api._updateKeyless(
          expected,
          patch,
          current,
          stamp,
          operation.native,
        );
        _requireKeyless(current());
        return _settle(
          SupportProviderSetupAction.update,
          effect,
          pending!,
          current,
        );
      },
      (receipt, revision) => _api._publishKeyless(receipt._effect, revision),
    );
  }

  Future<SupportProviderSetupReceipt> _settle(
    SupportProviderSetupAction action,
    KeylessApiConfigReceipt effect,
    SupportMutationReservation pending,
    bool Function() current, {
    SupportMutationFact fact = SupportMutationFact.applied,
  }) async {
    final settled = await _support.settleMutation(
      expected: pending,
      fact: fact,
      hasOriginalDbCustody: current,
    );
    _requireKeyless(current() && settled != null);
    final row = await _api._keylessRow(effect.connectionId, current);
    _requireKeyless(current() && row == effect._afterRow);
    final journal = await _support.readCurrentMutation(
      id: settled!.record.id,
      sessionId: settled.record.sessionId,
      domain: domain,
      targetId: effect.connectionId,
      isCurrent: current,
    );
    _requireKeyless(
      current() &&
          journal != null &&
          _support.sameMutationHistoryObservation(settled, journal),
    );
    // Journal decrypt/callbacks can await; compare the effect once more afterwards.
    _requireKeyless(
      await _api._keylessRow(effect.connectionId, current) == effect._afterRow,
    );
    _requireKeyless(current());
    return SupportProviderSetupReceipt._(action, effect, settled, this);
  }

  Future<SupportProviderSetupReceipt?> undo({
    required SupportProviderSetupReceipt original,
    required bool Function() isCurrent,
  }) {
    if (!identical(original._owner, this) ||
        original._consumed ||
        original.status != SupportMutationStatus.applied ||
        !_api._claimKeyless(original._effect)) {
      return Future.value(null);
    }
    original._consumed = true;
    return _api._runKeyless(
      original.connectionId,
      isCurrent,
      (current, stamp, operation) async {
        final pending = await _support.reserveMutationUndo(
          expected: original._journal,
          isCurrent: current,
        );
        _requireKeyless(current() && pending != null);
        KeylessApiConfigReceipt effect;
        try {
          effect = await _api._restoreKeyless(
            original._effect,
            current,
            stamp,
            operation,
          );
        } on _KeylessUndoConflict {
          _requireKeyless(current());
          final settled = await _support.settleMutation(
            expected: pending!,
            fact: SupportMutationFact.undoConflict,
            hasOriginalDbCustody: current,
          );
          _requireKeyless(current() && settled != null);
          return SupportProviderSetupReceipt._(
            original.action,
            original._effect,
            settled!,
            this,
          );
        }
        _requireKeyless(current());
        return _settle(
          original.action,
          effect,
          pending!,
          current,
          fact: SupportMutationFact.undone,
        );
      },
      (receipt, revision) {
        if (receipt.status == SupportMutationStatus.undone) {
          _api._publishKeyless(receipt._effect, revision);
        }
      },
    );
  }
}
