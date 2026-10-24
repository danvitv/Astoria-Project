part of 'native_tool_transport.dart';

/// Opaque, single-flight continuation. Owns the same source, token and admission
/// callback for its entire finite lifetime, including application execution time.
final class NativeToolSession {
  NativeToolSession._(
    this._transport,
    this._request,
    this._token,
    this._originalCurrent,
    this._beforeWire,
    Duration deadline,
  ) {
    _transport.mutations.addFenceListener(_onFence);
    try {
      _timer = _transport.scheduleDeadline(deadline, () {
        _expired = true;
        _token.cancel();
        close();
      });
      if (_closed) _timer?.cancel();
    } catch (_) {
      close();
      _ntFail(NativeToolReason.transport);
    }
  }
  final NativeToolTransport _transport;
  final NativeToolRequest _request;
  final CancelToken _token;
  final bool Function() _originalCurrent;
  final NativeToolAdmission _beforeWire;
  Timer? _timer;
  HttpClientAdapter? _adapter;
  bool _closed = false;
  bool _retired = false;
  bool _checking = false;
  bool _busy = false;
  bool _started = false;
  bool _expired = false;
  int _round = 0;
  int _callCount = 0;
  ProviderTokenUsage? _reportedUsage;
  final _seenIds = <String>{};
  List<NativeToolCall> _pending = const [];
  final _history = <Map<String, Object?>>[];

  bool _authority() =>
      _transport.mutations.isStable &&
      _transport.authIssuer.isCurrent(_request.savedConnectionAuth);
  bool _current() {
    if (_closed || _retired || _token.isCancelled) return false;
    if (_checking || !_authority()) {
      _retired = true;
      return false;
    }
    _checking = true;
    try {
      if (!_ntCurrent(_originalCurrent) ||
          !_authority() ||
          _token.isCancelled ||
          _retired) {
        _retired = true;
        _token.cancel();
        return false;
      }
      return true;
    } finally {
      _checking = false;
    }
  }

  void _check() {
    if (_expired) _ntFail(NativeToolReason.deadline);
    if (_token.isCancelled) {
      _ntFail(
        _retired ? NativeToolReason.notCurrent : NativeToolReason.cancelled,
      );
    }
    _ntRequire(_current(), NativeToolReason.notCurrent);
  }

  void _onFence() {
    if (!_current()) {
      _token.cancel();
      close();
    }
  }

  Future<NativeToolTurn> start() => _turn(null);
  Future<NativeToolTurn> continueWith(List<NativeToolResult> results) =>
      _turn(List.unmodifiable(results));

