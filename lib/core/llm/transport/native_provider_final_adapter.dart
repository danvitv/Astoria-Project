part of 'native_provider_transport.dart';

/// One invocation shared by all adapter instances of a private native job.
/// In particular, legacy inner 408 behavior cannot issue a second wire.
final class _NativeDispatchFence {
  _NativeDispatchFence({
    required this.binding,
    required this.token,
    required this.model,
    required this.stream,
    required this._secret,
    required this.protocol,
    this.plan,
    this.frozenBodyJson,
  });
  final NativeProviderDispatchBinding binding;
  final CancelToken token;
  final String model;
  final bool stream;
  final String protocol;
  final _NativeWirePlan? plan;
  final String? frozenBodyJson;
  void Function()? _recheckOriginal;
  String _secret;
  bool claimed = false;
  bool retired = false;

  void check(RequestOptions options) {
    _nativeRequire(
      !retired && !token.isCancelled,
      NativeProviderTransportReason.cancelled,
    );
    _nativeRequire(binding.isCurrent, NativeProviderTransportReason.notCurrent);
    _recheckOriginal?.call();
    binding.requireFinalRequest(
      uri: options.uri,
      method: options.method,
      protocol: binding.route.protocol,
      purpose: binding.purpose,
      model: model,
      stream: stream,
    );
    final actual = <String, dynamic>{};
    for (final entry in options.headers.entries) {
      final key = entry.key.toLowerCase();
      _nativeRequire(
        !actual.containsKey(key),
        NativeProviderTransportReason.invalidRequest,
      );
      actual[key] = entry.value;
    }
    final expected =
        plan?.headers ??
        {
          'Content-Type': 'application/json',
          if (protocol == LlmProtocol.anthropic) ...{
            'x-api-key': _secret,
            'anthropic-version': '2023-06-01',
          } else if (protocol == LlmProtocol.gemini) ...{
            'x-goog-api-key': _secret,
          } else ...{
            'Authorization': 'Bearer $_secret',
            if (protocol == LlmProtocol.openrouter)
              ...OpenRouterChatTransport.extraHeaders,
          },
        };
    final length = actual.remove('content-length');
    _nativeRequire(
      actual.length == expected.length &&
          expected.entries.every(
            (entry) => actual[entry.key.toLowerCase()] == entry.value,
          ),
      NativeProviderTransportReason.invalidRequest,
    );
    _nativeRequire(
      !options.followRedirects &&
          options.maxRedirects == 0 &&
          !options.receiveDataWhenStatusError &&
          options.responseType == ResponseType.stream &&
          identical(options.cancelToken, token),
      NativeProviderTransportReason.invalidRequest,
    );
    final body = options.data;
    _nativeRequire(
      body is Map<String, dynamic>,
      NativeProviderTransportReason.invalidRequest,
    );
    if (binding.route.protocol != CredentialProtocol.gemini) {
      _nativeRequire(
        (body as Map)['model'] == model && body['stream'] == stream,
        NativeProviderTransportReason.invalidRequest,
      );
    }
    final json = _nativeEncode(body);
    final frozen = plan?.bodyJson ?? frozenBodyJson;
    _nativeRequire(
      protocol != LlmProtocol.gemini || frozen != null,
      NativeProviderTransportReason.invalidRequest,
    );
    _nativeRequire(
      frozen == null || json == frozen,
      NativeProviderTransportReason.invalidRequest,
    );
    _nativeRequire(
      length == null ||
          length == '${utf8.encode(json).length}' ||
          length == utf8.encode(json).length,
      NativeProviderTransportReason.invalidRequest,
    );
    _nativeRequire(binding.isCurrent, NativeProviderTransportReason.notCurrent);
  }

  void retire() {
    retired = true;
    _secret = '';
    _recheckOriginal = null;
    plan?.headers.clear();
  }
}

