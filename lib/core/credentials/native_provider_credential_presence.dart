part of 'native_provider_credentials.dart';

enum NativeProviderCredentialPresence {
  absent,
  present,
  prepared,
  unavailable,
  corrupt,
}

/// Trusted repo guard for malformed/non-keyless rows which cannot mint an auth
/// reference. Presence grants NO auth and never exports envelope metadata.
/// Only actual-key absence permits preparation inspection; prepared denies legacy
/// fallback without changing actual-key readiness or metadata.
extension NativeProviderCredentialPresenceInspection
    on NativeProviderCredentialVault {
  Future<NativeProviderCredentialPresence> inspectNativePresence({
    required String connectionId,
    required bool Function() isCurrent,
  }) async {
    try {
      _slot(connectionId);
    } catch (_) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    final stamp = _mutations.observe();
    if (stamp == null) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    bool current() => _current(isCurrent) && _mutations.isCurrent(stamp);
    _requireCurrent(current);
    try {
      final result = await _serialize(() async {
        final absenceEpoch = _absenceEpoch(connectionId);
        final record = await _readRecord(connectionId);
        _requireCurrent(current);
        if (record != null) return NativeProviderCredentialPresence.present;
        final prepared = await _readPreparedMarker(
          connectionId,
          isCurrent: current,
        );
        _requireCurrent(current);
        if (!prepared) {
          _retainOrdinaryAbsence(connectionId, absenceEpoch);
        }
        return prepared
            ? NativeProviderCredentialPresence.prepared
            : NativeProviderCredentialPresence.absent;
      });
      _requireCurrent(current);
      return result;
    } on NativeProviderException catch (error) {
      _invalidateOrdinaryAbsence(connectionId);
      _requireCurrent(current);
      return error.failure == NativeProviderFailure.corrupt
          ? NativeProviderCredentialPresence.corrupt
          : NativeProviderCredentialPresence.unavailable;
    } catch (_) {
      _invalidateOrdinaryAbsence(connectionId);
      _requireCurrent(current);
      return NativeProviderCredentialPresence.unavailable;
    }
  }

  /// Denial-only native repo hook also works for a malformed saved row. Await
  /// before the ordinary edit, including first access after process recreation.
  Future<void> disableNativeConnectionForOrdinaryMutation({
    required String connectionId,
  }) {
    _invalidateOrdinaryAbsence(connectionId);
    if (_mutations._disposed) {
      return Future.error(
        const NativeProviderException(NativeProviderFailure.stale),
      );
    }
    try {
      _slot(connectionId);
    } catch (_) {
      return Future.error(
        const NativeProviderException(NativeProviderFailure.denied),
      );
    }
    _disabled.add(connectionId);
    return _serialize(() => _persistDisabled(connectionId)).catchError((
      Object error,
    ) {
      _invalidationFailed = true;
      throw error;
    });
  }
}
