part of 'native_provider_credentials.dart';

enum NativeProviderCredentialState {
  absent,
  unavailable,
  corrupt,
  disabled,
  conflicting,
  ready,
}

/// Native-only opaque observation. Only metadata/state are diagnostic values.
/// The private random revision is neither exposed nor a secret equality answer.
final class NativeProviderCredentialObservation {
  const NativeProviderCredentialObservation._(
    this._owner,
    this.connection,
    this.purpose,
    this.state,
    this.metadata,
    this._stamp,
    this._revision,
  );
  final NativeProviderCredentialVault _owner;
  final NativeProviderConnectionIdentity connection;
  final NativeProviderPurpose purpose;
  final NativeProviderCredentialState state;
  final CredentialMetadata metadata;
  final NativeConnectionStamp _stamp;
  final String? _revision;
  @override
  String toString() => 'NativeProviderCredentialObservation(${state.name})';
}

/// Wraps the SAME vault; no second key store, migration, seeding or fallback.
/// Give this privileged owner only to trusted native entry/composition code.
final class NativeProviderCredentialVault {
  NativeProviderCredentialVault({
    required this._vault,
    required SecretRedactionCoordinator redaction,
    required NativeConnectionMutationOwner mutations,
    required NativeProviderRoutePolicy routePolicy,
  }) : _redaction = redaction,
       _mutations = mutations,
       _routePolicy = routePolicy {
    if (!identical(redaction, mutations._redaction) ||
        !identical(redaction, routePolicy._redaction)) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
  }
  final CredentialVault _vault;
  final SecretRedactionCoordinator _redaction;
  final NativeConnectionMutationOwner _mutations;
  final NativeProviderRoutePolicy _routePolicy;
  final Set<String> _disabled = {};
  final Map<String, _NativeOrdinaryAbsence> _ordinaryAbsences = {};
  Future<void> _tail = Future<void>.value();
  bool _invalidationFailed = false;

  CredentialSlot _slot(String id) =>
      CredentialSlot(domain: 'api_config.native_llm', id: id);

  /// Registration happens synchronously, even for rejected/retired submissions.
  /// Once actual storage invocation starts, return its original outcome despite
  /// view retirement. Never rollback-delete, retry, restore or transfer a key.
  Future<CredentialMetadata> storeFromNativeEntry({
    required NativeProviderSecretEntryPermit permit,
    required String secret,
  }) {
    try {
      _redaction.registerSecret(secret);
      _invalidateOrdinaryAbsence(permit._review.connection.id);
      if (!_validNativeSecret(secret) || permit._used) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
      permit._used = true;
      final review = permit._review;
      if (!identical(review._issuer._mutations, _mutations) ||
          !identical(review._issuer._routePolicy, _routePolicy)) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
      final admission = _mutations.admit(
        expected: review._stamp,
        isOriginalOwner: () => review._lifetime.isCurrent,
      );
      if (admission == null) {
        throw const NativeProviderException(NativeProviderFailure.stale);
      }
      return _mutations.runOwned(
        admission: admission,
        operation: (lease) => _serialize(() async {
          _requireCurrent(() => lease.isCurrent);
          if (!_routePolicy._approved(
            review.connection,
            review.purposes,
            review._lifetime,
            review._approval,
          )) {
            throw const NativeProviderException(NativeProviderFailure.denied);
          }
          final original = await _readRecord(review.connection.id);
          _requireCurrent(() => lease.isCurrent);
          // A fresh approval cannot rebind/reactivate an old disabled credential.
          if (original != null &&
              (!original.active ||
                  _disabled.contains(review.connection.id) ||
                  original.connection != review.connection ||
                  !_samePurposes(original.purposes, review.purposes) ||
                  !_sameRoutes(original.routes, review.routes))) {
            throw const NativeProviderException(
              NativeProviderFailure.conflicting,
            );
          }
          final record = _NativeProviderCredentialRecord(
            secret: secret,
            connection: review.connection,
            routes: review.routes,
            purposes: review.purposes,
            revision: _nativeRevision(),
            active: true,
          );
          _requireCurrent(() => lease.isCurrent);
          // A pre-key edit did not disable any secret. Fresh entry may create
          // its FIRST record; an existing disabled record can never reactivate.
          if (original == null) _disabled.remove(review.connection.id);
          // Ignore CredentialVault's ENVELOPE metadata; it is never key metadata.
          // The LAST admission runs inside the actual backend-slot FIFO, not
          // just here before an intervening generic-vault queued await.
          await _vault.storeGuarded(
            _slot(review.connection.id),
            record.encode(),
            isCurrent: () =>
                lease.isCurrent &&
                !_disabled.contains(review.connection.id) &&
                _routePolicy._approved(
                  review.connection,
                  review.purposes,
                  review._lifetime,
                  review._approval,
                ) &&
                lease.isCurrent &&
                !_disabled.contains(review.connection.id),
          );
          return CredentialMetadata.fromSecret(secret);
        }),
      );
    } on NativeProviderException catch (error) {
      return Future.error(error);
    } catch (_) {
      return Future.error(
        const NativeProviderException(NativeProviderFailure.unavailable),
      );
    }
  }

