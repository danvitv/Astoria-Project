part of 'native_provider_transport.dart';

/// Native Astoria extension, not a text-consent issuer. Original accepted
/// authorize/admit/capsule semantics and the text-only plan are left unchanged.
/// Constructor ports remain in trusted native custody; no public key consumer.
final class NativeProviderPrivateTextDispatcher {
  const NativeProviderPrivateTextDispatcher({
    required this.credentials,
    required this.authIssuer,
    required this.mutations,
    required this.routes,
    required this.privateTextTransport,
  });
  final NativeProviderCredentialVault credentials;
  final NativeSavedConnectionAuthIssuer authIssuer;
  final NativeConnectionMutationOwner mutations;
  final NativeProviderRoutePolicy routes;
  final PrivateTextTransport privateTextTransport;

  Future<PrivateTextOutcome> generate({
    required SavedConnectionAuth savedConnectionAuth,
    required ChatTransportRequest request,
    required String protocol,
    required Uri approvedRecipient,
    required CancelToken cancelToken,
    required bool Function() isCurrent,
    void Function()? onActivity,
    Duration deadline = PrivateTextLimits.deadline,
  }) async {
    final auth = savedConnectionAuth;
    final predicate = request.nativeSourceIsCurrent;
    final source = _NativeSourceCurrent([isCurrent, ?predicate]);
    bool originalAuthority() =>
        mutations.isStable && authIssuer.isCurrent(auth);
    bool current() =>
        !cancelToken.isCancelled &&
        source.check(originalAuthority) &&
        !cancelToken.isCancelled &&
        originalAuthority();
    final job = _NativePrivateTextJob(
      transport: privateTextTransport,
      auth: auth,
      request: request,
      protocol: protocol,
      recipient: approvedRecipient,
      token: cancelToken,
      current: current,
      onActivity: onActivity,
      deadline: deadline,
    );
    void fenceChanged() {
      if (!current()) {
        cancelToken.cancel();
        job.close();
      }
    }

    mutations.addFenceListener(fenceChanged);
    try {
      final source = auth.connection;
      _nativeRequire(
        auth.purpose == NativeProviderPurpose.astoria &&
            request.apiKey.isEmpty &&
            request.extraRequestParameters.isEmpty &&
            (request.savedConnectionAuth == null ||
                identical(request.savedConnectionAuth, auth)) &&
            (request.savedConnectionId == null ||
                request.savedConnectionId == source.id) &&
            protocol == source.protocol &&
            request.endpoint == source.endpoint &&
            request.model == source.model &&
            request.useResponsesApi == source.useResponsesApi,
        NativeProviderTransportReason.denied,
      );
      _nativeRequire(request.stream, NativeProviderTransportReason.unsupported);
      _nativeRequire(current(), NativeProviderTransportReason.notCurrent);
      final observation = await credentials.inspectSavedConnection(
        connection: auth,
        isCurrent: current,
      );
      _nativeRequire(current(), NativeProviderTransportReason.notCurrent);
      _nativeRequire(
        observation.state == NativeProviderCredentialState.ready,
        NativeProviderTransportReason.denied,
      );
      final route = _nativeRoute(routes, auth, true);
      _nativeRequire(
        approvedRecipient == route.endpoint,
        NativeProviderTransportReason.denied,
      );
      final broker = NativeProviderCredentialBroker(
        credentials: credentials,
        transport: job.runBound,
      );
      await broker.dispatch(observation, route: route, isCurrent: current);
      // This is a settlement, never a new approval or renewed original owner.
      return job.outcome ?? _privateNativeFailure(PrivateTextReason.transport);
    } on NativeProviderTransportException catch (failure) {
      return job.outcome ??
          _privateNativeFailure(_privateNativeReason(failure.reason));
    } on NativeProviderException catch (failure) {
      // Preserve an ALREADY started original accepted outcome, especially the
      // admittedFailed latch. Do not relabel it as a new successful/cancelled run.
      return job.outcome ??
          _privateNativeFailure(
            failure.failure == NativeProviderFailure.stale
                ? PrivateTextReason.notCurrent
                : failure.failure == NativeProviderFailure.unavailable
                ? PrivateTextReason.transport
                : PrivateTextReason.denied,
          );
    } catch (_) {
      return job.outcome ?? _privateNativeFailure(PrivateTextReason.transport);
    } finally {
      mutations.removeFenceListener(fenceChanged);
      job.close();
    }
  }
}

final class _NativePrivateTextJob {
  _NativePrivateTextJob({
    required this.transport,
    required this.auth,
    required this.request,
    required this.protocol,
    required this.recipient,
    required this.token,
    required this.current,
    required this.deadline,
    this.onActivity,
  });
  final PrivateTextTransport transport;
  final SavedConnectionAuth auth;
  final ChatTransportRequest request;
  final String protocol;
  final Uri recipient;
  final CancelToken token;
  final bool Function() current;
  final Duration deadline;
  final void Function()? onActivity;
  PrivateTextOutcome? outcome;
  _NativeDispatchFence? _fence;
  final _adapters = <HttpClientAdapter>[];

