part of 'native_provider_credentials.dart';

/// Positive local ownership proof for a NEW reviewed keyless settings mutation.
/// This does not approve a purpose, network call, key entry, Undo or restoration.
/// It never exports the protected record or compares/exposes the secret itself.
extension NativeProviderOwnershipInspection on NativeProviderCredentialVault {
  Future<NativeProviderCredentialState> inspectNativeOwnership({
    required ApiConfig saved,
    required bool Function() isCurrent,
  }) async {
    final stamp = _mutations.observe();
    if (stamp == null) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    bool current() => _current(isCurrent) && _mutations.isCurrent(stamp);
    _requireCurrent(current);
    try {
      final record = await _serialize(() => _readRecord(saved.id));
      _requireCurrent(current);
      if (record == null) return NativeProviderCredentialState.absent;
      final identity = NativeProviderConnectionIdentity._fromSaved(
        saved,
        _redaction,
      );
      if (identity == null ||
          record.connection != identity ||
          saved.apiKey.isNotEmpty ||
          saved.embeddingApiKey.isNotEmpty ||
          saved.embeddingEnabled ||
          saved.extraRequestParameters.isNotEmpty) {
        return NativeProviderCredentialState.conflicting;
      }
      if (!record.active || _disabled.contains(saved.id)) {
        return NativeProviderCredentialState.disabled;
      }
      return NativeProviderCredentialState.ready;
    } on NativeProviderException catch (error) {
      _requireCurrent(current);
      return error.failure == NativeProviderFailure.corrupt
          ? NativeProviderCredentialState.corrupt
          : NativeProviderCredentialState.unavailable;
    } catch (_) {
      _requireCurrent(current);
      return NativeProviderCredentialState.unavailable;
    }
  }
}