/// Final, capture-free adapter fence. The injected inner adapter is trusted
/// native custody and must itself support forced cancellation and no captures.
final class _NativeFinalAdapter implements HttpClientAdapter {
  _NativeFinalAdapter({
    required HttpClientAdapter Function() this._factory,
    required _NativeDispatchFence this._fence,
  });
  HttpClientAdapter Function()? _factory;
  _NativeDispatchFence? _fence;
  HttpClientAdapter? _inner;
  bool _closed = false;
  NativeProviderTransportException? failure;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final fence = _fence;
    if (_closed || fence == null) {
      _nativeFail(NativeProviderTransportReason.cancelled);
    }
    fence.check(options);
    _nativeRequire(!fence.claimed, NativeProviderTransportReason.denied);
    final inner = _factory!();
    try {
      _nativeRequire(!_closed, NativeProviderTransportReason.cancelled);
      fence.check(
        options,
      ); // Factory code is a callback/currentness checkpoint.
    } catch (_) {
      // close() may have run DURING the factory callback, before this prepared
      // adapter existed. Do not leak it or reopen an already retired owner.
      try {
        inner.close(force: true);
      } catch (_) {
        /* Fixed diagnostics only. */
      }
      rethrow;
    }
    _inner = inner;
    _nativeRequire(!fence.claimed, NativeProviderTransportReason.denied);
    fence.claimed = true;
    // Independent original frozen upload. No interceptor/transformed stream can
    // change the body after the exact final fence.
    final bytes = Uint8List.fromList(
      utf8.encode(
        fence.plan?.bodyJson ??
            fence.frozenBodyJson ??
            _nativeEncode(options.data),
      ),
    );
    fence.check(options);
    try {
      final response = await Future.any<ResponseBody>([
        inner.fetch(options, Stream.value(bytes), cancelFuture),
        fence.token.whenCancel.then<ResponseBody>(
          (_) => _nativeFail(NativeProviderTransportReason.cancelled),
        ),
      ]);
      fence.check(options);
      if (response.statusCode < 200 ||
          response.statusCode >= 300 ||
          response.isRedirect) {
        // Never listen to rejected bytes, headers, Location or status text.
        inner.close(force: true);
        _nativeFail(NativeProviderTransportReason.httpStatus);
      }
      final contentTypes = response.headers.entries
          .where((entry) => entry.key.toLowerCase() == 'content-type')
          .expand((entry) => entry.value)
          .toList();
      final expectedType = fence.stream
          ? 'text/event-stream'
          : 'application/json';
      _nativeRequire(
        contentTypes.length == 1 &&
            contentTypes.single.length <= 256 &&
            contentTypes.single.split(';').first.trim().toLowerCase() ==
                expectedType,
        NativeProviderTransportReason.unsupported,
      );
      // Strip ALL response metadata before Dio can materialize its response.
      return ResponseBody(
        response.stream,
        response.statusCode,
        headers: {
          Headers.contentTypeHeader: [expectedType],
        },
      );
    } on NativeProviderTransportException catch (error) {
      failure = NativeProviderTransportException(error.reason);
      rethrow;
    } on NativeProviderException catch (error) {
      failure = NativeProviderTransportException(
        _credentialReason(error.failure),
      );
      rethrow;
    } catch (_) {
      failure = const NativeProviderTransportException(
        NativeProviderTransportReason.transport,
      );
      _nativeFail(NativeProviderTransportReason.transport);
    }
  }

  @override
  void close({bool force = false}) {
    if (_closed) return;
    _closed = true;
    try {
      _inner?.close(force: true);
    } catch (_) {
      /* Fixed failures only. */
    }
    _inner = null;
    _factory = null;
    _fence = null;
  }
}

/// Validate primitives, cycles, depth and nodes before calling jsonEncode; an
/// arbitrary schema object/toJson can never run inside the native serializer.
String _nativeEncode(Object? input) {
  final active = <Object>{};
  var nodes = 0;
  var characters = 0;
  void visit(Object? value, int depth) {
    _nativeRequire(
      ++nodes <= 8192 && depth <= 32,
      NativeProviderTransportReason.wireLimit,
    );
    if (value == null || value is bool || value is int) return;
    if (value is double) {
      _nativeRequire(
        value.isFinite,
        NativeProviderTransportReason.invalidRequest,
      );
      return;
    }
    if (value is String) {
      characters += value.length;
      _nativeRequire(
        characters <= NativeProviderTransportLimits.requestBytes &&
            utf8.decode(utf8.encode(value)) == value,
        NativeProviderTransportReason.wireLimit,
      );
      return;
    }
    _nativeRequire(
      value is Map || value is List,
      NativeProviderTransportReason.invalidRequest,
    );
    _nativeRequire(
      active.add(value),
      NativeProviderTransportReason.invalidRequest,
    );
    if (value is Map) {
      for (final entry in value.entries) {
        _nativeRequire(
          entry.key is String,
          NativeProviderTransportReason.invalidRequest,
        );
        visit(entry.key, depth + 1);
        visit(entry.value, depth + 1);
      }
    } else {
      for (final child in value as List) {
        visit(child, depth + 1);
      }
    }
    active.remove(value);
  }

  visit(input, 0);
  final encoded = jsonEncode(input);
  _nativeRequire(
    utf8.encode(encoded).length <= NativeProviderTransportLimits.requestBytes,
    NativeProviderTransportReason.wireLimit,
  );
  return encoded;
}
