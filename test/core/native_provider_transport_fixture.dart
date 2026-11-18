import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_completion_metadata.dart';
import 'package:glaze_flutter/core/llm/transport/native_provider_transport.dart';

import 'native_provider_fixture.dart';

export 'native_provider_fixture.dart';
export 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
export 'package:glaze_flutter/core/llm/transport/native_provider_transport.dart';

const nativeTransportProtocols = [
  'openai',
  'openai_responses',
  'anthropic',
  'gemini',
  'openrouter',
  'custom_chat_completion',
];

ApiConfig nativeTransportRow(String protocol, {bool stream = true}) {
  final model = protocol == 'gemini'
      ? 'gemini-3.1-pro'
      : protocol == 'anthropic'
      ? 'claude-sonnet-4-5'
      : 'test-model';
  final endpoint = switch (protocol) {
    'openai_responses' => 'https://api.openai.com/v1/responses',
    'anthropic' => 'https://api.anthropic.com/v1/messages',
    'gemini' =>
      'https://generativelanguage.googleapis.com/v1beta/models/$model:${stream ? 'streamGenerateContent' : 'generateContent'}',
    'openrouter' => 'https://openrouter.ai/api/v1/chat/completions',
    'custom_chat_completion' => 'https://synthetic.example/v1/chat/completions',
    _ => 'https://api.openai.com/v1/chat/completions',
  };
  return ApiConfig(
    id: 'transport-$protocol',
    providerId: protocol,
    protocol: protocol,
    endpoint: endpoint,
    model: model,
    stream: stream,
    useResponsesApi: protocol == 'openai_responses',
  );
}

final class NativeTransportWire {
  NativeTransportWire(RequestOptions options, Uint8List upload)
    : uri = options.uri,
      method = options.method,
      headers = Map<String, dynamic>.from(options.headers),
      body = jsonDecode(utf8.decode(upload)) as Map<String, dynamic>,
      cancelToken = options.cancelToken;
  final Uri uri;
  final String method;
  final Map<String, dynamic> headers;
  final Map<String, dynamic> body;
  final CancelToken? cancelToken;
}

/// Synthetic wire only. No Dio default adapter, plugin, app graph or socket.
final class NativeTransportFakeAdapter implements HttpClientAdapter {
  NativeTransportFakeAdapter(this.owner);
  final NativeTransportHarness owner;
  bool closed = false;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in requestStream!) {
      bytes.add(chunk);
    }
    owner.wires.add(NativeTransportWire(options, bytes.takeBytes()));
    if (owner.respond != null) return owner.respond!(owner.wires.last);
    if (owner.beforeResponse != null) await owner.beforeResponse!();
    if (owner.fetchError != null) throw owner.fetchError!;
    return ResponseBody(
      owner.responseStream ??
          Stream.value(Uint8List.fromList(utf8.encode(owner.response))),
      owner.status,
      isRedirect: owner.status >= 300 && owner.status < 400,
      headers: {
        Headers.contentTypeHeader: [owner.contentType],
        'x-ignored-raw-canary': [nativeCanary],
      },
    );
  }

  @override
  void close({bool force = false}) {
    closed = true;
  }
}

final class NativeTransportLegacy implements ChatTransport {
  final requests = <ChatTransportRequest>[];
  @override
  Future<void> stream({
    required ChatTransportRequest request,
    CancelToken? cancelToken,
    ChatTransportOnUpdate? onUpdate,
    ChatTransportOnComplete? onComplete,
    ChatTransportOnError? onError,
  }) async {
    requests.add(request);
    onComplete?.call('legacy', null);
  }

  @override
  Future<List<Map<String, dynamic>>> fetchModels({
    required String endpoint,
    required String apiKey,
  }) async => [];
}

final class NativeTransportHarness {
  NativeTransportHarness(String protocol, {ApiConfig? row})
    : core = NativeProviderFixture(row: row ?? nativeTransportRow(protocol)),
      protocol = protocol {
    response = nativeTransportSse(protocol);
    factory = NativeProviderTransportFactory(
      credentials: core.credentials,
      authIssuer: core.auth,
      mutations: core.mutations,
      routes: core.policy,
      currentRedactor: () => core.redaction.redactor,
      adapterFactory: adapter,
      legacyPicker: (_) => legacy,
      scheduleDeadline: (duration, callback) {
        deadlineCallback = callback;
        return Timer(duration, callback);
      },
    );
  }
  final NativeProviderFixture core;
  final String protocol;
  final legacy = NativeTransportLegacy();
  late final NativeProviderTransportFactory factory;
  final adapters = <NativeTransportFakeAdapter>[];
  final wires = <NativeTransportWire>[];
  final updates = <(String, String?)>[];
  final errors = <Object>[];
  final completions = <(String, String?, String?)>[];
  String response = '';
  String contentType = 'text/event-stream';
  int status = 200;
  Stream<Uint8List>? responseStream;
  Future<void> Function()? beforeResponse;
  void Function()? onFactory;
  Object? fetchError;
  Future<ResponseBody> Function(NativeTransportWire)? respond;
  void Function()? deadlineCallback;

  HttpClientAdapter adapter() {
    onFactory?.call();
    final value = NativeTransportFakeAdapter(this);
    adapters.add(value);
    return value;
  }

