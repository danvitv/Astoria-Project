part of 'native_provider_credentials.dart';

/// Denial-only protected metadata recheck INSIDE the original owned keyless
/// queue. No auth/reference/secret DTO is issued, and no credential is changed.
extension NativeProviderKeylessTerminalOwnership
    on NativeProviderCredentialVault {
  Future<void> verifyKeylessTerminalOwnership({
    required NativeConnectionOperationLease lease,
    required String connectionId,
    required ApiConfig? saved,
    required bool expectedHasKey,
  }) => _serialize(() async {
    void checkpoint() {
      _requireCurrent(
        () => identical(lease._owner, _mutations) && lease.isCurrent,
      );
    }

    checkpoint();
    if (saved != null && saved.id != connectionId) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
    final record = await _readRecord(connectionId);
    checkpoint();
    if (record != null) {
      if (saved == null) {
        throw const NativeProviderException(NativeProviderFailure.conflicting);
      }
      final identity = NativeProviderConnectionIdentity._fromSaved(
        saved,
        _redaction,
      );
      if (!expectedHasKey ||
          identity == null ||
          record.connection != identity ||
          !record.active ||
          _disabled.contains(connectionId) ||
          saved.apiKey.isNotEmpty ||
          saved.embeddingApiKey.isNotEmpty ||
          saved.embeddingEnabled ||
          saved.extraRequestParameters.isNotEmpty) {
        throw const NativeProviderException(NativeProviderFailure.conflicting);
      }
      checkpoint();
      return;
    }
    if (expectedHasKey) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
    final prepared = await _readPreparedMarker(
      connectionId,
      isCurrent: () => lease.isCurrent,
    );
    checkpoint();
    if (saved == null && prepared) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
  });
}
