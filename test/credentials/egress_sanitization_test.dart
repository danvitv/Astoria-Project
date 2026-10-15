import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

class _RecordingSink implements LlmRequestCaptureSink {
  final List<LlmRequestCaptureEvent> events = [];

  @override
  void record(LlmRequestCaptureEvent event) => events.add(event);
}

class _SerializerProbe {
  var stringCalls = 0;
  var jsonCalls = 0;

  @override
  String toString() {
    stringCalls++;
    return 'SERIALIZER_CANARY_SECRET_6754321';
  }

  Object toJson() {
    jsonCalls++;
    return {'secret': 'SERIALIZER_CANARY_SECRET_6754321'};
  }
}

class _FailingSink implements LlmRequestCaptureSink {
  _FailingSink({required this.asyncFailure});

  final bool asyncFailure;

  @override
  Future<void> record(LlmRequestCaptureEvent event) {
    final error = StateError('SINK_EXCEPTION_CANARY_SECRET_246810');
    if (asyncFailure) return Future<void>.error(error);
    throw error;
  }
}

ChatTransportRequest _requestWithContent(Object? content) =>
    ChatTransportRequest(
      endpoint: 'https://example.com/v1/chat/completions',
      apiKey: '',
      model: 'model',
      messages: [
        {'role': 'user', 'content': content},
      ],
      maxTokens: 64,
      temperature: 0.5,
      topP: 1,
    );

LlmCaptureContext _allContextFields(String suffix) => LlmCaptureContext(
  stage: 'main$suffix',
  sessionId: 'session-1$suffix',
  messageId: 'message-1$suffix',
  pipelineRunId: 'turn:session-1:7$suffix',
  callId: 'call:main:session-1:7$suffix',
  parentCallId: 'call:parent:session-1:7$suffix',
  logicalCallId: 'logical-1$suffix',
  relatedArtifactId: 'artifact-1$suffix',
  agentId: 'agent-1$suffix',
  stageOrdinal: 2,
  attempt: 3,
);

