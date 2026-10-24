part of 'native_tool_transport.dart';

enum _ToolProtocol {
  chat,
  responses,
  anthropic,
  gemini;

  static _ToolProtocol fromRoute(CredentialProtocol protocol) =>
      switch (protocol) {
        CredentialProtocol.openAiChatCompletions => chat,
        CredentialProtocol.openAiResponses => responses,
        CredentialProtocol.anthropic => anthropic,
        CredentialProtocol.gemini => gemini,
        _ => throw const NativeToolException(NativeToolReason.unsupported),
      };
}

List<Map<String, Object?>> _initialToolHistory(
  NativeToolRequest request,
  _ToolProtocol protocol,
) {
  var characters = 0;
  return request.messages.map((m) {
    characters += m.text.length;
    _ntRequire(
      characters <= NativeToolLimits.contextCharacters,
      NativeToolReason.limit,
    );
    if (protocol == _ToolProtocol.gemini) {
      return <String, Object?>{
        'role': m.role == NativeToolRole.assistant
            ? 'model'
            : m.role == NativeToolRole.system
            ? 'system'
            : 'user',
        'parts': [
          {'text': m.text},
        ],
      };
    }
    if (protocol == _ToolProtocol.anthropic) {
      return <String, Object?>{
        'role': m.role.name,
        'content': [
          {'type': 'text', 'text': m.text},
        ],
      };
    }
    return <String, Object?>{'role': m.role.name, 'content': m.text};
  }).toList();
}

Map<String, Object?> _toolBody(
  NativeToolRequest r,
  _ToolProtocol p,
  List<Map<String, Object?>> history,
) {
  _ntRequire(
    history.length <= NativeToolLimits.messages,
    NativeToolReason.limit,
  );
  final c = r.config;
  final reasoning = _toolReasoning(c, p);
  final definitions = r.tools
      .map(
        (tool) => <String, Object?>{
          'name': tool.name,
          'description': tool.description,
          'parameters': tool.parameters,
        },
      )
      .toList();
  if (p == _ToolProtocol.chat || p == _ToolProtocol.responses) {
    return {
      'model': c.model,
      'stream': false,
      if (p == _ToolProtocol.responses) ...{
        'store': false,
        'input': history,
        'max_output_tokens': c.maxTokens,
        'tools': definitions.map((f) => {'type': 'function', ...f}).toList(),
      } else ...{
        'messages': history,
        'max_tokens': c.maxTokens,
        'tools': definitions
            .map((f) => {'type': 'function', 'function': f})
            .toList(),
        if (!c.omitFrequencyPenalty) 'frequency_penalty': c.frequencyPenalty,
        if (!c.omitPresencePenalty) 'presence_penalty': c.presencePenalty,
      },
      'tool_choice': 'auto',
      'parallel_tool_calls': false,
      if (!c.omitTemperature) 'temperature': c.temperature,
      if (!c.omitTopP) 'top_p': c.topP,
      ...reasoning,
    };
  }
  final system = <Object?>[];
  final messages = <Map<String, Object?>>[];
  var seenNonSystem = false;
  for (final m in history) {
    if (m['role'] == 'system') {
      _ntRequire(!seenNonSystem, NativeToolReason.unsupported);
      if (c.useSystemInstruction) {
        system.addAll(
          m[p == _ToolProtocol.gemini ? 'parts' : 'content'] as List,
        );
      } else {
        messages.add({...m, 'role': 'user'});
      }
    } else {
      seenNonSystem = true;
      messages.add(m);
    }
  }
  if (p == _ToolProtocol.anthropic) {
    return {
      'model': c.model,
      'stream': false,
      'max_tokens': c.maxTokens,
      'messages': messages,
      if (system.isNotEmpty) 'system': system,
      'tools': definitions
          .map(
            (f) => {
              'name': f['name'],
              'description': f['description'],
              'input_schema': f['parameters'],
            },
          )
          .toList(),
      'tool_choice': {'type': 'auto'},
      if (!c.omitTemperature && reasoning['thinking'] == null)
        'temperature': c.temperature,
      if (!c.omitTopP && reasoning['thinking'] == null) 'top_p': c.topP,
      if (!c.omitTopK && c.topK > 0 && reasoning['thinking'] == null)
        'top_k': c.topK,
      ...reasoning,
    };
  }
  return {
    'contents': messages,
    if (system.isNotEmpty) 'systemInstruction': {'parts': system},
    'tools': [
      {'functionDeclarations': definitions},
    ],
    'toolConfig': {
      'functionCallingConfig': {'mode': 'AUTO'},
    },
    'generationConfig': {
      'maxOutputTokens': c.maxTokens,
      if (!c.omitTemperature) 'temperature': c.temperature,
      if (!c.omitTopP) 'topP': c.topP,
      if (!c.omitTopK && c.topK > 0) 'topK': c.topK,
      ...reasoning,
    },
  };
}

