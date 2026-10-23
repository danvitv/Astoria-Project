import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';

String frame(Map<String, dynamic> event) => 'data: ${jsonEncode(event)}\n\n';
String chatDelta(String text) => frame({
  'choices': [
    {
      'index': 0,
      'delta': {'content': text},
      'finish_reason': null,
    },
  ],
});
String chatFinish([String reason = 'stop']) => frame({
  'choices': [
    {'index': 0, 'delta': <String, dynamic>{}, 'finish_reason': reason},
  ],
});
String chatComplete(String text) =>
    '${chatDelta(text)}${chatFinish()}data: [DONE]\n\n';

String responsesComplete(String text) =>
    frame({'type': 'response.output_text.delta', 'delta': text}) +
    frame({
      'type': 'response.completed',
      'response': {
        'status': 'completed',
        'output': [
          {
            'type': 'reasoning',
            'summary': [
              {'text': 'REASONING_CANARY'},
            ],
          },
          {
            'type': 'message',
            'role': 'assistant',
            'content': [
              {
                'type': 'output_text',
                'text': text,
                'annotations': ['RAW_PROVIDER_CANARY'],
              },
            ],
          },
        ],
      },
    });
String anthropicStart() => frame({
  'type': 'message_start',
  'message': {'role': 'assistant', 'content': <Object?>[], 'stop_reason': null},
});
String anthropicText(String text) =>
    frame({
      'type': 'content_block_start',
      'index': 0,
      'content_block': {'type': 'text', 'text': ''},
    }) +
    frame({
      'type': 'content_block_delta',
      'index': 0,
      'delta': {'type': 'text_delta', 'text': text},
    }) +
    frame({'type': 'content_block_stop', 'index': 0});
String anthropicFinish([String reason = 'end_turn']) =>
    frame({
      'type': 'message_delta',
      'delta': {'stop_reason': reason},
    }) +
    frame({'type': 'message_stop'});
String anthropicComplete(String text) =>
    anthropicStart() + anthropicText(text) + anthropicFinish();
String geminiText(String text, {String? finish}) => frame({
  'candidates': [
    {
      'index': 0,
      'content': {
        'role': 'model',
        'parts': [
          {'text': 'REASONING_CANARY', 'thought': true},
          {'text': text},
        ],
      },
      'finishReason': ?finish,
    },
  ],
  'usageMetadata': {'rawCanary': 'RAW_PROVIDER_CANARY'},
});

ChatTransportRequest privateRequest({
  String endpoint = 'https://fixture.invalid/v1/chat/completions',
  String model = 'fixture-model',
  bool stream = true,
  bool responses = false,
  List<Map<String, dynamic>>? messages,
  bool omit = false,
}) => ChatTransportRequest(
  endpoint: endpoint,
  apiKey: 'fixture-credential',
  model: model,
  messages:
      messages ??
      const [
        {'role': 'system', 'content': 'SELECTED_CONTEXT_CANARY'},
        {'role': 'user', 'content': 'CURRENT_TEXT_CANARY'},
      ],
  maxTokens: 64,
  temperature: 0,
  topP: 1,
  stream: stream,
  useResponsesApi: responses,
  requestReasoning: true,
  reasoningEffort: 'low',
  omitTemperature: omit,
  omitTopP: omit,
  omitReasoning: omit,
  sessionIdMode: 'off',
);

/// Synthetic adapter observes the REAL native request, encoded upload,
/// cancelFuture, response subscription, and force-close. Never uses HTTP.
final class PrivateFixtureAdapter implements HttpClientAdapter {
  PrivateFixtureAdapter(
    this.body, {
    this.status = 200,
    this.quiet = false,
    this.oneByteChunks = false,
    this.contentType = 'text/event-stream',
    this.rawBytes,
  });
  final String body;
  final int status;
  final bool quiet;
  final bool oneByteChunks;
  final String contentType;
  final List<int>? rawBytes;
  final fetched = Completer<void>();
  final forceClosed = Completer<void>();
  final responseCancelled = Completer<void>();
  final cancelObserved = Completer<void>();
  RequestOptions? options;
  String? upload;
  bool closed = false;
  int responseListens = 0;
  StreamController<Uint8List>? _response;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    this.options = options;
    if (!fetched.isCompleted) fetched.complete();
    unawaited(
      cancelFuture?.then((_) {
        if (!cancelObserved.isCompleted) cancelObserved.complete();
      }),
    );
    final bytes = <int>[];
    if (requestStream != null) {
      await for (final chunk in requestStream) {
        bytes.addAll(chunk);
      }
    }
    upload = utf8.decode(bytes);
    final content = rawBytes ?? utf8.encode(body);
    late StreamController<Uint8List> controller;
    controller = StreamController<Uint8List>(
      onListen: () {
        responseListens++;
        if (oneByteChunks) {
          for (final byte in content) {
            controller.add(Uint8List.fromList([byte]));
          }
        } else if (content.isNotEmpty) {
          controller.add(Uint8List.fromList(content));
        }
        if (!quiet) unawaited(controller.close());
      },
      onCancel: () {
        if (!responseCancelled.isCompleted) responseCancelled.complete();
      },
    );
    _response = controller;
    return ResponseBody(
      controller.stream,
      status,
      statusMessage: 'RAW_PROVIDER_CANARY',
      headers: {
        'content-type': [contentType],
        'location': [
          'https://RAW_PROVIDER_CANARY.invalid/?key=fixture-credential',
        ],
      },
    );
  }

  @override
  void close({bool force = false}) {
    closed = force;
    if (force && !forceClosed.isCompleted) forceClosed.complete();
    if (_response?.hasListener == true) unawaited(_response!.close());
  }
}

final class PrivateFixture {
  PrivateFixture(
    List<PrivateFixtureAdapter> adapters, {
    PrivateTextAuthorization? authorize,
    SecretRedactor Function()? redactor,
  }) {
    transport = PrivateTextTransport(
      adapterFactory: () {
        final adapter = adapters[created.length];
        created.add(adapter);
        return adapter;
      },
      currentRedactor: redactor ?? () => SecretRedactor(),
      authorize: (handoff) async {
        handoffs.add(handoff);
        return authorize == null ? true : await authorize(handoff);
      },
    );
  }
  final created = <PrivateFixtureAdapter>[];
  final handoffs = <PrivateTextHandoff>[];
  late final PrivateTextTransport transport;
  Future<PrivateTextOutcome> run({
    String protocol = LlmProtocol.openai,
    ChatTransportRequest? request,
    CancelToken? cancelToken,
    bool Function()? isCurrent,
    Uri? approved,
    void Function()? activity,
    Duration? deadline,
  }) {
    final input = request ?? privateRequest();
    return transport.generate(
      protocol: protocol,
      request: input,
      approvedRecipient: approved ?? Uri.parse(input.endpoint),
      cancelToken: cancelToken ?? CancelToken(),
      isCurrent: isCurrent ?? () => true,
      onActivity: activity,
      deadline: deadline ?? PrivateTextLimits.deadline,
    );
  }
}
