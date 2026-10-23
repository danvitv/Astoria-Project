import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_dump.dart';
import 'package:glaze_flutter/core/llm/transport/openai_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/openrouter_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/post_processing_chat_transport.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/core/llm/transport/transport_factory.dart';

import '_private_text_fixture.dart';

final class _CaptureSink implements LlmRequestCaptureSink {
  final events = <LlmRequestCaptureEvent>[];
  @override
  void record(LlmRequestCaptureEvent event) => events.add(event);
}

void main() {
  final routes = [
    (
      LlmProtocol.openai,
      'https://fixture.invalid/v1/chat/completions',
      'fixture-model',
      false,
    ),
    (
      LlmProtocol.customChatCompletion,
      'https://fixture.invalid/chat/completions',
      'fixture-model',
      false,
    ),
    (
      LlmProtocol.customChatCompletion,
      'https://fixture.invalid/responses',
      'fixture-model',
      true,
    ),
    (
      LlmProtocol.openaiResponses,
      'https://fixture.invalid/v1/responses',
      'fixture-model',
      false,
    ),
    (
      LlmProtocol.anthropic,
      'https://fixture.invalid/v1/messages',
      'claude-fixture',
      false,
    ),
    (
      LlmProtocol.gemini,
      'https://fixture.invalid/v1beta/models/gemini-2.5-flash:streamGenerateContent',
      'gemini-2.5-flash',
      false,
    ),
    (
      LlmProtocol.openrouter,
      OpenRouterChatTransport.baseUrl,
      'anthropic/claude-fixture',
      false,
    ),
  ];
  for (final route in routes) {
    test(
      'native wire and strict split UTF8: ${route.$1} ${route.$4}',
      () async {
        const text = 'Привет 🐈';
        final body = switch (route.$1) {
          LlmProtocol.anthropic => anthropicComplete(text),
          LlmProtocol.gemini => geminiText(text, finish: 'STOP'),
          _ when route.$1 == LlmProtocol.openaiResponses || route.$4 =>
            responsesComplete(text),
          _ => chatComplete(text),
        };
        final adapter = PrivateFixtureAdapter(body, oneByteChunks: true);
        final fixture = PrivateFixture([adapter]);
        final result = await fixture.run(
          protocol: route.$1,
          request: privateRequest(
            endpoint: route.$2,
            model: route.$3,
            responses: route.$4,
          ),
        );
        expect(result.status, PrivateTextStatus.complete);
        expect(result.text, text);
        expect(result.reason, PrivateTextReason.none);
        final options = adapter.options!;
        final wire = jsonDecode(adapter.upload!) as Map<String, dynamic>;
        expect(options.method, 'POST');
        expect(options.followRedirects, false);
        expect(options.maxRedirects, 0);
        expect(options.receiveDataWhenStatusError, false);
        expect(wire['stream'], route.$1 == LlmProtocol.gemini ? isNull : true);
        final serialized = jsonEncode(wire);
        expect(serialized, contains('SELECTED_CONTEXT_CANARY'));
        expect(serialized, contains('CURRENT_TEXT_CANARY'));
        for (final excluded in [
          'session_id',
          'cache_control',
          'tools',
          'response_format',
          'UNSELECTED_CANARY',
        ]) {
          expect(serialized, isNot(contains(excluded)));
        }
        expect(fixture.handoffs.single.recipient.toString(), route.$2);
        expect(fixture.handoffs.single.method, 'POST');
        expect(fixture.handoffs.single.attempt, 1);
        if (route.$1 == LlmProtocol.gemini) {
          expect(options.uri.path, Uri.parse(route.$2).path);
          expect(options.uri.queryParameters, {
            'key': 'fixture-credential',
            'alt': 'sse',
          });
          expect(options.headers['Authorization'], isNull);
          expect(wire['generationConfig']['temperature'], 0);
          expect(wire['generationConfig']['topP'], 1);
        } else if (route.$1 == LlmProtocol.anthropic) {
          expect(options.uri.toString(), route.$2);
          expect(options.headers['x-api-key'], 'fixture-credential');
          expect(options.headers['Authorization'], isNull);
          expect(wire['max_tokens'], greaterThan(0));
        } else {
          expect(options.uri.toString(), route.$2);
          expect(options.headers['Authorization'], 'Bearer fixture-credential');
          expect(wire['model'], route.$3);
          expect(wire['temperature'], 0);
          expect(wire['top_p'], 1);
          expect(
            wire[route.$1 == LlmProtocol.openaiResponses || route.$4
                ? 'max_output_tokens'
                : 'max_tokens'],
            64,
          );
          if (route.$1 == LlmProtocol.openrouter) {
            expect(
              options.headers['HTTP-Referer'],
              OpenRouterChatTransport.referer,
            );
            expect(options.headers['X-Title'], OpenRouterChatTransport.title);
          }
        }
        expect(adapter.closed, true);
        expect(result.toString(), isNot(contains(text)));
      },
    );
  }

  test(
    'whole-buffer redaction across deltas uses the CURRENT secret policy',
    () async {
      var redactor = SecretRedactor();
      final adapter = PrivateFixtureAdapter(
        '${chatDelta('before CANARY_')}${chatDelta('SECRET_93742 after')}${chatFinish()}data: [DONE]\n\n',
      );
      final fixture = PrivateFixture([adapter], redactor: () => redactor);
      final result = await fixture.run(
        activity: () {
          redactor = SecretRedactor(knownSecrets: ['CANARY_SECRET_93742']);
        },
      );
      expect(result.text, 'before [REDACTED] after');
      expect(result.status, PrivateTextStatus.complete);
    },
  );

  test('connection omit controls survive private mapping', () async {
    for (final route in routes) {
      final body = switch (route.$1) {
        LlmProtocol.anthropic => anthropicComplete('safe'),
        LlmProtocol.gemini => geminiText('safe', finish: 'STOP'),
        _ when route.$1 == LlmProtocol.openaiResponses || route.$4 =>
          responsesComplete('safe'),
        _ => chatComplete('safe'),
      };
      final adapter = PrivateFixtureAdapter(body);
      final result = await PrivateFixture([adapter]).run(
        protocol: route.$1,
        request: privateRequest(
          endpoint: route.$2,
          model: route.$3,
          responses: route.$4,
          omit: true,
        ),
      );
      expect(result.status, PrivateTextStatus.complete);
      final wire = jsonDecode(adapter.upload!) as Map<String, dynamic>;
      final sampling = route.$1 == LlmProtocol.gemini
          ? wire['generationConfig'] as Map
          : wire;
      expect(sampling.containsKey('temperature'), false);
      expect(
        sampling.containsKey(route.$1 == LlmProtocol.gemini ? 'topP' : 'top_p'),
        false,
      );
      for (final field in [
        'reasoning',
        'reasoning_effort',
        'thinking',
        'thinkingConfig',
      ]) {
        expect(sampling.containsKey(field), false);
      }
    }
  });

  test(
    'exhausted CURRENT sanitizer returns explicit limited without text',
    () async {
      var redactor = SecretRedactor();
      final result =
          await PrivateFixture([
            PrivateFixtureAdapter(chatComplete('safe')),
          ], redactor: () => redactor).run(
            activity: () {
              redactor = SecretRedactor(
                knownSecrets: List.generate(
                  257,
                  (index) => 'synthetic-secret-$index',
                ),
              );
            },
          );
      expect(result.status, PrivateTextStatus.limited);
      expect(result.reason, PrivateTextReason.sanitationLimit);
      expect(result.text, isEmpty);
    },
  );

  test(
    'all response canaries stay absent from public text and diagnostics',
    () async {
      final logs = <String?>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message);
      addTearDown(() => debugPrint = previousPrint);
      final content = frame({
        'choices': [
          {
            'index': 0,
            'delta': {
              'content': 'safe fixture-credential',
              'reasoning': 'REASONING_CANARY',
            },
            'finish_reason': 'stop',
          },
        ],
        'private': 'RAW_PROVIDER_CANARY',
      });
      final adapter = PrivateFixtureAdapter('${content}data: [DONE]\n\n');
      final result = await PrivateFixture([adapter]).run();
      expect(result.text, 'safe [REDACTED]');
      expect(logs.join(), isNot(contains('fixture-credential')));
      expect(logs.join(), isNot(contains('RAW_PROVIDER_CANARY')));
      expect(logs.join(), isNot(contains('REASONING_CANARY')));
    },
  );

  test(
    'private and simultaneous ordinary captures remain independent',
    () async {
      final previousSink = LlmRequestCapture.sink;
      final previousDump = LlmRequestDump.enabled;
      final sink = _CaptureSink();
      LlmRequestCapture.sink = sink;
      // No disk dumping. The production boundary never changes either global.
      LlmRequestDump.enabled = false;
      addTearDown(() {
        LlmRequestCapture.sink = previousSink;
        LlmRequestDump.enabled = previousDump;
      });
      final quiet = PrivateFixtureAdapter(chatDelta('private'), quiet: true);
      final token = CancelToken();
      final active = Completer<void>();
      final private = PrivateFixture([
        quiet,
      ]).run(cancelToken: token, activity: active.complete);
      await active.future;
      final ordinaryAdapter = PrivateFixtureAdapter(chatComplete('ordinary'));
      final ordinary = LoggingChatTransport(
        OpenAiChatTransport(dio: Dio()..httpClientAdapter = ordinaryAdapter),
      );
      await ordinary.stream(
        request: privateRequest(
          messages: const [
            {'role': 'user', 'content': 'ORDINARY_CAPTURE_CANARY'},
          ],
        ),
      );
      expect(LlmRequestCapture.sink, same(sink));
      expect(LlmRequestDump.enabled, false);
      expect(sink.events, hasLength(1));
      expect(
        jsonEncode(sink.events.single.request),
        contains('ORDINARY_CAPTURE_CANARY'),
      );
      expect(
        jsonEncode(sink.events.single.request),
        isNot(contains('CURRENT_TEXT_CANARY')),
      );
      expect(
        pickChatTransport(LlmProtocol.openai),
        isA<PostProcessingChatTransport>(),
      );
      token.cancel();
      expect((await private).status, PrivateTextStatus.stopped);
    },
  );
}
