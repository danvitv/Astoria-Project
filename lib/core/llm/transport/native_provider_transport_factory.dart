part of 'native_provider_transport.dart';

/// Inject one actual protected owner, never its read-only metadata facade.
/// The factory and its constructor ports stay in native composition custody.
final class NativeProviderTransportFactory {
  const NativeProviderTransportFactory({
    required this.credentials,
    required this.authIssuer,
    required this.mutations,
    required this.routes,
    required this.currentRedactor,
    required this.adapterFactory,
    this.legacyPicker = pickChatTransport,
    this.scheduleDeadline = Timer.new,
  });

  final NativeProviderCredentialVault credentials;
  final NativeSavedConnectionAuthIssuer authIssuer;
  final NativeConnectionMutationOwner mutations;
  final NativeProviderRoutePolicy routes;
  final SecretRedactor Function() currentRedactor;
  final HttpClientAdapter Function() adapterFactory;
  final ChatTransport Function(String) legacyPicker;
  final Timer Function(Duration, void Function()) scheduleDeadline;

  ChatTransport pick(String protocol) =>
      _NativeProviderChatTransport(this, protocol);
}

final class _NativeProviderChatTransport implements ChatTransport {
  const _NativeProviderChatTransport(this.factory, this.protocol);
  final NativeProviderTransportFactory factory;
  final String protocol;

  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    final token = cancelToken ?? CancelToken();
    final auth = request.savedConnectionAuth;
    final predicate = request.nativeSourceIsCurrent;
    final source = _NativeSourceCurrent([
      if (auth != null && predicate != null) predicate,
    ]);
    bool originalAuthority() =>
        factory.mutations.isStable &&
        (auth == null || factory.authIssuer.isCurrent(auth));
    bool sourceCurrent() => source.check(originalAuthority);
    bool current() =>
        !token.isCancelled &&
        sourceCurrent() &&
        !token.isCancelled &&
        originalAuthority();
    if (auth == null) {
      try {
        final id = request.savedConnectionId;
        if (id != null) {
          _nativeRequire(current(), NativeProviderTransportReason.notCurrent);
          final presence = await factory.credentials.inspectNativePresence(
            connectionId: id,
            isCurrent: current,
          );
          _nativeRequire(current(), NativeProviderTransportReason.notCurrent);
          _nativeRequire(
            presence == NativeProviderCredentialPresence.absent,
            NativeProviderTransportReason.denied,
          );
        }
      } on NativeProviderTransportException catch (failure) {
        _report(failure, token, sourceCurrent, onError);
        return;
      } on NativeProviderException catch (failure) {
        _report(
          NativeProviderTransportException(_credentialReason(failure.failure)),
          token,
          sourceCurrent,
          onError,
        );
        return;
      } catch (_) {
        _report(
          const NativeProviderTransportException(
            NativeProviderTransportReason.transport,
          ),
          token,
          sourceCurrent,
          onError,
        );
        return;
      }
      // Preserve the ORIGINAL request, callbacks, token AND exception behavior.
      // Legacy dispatch is deliberately outside the native failure conversion.
      return factory
          .legacyPicker(protocol)
          .stream(
            request: request,
            cancelToken: cancelToken,
            onUpdate: onUpdate,
            onComplete: onComplete,
            onError: onError,
          );
    }
    try {
      _validateNativeSource(protocol, request, auth);
      _nativeRequire(current(), NativeProviderTransportReason.notCurrent);
      final job = _NativeWireJob(
        factory: factory,
        protocol: protocol,
        request: request,
        token: token,
        current: current,
        onUpdate: onUpdate,
        onComplete: onComplete,
      );
      try {
        job.start();
        final observation = await job.awaitOwned(
          factory.credentials.inspectSavedConnection(
            connection: auth,
            isCurrent: current,
          ),
        );
        _nativeRequire(current(), NativeProviderTransportReason.notCurrent);
        _nativeRequire(
          observation.state == NativeProviderCredentialState.ready,
          NativeProviderTransportReason.denied,
        );
        final route = _nativeRoute(factory.routes, auth, request.stream);
        // The key consumer is installed once in this job's PRIVATE constructor.
        final broker = NativeProviderCredentialBroker(
          credentials: factory.credentials,
          transport: job.runBound,
        );
        try {
          await job.awaitOwned(
            broker.dispatch(observation, route: route, isCurrent: current),
          );
        } on NativeProviderException {
          // No second settlement after an onComplete callback revokes custody.
          if (job.completed) return;
          if (job.failure != null) throw job.failure!;
          if (job.expired) _nativeFail(NativeProviderTransportReason.deadline);
          rethrow;
        }
        _nativeRequire(current(), NativeProviderTransportReason.notCurrent);
      } on NativeProviderException {
        if (job.expired) _nativeFail(NativeProviderTransportReason.deadline);
        rethrow;
      } on NativeProviderTransportException {
        if (job.expired) _nativeFail(NativeProviderTransportReason.deadline);
        rethrow;
      } finally {
        await job.dispose();
      }
    } on NativeProviderTransportException catch (failure) {
      _report(failure, token, sourceCurrent, onError);
    } on NativeProviderException catch (failure) {
      _report(
        NativeProviderTransportException(_credentialReason(failure.failure)),
        token,
        sourceCurrent,
        onError,
      );
    } catch (_) {
      _report(
        const NativeProviderTransportException(
          NativeProviderTransportReason.transport,
        ),
        token,
        sourceCurrent,
        onError,
      );
    }
  }

  void _report(
    NativeProviderTransportException failure,
    CancelToken token,
    bool Function() sourceCurrent,
    ChatTransportOnError? callback,
  ) {
    // Suppress late paints for revoked saved authority. A caller's Stop owns its
    // own cleanup. Failure diagnostics are always fixed, never underlying text.
    if (!_nativeCurrent(sourceCurrent)) {
      token.cancel();
      return;
    }
    // A source callback may synchronously Stop while returning TRUE. Check the
    // token AFTER that callback; only our owned deadline may ignore its own bit.
    if (_nativeCurrent(sourceCurrent) &&
        (!token.isCancelled ||
            failure.reason == NativeProviderTransportReason.deadline)) {
      try {
        callback?.call(NativeProviderTransportException(failure.reason));
      } catch (_) {
        /* User callbacks cannot become provider diagnostics. */
      }
      if (!_nativeCurrent(sourceCurrent)) token.cancel();
    }
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => const [];
  // There is no source/auth/probe approval in this old signature. Do not expose
  // a generic key/probe bypass, even for a saved keyless native connection.
}

void _validateNativeSource(
  String protocol,
  ChatTransportRequest request,
  SavedConnectionAuth auth,
) {
  final source = auth.connection;
  _nativeRequire(
    protocol == source.protocol &&
        (request.savedConnectionId == null ||
            request.savedConnectionId == source.id) &&
        request.endpoint == source.endpoint &&
        request.model == source.model &&
        request.useResponsesApi == source.useResponsesApi &&
        request.apiKey.isEmpty &&
        request.extraRequestParameters.isEmpty,
    NativeProviderTransportReason.denied,
  );
  _nativeRequire(
    auth.purpose != NativeProviderPurpose.astoria,
    NativeProviderTransportReason.denied,
  );
}

CredentialRoute _nativeRoute(
  NativeProviderRoutePolicy policy,
  SavedConnectionAuth auth,
  bool stream,
) {
  final routes = policy.routesFor(
    connection: auth.connection,
    purpose: auth.purpose,
  );
  if (auth.connection.protocol != LlmProtocol.gemini) return routes.single;
  final suffix = stream ? ':streamGenerateContent' : ':generateContent';
  return routes.singleWhere((route) => route.endpoint.path.endsWith(suffix));
}