  Future<void> store({
    Set<NativeProviderPurpose> purposes = const {
      NativeProviderPurpose.roleplay,
    },
  }) async {
    NativeProviderDestinationApproval? approval;
    if (protocol == 'custom_chat_completion') {
      approval = core.policy.confirmCustomDestination(
        core.policy.reviewCustomDestination(
          connection: core.reference(purposes.first).connection,
          purposes: purposes,
          lifetime: core.lifetime,
        ),
      );
    }
    await core.store(purposes: purposes, destinationApproval: approval);
  }

  ChatTransportRequest request({
    bool includeAuth = true,
    String? key,
    String? model,
    String? endpoint,
    bool? stream,
    NativeProviderPurpose purpose = NativeProviderPurpose.roleplay,
    Map<String, dynamic>? schema,
    List<Map<String, dynamic>>? tools,
    List<Map<String, dynamic>>? messages,
    SavedConnectionAuth? auth,
    void Function(ChatTransportCompletionMetadata metadata)?
    completionMetadataSink,
  }) => ChatTransportRequest(
    endpoint: endpoint ?? core.row.endpoint,
    apiKey: key ?? '',
    model: model ?? core.row.model,
    messages:
        messages ??
        const [
          {'role': 'user', 'content': 'Hello'},
        ],
    savedConnectionId: core.row.id,
    savedConnectionAuth: includeAuth ? auth ?? core.reference(purpose) : null,
    maxTokens: 1024,
    temperature: 0,
    topP: 1,
    stream: stream ?? core.row.stream,
    useResponsesApi: core.row.useResponsesApi,
    requestReasoning: true,
    showNativeReasoning: true,
    responseJsonSchema: schema,
    tools: tools,
    completionMetadataSink: completionMetadataSink,
  );

  Future<void> run({
    ChatTransportRequest? input,
    CancelToken? token,
    void Function(String, String?)? update,
  }) => factory
      .pick(protocol)
      .stream(
        request: input ?? request(),
        cancelToken: token,
        onUpdate: (text, reasoning) {
          updates.add((text, reasoning));
          update?.call(text, reasoning);
        },
        onComplete: (text, reasoning, {rawResponseJson}) {
          completions.add((text, reasoning, rawResponseJson));
        },
        onError: errors.add,
      );
}

String nativeTransportSse(
  String protocol, {
  String text = 'Visible text ',
  String reasoning = 'Reasoning text ',
}) {
  final events = nativeTransportEvents(
    protocol,
    text: text,
    reasoning: reasoning,
  );
  return events.map((event) => 'data: ${jsonEncode(event)}\n\n').join() +
      (const [
            'openai',
            'openrouter',
            'custom_chat_completion',
          ].contains(protocol)
          ? 'data: [DONE]\n\n'
          : '');
}

List<Map<String, dynamic>> nativeTransportEvents(
  String protocol, {
  String text = 'Visible text ',
  String reasoning = 'Reasoning text ',
}) => switch (protocol) {
  'openai_responses' => [
    {'type': 'response.reasoning_summary_text.delta', 'delta': reasoning},
    {'type': 'response.output_text.delta', 'delta': text},
    {'type': 'response.output_text.done', 'text': text},
    {
      'type': 'response.completed',
      'response': {
        'status': 'completed',
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
    },
  ],
  'anthropic' => [
    {
      'type': 'message_start',
      'message': {
        'role': 'assistant',
        'content': <Object?>[],
        'stop_reason': null,
      },
    },
    {
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'thinking', 'thinking': ''},
    },
    {
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'thinking_delta', 'thinking': reasoning},
    },
    {'type': 'content_block_stop', 'index': 0},
    {
      'type': 'content_block_start',
      'index': 1,
      'content_block': {'type': 'text', 'text': ''},
    },
    {
      'type': 'content_block_delta',
      'index': 1,
      'delta': {'type': 'text_delta', 'text': text},
    },
    {'type': 'content_block_stop', 'index': 1},
    {
      'type': 'message_delta',
      'delta': {'stop_reason': 'end_turn'},
    },
    {'type': 'message_stop'},
  ],
  'gemini' => [
    {
      'candidates': [
        {
          'index': 0,
          'content': {
            'role': 'model',
            'parts': [
              {'text': reasoning, 'thought': true},
              {'text': text},
            ],
          },
          'finishReason': 'STOP',
        },
      ],
    },
  ],
  _ => [
    {
      'choices': [
        {
          'index': 0,
          'delta': {
            'role': 'assistant',
            'content': text,
            'reasoning_content': reasoning,
          },
        },
      ],
    },
    {
      'choices': [
        {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': 'stop'},
      ],
    },
  ],
};

String nativeTransportJson(
  String protocol, {
  String text = 'Visible text ',
  String reasoning = 'Reasoning text ',
}) => jsonEncode(switch (protocol) {
  'openai_responses' => {
    'status': 'completed',
    'output': [
      {
        'type': 'reasoning',
        'summary': [
          {'type': 'summary_text', 'text': reasoning},
        ],
      },
      {
        'type': 'message',
        'role': 'assistant',
        'content': [
          {'type': 'output_text', 'text': text},
        ],
      },
    ],
  },
  'anthropic' => {
    'type': 'message',
    'role': 'assistant',
    'stop_reason': 'end_turn',
    'content': [
      {'type': 'thinking', 'thinking': reasoning},
      {'type': 'text', 'text': text},
    ],
  },
  'gemini' => nativeTransportEvents(
    protocol,
    text: text,
    reasoning: reasoning,
  ).single,
  _ => {
    'choices': [
      {
        'index': 0,
        'message': {
          'role': 'assistant',
          'content': text,
          'reasoning_content': reasoning,
        },
        'finish_reason': 'stop',
      },
    ],
  },
});