  Future<NativeToolTurn> _turn(List<NativeToolResult>? results) async {
    // A rejected concurrent invocation must not retire the active owner.
    if (_busy) return _failure(NativeToolReason.denied, false);
    _busy = true;
    _started = false;
    _reportedUsage = null;
    NativeToolTurn? settled;
    try {
      _check();
      _ntRequire(_round < NativeToolLimits.rounds, NativeToolReason.limit);
      _ntRequire(
        results == null ? _round == 0 : _pending.isNotEmpty,
        NativeToolReason.invalidRequest,
      );
      final auth = _request.savedConnectionAuth;
      final c = _request.config;
      final source = auth.connection;
      _ntRequire(
        auth.purpose == NativeProviderPurpose.astoria &&
            c.id == source.id &&
            c.providerId == source.providerId &&
            c.protocol == source.protocol &&
            c.endpoint == source.endpoint &&
            c.model == source.model &&
            c.stream == source.stream &&
            c.useResponsesApi == source.useResponsesApi &&
            c.mode == 'chat',
        NativeToolReason.denied,
      );
      _ntRequire(
        c.maxTokens > 0 &&
            c.maxTokens <= NativeToolLimits.maxOutputTokens &&
            c.contextSize > 0 &&
            c.contextSize <= NativeToolLimits.contextCharacters &&
            c.temperature.isFinite &&
            c.topP.isFinite &&
            c.frequencyPenalty.isFinite &&
            c.presencePenalty.isFinite &&
            c.topK >= 0,
        NativeToolReason.invalidRequest,
      );
      final routes = _transport.routes.routesFor(
        connection: source,
        purpose: auth.purpose,
      );
      final route = source.protocol == 'gemini'
          ? routes.singleWhere(
              (r) => r.endpoint.path.endsWith(':generateContent'),
            )
          : routes.single;
      _ntRequire(
        route.endpoint == _request.approvedRecipient,
        NativeToolReason.denied,
      );
      final protocol = _ToolProtocol.fromRoute(route.protocol);
      if (_round == 0) _history.addAll(_initialToolHistory(_request, protocol));
      if (results != null) {
        _ntRequire(
          results.length == _pending.length &&
              results.map((r) => r.callId).toSet().length == results.length,
          NativeToolReason.invalidRequest,
        );
        final ordered = <NativeToolResult>[];
        for (final call in _pending) {
          final matching = results.where(
            (r) => r.callId == call.id && r.name == call.name,
          );
          _ntRequire(matching.length == 1, NativeToolReason.invalidRequest);
          ordered.add(matching.single);
        }
        _history.addAll(
          _toolResultHistory(protocol, _pending, ordered, _history.last),
        );
      }
      final observation = await _awaitOwned(
        _transport.credentials.inspectSavedConnection(
          connection: auth,
          isCurrent: _current,
        ),
      );
      _check();
      _ntRequire(
        observation.state == NativeProviderCredentialState.ready,
        NativeToolReason.denied,
      );
      final broker = NativeProviderCredentialBroker(
        credentials: _transport.credentials,
        transport: (binding, secret) async {
          try {
            _check();
            _ntRequire(binding.isCurrent, NativeToolReason.notCurrent);
            final redactor = _transport.currentRedactor().withKnownSecrets(
              [secret],
              maxInputLength: NativeToolLimits.responseBytes,
              maxOutputLength: NativeToolLimits.responseBytes,
              maxDepth: NativeToolLimits.responseDepth,
              maxNodes: NativeToolLimits.responseNodes,
            );
            _check(); // Redactor factory is a native callback checkpoint.
            final body = _toolBody(_request, protocol, _history);
            _toolSafeWireStrings(body, redactor);
            final json = _toolEncode(body, NativeToolLimits.requestBytes);
            final job = _ToolWireJob(this, binding, body, json, secret);
            final capsule = NativeToolDispatchCapsule._(job);
            try {
              await _awaitOwned(_beforeWire(capsule));
              // A callback's bool cannot invent admission, nor erase a wire fact.
              if (job.pending == null) {
                _check();
                _ntFail(NativeToolReason.denied);
              }
              final raw = await _awaitOwned(job.pending!);
              _check();
              _reportedUsage = _toolUsage(protocol, raw);
              final decoded = _decodeToolResponse(
                protocol,
                raw,
                redactor,
                _request.tools,
                _round + 1,
                _seenIds,
              );
              _check();
              _ntRequire(
                decoded.usage?.outputTokens == null ||
                    decoded.usage!.outputTokens! <= c.maxTokens,
                NativeToolReason.limit,
              );
              _ntRequire(
                _callCount + decoded.calls.length <=
                    NativeToolLimits.callsPerSession,
                NativeToolReason.limit,
              );
              _callCount += decoded.calls.length;
              _seenIds.addAll(decoded.calls.map((call) => call.id));
              _pending = decoded.calls;
              _history.addAll(decoded.replay);
              _round++;
              settled = NativeToolTurn(
                status: decoded.calls.isEmpty
                    ? NativeToolStatus.complete
                    : NativeToolStatus.calls,
                dispatch: NativeToolDispatch.admitted,
                text: decoded.text,
                calls: decoded.calls,
                actualUsage: decoded.usage,
              );
            } finally {
              capsule._retire();
              job.retire();
            }
          } on NativeToolException catch (e) {
            settled ??= _failure(e.reason, _started);
          } on NativeProviderException catch (e) {
            settled ??= _failure(_ntCredentialReason(e.failure), _started);
          } catch (_) {
            settled ??= _failure(NativeToolReason.transport, _started);
          }
        },
      );
      await _awaitOwned(
        broker.dispatch(observation, route: route, isCurrent: _current),
      );
      _check();
    } on NativeToolException catch (e) {
      settled ??= _failure(e.reason, _started);
    } on NativeProviderException catch (e) {
      settled ??= _failure(_ntCredentialReason(e.failure), _started);
    } catch (_) {
      settled ??= _failure(NativeToolReason.transport, _started);
    } finally {
      try {
        _adapter?.close(force: true);
      } catch (_) {
        /* Fixed failures only. */
      }
      _adapter = null;
      _busy = false;
    }
    final result = settled ?? _failure(NativeToolReason.transport, _started);
    if (result.status != NativeToolStatus.calls) close();
    return result;
  }

  Future<T> _awaitOwned<T>(Future<T> future) async {
    final value = await Future.any<T>([
      future,
      _token.whenCancel.then<T>((_) {
        _ntFail(
          _expired
              ? NativeToolReason.deadline
              : _retired
              ? NativeToolReason.notCurrent
              : NativeToolReason.cancelled,
        );
      }),
    ]);
    _check();
    return value;
  }

  NativeToolTurn _failure(NativeToolReason reason, bool started) =>
      NativeToolTurn(
        status:
            const [
              NativeToolReason.cancelled,
              NativeToolReason.notCurrent,
              NativeToolReason.deadline,
            ].contains(reason)
            ? NativeToolStatus.stopped
            : NativeToolStatus.error,
        dispatch: started
            ? NativeToolDispatch.admittedFailed
            : NativeToolDispatch.notAdmitted,
        reason: reason,
        actualUsage: started ? _reportedUsage : null,
      );
  void close() {
    if (_closed) return;
    _closed = true;
    if (_busy && !_token.isCancelled) _token.cancel();
    _timer?.cancel();
    _transport.mutations.removeFenceListener(_onFence);
    try {
      _adapter?.close(force: true);
    } catch (_) {
      /* Fixed failures only. */
    }
    _adapter = null;
    _history.clear();
    _pending = const [];
  }

  @override
  String toString() => 'NativeToolSession';
}
