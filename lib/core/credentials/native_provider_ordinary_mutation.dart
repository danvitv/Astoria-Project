part of 'native_provider_credentials.dart';

// Shared invalidation only, keyed by the actual generic vault owner. A replacement
// native wrapper can revoke old facts, but never acquire another wrapper's fact.
final _ordinaryAbsenceEpochs = Expando<Map<String, Object>>();

final class _NativeOrdinaryAbsence {
  _NativeOrdinaryAbsence(this.owner, this.id, this.epoch);
  final NativeProviderCredentialVault owner;
  final String id;
  final Object epoch;

  @override
  String toString() => 'NativeOrdinaryAbsence';
}

/// Denial-only checks for the constructor-injected ordinary repository guard.
/// The repository owns current row reads/SQL. Fresh native record checks stay
/// inside the SAME held native operation; retained absence admits ordinary DB
/// custody only. No key, entry permit or dispatch reference is returned.
extension NativeProviderOrdinaryMutation on NativeProviderCredentialVault {
  Map<String, Object> get _absenceEpochs =>
      _ordinaryAbsenceEpochs[_vault] ??= <String, Object>{};

  Object _absenceEpoch(String id) => _absenceEpochs[id] ??= Object();

  /// Opaque ordinary-only fact, never a dispatch, entry or metadata cache. Both
  /// native key and preparation slots must have actually been observed absent.
  Object? observedOrdinaryAbsence(String id) {
    final fact = _ordinaryAbsences[id];
    return isObservedOrdinaryAbsence(fact, id) ? fact : null;
  }

  bool isObservedOrdinaryAbsence(Object? fact, String id) =>
      fact is _NativeOrdinaryAbsence &&
      identical(fact.owner, this) &&
      fact.id == id &&
      identical(_ordinaryAbsences[id], fact) &&
      identical(_absenceEpochs[id], fact.epoch);

  void _retainOrdinaryAbsence(String id, Object epoch) {
    if (identical(_absenceEpochs[id], epoch)) {
      final original = _ordinaryAbsences[id];
      if (original != null && identical(original.epoch, epoch)) return;
      _ordinaryAbsences[id] = _NativeOrdinaryAbsence(this, id, epoch);
    }
  }

  /// Before ANY native key/preparation mutation attempt, including denial. This
  /// also prevents an in-flight older read from reinstalling a revoked fact.
  void _invalidateOrdinaryAbsence(String id) {
    final epochs = _absenceEpochs;
    if (epochs.containsKey(id)) epochs[id] = Object();
    _ordinaryAbsences.remove(id);
  }

  Future<void> guardOrdinaryPut({
    required NativeConnectionOperationLease lease,
    required ApiConfig? existing,
    required ApiConfig proposed,
  }) => _serialize(() async {
    _requireOrdinaryLease(lease);
    final absenceEpoch = _absenceEpoch(proposed.id);
    final record = await _readRecord(proposed.id);
    _requireOrdinaryLease(lease);
    if (record == null) {
      final prepared = await _readPreparedMarker(
        proposed.id,
        isCurrent: () => lease.isCurrent,
      );
      _requireOrdinaryLease(lease);
      if (!prepared) {
        _retainOrdinaryAbsence(proposed.id, absenceEpoch);
        return; // Verified absence; legacy behavior is unchanged.
      }
      if (existing == null ||
          existing.id != proposed.id ||
          !_preparedSafeShape(existing) ||
          !_preparedSafeShape(proposed) ||
          _redaction.redactor.redactText(proposed.name) != proposed.name) {
        throw const NativeProviderException(NativeProviderFailure.conflicting);
      }
      return; // Marker is NOT a key: no credential rebind or purpose grant.
    }
    if (existing == null ||
        existing.id != proposed.id ||
        existing.apiKey.isNotEmpty ||
        existing.embeddingApiKey.isNotEmpty ||
        !_safeOrdinaryNativeFields(proposed)) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
    // Secret registration during record read precedes this display/input check.
    // Never turn an execution field into a redaction marker and then save it.
    if (_redaction.redactor.redactText(proposed.name) != proposed.name) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    if (!_sameOrdinaryDestination(existing, proposed) ||
        !_matchesOrdinaryIdentity(existing, record.connection)) {
      await _disableInsideOrdinaryLease(lease, proposed.id, record);
      _requireOrdinaryLease(lease);
    }
  });

  Future<void> guardOrdinaryDelete({
    required NativeConnectionOperationLease lease,
    required String connectionId,
  }) => _serialize(() async {
    _requireOrdinaryLease(lease);
    final absenceEpoch = _absenceEpoch(connectionId);
    final record = await _readRecord(connectionId);
    _requireOrdinaryLease(lease);
    if (record != null) {
      await _disableInsideOrdinaryLease(lease, connectionId, record);
      _requireOrdinaryLease(lease);
    } else {
      // Validate unknown/corrupt markers, but do not delete a deny-only marker.
      // A removed row may leave an orphan; it cannot later enter legacy dispatch.
      final prepared = await _readPreparedMarker(
        connectionId,
        isCurrent: () => lease.isCurrent,
      );
      _requireOrdinaryLease(lease);
      if (!prepared) _retainOrdinaryAbsence(connectionId, absenceEpoch);
    }
  });

  void _requireOrdinaryLease(NativeConnectionOperationLease lease) {
    _requireCurrent(
      () => identical(lease._owner, _mutations) && lease.isCurrent,
    );
  }

  Future<void> _disableInsideOrdinaryLease(
    NativeConnectionOperationLease lease,
    String id,
    _NativeProviderCredentialRecord record,
  ) async {
    _invalidateOrdinaryAbsence(id);
    _requireOrdinaryLease(lease);
    // Invalidate the original key immediately and preserve it privately even if
    // SQL later fails. Vault and DB do NOT form an atomic transaction; restoring
    // its old active flag would silently restore credential authority.
    _disabled.add(id);
    if (record.active) {
      await _vault.storeGuarded(
        _slot(id),
        record.disabled().encode(),
        isCurrent: () => identical(lease._owner, _mutations) && lease.isCurrent,
      );
    }
  }

  bool _safeOrdinaryNativeFields(ApiConfig proposed) =>
      proposed.mode == 'chat' &&
      proposed.apiKey.isEmpty &&
      proposed.embeddingApiKey.isEmpty &&
      !proposed.embeddingEnabled &&
      proposed.extraRequestParameters.isEmpty &&
      NativeProviderConnectionIdentity._fromSaved(proposed, _redaction) != null;
}

bool _sameOrdinaryDestination(ApiConfig before, ApiConfig after) =>
    before.id == after.id &&
    before.providerId == after.providerId &&
    before.protocol == after.protocol &&
    before.endpoint == after.endpoint &&
    before.model == after.model &&
    before.stream == after.stream &&
    before.useResponsesApi == after.useResponsesApi;

bool _matchesOrdinaryIdentity(
  ApiConfig saved,
  NativeProviderConnectionIdentity expected,
) =>
    saved.id == expected.id &&
    saved.providerId == expected.providerId &&
    saved.protocol == expected.protocol &&
    saved.endpoint == expected.endpoint &&
    saved.model == expected.model &&
    saved.stream == expected.stream &&
    saved.useResponsesApi == expected.useResponsesApi;