List<Map<String, Object?>> _toolResultHistory(
  _ToolProtocol p,
  List<NativeToolCall> calls,
  List<NativeToolResult> results,
  Map<String, Object?> assistant,
) {
  if (p == _ToolProtocol.chat) {
    return results
        .map(
          (r) => <String, Object?>{
            'role': 'tool',
            'tool_call_id': r.callId,
            'content': jsonEncode(r.content),
          },
        )
        .toList();
  }
  if (p == _ToolProtocol.responses) {
    return results
        .map(
          (r) => <String, Object?>{
            'type': 'function_call_output',
            'call_id': r.callId,
            'output': jsonEncode(r.content),
          },
        )
        .toList();
  }
  if (p == _ToolProtocol.anthropic) {
    return [
      {
        'role': 'user',
        'content': results
            .map(
              (r) => {
                'type': 'tool_result',
                'tool_use_id': r.callId,
                'content': jsonEncode(r.content),
              },
            )
            .toList(),
      },
    ];
  }
  // Gemini historically has no call id. Keep its exact optional provider id
  // private; generated round/index correlation IDs must never be invented on wire.
  final parts = assistant['parts'] as List;
  final functions = parts
      .where((part) => (part as Map).containsKey('functionCall'))
      .toList();
  _ntRequire(functions.length == calls.length);
  return [
    {
      'role': 'user',
      'parts': List.generate(results.length, (i) {
        final native = (functions[i] as Map)['functionCall'] as Map;
        return {
          'functionResponse': {
            'name': results[i].name,
            if (native['id'] != null) 'id': native['id'],
            'response': results[i].content,
          },
        };
      }),
    },
  ];
}

final class _DecodedToolTurn {
  _DecodedToolTurn(this.text, this.calls, this.replay, this.usage);
  final String text;
  final List<NativeToolCall> calls;
  final List<Map<String, Object?>> replay;
  final ProviderTokenUsage? usage;
}

_DecodedToolTurn _decodeToolResponse(
  _ToolProtocol protocol,
  Map<String, Object?> root,
  SecretRedactor redactor,
  List<NativeToolDefinition> definitions,
  int round,
  Set<String> seen,
) {
  _ntRequire(root['error'] == null, NativeToolReason.providerError);
  final calls = <NativeToolCall>[];
  final text = StringBuffer();
  void append(Object? raw) {
    _ntRequire(raw is String);
    _ntRequire(
      text.length + (raw as String).length <= NativeToolLimits.textCharacters,
      NativeToolReason.limit,
    );
    text.write(raw);
  }

  void call(Object? id, Object? name, Object? args) {
    _ntRequire(id is String && name is String && args is Map<String, Object?>);
    _ntRequire(
      calls.length < NativeToolLimits.callsPerTurn,
      NativeToolReason.limit,
    );
    _ntRequire(
      definitions.any((d) => d.name == name),
      NativeToolReason.unknownTool,
    );
    final parsed = NativeToolCall(
      id: id as String,
      name: name as String,
      arguments: args as Map<String, Object?>,
    );
    _ntRequire(
      !seen.contains(parsed.id) && !calls.any((c) => c.id == parsed.id),
    );
    _toolSafeStrings({
      'id': parsed.id,
      'name': parsed.name,
      'arguments': parsed.arguments,
    }, redactor);
    calls.add(parsed);
  }

  final replay = switch (protocol) {
    _ToolProtocol.chat => _decodeToolChat(root, call, append),
    _ToolProtocol.responses => _decodeToolResponses(root, call, append),
    _ToolProtocol.anthropic => _decodeToolAnthropic(root, call, append),
    _ToolProtocol.gemini => _decodeToolGemini(root, call, append, round),
  };
  // Entire original provider continuation, including hidden signatures, is checked
  // before any typed call escapes. A secret-bearing native envelope is refused,
  // never rewritten into a different tool call or published as executable data.
  _toolSafeWireStrings(replay, redactor);
  final safeText = redactor.redactJson(text.toString());
  _ntRequire(
    safeText is String && safeText.length <= NativeToolLimits.textCharacters,
    NativeToolReason.limit,
  );
  final usage = _toolUsage(protocol, root);
  return _DecodedToolTurn(
    safeText as String,
    List.unmodifiable(calls),
    replay,
    usage,
  );
}

Map<String, Object?> _toolObject(Object? raw) {
  _ntRequire(raw is Map<String, Object?>);
  return raw as Map<String, Object?>;
}

List<Object?> _toolList(Object? raw) {
  _ntRequire(raw is List);
  return (raw as List).cast<Object?>();
}

void _toolKeys(Map<String, Object?> object, Set<String> allowed) => _ntRequire(
  object.keys.every(allowed.contains),
  NativeToolReason.unsupported,
);
