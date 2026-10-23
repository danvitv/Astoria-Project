part of 'api_config_repo.dart';

/// Public typed operations; all effect work stays inside this repository library.
extension KeylessApiConfigRepo on ApiConfigRepo {
  /// Equality of two actual current native observations; never mints authority.
  bool sameKeylessObservation(
    KeylessApiConfigObservation expected,
    KeylessApiConfigObservation observed,
  ) {
    try {
      return identical(expected._owner, this) &&
          identical(observed._owner, this) &&
          _keyless.pending == 0 &&
          _keyless.stamp == expected._stamp &&
          expected._stamp == observed._stamp &&
          expected._row == observed._row &&
          expected._nativeRevision != null &&
          expected._nativeRevision == observed._nativeRevision &&
          expected._nativeRevision ==
              _keylessMutations?.revisionFor(expected.view.connectionId) &&
          identical(expected._creation, observed._creation) &&
          _keyless.pending == 0 &&
          _keyless.stamp == expected._stamp;
    } catch (_) {
      throw const KeylessApiConfigException();
    }
  }

  Future<KeylessApiConfigObservation?> inspectKeyless(
    String connectionId,
  ) async {
    try {
      final stamp = _keyless.stamp;
      bool current() => _keyless.pending == 0 && _keyless.stamp == stamp;
      final row = await _keylessRow(connectionId, current);
      _requireKeyless(current());
      if (row == null) return null;
      final view = _keylessView(row);
      if (view == null) return null;
      final revision = _keylessMutations?.revisionFor(connectionId);
      _requireKeyless(current());
      return KeylessApiConfigObservation._(
        view,
        row,
        this,
        stamp,
        revision,
        _keyless.creations[connectionId],
      );
    } on _KeylessRefused {
      return null;
    } catch (_) {
      throw const KeylessApiConfigException();
    }
  }

  Future<KeylessApiConfigReceipt?> createKeyless({
    required KeylessApiConfigDraft draft,
    required bool Function() isCurrent,
  }) => _runKeyless(
    draft.view.connectionId,
    isCurrent,
    (current, stamp, lease) => _createKeyless(draft, current, stamp),
    (receipt, revision) => _publishKeyless(receipt, revision),
  );

  Future<KeylessApiConfigReceipt?> updateKeyless({
    required KeylessApiConfigObservation expected,
    required KeylessApiConfigPatch patch,
    required bool Function() isCurrent,
  }) => _runKeyless(
    expected.view.connectionId,
    isCurrent,
    (current, stamp, operation) =>
        _updateKeyless(expected, patch, current, stamp, operation.native),
    (receipt, revision) => _publishKeyless(receipt, revision),
  );

  Future<KeylessApiConfigReceipt?> restoreKeyless({
    required KeylessApiConfigReceipt expected,
    required bool Function() isCurrent,
  }) {
    if (!_claimKeyless(expected)) return Future.value(null);
    return _runKeyless(
      expected.connectionId,
      isCurrent,
      (current, stamp, operation) =>
          _restoreKeyless(expected, current, stamp, operation),
      (receipt, revision) => _publishKeyless(receipt, revision),
    );
  }

  bool _claimKeyless(KeylessApiConfigReceipt receipt) {
    if (!identical(receipt._owner, this) ||
        receipt._consumed ||
        (receipt.action != KeylessApiConfigAction.create &&
            receipt.action != KeylessApiConfigAction.update)) {
      return false;
    }
    receipt._consumed = true;
    return true;
  }

  void _publishKeyless(
    KeylessApiConfigReceipt receipt,
    Object? settlementRevision,
  ) {
    receipt._nativeRevision = settlementRevision;
    if (receipt.action == KeylessApiConfigAction.undoCreate &&
        identical(
          _keyless.creations[receipt.connectionId],
          receipt._creation,
        )) {
      _keyless.creations.remove(receipt.connectionId);
    }
    if (settlementRevision == null) return;
    if (_keyless.pending != 0 || _keyless.stamp != receipt._stamp) return;
    if (receipt.action == KeylessApiConfigAction.create ||
        receipt.action == KeylessApiConfigAction.update ||
        receipt.action == KeylessApiConfigAction.restoreUpdate) {
      _keyless.creations[receipt.connectionId] = receipt._creation;
    }
  }

  Future<KeylessApiConfigReceipt> _createKeyless(
    KeylessApiConfigDraft draft,
    bool Function() current,
    int stamp,
  ) async {
    final view = draft.view;
    _requireKeyless(view.isValid);
    _requireKeyless(await _keylessRow(view.connectionId, current) == null);
    _requireKeyless(current());
    await _db.into(_db.apiConfigs).insert(_keylessInsert(view));
    _requireKeyless(current());
    final row = await _keylessRow(view.connectionId, current);
    _requireKeyless(
      current() &&
          row == _keylessCreatedRow(view) &&
          row != null &&
          _keylessView(row) == view,
    );
    return KeylessApiConfigReceipt._(
      KeylessApiConfigAction.create,
      null,
      view,
      null,
      row,
      this,
      stamp + 2,
      Object(),
    );
  }

