part of 'native_provider_transport.dart';

/// Entirely private ephemeral wire data; no keyed DTO is returned to callers.
final class _NativeWirePlan {
  _NativeWirePlan(
    String protocol,
    ChatTransportRequest input,
    NativeProviderDispatchBinding binding,
    String secret,
    SecretRedactor redactor,
  ) {
    _nativeRequire(
      (input.maxTokens == -1 ||
              (input.maxTokens > 0 && input.maxTokens <= 0x7fffffff)) &&
          input.temperature.isFinite &&
          input.topP.isFinite &&
          input.frequencyPenalty.isFinite &&
          input.presencePenalty.isFinite &&
          input.tools == null &&
          input.toolChoice == null &&
          input.extraRequestParameters.isEmpty &&
          input.messages.isNotEmpty &&
          input.messages.length <= 514 &&
          const ['off', '5min', '1h'].contains(input.cacheControlTtl) &&
          const [
            'depth',
            'stable_prefix',
          ].contains(input.cacheBreakpointMode) &&
          const ['off', 'always', 'openrouter'].contains(input.sessionIdMode),
      NativeProviderTransportReason.invalidRequest,
    );
    var context = 0;
    for (final messages in [
      input.messages,
      input.previousMessages ?? const [],
    ]) {
      for (final message in messages) {
        _nativeRequire(
          message.keys.every(
                (key) => const ['role', 'content', 'name'].contains(key),
              ) &&
              const ['system', 'user', 'assistant'].contains(message['role']) &&
              message['content'] is String &&
              (message['name'] == null || message['name'] is String),
          NativeProviderTransportReason.unsupported,
        );
        context += (message['content'] as String).length;
        _nativeRequire(
          context <= NativeProviderTransportLimits.contextCharacters,
          NativeProviderTransportReason.invalidRequest,
        );
        _nativeRequire(
          redactor.redactText(message['content'] as String) ==
              message['content'],
          NativeProviderTransportReason.invalidRequest,
        );
      }
    }
    // Bounds are checked BEFORE serializers/converters traverse caller trees.
    final frozenMessages = _nativeJson(_nativeEncode(input.messages)) as List;
    final frozenPrevious = input.previousMessages == null
        ? null
        : _nativeJson(_nativeEncode(input.previousMessages)) as List;
    final frozenSchema = input.responseJsonSchema == null
        ? null
        : _nativeJson(_nativeEncode(input.responseJsonSchema))
              as Map<String, dynamic>;
    var request = _nativeKeyedCopy(
      input,
      secret,
      messages: frozenMessages.cast<Map<String, dynamic>>(),
      previousMessages: frozenPrevious?.cast<Map<String, dynamic>>(),
      schema: frozenSchema,
    );
    final mode = PromptPostProcessing.normalize(request.promptPostProcessing);
    if (mode != PromptPostProcessing.none) {
      request = request.withMessages(
        postProcessPrompt(
          request.messages,
          mode,
          charName: request.charName,
          userName: request.userName,
        ),
        previousMessages: request.previousMessages == null
            ? null
            : postProcessPrompt(
                request.previousMessages!,
                mode,
                charName: request.charName,
                userName: request.userName,
              ),
      );
    }
    final responses =
        binding.route.protocol == CredentialProtocol.openAiResponses;
    Map<String, dynamic> body;
    headers = {'Content-Type': 'application/json'};
    prefill = null;
    if (protocol == LlmProtocol.anthropic) {
      // The legacy pure builder has a debug branch for this shape. Refuse it
      // rather than invoke a logger or silently drop an unbound prompt turn.
      _nativeRequire(
        !(request.requestReasoning &&
            !request.omitReasoning &&
            request.messages.last['role'] == 'assistant'),
        NativeProviderTransportReason.unsupported,
      );
      final built = AnthropicChatTransport.buildRequest(request);
      body = built.body;
      headers = built.headers;
      prefill = built.prefill;
      if (frozenSchema != null) {
        final output =
            body.putIfAbsent('output_config', () => <String, dynamic>{})
                as Map<String, dynamic>;
        output['format'] = {'type': 'json_schema', 'schema': frozenSchema};
      }
    } else if (protocol == LlmProtocol.gemini) {
      // Reuse only the pure body projection with a keyless serializer input.
      // No legacy ?key URL containing the real key is even constructed.
      body = GeminiChatTransport.buildRequest(
        _nativeKeyedCopy(request, ''),
      ).body;
      headers['x-goog-api-key'] = secret;
    } else {
      if (protocol == LlmProtocol.openrouter) {
        request = _nativeOpenRouterCache(request);
        headers.addAll(OpenRouterChatTransport.extraHeaders);
      }
      headers['Authorization'] = 'Bearer $secret';
      body = responses
          ? OpenAiResponsesTransport.buildBody(request)
          : OpenAiChatTransport.buildBody(request, protocol: protocol);
      if (responses && frozenSchema != null) {
        // Additive Responses schema support; accepted private text plan remains
        // unchanged and still refuses schema traffic.
        body['text'] = {
          'format': {
            'type': 'json_schema',
            'name': 'astoria_response',
            'strict': true,
            'schema': frozenSchema,
          },
        };
      }
    }
    decoderProtocol = responses ? LlmProtocol.openaiResponses : protocol;
    schema = frozenSchema;
    uri = protocol == LlmProtocol.gemini && input.stream
        ? binding.route.endpoint.replace(query: 'alt=sse')
        : binding.route.endpoint;
    bodyJson = _nativeEncode(body);
    _nativeRequire(
      !_nativeCredentialForms(secret).any(bodyJson.contains),
      NativeProviderTransportReason.invalidRequest,
    );
    _nativeRequire(
      utf8.encode(bodyJson).length <=
          NativeProviderTransportLimits.requestBytes,
      NativeProviderTransportReason.invalidRequest,
    );
    // Validate then materialize a bounded frozen body, never arbitrary toJson.
    this.body = _nativeJson(bodyJson) as Map<String, dynamic>;
    binding.requireFinalRequest(
      uri: uri,
      method: 'POST',
      protocol: binding.route.protocol,
      purpose: binding.purpose,
      model: input.model,
      stream: input.stream,
    );
  }

