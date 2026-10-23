part of 'native_provider_credentials.dart';

typedef NativeProviderSavedConnectionReader =
    Future<ApiConfig?> Function(String id);

final class NativeProviderSecretEntryReview {
  NativeProviderSecretEntryReview._(
    this._issuer,
    this.connection,
    this.purposes,
    this.routes,
    this._stamp,
    this._lifetime,
    this._approval,
  );
  final NativeProviderSecretEntryIssuer _issuer;
  final NativeProviderConnectionIdentity connection;
  final Set<NativeProviderPurpose> purposes;
  final List<CredentialRoute> routes;
  final NativeConnectionStamp _stamp;
  final NativeProviderViewLifetime _lifetime;
  final NativeProviderDestinationApproval? _approval;
  bool _confirmed = false;
  bool get isCurrent =>
      _issuer._mutations.isCurrent(_stamp) &&
      _lifetime.isCurrent &&
      _issuer._mutations.isCurrent(_stamp);
  @override
  String toString() => 'NativeProviderSecretEntryReview';
}

/// Once-only authority to ENTER a secret; never permission to send or test.
final class NativeProviderSecretEntryPermit {
  NativeProviderSecretEntryPermit._(this._review);
  final NativeProviderSecretEntryReview _review;
  bool _used = false;
  @override
  String toString() => 'NativeProviderSecretEntryPermit';
}

final class NativeProviderSecretEntryIssuer {
  NativeProviderSecretEntryIssuer({
    required this._mutations,
    required this._routePolicy,
    required this._readSavedConnection,
  });
  final NativeConnectionMutationOwner _mutations;
  final NativeProviderRoutePolicy _routePolicy;
  final NativeProviderSavedConnectionReader _readSavedConnection;

  /// Call from trusted native entry UI after independent permissions/ownership.
  /// Latest row must be exactly the displayed identity, not just the same ID.
  Future<NativeProviderSecretEntryReview> review({
    required SavedConnectionAuth connection,
    required Set<NativeProviderPurpose> purposes,
    required NativeProviderViewLifetime lifetime,
    NativeProviderDestinationApproval? destinationApproval,
  }) async {
    bool current() =>
        lifetime.isCurrent && _mutations.isCurrent(connection._stamp);
    _requireCurrent(current);
    if (!purposes.contains(connection.purpose)) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    final ApiConfig? saved;
    try {
      saved = await _readSavedConnection(connection.connection.id);
    } catch (_) {
      _requireCurrent(current);
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
    _requireCurrent(current);
    if (saved == null) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    final latest = NativeSavedConnectionAuthIssuer(
      mutations: _mutations,
    ).referenceFor(saved, connection.purpose);
    final row = _mutations._row(connection.connection);
    if (latest?.connection != connection.connection ||
        row == null ||
        row.conflicting) {
      throw const NativeProviderException(NativeProviderFailure.conflicting);
    }
    if (!_routePolicy._approved(
      connection.connection,
      purposes,
      lifetime,
      destinationApproval,
    )) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    return NativeProviderSecretEntryReview._(
      this,
      connection.connection,
      Set.unmodifiable(purposes),
      _routePolicy._routeSet(connection.connection, purposes),
      connection._stamp,
      lifetime,
      destinationApproval,
    );
  }

  /// ONLY the actual final native gesture on the freshly observed entry review.
  NativeProviderSecretEntryPermit confirmNativeEntry(
    NativeProviderSecretEntryReview displayed,
  ) {
    _requireCurrent(() => displayed.isCurrent);
    if (!identical(displayed._issuer, this) ||
        displayed._confirmed ||
        !_routePolicy._approved(
          displayed.connection,
          displayed.purposes,
          displayed._lifetime,
          displayed._approval,
        )) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    displayed._confirmed = true;
    return NativeProviderSecretEntryPermit._(displayed);
  }

  @override
  String toString() => 'NativeProviderSecretEntryIssuer';
}