  Future<KeylessApiConfigReceipt> _updateKeyless(
    KeylessApiConfigObservation expected,
    KeylessApiConfigPatch patch,
    bool Function() current,
    int stamp,
    KeylessNativeMutationLease lease,
  ) async {
    _requireKeyless(
      identical(expected._owner, this) &&
          expected._stamp == stamp &&
          expected._nativeRevision != null &&
          expected._nativeRevision == lease.priorRevision,
    );
    final creation = expected._creation;
    _requireKeyless(
      creation != null
          ? identical(_keyless.creations[expected.view.connectionId], creation)
          : lease.nativeOwned,
    );
    final row = await _keylessRow(expected.view.connectionId, current);
    _requireKeyless(
      current() &&
          row == expected._row &&
          row != null &&
          _keylessView(row) == expected.view,
    );
    KeylessApiConfigView after;
    try {
      after = patch.applyTo(expected.view);
    } on FormatException {
      throw const _KeylessRefused();
    }
    _requireKeyless(
      current() &&
          (after.model == expected.view.model || lease.allowsModelChange),
    );
    // Durable protected ownership can support a NEW explicit same-process action
    // after restart. It never reconstructs any historical receipt or approval.
    return _writeKeylessPatch(
      row!,
      expected.view,
      after,
      creation ?? Object(),
      current,
      stamp,
      KeylessApiConfigAction.update,
    );
  }

  Future<KeylessApiConfigReceipt> _writeKeylessPatch(
    ApiConfigRow beforeRow,
    KeylessApiConfigView before,
    KeylessApiConfigView after,
    Object creation,
    bool Function() current,
    int stamp,
    KeylessApiConfigAction action,
  ) async {
    _requireKeyless(current() && after.isValid);
    final count = await (_db.update(
      _db.apiConfigs,
    )..where((t) => _keylessExact(beforeRow))).write(_keylessPatch(after));
    _requireKeyless(current() && count == 1);
    final row = await _keylessRow(before.connectionId, current);
    _requireKeyless(
      current() &&
          row == _keylessPatchedRow(beforeRow, after) &&
          row != null &&
          _keylessView(row) == after,
    );
    return KeylessApiConfigReceipt._(
      action,
      before,
      after,
      beforeRow,
      row,
      this,
      stamp + 2,
      creation,
    );
  }

  Future<KeylessApiConfigReceipt> _restoreKeyless(
    KeylessApiConfigReceipt expected,
    bool Function() current,
    int stamp,
    _KeylessOperation operation,
  ) async {
    _requireUndo(
      expected._stamp == stamp &&
          expected._nativeRevision != null &&
          expected._nativeRevision == operation.native.priorRevision &&
          identical(
            _keyless.creations[expected.connectionId],
            expected._creation,
          ),
    );
    final row = await _keylessRow(expected.connectionId, current);
    _requireKeyless(current());
    _requireUndo(
      row != null &&
          row == expected._afterRow &&
          _keylessView(row) == expected.after,
    );
    if (expected.action == KeylessApiConfigAction.update) {
      // Retain and verify the ORIGINAL full preimage. Undo still writes only the
      // allowlisted fields; their inverse must reproduce every captured byte.
      final originalBeforeRow = expected._beforeRow;
      final originalBeforeView = expected.before;
      _requireUndo(
        originalBeforeRow != null &&
            originalBeforeView != null &&
            _keylessView(originalBeforeRow) == originalBeforeView &&
            _keylessPatchedRow(row!, originalBeforeView) == originalBeforeRow,
      );
      _requireUndo(
        expected.after!.model == expected.before!.model ||
            operation.native.allowsModelChange,
      );
      return _writeKeylessPatch(
        row!,
        expected.after!,
        expected.before!,
        expected._creation,
        current,
        stamp,
        KeylessApiConfigAction.restoreUpdate,
      );
    }
    final proof = await _keylessCreateUndoProof?.acquire(
      connectionId: expected.connectionId,
      isCurrent: current,
    );
    try {
      _requireKeyless(current());
      if (proof == null ||
          !proof.isCurrent ||
          !proof.credentialAbsent ||
          !proof.referencesAbsent) {
        throw const _KeylessUndoConflict();
      }
    } catch (_) {
      proof?.release();
      rethrow;
    }
    operation.proof = proof;
    _requireKeyless(await _keylessRow(expected.connectionId, current) == row);
    _requireKeyless(current());
    final count = await (_db.delete(
      _db.apiConfigs,
    )..where((t) => _keylessExact(row!))).go();
    _requireKeyless(current() && count == 1);
    _requireKeyless(await _keylessRow(expected.connectionId, current) == null);
    _requireKeyless(current());
    return KeylessApiConfigReceipt._(
      KeylessApiConfigAction.undoCreate,
      expected.after,
      null,
      row,
      null,
      this,
      stamp + 2,
      expected._creation,
    );
  }
}

void _requireUndo(bool value) {
  if (!value) throw const _KeylessUndoConflict();
}
