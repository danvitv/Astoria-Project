part of 'native_tool_transport.dart';

/// One private credential-bound POST. No Dio client/default adapter is created.
final class _ToolWireJob {
  _ToolWireJob(this.session, this.binding, this.body, this.json, this._secret);
  final NativeToolSession session;
  final NativeProviderDispatchBinding binding;
  final Map<String, Object?> body;
  final String json;
  String _secret;
  Future<Map<String, Object?>>? pending;
  bool _retired = false;
  bool _received = false;
  RequestOptions? _options;

  void _check(RequestOptions options) {
    session._check();
    _ntRequire(!_retired && binding.isCurrent, NativeToolReason.notCurrent);
    binding.requireFinalRequest(
      uri: options.uri,
      method: options.method,
      protocol: binding.route.protocol,
      purpose: NativeProviderPurpose.astoria,
      model: session._request.config.model,
      stream: false,
    );
    _ntRequire(
      options.uri == session._request.approvedRecipient &&
          !options.followRedirects &&
          options.maxRedirects == 0 &&
          !options.receiveDataWhenStatusError &&
          options.responseType == ResponseType.stream &&
          identical(options.cancelToken, session._token) &&
          identical(options.data, body) &&
          _toolEncode(body, NativeToolLimits.requestBytes) == json,
      NativeToolReason.denied,
    );
    final expected = _headers();
    _ntRequire(
      options.headers.length == expected.length &&
          expected.entries.every((e) => options.headers[e.key] == e.value),
      NativeToolReason.denied,
    );
    session._check();
    _ntRequire(binding.isCurrent, NativeToolReason.notCurrent);
  }

  Map<String, Object?> _headers() => {
    'Content-Type': 'application/json',
    if (binding.route.protocol == CredentialProtocol.anthropic) ...{
      'x-api-key': _secret,
      'anthropic-version': '2023-06-01',
    } else if (binding.route.protocol == CredentialProtocol.gemini) ...{
      'x-goog-api-key': _secret,
    } else ...{
      'Authorization': 'Bearer $_secret',
    },
  };