  Future<void> runBound(
    NativeProviderDispatchBinding binding,
    String secret,
  ) async {
    _nativeRequire(
      current() && binding.isCurrent,
      NativeProviderTransportReason.notCurrent,
    );
    final finalRecipient = protocol == LlmProtocol.gemini
        ? recipient.replace(query: 'alt=sse')
        : recipient;
    binding.requireFinalRequest(
      uri: finalRecipient,
      method: 'POST',
      protocol: binding.route.protocol,
      purpose: auth.purpose,
      model: request.model,
      stream: request.stream,
    );
    final keyed = _nativeKeyedCopy(request, secret);
    PrivateTextRequestPlan? geminiOriginal;
    if (protocol == LlmProtocol.gemini) {
      try {
        // Freeze through the UNCHANGED accepted plan. The actual inner job still
        // builds/validates its own same original query-auth plan and capsule.
        geminiOriginal = PrivateTextRequestPlan(
          protocol,
          keyed,
          recipient,
          transport.currentRedactor().withKnownSecrets(
            [secret],
            maxInputLength: PrivateTextLimits.contextCharacters,
            maxOutputLength: PrivateTextLimits.contextCharacters,
          ),
        );
      } on PrivateTextFailure catch (failure) {
        outcome = _privateNativeFailure(failure.reason);
        return;
      }
    }
    final fence = _NativeDispatchFence(
      binding: binding,
      token: token,
      model: request.model,
      stream: true,
      protocol: protocol,
      secret: secret,
      frozenBodyJson: geminiOriginal?.bodyJson,
    );
    _fence = fence;
    bool boundCurrent() => binding.isCurrent && current() && binding.isCurrent;
    final native = PrivateTextTransport(
      adapterFactory: () {
        _nativeRequire(
          boundCurrent(),
          NativeProviderTransportReason.notCurrent,
        );
        final finalAdapter = _NativeFinalAdapter(
          factory: transport.adapterFactory,
          fence: fence,
        );
        final original = geminiOriginal;
        final HttpClientAdapter adapter = original == null
            ? finalAdapter
            : _NativeGeminiPrivateAuthAdapter(
                original: original,
                secret: secret,
                finalAdapter: finalAdapter,
                fence: fence,
                isCurrent: boundCurrent,
                currentRedactor: transport.currentRedactor,
              );
        _adapters.add(adapter);
        return adapter;
      },
      currentRedactor: transport.currentRedactor,
      authorize: (handoff) async {
        if (!boundCurrent()) return false;
        final granted = await transport.authorize(handoff);
        return boundCurrent() && granted;
      },
      admit: transport.admit == null
          ? null
          : (capsule) async {
              if (!boundCurrent()) return false;
              final granted = await transport.admit!(capsule);
              // Check custody after H's asynchronous settlement without rewriting its
              // already-started original fact. The unchanged accepted owner classifies
              // currentness/cancellation and preserves admittedFailed independently.
              if (!boundCurrent()) token.cancel();
              return granted;
            },
      scheduleDeadline: transport.scheduleDeadline,
    );
    outcome = await native.generate(
      protocol: protocol,
      request: geminiOriginal?.request ?? keyed,
      approvedRecipient: recipient,
      cancelToken: token,
      isCurrent: boundCurrent,
      deadline: deadline,
      onActivity: onActivity == null
          ? null
          : () {
              if (!boundCurrent()) return;
              onActivity!();
              if (!boundCurrent()) token.cancel();
            },
    );
    // Broker also rechecks after this callback. No keyed DTO escapes the job.
    _nativeCurrent(boundCurrent);
  }

  void close() {
    for (final adapter in _adapters) {
      adapter.close(force: true);
    }
    _adapters.clear();
    _fence?.retire();
    _fence = null;
  }
}

PrivateTextReason _privateNativeReason(NativeProviderTransportReason reason) =>
    switch (reason) {
      NativeProviderTransportReason.notCurrent => PrivateTextReason.notCurrent,
      NativeProviderTransportReason.cancelled => PrivateTextReason.cancelled,
      NativeProviderTransportReason.unsupported =>
        PrivateTextReason.unsupported,
      NativeProviderTransportReason.denied => PrivateTextReason.denied,
      NativeProviderTransportReason.invalidRequest =>
        PrivateTextReason.invalidRequest,
      _ => PrivateTextReason.transport,
    };

PrivateTextOutcome _privateNativeFailure(PrivateTextReason reason) =>
    PrivateTextOutcome(
      status:
          reason == PrivateTextReason.cancelled ||
              reason == PrivateTextReason.notCurrent
          ? PrivateTextStatus.stopped
          : PrivateTextStatus.error,
      text: '',
      reason: reason,
    );
