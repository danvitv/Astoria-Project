import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_completion_metadata.dart';

import 'native_provider_transport_fixture.dart';

void main() {
  for (final protocol in nativeTransportProtocols) {
    for (final streaming in [true, false]) {
      test(
        '$protocol ${streaming ? 'stream' : 'completion'} uses one bound private wire',
        () async {
          final h = NativeTransportHarness(
            protocol,
            row: nativeTransportRow(protocol, stream: streaming),
          );
          await h.store();
          ChatTransportCompletionMetadata? completionMetadata;
          final request = h.request(
            completionMetadataSink: (metadata) => completionMetadata = metadata,
          );
          if (!streaming) {
            h.response = nativeTransportJson(protocol);
            h.contentType = 'application/json';
          }
          await h.run(input: request);
          expect(request.apiKey, isEmpty);
          expect(h.core.row.apiKey, isEmpty);
          expect(h.legacy.requests, isEmpty);
          expect(h.errors, isEmpty);
          expect(h.wires, hasLength(1));
          expect(h.adapters.every((adapter) => adapter.closed), isTrue);
          final wire = h.wires.single;
          expect(wire.method, 'POST');
          expect(
            wire.uri.toString(),
            protocol == 'gemini' && streaming
                ? '${h.core.row.endpoint}?alt=sse'
                : h.core.row.endpoint,
          );
          expect(wire.uri.toString(), isNot(contains(nativeCanary)));
          final header = protocol == 'anthropic'
              ? 'x-api-key'
              : protocol == 'gemini'
              ? 'x-goog-api-key'
              : 'Authorization';
          expect(
            wire.headers[header],
            protocol == 'anthropic' || protocol == 'gemini'
                ? nativeCanary
                : 'Bearer $nativeCanary',
          );
          expect(jsonEncode(wire.body), isNot(contains(nativeCanary)));
          expect(jsonEncode(wire.body), isNot(contains('savedConnectionAuth')));
          expect(jsonEncode(wire.body), isNot(contains('savedConnectionId')));
          final sampling = protocol == 'gemini'
              ? wire.body['generationConfig'] as Map
              : wire.body;
          expect(sampling['temperature'], 0);
          expect(sampling[protocol == 'gemini' ? 'topP' : 'top_p'], 1);
          if (protocol == 'openrouter') {
            expect(
              wire.headers['HTTP-Referer'],
              OpenRouterChatTransport.referer,
            );
            expect(wire.headers['X-Title'], OpenRouterChatTransport.title);
          }
          expect(h.completions, hasLength(1));
          expect(h.completions.single.$1, 'Visible text ');
          expect(h.completions.single.$2, 'Reasoning text ');
          expect(h.completions.single.$3, isNot(contains(nativeCanary)));
          expect(completionMetadata, isNotNull);
          expect(completionMetadata!.finishReason, 'stop');
          expect(completionMetadata!.wireProtocol, switch (protocol) {
            'anthropic' => 'anthropic_messages',
            'gemini' => 'gemini_generate_content',
            'openai_responses' => 'openai_responses',
            _ => 'openai_chat',
          });
          final raw = jsonDecode(h.completions.single.$3!) as Map;
          expect(
            raw.keys,
            unorderedEquals(['choices', 'astoria_stream_termination']),
          );
          expect(raw['astoria_stream_termination'], 'terminal');
          if (streaming) {
            expect(h.updates.map((delta) => delta.$1).join(), 'Visible text ');
            expect(
              h.updates.map((delta) => delta.$2 ?? '').join(),
              'Reasoning text ',
            );
          } else {
            expect(h.updates, isEmpty);
          }
        },
      );
    }
  }

  for (final protocol in nativeTransportProtocols) {
    for (final streaming in [true, false]) {
      test(
        '$protocol safe schema stays text-only with terminal unwrapping ($streaming)',
        () async {
          final h = NativeTransportHarness(
            protocol,
            row: nativeTransportRow(protocol, stream: streaming),
          );
          await h.store();
          const text = '{"prefix":"Start: ","content":"safe reply"}';
          h.response = streaming
              ? nativeTransportSse(protocol, text: text)
              : nativeTransportJson(protocol, text: text);
          h.contentType = streaming ? 'text/event-stream' : 'application/json';
          await h.run(
            input: h.request(
              schema: const {
                'type': 'object',
                'properties': {
                  'prefix': {'type': 'string'},
                  'content': {'type': 'string'},
                },
                'required': ['prefix', 'content'],
                'additionalProperties': false,
              },
            ),
          );
          expect(h.errors, isEmpty);
          expect(h.completions.single.$1, 'Start: safe reply');
          expect(
            h.updates,
            isEmpty,
            reason: 'Schema JSON never escapes before terminal',
          );
          final body = h.wires.single.body;
          expect(
            protocol == 'gemini'
                ? (body['generationConfig'] as Map)['responseSchema']
                : protocol == 'openai_responses'
                ? (body['text'] as Map)['format']
                : protocol == 'anthropic'
                ? (body['output_config'] as Map)['format']
                : body['response_format'],
            isNotNull,
          );
        },
      );
    }
  }

  test(
    'custom Responses is explicit, not inferred from a familiar hostname',
    () async {
      final row = nativeTransportRow('custom_chat_completion').copyWith(
        useResponsesApi: true,
        endpoint: 'https://synthetic.example/v1/responses',
      );
      final h = NativeTransportHarness('custom_chat_completion', row: row);
      await h.store();
      h.response = nativeTransportSse('openai_responses');
      await h.run();
      expect(h.errors, isEmpty);
      expect(h.wires.single.body['input'], isNotNull);
      expect(h.wires.single.body['messages'], isNull);
    },
  );

  test(
    'source authority is nonserialized and survives actual request copies',
    () async {
      final h = NativeTransportHarness('openrouter');
      await h.store();
      final auth = h.core.reference();
      void completionSink(ChatTransportCompletionMetadata _) {}
      final request = ChatTransportRequest.fromApiConfig(
        h.core.row,
        savedConnectionAuth: auth,
        messages: const [
          {'role': 'user', 'content': 'original'},
        ],
        completionMetadataSink: completionSink,
      );
      final rewritten = request.withMessages(const [
        {'role': 'user', 'content': 'rewritten'},
      ]);
      final routed = OpenRouterChatTransport.buildRouterRequest(rewritten);
      expect(request.savedConnectionId, h.core.row.id);
      expect(identical(request.savedConnectionAuth, auth), isTrue);
      expect(identical(rewritten.savedConnectionAuth, auth), isTrue);
      expect(identical(routed.savedConnectionAuth, auth), isTrue);
      expect(
        identical(rewritten.completionMetadataSink, completionSink),
        isTrue,
      );
      expect(identical(routed.completionMetadataSink, completionSink), isTrue);
      expect(routed.savedConnectionId, h.core.row.id);
      final body = OpenAiChatTransport.buildBody(
        routed,
        protocol: 'openrouter',
      );
      expect(jsonEncode(body), isNot(contains('SavedConnectionAuth')));
      expect(jsonEncode(body), isNot(contains(h.core.row.id)));
      expect(jsonEncode(body), isNot(contains(nativeCanary)));
      final legacy = ChatTransportRequest.fromApiConfig(
        h.core.row,
        messages: const [],
      );
      expect(legacy.savedConnectionAuth, isNull);
      expect(legacy.savedConnectionId, h.core.row.id);
    },
  );

  test('withMessages preserves all ordinary request options and schema', () {
    const schema = {'type': 'object'};
    const request = ChatTransportRequest(
      endpoint: 'https://synthetic.example/v1/chat/completions',
      apiKey: '',
      model: 'model',
      messages: [],
      savedConnectionId: 'known-id',
      maxTokens: 17,
      temperature: 0,
      topP: 1,
      topK: 9,
      frequencyPenalty: 0.2,
      presencePenalty: 0.3,
      stream: false,
      requestReasoning: true,
      useResponsesApi: true,
      reasoningEffort: 'high',
      omitTemperature: true,
      omitTopP: true,
      omitTopK: true,
      omitFrequencyPenalty: true,
      omitPresencePenalty: true,
      omitReasoning: true,
      omitReasoningEffort: true,
      showNativeReasoning: false,
      receiveTimeoutMs: 0,
      sessionId: 'session',
      previousMessages: [],
      cacheControlTtl: '1h',
      cacheBreakpointMode: 'stable_prefix',
      sessionIdMode: 'always',
      promptPostProcessing: 'single',
      charName: 'char',
      userName: 'user',
      tools: [],
      toolChoice: 'none',
      responseJsonSchema: schema,
      useSystemInstruction: false,
    );
    final copy = request.withMessages(const [
      {'role': 'user', 'content': 'copy'},
    ]);
    expect(copy.savedConnectionId, 'known-id');
    expect(copy.maxTokens, 17);
    expect(copy.temperature, 0);
    expect(copy.topP, 1);
    expect(copy.topK, 9);
    expect(copy.frequencyPenalty, 0.2);
    expect(copy.presencePenalty, 0.3);
    expect(copy.stream, isFalse);
    expect(copy.useResponsesApi, isTrue);
    expect(copy.requestReasoning, isTrue);
    expect(copy.reasoningEffort, 'high');
    expect(copy.omitTemperature, isTrue);
    expect(copy.omitTopP, isTrue);
    expect(copy.omitTopK, isTrue);
    expect(copy.omitFrequencyPenalty, isTrue);
    expect(copy.omitPresencePenalty, isTrue);
    expect(copy.omitReasoning, isTrue);
    expect(copy.omitReasoningEffort, isTrue);
    expect(copy.showNativeReasoning, isFalse);
    expect(copy.receiveTimeoutMs, 0);
    expect(copy.sessionId, 'session');
    expect(copy.previousMessages, isEmpty);
    expect(copy.cacheControlTtl, '1h');
    expect(copy.cacheBreakpointMode, 'stable_prefix');
    expect(copy.sessionIdMode, 'always');
    expect(copy.promptPostProcessing, 'none');
    expect(copy.charName, 'char');
    expect(copy.userName, 'user');
    expect(copy.tools, isEmpty);
    expect(copy.toolChoice, 'none');
    expect(copy.responseJsonSchema, schema);
    expect(copy.useSystemInstruction, isFalse);
  });

  for (final purpose in [
    NativeProviderPurpose.studio,
    NativeProviderPurpose.memoryBooks,
  ]) {
    test(
      'separately entered $purpose credential can complete native text',
      () async {
        final h = NativeTransportHarness('openai');
        await h.store(purposes: {purpose});
        await h.run(input: h.request(purpose: purpose));
        expect(h.errors, isEmpty);
        expect(h.completions, hasLength(1));
        expect(h.wires, hasLength(1));
      },
    );
  }
}
