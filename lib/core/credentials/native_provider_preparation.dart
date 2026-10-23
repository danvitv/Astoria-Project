part of 'native_provider_credentials.dart';

/// A protected DENIAL marker, not a key, route/purpose approval, receipt or config.
/// Parent must hold the original lease, verify DB absence, persist this marker,
/// then recheck that lease BEFORE starting the DB create transaction. An orphan
/// after a denied/rolled-back create is safe; never delete/retry/restore it here.
extension NativeProviderPreparation on NativeProviderCredentialVault {
  Future<void> markPreparedForNativeCreate({
    required NativeConnectionOperationLease lease,
    required String connectionId,
  }) {
    _invalidateOrdinaryAbsence(connectionId);
    try {
      _requirePreparationLease(lease);
      if (!_safePreparationId(connectionId)) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
      final slot = _preparationSlot(connectionId);
      return _serialize(() async {
        _requirePreparationLease(lease);
        bool current() => lease.isCurrent;
        if (await _vault.hasStoredValue(_slot(connectionId))) {
          _requirePreparationLease(lease);
          throw const NativeProviderException(
            NativeProviderFailure.conflicting,
          );
        }
        _requirePreparationLease(lease);
        final exists = await _readPreparedMarker(
          connectionId,
          isCurrent: current,
        );
        _requirePreparationLease(lease);
        // This is a presence-only read. Never decode/read a real key as proof of
        // preparation, and never overwrite it or turn it into another binding.
        if (await _vault.hasStoredValue(_slot(connectionId))) {
          _requirePreparationLease(lease);
          throw const NativeProviderException(
            NativeProviderFailure.conflicting,
          );
        }
        _requirePreparationLease(lease);
        if (exists) {
          return; // Valid exact marker is idempotent, NOT overwritten.
        }
        await _vault.storeGuarded(
          slot,
          _preparationBytes(connectionId),
          isCurrent: () =>
              identical(lease._owner, _mutations) && lease.isCurrent,
        );
        // Actual started write/readback is an ORIGINAL fact even after retirement.
        // Parent must check lease.isCurrent before DB admission/publication.
        // Ignore generic ENVELOPE metadata; marker never has key character count.
      });
    } on NativeProviderException catch (error) {
      return Future.error(error);
    } catch (_) {
      return Future.error(
        const NativeProviderException(NativeProviderFailure.unavailable),
      );
    }
  }

  /// Fresh offline-only ownership of a CURRENT safe keyless saved row. The ID
  /// marker deliberately does not bind URL/model: separately reviewed PRE-KEY
  /// changes are allowed. Actual key presence always refuses this path, without
  /// consuming/reading that key or reconstructing any old creation/action receipt.
  Future<bool> isPreparedNativeOwned({
    required NativeConnectionOperationLease lease,
    required ApiConfig saved,
  }) async {
    _requirePreparationLease(lease);
    if (!_preparedSafeShape(saved)) return false;
    return _serialize(() async {
      _requirePreparationLease(lease);
      if (await _vault.hasStoredValue(_slot(saved.id))) {
        _requirePreparationLease(lease);
        return false;
      }
      _requirePreparationLease(lease);
      final prepared = await _readPreparedMarker(
        saved.id,
        isCurrent: () => lease.isCurrent,
      );
      _requirePreparationLease(lease);
      if (!prepared) return false;
      final hasKeyRecord = await _vault.hasStoredValue(_slot(saved.id));
      _requirePreparationLease(lease);
      return !hasKeyRecord && _preparedSafeShape(saved) && lease.isCurrent;
    });
  }

  void _requirePreparationLease(NativeConnectionOperationLease lease) {
    if (!identical(lease._owner, _mutations)) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    _requireCurrent(() => lease.isCurrent);
  }

  bool _safePreparationId(String id) {
    try {
      if (id.isEmpty ||
          id.length > 128 ||
          RegExp(r'[^a-zA-Z0-9._-]').hasMatch(id)) {
        return false;
      }
      _preparationSlot(id);
      return _redaction.redactor.redactText(id) == id;
    } catch (_) {
      return false;
    }
  }

  bool _preparedSafeShape(ApiConfig saved) {
    if (saved.apiKey.isNotEmpty ||
        saved.embeddingApiKey.isNotEmpty ||
        saved.embeddingEnabled ||
        saved.embeddingEndpoint.isNotEmpty ||
        saved.embeddingModel.isNotEmpty ||
        saved.embeddingLlmPresetId.isNotEmpty ||
        saved.extraRequestParameters.isNotEmpty ||
        !_safePreparationId(saved.id)) {
      return false;
    }
    final connection = NativeProviderConnectionIdentity._fromSaved(
      saved,
      _redaction,
    );
    if (connection == null) return false;
    try {
      // Pure compatible HTTPS routing validation, NOT custom/purpose permission.
      _routePolicy.routesFor(
        connection: connection,
        purpose: NativeProviderPurpose.roleplay,
      );
      return true;
    } catch (_) {
      return false;
    }
  }

  CredentialSlot _preparationSlot(String id) =>
      CredentialSlot(domain: 'api_config.native_prepared', id: id);

  String _preparationBytes(String id) => jsonEncode({
    'v': 1,
    'kind': 'keyless-native-preparation',
    'connectionId': id,
  });

  Future<bool> _readPreparedMarker(
    String id, {
    required bool Function() isCurrent,
  }) async {
    _requireCurrent(isCurrent);
    if (!_safePreparationId(id)) {
      throw const NativeProviderException(NativeProviderFailure.corrupt);
    }
    final slot = _preparationSlot(id);
    final bool present;
    try {
      present = await _vault.hasStoredValue(slot);
    } catch (_) {
      _invalidateOrdinaryAbsence(id);
      _requireCurrent(isCurrent);
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
    // A freshly observed marker (even corrupt) contradicts old ordinary absence.
    // This is invalidation only; the exact read/validation below stays unchanged.
    if (present) _invalidateOrdinaryAbsence(id);
    _requireCurrent(isCurrent);
    if (!present) return false;
    var canonical = false;
    try {
      await _vault.useSecret(slot, (encoded) async {
        _requireCurrent(isCurrent);
        // Exact bounded canonical bytes validate all fields/types/version and
        // reject duplicates/unknown keys/escapes/JSON nesting without parsing an
        // arbitrary tree. Max ID is 128 ASCII chars; valid record is <256 bytes.
        canonical =
            encoded.length <= 256 &&
            utf8.encode(encoded).length <= 256 &&
            encoded == _preparationBytes(id);
      });
    } on CredentialVaultException catch (error) {
      _requireCurrent(isCurrent);
      throw NativeProviderException(
        error.failure == CredentialVaultFailure.missing
            ? NativeProviderFailure.corrupt
            : NativeProviderFailure.unavailable,
      );
    } catch (_) {
      _requireCurrent(isCurrent);
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
    _requireCurrent(isCurrent);
    if (!canonical) {
      throw const NativeProviderException(NativeProviderFailure.corrupt);
    }
    return true;
  }
}