  Future<NativeProviderCredentialObservation> inspect({
    required NativeProviderConnectionIdentity connection,
    required NativeProviderPurpose purpose,
    required bool Function() isCurrent,
  }) async {
    final row = _mutations._row(connection);
    final stamp = _mutations.observe();
    _requireCurrent(isCurrent);
    if (stamp == null || row == null) {
      throw const NativeProviderException(NativeProviderFailure.stale);
    }
    bool current() =>
        _current(isCurrent) &&
        _mutations.isCurrent(stamp) &&
        _mutations._row(connection) != null;
    NativeProviderCredentialObservation observation(
      NativeProviderCredentialState state, [
      _NativeProviderCredentialRecord? record,
    ]) => NativeProviderCredentialObservation._(
      this,
      connection,
      purpose,
      state,
      record == null
          ? CredentialMetadata.absent
          : CredentialMetadata.fromSecret(record.secret),
      stamp,
      record?.revision,
    );
    try {
      final record = await _serialize(() => _readRecord(connection.id));
      _requireCurrent(current);
      if (record == null) {
        return observation(NativeProviderCredentialState.absent);
      }
      if (row.conflicting ||
          record.connection != connection ||
          !record.purposes.contains(purpose)) {
        return observation(NativeProviderCredentialState.conflicting);
      }
      if (!record.active || _disabled.contains(connection.id)) {
        return observation(NativeProviderCredentialState.disabled, record);
      }
      return observation(NativeProviderCredentialState.ready, record);
    } on NativeProviderException catch (error) {
      _requireCurrent(current);
      return observation(
        error.failure == NativeProviderFailure.corrupt
            ? NativeProviderCredentialState.corrupt
            : NativeProviderCredentialState.unavailable,
      );
    } catch (_) {
      _requireCurrent(current);
      return observation(NativeProviderCredentialState.unavailable);
    }
  }

  /// Required saved-request entry point: rejects the ORIGINAL issued row stamp,
  /// not merely an identity which happens to be equal again after an ABA edit.
  Future<NativeProviderCredentialObservation> inspectSavedConnection({
    required SavedConnectionAuth connection,
    required bool Function() isCurrent,
  }) {
    bool current() =>
        _current(isCurrent) &&
        _mutations.isCurrent(connection._stamp) &&
        _mutations._row(connection.connection) != null;
    _requireCurrent(current);
    return inspect(
      connection: connection.connection,
      purpose: connection.purpose,
      isCurrent: current,
    );
  }

  /// Repo MUST await this before ordinary edits/deletes of a possibly native row,
  /// including first access after restart. No enumeration API exists in Vault.
  /// Secret is preserved in-place; no legacy slot is read or touched.
  Future<void> disableForOrdinaryMutation({
    required NativeProviderConnectionIdentity connection,
  }) => disableNativeConnectionForOrdinaryMutation(connectionId: connection.id);

  /// Drain explicitly requested per-ID disables, not global no-ID observation.
  /// Callers must also await each original disable's actual outcome.
  Future<void> settleOrdinaryInvalidations() async {
    await _tail;
    if (_invalidationFailed) {
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
  }

  Future<void> _persistDisabled(String id) async {
    _requireCurrent(() => !_mutations._disposed);
    final record = await _readRecord(id);
    _requireCurrent(() => !_mutations._disposed);
    if (record != null && record.active) {
      await _vault.storeGuarded(
        _slot(id),
        record.disabled().encode(),
        isCurrent: () => !_mutations._disposed,
      );
    }
  }

  Future<_NativeProviderCredentialRecord?> _readRecord(String id) async {
    try {
      final record = await _readRecordFresh(id);
      if (record != null) _invalidateOrdinaryAbsence(id);
      return record;
    } catch (_) {
      _invalidateOrdinaryAbsence(id);
      rethrow;
    }
  }

  Future<_NativeProviderCredentialRecord?> _readRecordFresh(String id) async {
    _NativeProviderCredentialRecord? record;
    NativeProviderException? decodeFailure;
    try {
      await _vault.useSecret(_slot(id), (encoded) async {
        try {
          record = _NativeProviderCredentialRecord.decode(
            encoded,
            _redaction,
            _routePolicy,
          );
        } on NativeProviderException catch (error) {
          decodeFailure = error;
        }
      });
    } on CredentialVaultException catch (error) {
      if (error.failure == CredentialVaultFailure.missing) {
        final bool present;
        try {
          present = await _vault.hasStoredValue(_slot(id));
        } catch (_) {
          throw const NativeProviderException(
            NativeProviderFailure.unavailable,
          );
        }
        if (present) {
          throw const NativeProviderException(NativeProviderFailure.corrupt);
        }
        return null;
      }
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    } catch (_) {
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
    if (decodeFailure != null) throw decodeFailure!;
    return record;
  }

  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _tail.then((_) => operation()).catchError((Object error) {
      if (error is CredentialVaultAdmissionDenied) {
        throw const NativeProviderException(NativeProviderFailure.stale);
      }
      if (error is NativeProviderException) throw error;
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    });
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  @override
  String toString() => 'NativeProviderCredentialVault';
}