  late final Uri uri;
  late final String decoderProtocol;
  late Map<String, String> headers;
  late final Map<String, dynamic> body;
  late final String bodyJson;
  late final Map<String, dynamic>? schema;
  late String? prefill;
}

ChatTransportRequest _nativeKeyedCopy(
  ChatTransportRequest input,
  String secret, {
  List<Map<String, dynamic>>? messages,
  List<Map<String, dynamic>>? previousMessages,
  Map<String, dynamic>? schema,
}) => ChatTransportRequest(
  endpoint: input.endpoint,
  apiKey: secret,
  model: input.model,
  savedConnectionAuth: input.savedConnectionAuth,
  savedConnectionId: input.savedConnectionId,
  nativeSourceIsCurrent: input.nativeSourceIsCurrent,
  messages: messages ?? input.messages,
  maxTokens: input.maxTokens,
  temperature: input.temperature,
  topP: input.topP,
  topK: input.topK,
  frequencyPenalty: input.frequencyPenalty,
  presencePenalty: input.presencePenalty,
  stream: input.stream,
  requestReasoning: input.requestReasoning,
  useResponsesApi: input.useResponsesApi,
  reasoningEffort: input.reasoningEffort,
  omitTemperature: input.omitTemperature,
  omitTopP: input.omitTopP,
  omitTopK: input.omitTopK,
  omitFrequencyPenalty: input.omitFrequencyPenalty,
  omitPresencePenalty: input.omitPresencePenalty,
  omitReasoning: input.omitReasoning,
  omitReasoningEffort: input.omitReasoningEffort,
  showNativeReasoning: input.showNativeReasoning,
  receiveTimeoutMs: input.receiveTimeoutMs,
  sessionId: input.sessionId,
  previousMessages: previousMessages ?? input.previousMessages,
  cacheControlTtl: input.cacheControlTtl,
  cacheBreakpointMode: input.cacheBreakpointMode,
  sessionIdMode: input.sessionIdMode,
  promptPostProcessing: input.promptPostProcessing,
  charName: input.charName,
  userName: input.userName,
  tools: input.tools,
  toolChoice: input.toolChoice,
  responseJsonSchema: schema ?? input.responseJsonSchema,
  useSystemInstruction: input.useSystemInstruction,
  extraRequestParameters: input.extraRequestParameters,
  // Retain metadata so the UNCHANGED private text plan can refuse capture input.
  // The new general wire never installs diagnostic capture behavior.
  captureContext: input.captureContext,
  completionMetadataSink: input.completionMetadataSink,
);

