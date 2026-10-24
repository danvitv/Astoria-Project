import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';

import '../../core/native_provider_transport_fixture.dart';

export 'package:dio/dio.dart';
export 'package:glaze_flutter/core/llm/transport/native_tool_transport.dart';
export '../../core/native_provider_transport_fixture.dart';

final class ToolHarness {
  ToolHarness(String protocol) : native = NativeTransportHarness(protocol) {
    native.contentType = 'application/json';
    transport = NativeToolTransport(
      credentials: native.core.credentials,
      authIssuer: native.core.auth,
      mutations: native.core.mutations,
      routes: native.core.policy,
      currentRedactor: () => native.core.redaction.redactor,
      adapterFactory: native.adapter,
      scheduleDeadline: (duration, callback) {
        expire = callback;
        return Timer(duration, callback);
      },
    );
  }
  final NativeTransportHarness native;
  late final NativeToolTransport transport;
  void Function()? expire;
  final token = CancelToken();
  bool current = true;
  final tools = [
    NativeToolDefinition(
      name: 'set_theme',
      description: 'Set installed theme',
      parameters: {
        'type': 'object',
        'properties': {
          'value': {'type': 'string'},
        },
      },
    ),
  ];
  Future<void> store() =>
      native.store(purposes: {NativeProviderPurpose.astoria});
  Uri get recipient => native.protocol == 'gemini'
      ? Uri.parse(
          native.core.row.endpoint.replaceFirst(
            ':streamGenerateContent',
            ':generateContent',
          ),
        )
      : Uri.parse(native.core.row.endpoint);
  NativeToolSession session({
    NativeToolAdmission? admit,
    ApiConfig? config,
    SavedConnectionAuth? auth,
    Uri? approvedRecipient,
    List<NativeToolMessage>? messages,
    bool Function()? isCurrent,
  }) => transport.open(
    request: NativeToolRequest(
      config: config ?? native.core.row,
      savedConnectionAuth:
          auth ?? native.core.reference(NativeProviderPurpose.astoria),
      approvedRecipient: approvedRecipient ?? recipient,
      tools: tools,
      messages:
          messages ??
          [
            NativeToolMessage(
              role: NativeToolRole.user,
              text: 'Use a dark theme',
            ),
          ],
    ),
    cancelToken: token,
    isCurrent: isCurrent ?? () => current,
    beforeWire:
        admit ??
        (capsule) async {
          capsule.dispatch();
          return true;
        },
  );
  Map<String, Object?> response({
    bool tool = true,
    String name = 'set_theme',
    String id = 'call_1',
    Object? arguments = const {'value': 'dark'},
    String? prose,
    int outputTokens = 5,
  }) {
    final text = prose ?? 'Theme is dark.';
    return switch (native.protocol) {
      'openai_responses' => {
        'id': tool ? 'resp_1' : 'resp_2',
        'status': 'completed',
        'error': null,
        'output': [
          if (tool)
            {
              'type': 'function_call',
              'id': 'fc_1',
              'call_id': id,
              'name': name,
              'arguments': arguments is String
                  ? arguments
                  : jsonEncode(arguments),
              'status': 'completed',
            }
          else
            {
              'type': 'message',
              'id': 'msg_2',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {
                  'type': 'output_text',
                  'text': text,
                  'annotations': <Object?>[],
                },
              ],
            },
        ],
        'usage': {
          'input_tokens': 11,
          'output_tokens': outputTokens,
          'total_tokens': 16,
          'input_tokens_details': {'cached_tokens': 3},
        },
      },
      'anthropic' => {
        'type': 'message',
        'role': 'assistant',
        'stop_reason': tool ? 'tool_use' : 'end_turn',
        'content': [
          if (tool) ...[
            {
              'type': 'thinking',
              'thinking': 'Choose installed theme.',
              'signature': 'native_signature',
            },
            {'type': 'tool_use', 'id': id, 'name': name, 'input': arguments},
          ] else
            {'type': 'text', 'text': text},
        ],
        'usage': {
          'input_tokens': 11,
          'output_tokens': outputTokens,
          'cache_read_input_tokens': 3,
          'cache_creation_input_tokens': 2,
        },
      },
      'gemini' => {
        'candidates': [
          {
            'index': 0,
            'finishReason': 'STOP',
            'content': {
              'role': 'model',
              'parts': [
                if (tool)
                  {
                    'functionCall': {'id': id, 'name': name, 'args': arguments},
                    'thoughtSignature': 'native_thought_signature',
                  }
                else
                  {'text': text},
              ],
            },
          },
        ],
        'usageMetadata': {
          'promptTokenCount': 11,
          'candidatesTokenCount': outputTokens,
          'totalTokenCount': 16,
          'cachedContentTokenCount': 3,
          'thoughtsTokenCount': 2,
        },
      },
      _ => {
        'choices': [
          {
            'index': 0,
            'finish_reason': tool ? 'tool_calls' : 'stop',
            'message': {
              'role': 'assistant',
              'content': tool ? null : text,
              if (tool)
                'tool_calls': [
                  {
                    'type': 'function',
                    'id': id,
                    'function': {
                      'name': name,
                      'arguments': arguments is String
                          ? arguments
                          : jsonEncode(arguments),
                    },
                  },
                ],
            },
          },
        ],
        'usage': {
          'prompt_tokens': 11,
          'completion_tokens': outputTokens,
          'total_tokens': 16,
          'prompt_tokens_details': {'cached_tokens': 3},
        },
      },
    };
  }

  void reply(Map<String, Object?> value) {
    native.response = jsonEncode(value);
  }
}
