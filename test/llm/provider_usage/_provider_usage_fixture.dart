import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

import '../transport/_private_text_fixture.dart';

export '../transport/_private_text_fixture.dart';

final class UsageRoute {
  const UsageRoute(this.protocol, this.endpoint, {this.responses = false});
  final String protocol;
  final String endpoint;
  final bool responses;
  String get decoderProtocol =>
      responses ? LlmProtocol.openaiResponses : protocol;
  ChatTransportRequest get request => privateRequest(
    endpoint: endpoint,
    model: 'fixture-model',
    responses: responses,
  );
  Future<PrivateTextOutcome> run(String body, {bool split = false}) =>
      PrivateFixture([
        PrivateFixtureAdapter(body, oneByteChunks: split),
      ]).run(protocol: protocol, request: request);
}

const usageRoutes = [
  UsageRoute(LlmProtocol.openai, 'https://fixture.invalid/v1/chat/completions'),
  UsageRoute(
    LlmProtocol.customChatCompletion,
    'https://fixture.invalid/chat/completions',
  ),
  UsageRoute(LlmProtocol.openrouter, OpenRouterChatTransport.baseUrl),
  UsageRoute(
    LlmProtocol.openaiResponses,
    'https://fixture.invalid/v1/responses',
  ),
  UsageRoute(
    LlmProtocol.customChatCompletion,
    'https://fixture.invalid/responses',
    responses: true,
  ),
  UsageRoute(LlmProtocol.anthropic, 'https://fixture.invalid/v1/messages'),
  UsageRoute(
    LlmProtocol.gemini,
    'https://fixture.invalid/v1beta/models/fixture-model:streamGenerateContent',
  ),
];

// Use only metadata containers on the admitted existing event shapes. Numeric
// names are explicit fixtures, not aliases inferred from prose or raw strings.
Map<String, dynamic> usageFields(
  String protocol, {
  Object? input,
  Object? output,
  Object? total,
  Object? cached,
  Object? creation,
  Object? reasoning,
}) => switch (protocol) {
  LlmProtocol.openaiResponses => {
    'input_tokens': ?input,
    'output_tokens': ?output,
    'total_tokens': ?total,
    'input_tokens_details': {'cached_tokens': ?cached},
    'output_tokens_details': {'reasoning_tokens': ?reasoning},
  },
  LlmProtocol.anthropic => {
    'input_tokens': ?input,
    'output_tokens': ?output,
    'cache_read_input_tokens': ?cached,
    'cache_creation_input_tokens': ?creation,
  },
  LlmProtocol.gemini => {
    'promptTokenCount': ?input,
    'candidatesTokenCount': ?output,
    'totalTokenCount': ?total,
    'cachedContentTokenCount': ?cached,
    'thoughtsTokenCount': ?reasoning,
  },
  _ => {
    'prompt_tokens': ?input,
    'completion_tokens': ?output,
    'total_tokens': ?total,
    'prompt_tokens_details': {'cached_tokens': ?cached},
    'completion_tokens_details': {'reasoning_tokens': ?reasoning},
  },
};

Map<String, dynamic> usageChatEvent(String text, {Object? usage}) => {
  'choices': [
    {
      'index': 0,
      'delta': {'content': text},
      'finish_reason': null,
    },
  ],
  'usage': ?usage,
};

Map<String, dynamic> usageResponsesTerminal(String text, {Object? usage}) => {
  'type': 'response.completed',
  'response': {
    'status': 'completed',
    'usage': ?usage,
    'output': [
      {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
      },
    ],
  },
};

Map<String, dynamic> usageAnthropicStart({Object? usage}) => {
  'type': 'message_start',
  'message': {
    'role': 'assistant',
    'content': <Object?>[],
    'stop_reason': null,
    'usage': ?usage,
  },
};

Map<String, dynamic> usageGeminiEvent(
  String text, {
  Object? usage,
  String? finish,
}) => {
  'candidates': [
    {
      'index': 0,
      'content': {
        'role': 'model',
        'parts': [
          {'text': text},
        ],
      },
      'finishReason': ?finish,
    },
  ],
  'usageMetadata': ?usage,
};

String usageComplete(
  String protocol,
  String text, {
  Object? usage,
}) => switch (protocol) {
  LlmProtocol.openaiResponses =>
    frame({'type': 'response.output_text.delta', 'delta': text}) +
        frame(usageResponsesTerminal(text, usage: usage)),
  LlmProtocol.anthropic =>
    frame(usageAnthropicStart(usage: usage)) +
        anthropicText(text) +
        frame({
          'type': 'message_delta',
          'delta': {'stop_reason': 'end_turn'},
          'usage': ?usage,
        }) +
        frame({'type': 'message_stop'}),
  LlmProtocol.gemini => frame(
    usageGeminiEvent(text, usage: usage, finish: 'STOP'),
  ),
  _ =>
    '${frame(usageChatEvent(text, usage: usage))}'
        '${chatFinish()}'
        '${usage is Map ? frame({'choices': <Object?>[], 'usage': usage}) : ''}'
        'data: [DONE]\n\n',
};

String usagePartial(String protocol, String text, {Object? usage}) =>
    switch (protocol) {
      LlmProtocol.openaiResponses => frame({
        'type': 'response.output_text.delta',
        'delta': text,
        // Top-level usage on a text delta is deliberately not authoritative.
        'usage': ?usage,
      }),
      LlmProtocol.anthropic =>
        frame(usageAnthropicStart(usage: usage)) + anthropicText(text),
      LlmProtocol.gemini => frame(usageGeminiEvent(text, usage: usage)),
      _ => frame(usageChatEvent(text, usage: usage)),
    };

List<int?> usageNumbers(ProviderTokenUsage? usage) => [
  usage?.inputTokens,
  usage?.outputTokens,
  usage?.totalTokens,
  usage?.cachedInputTokens,
  usage?.cacheCreationInputTokens,
  usage?.reasoningTokens,
];
