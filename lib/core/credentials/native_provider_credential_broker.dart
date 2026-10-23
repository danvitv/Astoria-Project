part of 'native_provider_credentials.dart';

/// Install once per native job, never as a per-call tool-supplied callback.
/// Consumer must not retain/log/return the key or put it in errors. It owns the
/// HTTP adapter, cancellation, safe output, and disabled redirects/retries.
typedef NativeBoundProviderTransport =
    Future<void> Function(NativeProviderDispatchBinding binding, String secret);

/// Constructor-only transport's final adapter fence, not a serializable permit.
/// Recheck BEFORE every actual fetch/retry and after any native async callback.
final class NativeProviderDispatchBinding {
  const NativeProviderDispatchBinding._(
    this.route,
    this.connection,
    this.purpose,
    this._isCurrent,
  );
  final CredentialRoute route;
  final NativeProviderConnectionIdentity connection;
  final NativeProviderPurpose purpose;
  final bool Function() _isCurrent;
  bool get isCurrent => _current(_isCurrent);
  String get method => 'POST';

  /// URI must be the actual final SECRET-FREE URI. Gemini native transport uses
  /// x-goog-api-key auth, never a key query. Its only fixed query is alt=sse.
  /// All authenticated redirects are forbidden, including same-origin ones.
  void requireFinalRequest({
    required Uri uri,
    required String method,
    required CredentialProtocol protocol,
    required NativeProviderPurpose purpose,
    required String model,
    required bool stream,
  }) {
    _requireCurrent(() => isCurrent);
    var expected = route.endpoint;
    if (route.protocol == CredentialProtocol.gemini) {
      final action = stream ? ':streamGenerateContent' : ':generateContent';
      if (!expected.path.endsWith(action)) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
      if (stream) expected = expected.replace(query: 'alt=sse');
    }
    if (uri.toString() != expected.toString() ||
        method != this.method ||
        protocol != route.protocol ||
        purpose != this.purpose ||
        model != connection.model) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    _requireCurrent(() => isCurrent);
  }

  @override
  String toString() => 'NativeProviderDispatchBinding';
}

/// No writer/raw read/general secret consumer on the public dispatch surface.
/// Observation ownership, stamp, purpose and private revision must all match.
final class NativeProviderCredentialBroker {
  NativeProviderCredentialBroker({
    required this._credentials,
    required this._transport,
  });
  final NativeProviderCredentialVault _credentials;
  final NativeBoundProviderTransport _transport;

  Future<CredentialMetadata> metadata(
    NativeProviderCredentialObservation original, {
    required bool Function() isCurrent,
  }) async {
    bool current() => _usable(original, isCurrent);
    _requireCurrent(current);
    final latest = await _credentials.inspect(
      connection: original.connection,
      purpose: original.purpose,
      isCurrent: current,
    );
    _requireCurrent(current);
    if (latest.state != NativeProviderCredentialState.ready ||
        latest._revision != original._revision) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    return latest.metadata;
  }

  Future<void> dispatch(
    NativeProviderCredentialObservation original, {
    required CredentialRoute route,
    required bool Function() isCurrent,
  }) => _credentials._useBoundCredential(
    original,
    route: route,
    isCurrent: () => _usable(original, isCurrent),
    transport: _transport,
  );

  bool _usable(
    NativeProviderCredentialObservation original,
    bool Function() check,
  ) =>
      identical(original._owner, _credentials) &&
      original.state == NativeProviderCredentialState.ready &&
      _credentials._mutations.isCurrent(original._stamp) &&
      _current(check);

  @override
  String toString() => 'NativeProviderCredentialBroker';
}

/// Private bound owner port: accessible only within this credentials library.
extension on NativeProviderCredentialVault {
  Future<void> _useBoundCredential(
    NativeProviderCredentialObservation original, {
    required CredentialRoute route,
    required bool Function() isCurrent,
    required NativeBoundProviderTransport transport,
  }) async {
    bool current() =>
        _current(isCurrent) &&
        _mutations.isCurrent(original._stamp) &&
        !_disabled.contains(original.connection.id);
    _requireCurrent(current);
    final routes = _routePolicy.routesFor(
      connection: original.connection,
      purpose: original.purpose,
    );
    if (!routes.contains(route)) {
      throw const NativeProviderException(NativeProviderFailure.denied);
    }
    try {
      // Release the vault queue BEFORE invoking a long-running native transport:
      // unrelated chat/memory jobs may overlap, rotation must not wait on SSE.
      final record = await _serialize(
        () => _readRecord(original.connection.id),
      );
      _requireCurrent(current);
      final row = _mutations._row(original.connection);
      if (record == null ||
          !record.active ||
          row == null ||
          row.conflicting ||
          record.connection != original.connection ||
          record.revision != original._revision ||
          !record.purposes.contains(original.purpose) ||
          !record.routes.contains(route)) {
        throw const NativeProviderException(NativeProviderFailure.denied);
      }
      final binding = NativeProviderDispatchBinding._(
        route,
        original.connection,
        original.purpose,
        current,
      );
      _requireCurrent(current);
      await transport(binding, record.secret);
      _requireCurrent(current);
    } on NativeProviderException catch (error) {
      // Reconstruct the fixed code; never forward an arbitrary consumer object.
      _requireCurrent(current);
      throw NativeProviderException(error.failure);
    } catch (_) {
      _requireCurrent(current);
      throw const NativeProviderException(NativeProviderFailure.unavailable);
    }
  }
}
