part of 'native_provider_credentials.dart';

/// Storage facts only: no route/purpose approval, record revision or dispatch
/// observation. A saved-but-disabled key is still saved, not provider-tested.
final class NativeProviderConfigurationMetadata {
  const NativeProviderConfigurationMetadata._(this.presence, this.metadata);
  final NativeProviderCredentialPresence presence;
  final CredentialMetadata? metadata;
  bool get nativeManaged => presence != NativeProviderCredentialPresence.absent;
  @override
  String toString() => 'NativeProviderConfigurationMetadata';
}

/// Read-only native facade for settings/readiness owners. Do not hand the actual
/// privileged vault or broker constructor to tools through a narrowed interface.
/// Model DTOs receive ONLY observation.metadata/state, never the observation.
final class NativeProviderCredentialMetadataReader {
  NativeProviderCredentialMetadataReader({required this._credentials});
  final NativeProviderCredentialVault _credentials;

  /// Trusted native local/settings readers provide their own source guard. The
  /// actual key is registered for redaction BEFORE a caller can project a name.
  /// Metadata truth does not depend on whether a different purpose may send.
  Future<NativeProviderConfigurationMetadata> readConfiguration({
    required String connectionId,
    required bool Function() isCurrent,
  }) async {
    final owner = _credentials;
    owner._slot(connectionId);
    final stamp = owner._mutations.observe();
    if (stamp == null) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    bool current() => _current(isCurrent) && owner._mutations.isCurrent(stamp);
    _requireCurrent(current);
    try {
      final result = await owner._serialize(() async {
        final record = await owner._readRecord(connectionId);
        _requireCurrent(current);
        if (record != null) {
          return NativeProviderConfigurationMetadata._(
            NativeProviderCredentialPresence.present,
            CredentialMetadata.fromSecret(record.secret),
          );
        }
        final prepared = await owner._readPreparedMarker(
          connectionId,
          isCurrent: current,
        );
        _requireCurrent(current);
        return NativeProviderConfigurationMetadata._(
          prepared
              ? NativeProviderCredentialPresence.prepared
              : NativeProviderCredentialPresence.absent,
          CredentialMetadata.absent,
        );
      });
      _requireCurrent(current);
      return result;
    } on NativeProviderException catch (error) {
      _requireCurrent(current);
      return NativeProviderConfigurationMetadata._(
        error.failure == NativeProviderFailure.corrupt
            ? NativeProviderCredentialPresence.corrupt
            : NativeProviderCredentialPresence.unavailable,
        null,
      );
    } catch (_) {
      _requireCurrent(current);
      return const NativeProviderConfigurationMetadata._(
        NativeProviderCredentialPresence.unavailable,
        null,
      );
    }
  }

  Future<NativeProviderCredentialObservation> inspect({
    required NativeProviderConnectionIdentity connection,
    required NativeProviderPurpose purpose,
    required bool Function() isCurrent,
  }) => _credentials.inspect(
    connection: connection,
    purpose: purpose,
    isCurrent: isCurrent,
  );

  Future<NativeProviderCredentialObservation> inspectSavedConnection({
    required SavedConnectionAuth connection,
    required bool Function() isCurrent,
  }) => _credentials.inspectSavedConnection(
    connection: connection,
    isCurrent: isCurrent,
  );

  @override
  String toString() => 'NativeProviderCredentialMetadataReader';
}