  void dispatch() {
    _ntRequire(pending == null, NativeToolReason.denied);
    final options = RequestOptions(
      path: binding.route.endpoint.toString(),
      method: 'POST',
      data: body,
      headers: _headers(),
      cancelToken: session._token,
      followRedirects: false,
      maxRedirects: 0,
      receiveDataWhenStatusError: false,
      responseType: ResponseType.stream,
    );
    _options = options;
    _check(options);
    final adapter = session._transport.adapterFactory();
    try {
      _check(
        options,
      ); // Factory may synchronously revoke/replace original owner.
      session._adapter = adapter;
      final upload = Uint8List.fromList(utf8.encode(json));
      _check(
        options,
      ); // Immediately BEFORE fake/native POST; no intervening await.
      session._started = true;
      pending = _receive(
        adapter.fetch(
          options,
          Stream.value(upload),
          session._token.whenCancel.then<void>((_) {}),
        ),
      );
      // A caller can throw/stop after dispatch; observe pending errors regardless
      // of its admission settlement, without fabricating another outcome.
      unawaited(
        pending!.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    } catch (_) {
      try {
        adapter.close(force: true);
      } catch (_) {
        /* No raw diagnostics. */
      }
      rethrow;
    }
  }

  Future<Map<String, Object?>> _receive(
    Future<ResponseBody> responseFuture,
  ) async {
    final response = await session._awaitOwned(responseFuture);
    session._check();
    _ntRequire(
      response.statusCode >= 200 &&
          response.statusCode < 300 &&
          !response.isRedirect,
      NativeToolReason.httpStatus,
    );
    final types = response.headers.entries
        .where((e) => e.key.toLowerCase() == 'content-type')
        .expand((e) => e.value)
        .toList();
    _ntRequire(
      types.length == 1 &&
          types.single.length <= 256 &&
          types.single.split(';').first.trim().toLowerCase() ==
              'application/json',
      NativeToolReason.unsupported,
    );
    final bytes = BytesBuilder(copy: false);
    final iterator = StreamIterator(response.stream);
    try {
      while (await session._awaitOwned(iterator.moveNext())) {
        session._check();
        _ntRequire(
          bytes.length + iterator.current.length <=
              NativeToolLimits.responseBytes,
          NativeToolReason.limit,
        );
        bytes.add(iterator.current);
      }
      session._check();
      final text = utf8.decode(bytes.takeBytes(), allowMalformed: false);
      final parsed = _toolDecodeJson(text, NativeToolLimits.responseBytes);
      _ntRequire(parsed is Map<String, Object?>);
      _received = true;
      return parsed as Map<String, Object?>;
    } finally {
      unawaited(iterator.cancel());
    }
  }

  void retire() {
    _retired = true;
    _secret = '';
    _options?.headers.clear();
    _options = null;
    if (pending != null && !_received && !session._token.isCancelled) {
      session._token.cancel();
    }
  }
}

String _toolEncode(Object? input, int maxBytes) {
  var nodes = 0;
  var characters = 0;
  final active = Set<Object>.identity();
  void visit(Object? value, int depth) {
    _ntRequire(
      ++nodes <= NativeToolLimits.responseNodes &&
          depth <= NativeToolLimits.responseDepth,
      NativeToolReason.limit,
    );
    if (value == null || value is bool) return;
    if (value is num) {
      _ntRequire(value.isFinite);
      return;
    }
    if (value is String) {
      characters += value.length;
      _ntRequire(
        characters <= maxBytes && utf8.decode(utf8.encode(value)) == value,
        NativeToolReason.limit,
      );
      return;
    }
    _ntRequire((value is Map || value is List) && active.add(value));
    if (value is Map) {
      for (final e in value.entries) {
        _ntRequire(e.key is String);
        visit(e.key, depth + 1);
        visit(e.value, depth + 1);
      }
    } else {
      for (final child in value as List) {
        visit(child, depth + 1);
      }
    }
    active.remove(value);
  }

  visit(input, 0);
  final json = jsonEncode(input);
  _ntRequire(utf8.encode(json).length <= maxBytes, NativeToolReason.limit);
  return json;
}

Object? _toolDecodeJson(String text, int maxBytes) {
  _ntRequire(utf8.encode(text).length <= maxBytes, NativeToolReason.limit);
  var depth = 0;
  var nodes = 0;
  var quoted = false;
  var escaped = false;
  for (final code in text.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (code == 92) {
        escaped = true;
      } else if (code == 34) {
        quoted = false;
      }
    } else if (code == 34) {
      quoted = true;
      nodes++;
    } else if (code == 123 || code == 91) {
      depth++;
      nodes++;
    } else if (code == 125 || code == 93) {
      depth--;
      _ntRequire(depth >= 0);
    } else if (code == 44) {
      nodes++;
    }
    _ntRequire(
      depth <= NativeToolLimits.responseDepth &&
          nodes <= NativeToolLimits.responseNodes,
      NativeToolReason.limit,
    );
  }
  _ntRequire(!quoted && depth == 0);
  try {
    final value = jsonDecode(text);
    _toolEncode(
      value,
      maxBytes,
    ); // Validate primitive values before any projection.
    return value;
  } on NativeToolException {
    rethrow;
  } catch (_) {
    _ntFail(NativeToolReason.malformed);
  }
}

void _toolSafeStrings(Object? value, SecretRedactor redactor) {
  if (value is String) {
    // Primitive projection avoids parsing a JSON-looking prose string as tools.
    _ntRequire(redactor.redactJson(value) == value, NativeToolReason.denied);
  } else if (value is Map) {
    for (final entry in value.entries) {
      _toolSafeStrings(entry.key, redactor);
      _toolSafeStrings(entry.value, redactor);
    }
  } else if (value is List) {
    for (final child in value) {
      _toolSafeStrings(child, redactor);
    }
  }
}

/// JSON decoding here applies ONLY to protocol-defined argument/result fields.
/// It is sanitation, never execution or prose recognition. Numeric fields such
/// as maxTokens must not be mistaken for a credential by text field heuristics.
void _toolSafeWireStrings(Object? value, SecretRedactor redactor) {
  if (value is Map) {
    for (final entry in value.entries) {
      _toolSafeStrings(entry.key, redactor);
      final encoded =
          entry.value is String &&
          ((entry.key == 'arguments' &&
                  value['name'] is String &&
                  (value['type'] == 'function_call' ||
                      value.keys.every(
                        (k) => k == 'name' || k == 'arguments',
                      ))) ||
              (entry.key == 'output' &&
                  value['type'] == 'function_call_output') ||
              (entry.key == 'content' &&
                  (value['role'] == 'tool' || value['type'] == 'tool_result')));
      if (encoded) {
        final typed = _toolDecodeJson(
          entry.value as String,
          NativeToolLimits.jsonBytes,
        );
        _ntRequire(typed is Map<String, Object?>);
        _toolSafeStrings(typed, redactor);
      } else {
        _toolSafeWireStrings(entry.value, redactor);
      }
    }
  } else if (value is List) {
    for (final child in value) {
      _toolSafeWireStrings(child, redactor);
    }
  } else {
    _toolSafeStrings(value, redactor);
  }
}