void main() {
  const canarySecret = 'CANARY_LLM_SECRET_9918273645';
  const openAiCanary = 'sk-proj-canary1234567890abcdef';
  const geminiCanary = 'AIzaSyCanaryKey1234567890abcdef12345';
  const hfCanary = 'hf_canaryToken1234567890abcdef';
  const bearerCanary = 'Bearer custom_bearer_secret_987654';
  const queryCanary = 'query_secret_value_554433';

  late SecretRedactor redactor;

  setUp(() {
    redactor = SecretRedactor(knownSecrets: const [canarySecret]);
    LlmRequestCapture.redactor = redactor;
    activeErrorRedactor = redactor;
  });

  tearDown(() {
    LlmRequestCapture.sink = null;
    LlmRequestCapture.redactor = null;
    activeErrorRedactor = null;
  });

  group('LlmRequestCapture.sanitizeRequest', () {
    for (final secretLength in [1100, 1500, 2200]) {
      for (final offset in [1016, 199990]) {
        test('long secret $secretLength at $offset never leaks a prefix', () {
          final secret = 'LONG_CANARY_${'q' * (secretLength - 12)}';
          LlmRequestCapture.redactor = SecretRedactor(knownSecrets: [secret]);
          final payload =
              '${'safe ' * (offset ~/ 5)}${'x' * (offset % 5)}'
              '$secret ${'tail ' * 600}';
          final sanitized = LlmRequestCapture.sanitizeRequest(
            _requestWithContent(payload),
          );
          final message = (sanitized.request['messages'] as List).single as Map;
          final content = message['content'];
          final preview = content is Map
              ? content['text'] as String
              : content as String;
          final serialized = jsonEncode(sanitized.request);

          // Only ten source characters fit before the 200000-char preview cut.
          expect(preview, isNot(contains(secret.substring(0, 8))));
          expect(preview, isNot(contains(secret.substring(0, 128))));
          expect(preview, isNot(contains('q' * 32)));
          expect(serialized, isNot(contains(secret.substring(0, 8))));
          expect(serialized, isNot(contains(secret)));
          expect(
            preview,
            anyOf(contains(SecretRedactor.removed), SecretRedactor.limited),
          );
          if (content is Map) {
            expect(
              content['sha256'],
              sha256.convert(utf8.encode(preview)).toString(),
            );
            expect(
              content['sha256'],
              isNot(sha256.convert(utf8.encode(payload)).toString()),
            );
          }
        });
      }

      test('data preview cuts never expose long secret $secretLength', () {
        final secret = 'LONG_CANARY_${'q' * (secretLength - 12)}';
        LlmRequestCapture.redactor = SecretRedactor(knownSecrets: [secret]);
        final payload = 'data:image/png;base64,${'x' * 65}$secret${'y' * 100}';
        final sanitized = LlmRequestCapture.sanitizeRequest(
          _requestWithContent(payload),
        );
        final message = (sanitized.request['messages'] as List).single as Map;
        final preview = message['content'] as Map;

        expect(preview['prefix'], isNot(contains(secret.substring(0, 8))));
        expect(
          preview['sha256'],
          sha256.convert(utf8.encode(preview['prefix'] as String)).toString(),
        );
        expect(
          preview['sha256'],
          isNot(sha256.convert(utf8.encode(payload)).toString()),
        );
      });
    }

    test('normal captures above small redactor budgets remain useful', () {
      final payload = 'useful ordinary prose ' * 12000;
      final sanitized = LlmRequestCapture.sanitizeRequest(
        _requestWithContent(payload),
      );
      final message = (sanitized.request['messages'] as List).single as Map;
      final preview = message['content'] as Map;

      expect(preview['text'], payload.substring(0, 200000));
      expect(
        preview['sha256'],
        sha256.convert(utf8.encode(payload.substring(0, 200000))).toString(),
      );
      expect(sanitized.truncated, isTrue);
    });

    test('uninspectable full payload fails closed before making a preview', () {
      final secret = 'LONG_CANARY_${'q' * 2200}';
      LlmRequestCapture.redactor = SecretRedactor(knownSecrets: [secret]);
      final payload = '${'safe ' * 39998}$secret ${'tail ' * 50000}';
      final sanitized = LlmRequestCapture.sanitizeRequest(
        _requestWithContent(payload),
      );
      final message = (sanitized.request['messages'] as List).single as Map;
      final preview = message['content'] as Map;

      expect(preview['text'], SecretRedactor.limited);
      expect(
        preview['sha256'],
        sha256.convert(utf8.encode(SecretRedactor.limited)).toString(),
      );
      expect(
        jsonEncode(sanitized.request),
        isNot(contains(secret.substring(0, 8))),
      );
    });

    test('default fast path removes a lone GitHub fine-grained PAT', () {
      LlmRequestCapture.redactor = null;
      const token = 'github_pat_1234567890abcdefghijklmnopqrstuvwxyz';
      final sanitized = LlmRequestCapture.sanitizeRequest(
        _requestWithContent('Leaked $token alone'),
      );

      final message = (sanitized.request['messages'] as List).single as Map;
      expect(message['content'], 'Leaked ${SecretRedactor.removed} alone');
      expect(jsonEncode(sanitized.request), isNot(contains(token)));
    });

    test('unknown value and map-key serializers are never invoked', () {
      final value = _SerializerProbe();
      final key = _SerializerProbe();
      final sanitized = LlmRequestCapture.sanitizeRequest(
        _requestWithContent([
          value,
          {key: 'unregistered-secret-key-value'},
        ]),
      );

      final message = (sanitized.request['messages'] as List).single as Map;
      expect(message['content'], [
        SecretRedactor.removed,
        SecretRedactor.removed,
      ]);
      expect(value.stringCalls + value.jsonCalls, 0);
      expect(key.stringCalls + key.jsonCalls, 0);
      expect(
        jsonEncode(sanitized.request),
        isNot(contains('SERIALIZER_CANARY')),
      );
    });

    test('oversized previews hash only their sanitized visible text', () {
      final payloads = [
        'data:image/png;base64,$canarySecret${'A' * 160}',
        'data:image/png;base64,${'A' * 160}',
        'Useful $canarySecret ${'safe prose ' * 21000}',
        // A secret outside the lookahead must not affect the preview digest.
        '${'safe prose ' * 21000}$canarySecret',
      ];
      for (final payload in payloads) {
        final sanitized = LlmRequestCapture.sanitizeRequest(
          _requestWithContent(payload),
        );
        final message = (sanitized.request['messages'] as List).single as Map;
        final content = message['content'] as Map;
        final preview = (content['prefix'] ?? content['text']) as String;
        final digest = content['sha256'];

        expect(digest, sha256.convert(utf8.encode(preview)).toString());
        expect(digest, isNot(sha256.convert(utf8.encode(payload)).toString()));
        expect(preview, isNot(contains(canarySecret)));
        expect(content['charCount'], payload.length);
        expect(sanitized.truncated, isTrue);
      }
    });

    test(
      'strips URL userinfo, query, and fragment from endpoint and scrubs canary secrets from messages',
      () {
        final request = ChatTransportRequest(
          endpoint:
              'https://user:$canarySecret@example.com:8443/v1/chat/completions?key=$geminiCanary&token=$openAiCanary#frag-$canarySecret',
          apiKey: canarySecret,
          model: 'gpt-4o-$canarySecret',
          sessionId: 'session-$canarySecret',
          toolChoice: 'tool-$openAiCanary',
          messages: [
            {
              'role': 'system',
              'content':
                  'System key=$canarySecret and token $openAiCanary and $geminiCanary',
            },
            {
              'role': 'user',
              'content': [
                {
                  'type': 'text',
                  'text':
                      'Header Authorization: $bearerCanary and url https://u:p@api.example.com/v1?key=$queryCanary#frag and relative /v1/models?key=$queryCanary',
                },
                {
                  'type': 'image_url',
                  'image_url': {
                    'url': 'data:image/png;base64,$canarySecret${'A' * 120}',
                  },
                },
              ],
            },
          ],
          maxTokens: 128,
          temperature: 0.7,
          topP: 1.0,
          captureContext: const LlmCaptureContext(
            stage: 'chat.main',
            sessionId: 'session-1',
          ),
        );

        final sanitized = LlmRequestCapture.sanitizeRequest(request);
        final serialized = jsonEncode(sanitized.request);

        expect(
          sanitized.request['protocolEndpoint'],
          'https://example.com:8443/v1/chat/completions',
        );
        expect(sanitized.truncated, isTrue);
        expect(serialized, isNot(contains(canarySecret)));
        expect(serialized, isNot(contains(openAiCanary)));
        expect(serialized, isNot(contains(geminiCanary)));
        expect(serialized, isNot(contains('custom_bearer_secret_987654')));
        expect(serialized, isNot(contains(queryCanary)));
        expect(serialized, isNot(contains('user:')));
        expect(serialized, isNot(contains('u:p@')));
        expect(serialized, isNot(contains('frag-')));
      },
    );

    test(
      'default fallback redactor scrubs token patterns and URL credentials when redactor is null',
      () {
        LlmRequestCapture.redactor = null;

        final request = ChatTransportRequest(
          endpoint:
              'https://admin:pass123@example.com/v1/chat?key=$geminiCanary#section',
          apiKey: openAiCanary,
          model: 'gemini-2.5-pro',
          messages: const [
            {
              'role': 'user',
              'content':
                  'Leaked $openAiCanary, $geminiCanary, $hfCanary, $bearerCanary, and ?key=$queryCanary',
            },
          ],
          maxTokens: 64,
          temperature: 0.5,
          topP: 1.0,
        );

        final sanitized = LlmRequestCapture.sanitizeRequest(request);
        final serialized = jsonEncode(sanitized.request);

        expect(
          sanitized.request['protocolEndpoint'],
          'https://example.com/v1/chat',
        );
        expect(serialized, isNot(contains('admin')));
        expect(serialized, isNot(contains('pass123')));
        expect(serialized, isNot(contains(openAiCanary)));
        expect(serialized, isNot(contains(geminiCanary)));
        expect(serialized, isNot(contains(hfCanary)));
        expect(serialized, isNot(contains('custom_bearer_secret_987654')));
        expect(serialized, isNot(contains(queryCanary)));
      },
    );

    test(
      'scrubs canary secrets inside large and truncated messages across chunk and truncation boundaries',
      () {
        final largeContent =
            '${'a' * 1016}$canarySecret ${'b ' * 3580}$openAiCanary ${'c ' * 96000}$canarySecret ${'d ' * 500}';
        final request = ChatTransportRequest(
          endpoint: 'https://example.com/v1/chat',
          apiKey: canarySecret,
          model: 'gpt-4o',
          messages: [
            {'role': 'user', 'content': largeContent},
          ],
          maxTokens: 64,
          temperature: 0.5,
          topP: 1.0,
        );

        final sanitized = LlmRequestCapture.sanitizeRequest(request);
        final serialized = jsonEncode(sanitized.request);

        expect(sanitized.truncated, isTrue);
        expect(serialized, isNot(contains(canarySecret)));
        expect(serialized, isNot(contains('CANARY_LLM')));
        expect(serialized, isNot(contains(openAiCanary)));
      },
    );
  });

  group('LlmRequestCapture context projection', () {
    test('long context secrets use the same whole-text snapshot', () {
      final secret = 'LONG_CANARY_${'q' * 2188}';
      LlmRequestCapture.redactor = SecretRedactor(knownSecrets: [secret]);
      final sink = _RecordingSink();
      LlmRequestCapture.sink = sink;
      final suffix = '${' safe' * 203} $secret';
      LlmRequestCapture.recordAuxiliary(
        stage: 'embedding$suffix',
        endpoint: 'https://example.com/v1/embeddings',
        model: 'model',
        context: _allContextFields(suffix),
      );

      final event = sink.events.single;
      final expectedSuffix = suffix.replaceAll(secret, SecretRedactor.removed);
      expect(
        event.context!.toJson(),
        _allContextFields(expectedSuffix).toJson(),
      );
      expect(event.protocol, 'embedding$expectedSuffix');
      expect(
        jsonEncode(event.toJson()),
        isNot(contains(secret.substring(0, 8))),
      );
      expect(jsonEncode(event.toJson()), isNot(contains('q' * 32)));
      // A completed snapshot must not reopen raw metadata after policy rotation.
      LlmRequestCapture.redactor = null;
      expect(
        event.context!.toJson(),
        _allContextFields(expectedSuffix).toJson(),
      );
    });

    for (final suffix in ['', '-$canarySecret']) {
      test(
        'build and auxiliary preserve only safe explicit context (suffix=$suffix)',
        () {
          final context = _allContextFields(suffix);
          final expected = _allContextFields(
            suffix.replaceAll(canarySecret, SecretRedactor.removed),
          ).toJson();
          final protocol = 'openai$suffix';
          final built = LlmRequestCapture.build(
            ChatTransportRequest(
              endpoint: 'https://example.com/v1/chat',
              apiKey: '',
              model: 'model',
              messages: const [],
              maxTokens: 1,
              temperature: 0,
              topP: 1,
              captureContext: context,
            ),
            protocol: protocol,
          );

          expect(built.context!.toJson(), expected);
          expect(built.context!.withAttempt(4).toJson(), {
            ...expected,
            'attempt': 4,
          });
          expect(
            built.protocol,
            protocol.replaceAll(canarySecret, SecretRedactor.removed),
          );
          expect(jsonEncode(built.toJson()), isNot(contains(canarySecret)));

          final sink = _RecordingSink();
          LlmRequestCapture.sink = sink;
          LlmRequestCapture.recordAuxiliary(
            stage: protocol,
            endpoint: 'https://example.com/v1/embeddings',
            model: 'model',
            context: context,
          );
          expect(sink.events.single.context!.toJson(), expected);
          expect(sink.events.single.protocol, built.protocol);
          expect(
            jsonEncode(sink.events.single.toJson()),
            isNot(contains(canarySecret)),
          );
        },
      );
    }

    test('auxiliary derived context is scrubbed before dispatch', () {
      final sink = _RecordingSink();
      LlmRequestCapture.sink = sink;
      LlmRequestCapture.recordAuxiliary(
        stage: 'embedding-$canarySecret',
        endpoint: 'https://example.com/v1/embeddings',
        model: 'model',
        sessionId: 'session-$canarySecret',
        messageId: 'message-$canarySecret',
        pipelineRunId: 'turn-$canarySecret',
        agentId: 'agent-$canarySecret',
      );

      expect(sink.events.single.context!.toJson(), {
        'stage': 'embedding-${SecretRedactor.removed}',
        'sessionId': 'session-${SecretRedactor.removed}',
        'messageId': 'message-${SecretRedactor.removed}',
        'pipelineRunId': 'turn-${SecretRedactor.removed}',
        'agentId': 'agent-${SecretRedactor.removed}',
      });
      expect(
        jsonEncode(sink.events.single.toJson()),
        isNot(contains(canarySecret)),
      );
    });

    test(
      'externally constructed event dispatch projects protocol and context',
      () {
        final sink = _RecordingSink();
        LlmRequestCapture.sink = sink;
        final event = LlmRequestCaptureEvent(
          sequence: 77,
          createdAt: DateTime.utc(2026),
          protocol: 'openai-$canarySecret',
          context: _allContextFields('-$canarySecret'),
          request: const {'model': 'ordinary-model'},
          truncated: false,
        );
        LlmRequestCapture.dispatch(event);

        final projected = sink.events.single;
        expect(
          projected.context!.toJson(),
          _allContextFields('-${SecretRedactor.removed}').toJson(),
        );
        expect(projected.protocol, 'openai-${SecretRedactor.removed}');
        expect(projected.request, event.request);
        expect(projected.sequence, event.sequence);
        expect(projected.createdAt, event.createdAt);
        expect(jsonEncode(projected.toJson()), isNot(contains(canarySecret)));
        // Projection must not mutate the caller's object.
        expect(event.protocol, 'openai-$canarySecret');
      },
    );
  });

  group('LlmRequestCapture.recordAuxiliary', () {
    test('map limits preserve field-safe diagnostics without raw fallback', () {
      // A whole-map pass exceeds both its node and aggregate output budgets.
      LlmRequestCapture.redactor = SecretRedactor(
        knownSecrets: const [canarySecret],
        maxNodes: 16,
        maxOutputLength: 4096,
      );
      final sink = _RecordingSink();
      LlmRequestCapture.sink = sink;
      LlmRequestCapture.recordAuxiliary(
        stage: 'image.generate',
        endpoint: 'https://image.example.com/v1/images',
        model: 'flux',
        params: {
          'apiType': 'openai',
          'referenceCount': 2,
          'callbackUrl':
              '//user:unregistered-password@example.com/hook#private',
          'notes': 'Contains $canarySecret',
          'preview': 'data:image/png;base64,${'A' * 160}',
          for (var i = 0; i < 20; i++) 'safe_$i': 'useful prose ' * 400,
        },
      );

      final event = sink.events.single;
      expect(event.request['apiType'], 'openai');
      expect(event.request['referenceCount'], 2);
      expect(event.request['callbackUrl'], SecretRedactor.removed);
      expect(event.request['notes'], 'Contains ${SecretRedactor.removed}');
      expect(event.request['safe_19'], 'useful prose ' * 400);
      final preview = event.request['preview'] as Map;
      expect(preview['kind'], 'redacted_data_uri');
      expect(preview['sha256'], isA<String>());
      expect(
        jsonEncode(event.toJson()),
        isNot(contains('unregistered-password')),
      );
      expect(jsonEncode(event.toJson()), isNot(contains(canarySecret)));
    });

    test('closed redactor never returns raw auxiliary params', () {
      LlmRequestCapture.redactor = SecretRedactor(
        knownSecrets: List.filled(257, canarySecret),
      );
      final sink = _RecordingSink();
      LlmRequestCapture.sink = sink;
      LlmRequestCapture.recordAuxiliary(
        stage: 'embedding',
        endpoint: 'https://example.com/v1/embeddings',
        model: 'model',
        params: const {'notes': canarySecret},
      );

      expect(
        jsonEncode(sink.events.single.toJson()),
        isNot(contains(canarySecret)),
      );
    });

    test('cycles and excessive capture trees fail closed', () {
      final cycle = <String, dynamic>{};
      cycle['self'] = cycle;
      Object deep = canarySecret;
      for (var i = 0; i < 40; i++) {
        deep = {'child': deep};
      }
      final sink = _RecordingSink();
      LlmRequestCapture.sink = sink;
      LlmRequestCapture.recordAuxiliary(
        stage: 'embedding',
        endpoint: 'https://example.com/v1/embeddings',
        model: 'model',
        params: {
          'cycle': cycle,
          'deep': deep,
          'tooMany': List.filled(5000, canarySecret),
        },
      );

      final event = sink.events.single;
      expect(event.truncated, isTrue);
      expect(jsonEncode(event.toJson()), contains(SecretRedactor.limited));
      expect(jsonEncode(event.toJson()), isNot(contains(canarySecret)));
    });

    test(
      'sanitizes params for both secret-named keys and registered canary values inside nested maps and lists',
      () {
        final sink = _RecordingSink();
        LlmRequestCapture.sink = sink;

        LlmRequestCapture.recordAuxiliary(
          stage: 'image.generate',
          endpoint:
              'https://user:$canarySecret@image.example.com/v1/images?key=$geminiCanary#frag',
          model: 'flux-$canarySecret',
          messages: [
            {
              'role': 'prompt',
              'content':
                  'Draw with $canarySecret and $openAiCanary and ?key=$queryCanary',
            },
          ],
          params: {
            'apiKey': 'unregistered-raw-api-key-value',
            'authorization': 'Bearer unregistered-raw-auth-header',
            'apiType': 'openai',
            'referenceCount': 2,
            'nestedConfig': {
              'api_key': 'nested-unregistered-key',
              'accessToken': 'nested-unregistered-access-token',
              'password': 'nested-unregistered-password',
              'callbackUrl':
                  'https://u:p@callback.example.com/hook?token=$canarySecret#frag',
              'notes': 'Contains $canarySecret and $geminiCanary',
              'items': [
                canarySecret,
                openAiCanary,
                {'secret': 'deep-unregistered-secret'},
                {'description': 'Url ?key=$queryCanary and $bearerCanary'},
              ],
            },
          },
        );

        expect(sink.events, hasLength(1));
        final eventJson = sink.events.single.toJson();
        final serialized = jsonEncode(eventJson);

        expect(
          eventJson['protocolEndpoint'],
          'https://image.example.com/v1/images',
        );
        expect(eventJson['apiKey'], SecretRedactor.removed);
        expect(eventJson['authorization'], SecretRedactor.removed);
        expect(eventJson['apiType'], 'openai');
        expect(eventJson['referenceCount'], 2);

        final nested = eventJson['nestedConfig'] as Map<String, dynamic>;
        expect(nested['api_key'], SecretRedactor.removed);
        expect(nested['accessToken'], SecretRedactor.removed);
        expect(nested['password'], SecretRedactor.removed);
        expect(nested['callbackUrl'], 'https://callback.example.com/hook');

        expect(serialized, isNot(contains(canarySecret)));
        expect(serialized, isNot(contains(openAiCanary)));
        expect(serialized, isNot(contains(geminiCanary)));
        expect(serialized, isNot(contains(queryCanary)));
        expect(serialized, isNot(contains('custom_bearer_secret_987654')));
        expect(serialized, isNot(contains('unregistered-raw-api-key-value')));
        expect(serialized, isNot(contains('unregistered-raw-auth-header')));
        expect(serialized, isNot(contains('nested-unregistered-key')));
        expect(serialized, isNot(contains('nested-unregistered-access-token')));
        expect(serialized, isNot(contains('nested-unregistered-password')));
        expect(serialized, isNot(contains('deep-unregistered-secret')));
      },
    );
  });

  for (final asyncFailure in [false, true]) {
    test('sink exception never egresses (async=$asyncFailure)', () async {
      final output = <String>[];
      final previousDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) output.add(message);
      };
      try {
        LlmRequestCapture.sink = _FailingSink(asyncFailure: asyncFailure);
        LlmRequestCapture.dispatch(
          LlmRequestCapture.build(_requestWithContent('hello')),
        );
        await Future<void>.delayed(Duration.zero);

        expect(output, hasLength(1));
        expect(output.single, contains('sink failed'));
        expect(output.single, isNot(contains('SINK_EXCEPTION_CANARY')));
      } finally {
        debugPrint = previousDebugPrint;
      }
    });
  }

  group('formatError egress sanitization', () {
    DioException httpError(int status, dynamic body, {String? location}) {
      final options = RequestOptions(path: '/v1/chat/completions');
      return DioException.badResponse(
        statusCode: status,
        requestOptions: options,
        response: Response<dynamic>(
          requestOptions: options,
          statusCode: status,
          data: body,
          headers: Headers.fromMap({
            if (location != null) 'location': [location],
          }),
        ),
      );
    }

    void expectNoSecretParts(String text, String secret) {
      expect(text.contains(secret.substring(0, 8)), isFalse);
      expect(text.contains(secret.substring(0, 128)), isFalse);
      expect(text.contains('q' * 32), isFalse);
      expect(text.contains(secret), isFalse);
      expect(text.contains(sha256.convert(utf8.encode(secret)).toString()), isFalse);
    }

    for (final secretLength in [1100, 1500, 2200]) {
      for (final outputBudget in [8192, 4096]) {
        for (final offset in [0, 290]) {
          test('provider long secret $secretLength at $offset budget $outputBudget is scrubbed before display cut', () {
            final secret = 'LONG_CANARY_${'q' * (secretLength - 12)}';
            activeErrorRedactor = SecretRedactor(
              knownSecrets: [secret],
              maxOutputLength: outputBudget,
            );
            const lead = 'Provider rejected request ';
            final prefix = offset == 0 ? '' : '$lead${'x' * (offset - lead.length)}';
            final raw = '$prefix$secret Model unavailable ${'diagnostic ' * 1000}';
            // All accepted provider shapes must pass through the safe cut.
            final inputs = [
              {'error': {'message': raw}},
              jsonEncode({'detail': raw}),
              raw,
            ];
            for (final input in inputs) {
              final formatted = formatError(httpError(400, input));
              final body = formatted.split('\n').last;
              expectNoSecretParts(formatted, secret);
              expect(formatted.contains(sha256.convert(utf8.encode(raw)).toString()), isFalse);
              expect(body.length, lessThanOrEqualTo(301));
              expect(body.endsWith('…'), isTrue);
              expect(body.contains(SecretRedactor.limited), isFalse);
              expect(body.startsWith(offset == 0 ? SecretRedactor.removed : lead), isTrue);
              if (offset == 0) expect(body.contains('Model unavailable'), isTrue);
            }
          });

          test('generic long secret $secretLength at $offset budget $outputBudget is scrubbed before fallback', () {
            final secret = 'LONG_CANARY_${'q' * (secretLength - 12)}';
            activeErrorRedactor = SecretRedactor(
              knownSecrets: [secret],
              maxOutputLength: outputBudget,
            );
            const lead = 'Provider rejected request ';
            final prefix = offset == 0 ? '' : '$lead${'x' * (offset - lead.length)}';
            final raw = '$prefix$secret Model unavailable ${'diagnostic ' * 1000}';
            final inputs = <Object>[
              StateError(raw),
              DioException(
                requestOptions: RequestOptions(path: '/v1/chat'),
                type: DioExceptionType.unknown,
                message: raw,
              ),
            ];
            for (final input in inputs) {
              final formatted = formatError(input);
              expectNoSecretParts(formatted, secret);
              expect(formatted.contains(sha256.convert(utf8.encode(raw)).toString()), isFalse);
              expect(formatted.length, lessThanOrEqualTo(301));
              expect(formatted.endsWith('…'), isTrue);
              expect(formatted.contains(SecretRedactor.limited), isFalse);
              expect(formatted.contains(offset == 0 ? SecretRedactor.removed : lead), isTrue);
              if (offset == 0) expect(formatted.contains('Model unavailable'), isTrue);
            }
          });
        }
      }
    }

    test('oversized error inputs fail closed without partial inspection', () {
      final secret = 'LONG_CANARY_${'q' * 2188}';
      activeErrorRedactor = SecretRedactor(knownSecrets: [secret]);
      final raw = 'Useful lead $secret ${'diagnostic ' * 40000}';
      final inputs = <Object>[
        httpError(400, {'message': raw}),
        httpError(400, jsonEncode({'message': raw})),
        httpError(400, raw),
        StateError(raw),
        DioException(requestOptions: RequestOptions(path: '/v1/chat'), message: raw),
      ];
      for (final input in inputs) {
        final formatted = formatError(input);
        expectNoSecretParts(formatted, secret);
        expect(formatted.contains(SecretRedactor.limited), isTrue);
        expect(formatted.length, lessThanOrEqualTo(350));
      }
    });

    test('closed error policy stays closed after inspection budget extension', () {
      activeErrorRedactor = SecretRedactor(
        knownSecrets: List.filled(257, canarySecret),
      );
      expect(formatError(httpError(400, {'message': 'Useful $canarySecret'})), SecretRedactor.limited);
      expect(formatError(StateError('Useful $canarySecret')), SecretRedactor.limited);
    });

    test('ordinary long error prose remains useful and generics stay bounded', () {
      for (final outputBudget in [8192, 4096]) {
        activeErrorRedactor = SecretRedactor(
          knownSecrets: const [canarySecret],
          maxOutputLength: outputBudget,
        );
        final raw = 'Model unavailable ${'ordinary diagnostic ' * 12000}';
        for (final input in <Object>[httpError(400, raw), StateError(raw)]) {
          final formatted = formatError(input);
          expect(formatted.contains('Model unavailable'), isTrue);
          expect(formatted.contains(SecretRedactor.limited), isFalse);
          expect(formatted.length, lessThanOrEqualTo(350));
          expect(formatted.endsWith('…'), isTrue);
        }
        // Safe, short generic diagnostics should not be clamped to HTTP's 300.
        final medium = 'ordinary ' * 50;
        expect(formatError(medium), medium);
      }
    });

    test(
      'long errors with a short known secret remain useful at tight budgets',
      () {
        const shortSecret = 'pw42';
        for (final outputBudget in [8192, 4096]) {
          activeErrorRedactor = SecretRedactor(
            knownSecrets: const [shortSecret],
            maxInputLength: 8192,
            maxOutputLength: outputBudget,
          );
          final formatted = formatError(
            httpError(400, {
              'message':
                  'Model unavailable for $shortSecret ${'diagnostic ' * 1000}',
            }),
          );
          final body = formatted.split('\n').last;
          expect(
            body,
            startsWith('Model unavailable for ${SecretRedactor.removed}'),
          );
          expect(body, endsWith('…'));
          expect(body.length, inInclusiveRange(290, 301));
          expect(body, isNot(contains(shortSecret)));
          expect(body, isNot(contains(SecretRedactor.limited)));
        }
      },
    );

    test(
      'scrubs canary secrets, Bearer tokens, and query-key parameters from 4xx/5xx provider JSON and prose error bodies',
      () {
        final jsonMapError = httpError(401, {
          'error': {
            'message':
                'Incorrect API key provided: $openAiCanary for $canarySecret ($geminiCanary) with $bearerCanary at https://api.example.com/v1?key=$queryCanary',
          },
        });
        final formattedJsonMap = formatError(jsonMapError);
        expect(formattedJsonMap, isNot(contains(openAiCanary)));
        expect(formattedJsonMap, isNot(contains(canarySecret)));
        expect(formattedJsonMap, isNot(contains(geminiCanary)));
        expect(
          formattedJsonMap,
          isNot(contains('custom_bearer_secret_987654')),
        );
        expect(formattedJsonMap, isNot(contains(queryCanary)));
        expect(formattedJsonMap, contains(SecretRedactor.removed));

        final jsonTextError = httpError(
          500,
          jsonEncode({
            'detail':
                'Upstream failure for $canarySecret on /v1beta/models/gemini:streamGenerateContent?key=$queryCanary&alt=sse',
          }),
        );
        final formattedJsonText = formatError(jsonTextError);
        expect(formattedJsonText, isNot(contains(canarySecret)));
        expect(formattedJsonText, isNot(contains(queryCanary)));

        final proseError = httpError(
          502,
          'Gateway rejected Authorization: $bearerCanary, token=$openAiCanary, key=$geminiCanary, canary=$canarySecret, path=/v1/chat?api_key=$queryCanary',
        );
        final formattedProse = formatError(proseError);
        expect(formattedProse, isNot(contains(canarySecret)));
        expect(formattedProse, isNot(contains(openAiCanary)));
        expect(formattedProse, isNot(contains(geminiCanary)));
        expect(formattedProse, isNot(contains('custom_bearer_secret_987654')));
        expect(formattedProse, isNot(contains(queryCanary)));
      },
    );

    test(
      'scrubs secrets straddling the 300-character provider message clamp boundary',
      () {
        final padding = 'x' * 290;
        final boundaryError = httpError(400, {
          'message': '$padding $canarySecret trailing text',
        });

        final formatted = formatError(boundaryError);
        expect(formatted, isNot(contains(canarySecret)));
        expect(formatted, isNot(contains('CANARY_LLM')));
      },
    );

    test(
      'scrubs canary secrets, Bearer tokens, and query-key parameters from non-HTTP DioException messages and generic errors',
      () {
        final networkErr = DioException(
          requestOptions: RequestOptions(path: '/v1/chat'),
          type: DioExceptionType.unknown,
          message:
              'SocketException connecting to https://user:$canarySecret@api.example.com/v1?key=$geminiCanary with $bearerCanary and $openAiCanary and ?token=$queryCanary',
        );

        final formattedNetwork = formatError(networkErr);
        expect(formattedNetwork, isNot(contains(canarySecret)));
        expect(formattedNetwork, isNot(contains(geminiCanary)));
        expect(formattedNetwork, isNot(contains(openAiCanary)));
        expect(
          formattedNetwork,
          isNot(contains('custom_bearer_secret_987654')),
        );
        expect(formattedNetwork, isNot(contains(queryCanary)));
        expect(formattedNetwork, isNot(contains('user:')));
        expect(formattedNetwork, contains('https://api.example.com/v1'));

        final genericErr = StateError(
          'Failed with $canarySecret, $openAiCanary, $geminiCanary, $bearerCanary, ?key=$queryCanary',
        );
        final formattedGeneric = formatError(genericErr);
        expect(formattedGeneric, isNot(contains(canarySecret)));
        expect(formattedGeneric, isNot(contains(openAiCanary)));
        expect(formattedGeneric, isNot(contains(geminiCanary)));
        expect(
          formattedGeneric,
          isNot(contains('custom_bearer_secret_987654')),
        );
        expect(formattedGeneric, isNot(contains(queryCanary)));
      },
    );

    test(
      'scrubs userinfo, query parameters, fragments, and canary secrets from 301/302/307/308 redirect Location headers',
      () {
        for (final code in const [301, 302, 307, 308]) {
          final redirectErr = httpError(
            code,
            null,
            location:
                'https://user:$canarySecret@llm.example.com/v1/chat/completions?key=$geminiCanary&token=$openAiCanary&api_key=$queryCanary#frag-$canarySecret',
          );

          final formatted = formatError(redirectErr);
          expect(formatted, contains('HTTP $code'));
          expect(
            formatted,
            contains('→ https://llm.example.com/v1/chat/completions'),
          );
          expect(formatted, isNot(contains(canarySecret)));
          expect(formatted, isNot(contains(geminiCanary)));
          expect(formatted, isNot(contains(openAiCanary)));
          expect(formatted, isNot(contains(queryCanary)));
          expect(formatted, isNot(contains('user:')));
          expect(formatted, isNot(contains('frag-')));

          final relativeRedirectErr = httpError(
            code,
            null,
            location:
                '/v1/chat/completions?key=$geminiCanary&token=$queryCanary#frag-$canarySecret',
          );
          final formattedRelative = formatError(relativeRedirectErr);
          expect(formattedRelative, contains('→ /v1/chat/completions'));
          expect(formattedRelative, isNot(contains(canarySecret)));
          expect(formattedRelative, isNot(contains(geminiCanary)));
          expect(formattedRelative, isNot(contains(queryCanary)));
          expect(formattedRelative, isNot(contains('frag-')));
        }
      },
    );
  });
}