ChatTransportRequest _nativeOpenRouterCache(ChatTransportRequest request) {
  if (!isClaudeModelOnOpenRouter(request.model) ||
      request.cacheControlTtl == 'off') {
    // The OpenAI helper would send a top-level cache field. Native OR cache
    // markers, as on legacy OR, belong only in the message parts.
    return _nativeCacheOffCopy(request, request.messages);
  }
  final ttl = request.cacheControlTtl == '1h' ? '1h' : '5m';
  var messages = cachingSystemPromptForOpenRouter(request.messages, ttl: ttl);
  if (request.cacheBreakpointMode == cacheBreakpointModeStablePrefix) {
    messages = markStablePrefixCacheControl(
      messages,
      request.previousMessages == null
          ? null
          : cachingSystemPromptForOpenRouter(
              request.previousMessages!,
              ttl: ttl,
            ),
      ttl: ttl,
    );
  } else {
    messages = cachingAtDepthForOpenRouterClaude(messages, 2, ttl);
  }
  return _nativeCacheOffCopy(request, messages);
}

ChatTransportRequest _nativeCacheOffCopy(
  ChatTransportRequest r,
  List<Map<String, dynamic>> messages,
) => ChatTransportRequest(
  endpoint: r.endpoint,
  apiKey: r.apiKey,
  model: r.model,
  messages: messages,
  savedConnectionAuth: r.savedConnectionAuth,
  savedConnectionId: r.savedConnectionId,
  nativeSourceIsCurrent: r.nativeSourceIsCurrent,
  maxTokens: r.maxTokens,
  temperature: r.temperature,
  topP: r.topP,
  topK: r.topK,
  frequencyPenalty: r.frequencyPenalty,
  presencePenalty: r.presencePenalty,
  stream: r.stream,
  requestReasoning: r.requestReasoning,
  useResponsesApi: r.useResponsesApi,
  reasoningEffort: r.reasoningEffort,
  omitTemperature: r.omitTemperature,
  omitTopP: r.omitTopP,
  omitTopK: r.omitTopK,
  omitFrequencyPenalty: r.omitFrequencyPenalty,
  omitPresencePenalty: r.omitPresencePenalty,
  omitReasoning: r.omitReasoning,
  omitReasoningEffort: r.omitReasoningEffort,
  showNativeReasoning: r.showNativeReasoning,
  receiveTimeoutMs: r.receiveTimeoutMs,
  sessionId: r.sessionId,
  sessionIdMode: r.sessionIdMode,
  previousMessages: r.previousMessages,
  cacheBreakpointMode: r.cacheBreakpointMode,
  promptPostProcessing: r.promptPostProcessing,
  charName: r.charName,
  userName: r.userName,
  responseJsonSchema: r.responseJsonSchema,
  useSystemInstruction: r.useSystemInstruction,
  completionMetadataSink: r.completionMetadataSink,
);

Object? _nativeJson(String input) {
  _nativeRequire(
    input.length <= NativeProviderTransportLimits.requestBytes,
    NativeProviderTransportReason.wireLimit,
  );
  var depth = 0;
  var tokens = 0;
  var quoted = false;
  var escaped = false;
  for (final code in input.codeUnits) {
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
      _nativeRequire(++tokens <= 8192, NativeProviderTransportReason.wireLimit);
    } else if (code == 123 || code == 91) {
      _nativeRequire(
        ++depth <= 32 && ++tokens <= 8192,
        NativeProviderTransportReason.wireLimit,
      );
    } else if (code == 125 || code == 93) {
      _nativeRequire(--depth >= 0);
    } else if (code == 44) {
      _nativeRequire(++tokens <= 8192, NativeProviderTransportReason.wireLimit);
    }
  }
  _nativeRequire(!quoted && depth == 0);
  try {
    return jsonDecode(input);
  } catch (_) {
    _nativeFail(NativeProviderTransportReason.malformed);
  }
}

Set<String> _nativeCredentialForms(String secret) {
  final escaped = jsonEncode(secret);
  return {
    secret,
    Uri.encodeComponent(secret),
    Uri.encodeFull(secret),
    escaped.substring(1, escaped.length - 1),
    base64Encode(utf8.encode(secret)),
    base64UrlEncode(utf8.encode(secret)),
  };
}

bool _nativeLiteralCrosses(String left, String right, String literal) {
  if (left.isEmpty || right.isEmpty || literal.length < 2) return false;
  final start = left.length > literal.length
      ? left.length - literal.length + 1
      : 0;
  final tail = left.substring(start);
  final head = right.length >= literal.length
      ? right.substring(0, literal.length - 1)
      : right;
  final joined = '$tail$head';
  var match = joined.indexOf(literal);
  while (match >= 0 && match < tail.length) {
    if (match + literal.length > tail.length) return true;
    match = joined.indexOf(literal, match + 1);
  }
  return false;
}
