import 'dart:convert';
import 'dart:async';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/image_gen/services/naistera_image_provider.dart';
import 'package:glaze_flutter/features/image_gen/services/image_gen_http.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

class _NaisteraAdapter implements HttpClientAdapter {
  _NaisteraAdapter(this.reply);
  final FutureOr<ResponseBody> Function(RequestOptions) reply;
  final requests = <RequestOptions>[];
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) async {
    requests.add(options);
    return reply(options);
  }

  @override
  void close({bool force = false}) {}
}

void main() {
  /// Same canned protocol fixture, now injected: no socket or external backend.
  Future<
    ({
      String baseUrl,
      ImageGenHttp http,
      List<({String method, String path, Map<String, dynamic>? body})> requests,
    })
  >
  startServer(List<Map<String, dynamic>> responses) async {
    final requests =
        <({String method, String path, Map<String, dynamic>? body})>[];
    var index = 0;
    final adapter = _NaisteraAdapter((request) {
      requests.add((
        method: request.method,
        path: request.uri.path,
        body: request.data is Map
            ? Map<String, dynamic>.from(request.data as Map)
            : null,
      ));
      final response = responses[index.clamp(0, responses.length - 1)];
      index++;
      return ResponseBody.fromString(
        jsonEncode(response),
        200,
        headers: {
          Headers.contentTypeHeader: ['application/json'],
        },
      );
    });
    final dio = Dio()..httpClientAdapter = adapter;
    addTearDown(() => dio.close());
    return (
      baseUrl: 'https://synthetic-naistera.invalid',
      http: ImageGenHttp(dio: dio),
      requests: requests,
    );
  }

  group('NaisteraImageProvider', () {
    test('posts to /api/generate and decodes data_url', () async {
      final server = await startServer([
        {'data_url': 'data:image/png;base64,AQI=', 'content_type': 'image/png'},
      ]);

      final bytes =
          await NaisteraImageProvider(
            baseUrl: server.baseUrl,
            http: server.http,
          ).generate(
            apiKey: 'key',
            model: 'grok',
            prompt: 'a cat',
            aspectRatio: '16:9',
          );

      expect(bytes, [1, 2]);
      expect(server.requests.single.method, 'POST');
      expect(server.requests.single.path, '/api/generate');
      expect(server.requests.single.body, {
        'prompt': 'a cat',
        'aspect_ratio': '16:9',
        'model': 'grok',
      });
    });

    for (final location in [
      'prompt',
      'reference description',
      'reference key',
    ]) {
      test('raw quote-JSON $location is denied before POST encoding', () async {
        const alias = 'SYNTHETIC_PRIVATE"VALUE';
        final carried = jsonEncode({'label': alias});
        final previous = activeErrorRedactor;
        final policy = SecretRedactor(knownSecrets: const [alias]);
        activeErrorRedactor = policy;
        addTearDown(() => activeErrorRedactor = previous);
        // The original bug: one encoded alias matches the carried string, but
        // encoding the enclosing document adds an escaping layer and hides it.
        expect(policy.isKnownSecretFree(carried), isFalse);
        expect(
          policy.isKnownSecretFree(jsonEncode({'prompt': carried})),
          isTrue,
        );
        final server = await startServer([
          {'data_url': 'data:image/png;base64,AQI='},
        ]);
        await expectLater(
          NaisteraImageProvider(
            baseUrl: server.baseUrl,
            http: server.http,
            assetHttp: server.http,
          ).generate(
            apiKey: 'SYNTHETIC_ACCOUNT',
            model: 'grok',
            prompt: location == 'prompt' ? carried : 'public cat',
            aspectRatio: '1:1',
            references: location == 'prompt'
                ? null
                : [
                    {
                      'image': 'AQI=',
                      'description': location == 'reference description'
                          ? carried
                          : 'public',
                      if (location == 'reference key') carried: 'public',
                    },
                  ],
          ),
          throwsA(
            isA<StateError>().having(
              (error) => error.toString(),
              'safe detail',
              isNot(contains('SYNTHETIC_PRIVATE')),
            ),
          ),
        );
        expect(server.requests, isEmpty);
      });
    }

    test('raw JSON unknown receipt metadata denies image completion', () async {
      const alias = 'SYNTHETIC_PRIVATE"RECEIPT';
      final previous = activeErrorRedactor;
      activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
      addTearDown(() => activeErrorRedactor = previous);
      final server = await startServer([
        {
          'data_url': 'data:image/png;base64,AQI=',
          'futurePrivateMetadata': jsonEncode({'label': alias}),
        },
      ]);
      await expectLater(
        NaisteraImageProvider(
          baseUrl: server.baseUrl,
          http: server.http,
          assetHttp: server.http,
        ).generate(
          apiKey: 'SYNTHETIC_ACCOUNT',
          model: 'grok',
          prompt: 'public cat',
          aspectRatio: '1:1',
        ),
        throwsA(isA<StateError>()),
      );
      expect(server.requests, hasLength(1));
    });

    test(
      'CURRENT policy still guards original POST receipt after a public poll',
      () async {
        const alias = 'SYNTHETIC_PRIVATE"ORIGINAL_RECEIPT';
        final previous = activeErrorRedactor;
        activeErrorRedactor = SecretRedactor();
        addTearDown(() => activeErrorRedactor = previous);
        final adapter = _NaisteraAdapter((request) {
          if (request.method == 'GET') {
            activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
          }
          return ResponseBody.fromString(
            jsonEncode(
              request.method == 'POST'
                  ? {
                      'job_id': 'public-job',
                      'futurePrivateMetadata': jsonEncode({'label': alias}),
                    }
                  : {
                      'status': 'completed',
                      'data_url': 'data:image/png;base64,AQI=',
                    },
            ),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });
        final dio = Dio()..httpClientAdapter = adapter;
        addTearDown(() => dio.close());
        await expectLater(
          NaisteraImageProvider(
            http: ImageGenHttp(dio: dio),
            assetHttp: ImageGenHttp(dio: dio),
            pollInterval: Duration.zero,
          ).generate(
            apiKey: 'SYNTHETIC_ACCOUNT',
            model: 'grok',
            prompt: 'public cat',
            aspectRatio: '1:1',
          ),
          throwsA(isA<StateError>()),
        );
        expect(adapter.requests.map((request) => request.method), [
          'POST',
          'GET',
        ]);
      },
    );

    test(
      'native JSON guard retains whole aliases and has finite admission',
      () {
        final tree = {'left': 'public left', 'right': 'public right'};
        final policy = SecretRedactor(knownSecrets: [jsonEncode(tree)]);
        expect(policy.isKnownSecretFree('public left'), isTrue);
        expect(policy.isKnownSecretFree('public right'), isTrue);
        expect(
          NaisteraImageProvider.nativeJsonIsPublic(
            tree,
            policy.isKnownSecretFree,
          ),
          isFalse,
        );
        final cycle = <Object?>[];
        cycle.add(cycle);
        Object? deep = 'public';
        for (var i = 0; i < 65; i++) {
          deep = [deep];
        }
        for (final denied in [
          cycle,
          deep,
          List.filled(8192, 0),
          {1: 'public'},
          Object(),
          double.infinity,
        ]) {
          expect(
            NaisteraImageProvider.nativeJsonIsPublic(denied, (_) => true),
            isFalse,
          );
        }
        expect(
          NaisteraImageProvider.nativeJsonIsPublic(
            List.filled(8191, 0),
            (_) => true,
          ),
          isTrue,
        );
        expect(
          NaisteraImageProvider.nativeJsonIsPublic({
            'public': [null, true, 1, 'text'],
          }, (_) => true),
          isTrue,
        );
      },
    );

    test('sends references as data URLs in reference_objects', () async {
      final server = await startServer([
        {'data_url': 'data:image/png;base64,AQI='},
      ]);

      await NaisteraImageProvider(
        baseUrl: server.baseUrl,
        http: server.http,
      ).generate(
        apiKey: 'key',
        model: 'nano banana 2',
        prompt: 'a cat',
        aspectRatio: '1:1',
        references: [
          {
            'name': 'Mia',
            'image': 'AQI=',
            'mime': 'image/jpeg',
            'description': 'Mia',
            'source': 'char',
          },
          {
            'name': 'ctx',
            'image': 'data:image/png;base64,AQI=',
            'mime': 'image/png',
            'description': '',
            'source': 'context',
          },
        ],
      );

      expect(server.requests.single.body!['reference_objects'], [
        {'image': 'data:image/jpeg;base64,AQI=', 'description': 'Mia'},
        {'image': 'data:image/png;base64,AQI=', 'description': ''},
      ]);
    });

    test(
      'drops references when the caller says the model takes none',
      () async {
        final server = await startServer([
          {'data_url': 'data:image/png;base64,AQI='},
        ]);

        await NaisteraImageProvider(
          baseUrl: server.baseUrl,
          http: server.http,
        ).generate(
          apiKey: 'key',
          model: 'novelai',
          prompt: 'a cat',
          aspectRatio: '1:1',
          supportsReferences: false,
          references: [
            {'image': 'AQI=', 'mime': 'image/png', 'description': 'Mia'},
          ],
        );

        expect(
          server.requests.single.body!.containsKey('reference_objects'),
          isFalse,
        );
      },
    );

    test('normalizes a retired model label', () async {
      final server = await startServer([
        {'data_url': 'data:image/png;base64,AQI='},
      ]);

      await NaisteraImageProvider(
        baseUrl: server.baseUrl,
        http: server.http,
      ).generate(
        apiKey: 'key',
        model: 'nano banana',
        prompt: 'a cat',
        aspectRatio: '1:1',
      );

      expect(server.requests.single.body!['model'], 'nano banana 2');
    });

    test('polls the job endpoint when the response is async', () async {
      final server = await startServer([
        {'job_id': 'job1'},
        {'status': 'pending'},
        {'status': 'completed', 'data_url': 'data:image/png;base64,AQI='},
      ]);

      final bytes =
          await NaisteraImageProvider(
            baseUrl: server.baseUrl,
            http: server.http,
            pollInterval: const Duration(milliseconds: 10),
          ).generate(
            apiKey: 'key',
            model: 'grok',
            prompt: 'a cat',
            aspectRatio: '1:1',
          );

      expect(bytes, [1, 2]);
      expect(server.requests.map((r) => r.method).toList(), [
        'POST',
        'GET',
        'GET',
      ]);
      expect(server.requests.last.path, '/api/generate/jobs/job1');
    });

    test('reports a failed job instead of hanging', () async {
      final server = await startServer([
        {'job_id': 'job1'},
        {'status': 'failed', 'detail': 'moderation'},
      ]);

      await expectLater(
        NaisteraImageProvider(
          baseUrl: server.baseUrl,
          http: server.http,
          pollInterval: const Duration(milliseconds: 10),
        ).generate(
          apiKey: 'key',
          model: 'grok',
          prompt: 'a cat',
          aspectRatio: '1:1',
        ),
        throwsA(
          isA<StateError>().having(
            (e) => e.toString(),
            'message',
            contains('Naistera image generation unavailable'),
          ),
        ),
      );
    });

    for (final failure in [
      'no response',
      'HTTP 401',
      'HTTP 302',
      'cancelled',
      'empty key',
    ]) {
      test(
        'catalog finite public fallback ONLY allowed cause ($failure)',
        () async {
          final adapter = _NaisteraAdapter((request) {
            final authenticated = request.headers['Authorization'] != null;
            if (authenticated || failure == 'empty key') {
              if (failure.startsWith('HTTP'))
                return ResponseBody.fromString(
                  '{}',
                  int.parse(failure.split(' ').last),
                  headers: {
                    Headers.contentTypeHeader: ['application/json'],
                  },
                );
              throw DioException(
                requestOptions: request,
                type: failure == 'cancelled'
                    ? DioExceptionType.cancel
                    : DioExceptionType.connectionError,
                error: 'SYNTHETIC_RAW_PRIVATE_ERROR',
              );
            }
            return ResponseBody.fromString(
              '{"models":[{"id":123,"name":456,"references":false},'
              '{"id":"hidden","visible":false},{"id":"old","deprecated":true},{"id":"NewCaseModel"}]}',
              200,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            );
          });
          final dio = Dio()..httpClientAdapter = adapter;
          addTearDown(() => dio.close());
          final pending = NaisteraImageProvider(http: ImageGenHttp(dio: dio))
              .fetchModels(
                apiKey: failure == 'empty key' ? '' : 'SYNTHETIC_ACCOUNT_KEY',
              );
          if (failure == 'no response') {
            final catalog = await pending;
            expect(catalog.map((m) => m.id), ['123', 'NewCaseModel']);
            expect(catalog.first.name, '456');
            expect(catalog.first.references, isFalse);
            expect(catalog.last.references, isTrue);
            expect(adapter.requests, hasLength(2));
            expect(
              adapter.requests.last.headers.containsKey('Authorization'),
              isFalse,
            );
          } else {
            await expectLater(pending, throwsA(isA<StateError>()));
            expect(adapter.requests, hasLength(1));
          }
          expect(adapter.requests.every((r) => !r.followRedirects), isTrue);
        },
      );
    }
    test(
      'fallback does not retry when current policy retires its original recipient',
      () async {
        var current = true;
        final adapter = _NaisteraAdapter((request) {
          current = false;
          throw DioException(
            requestOptions: request,
            type: DioExceptionType.connectionError,
          );
        });
        final dio = Dio()..httpClientAdapter = adapter;
        addTearDown(() => dio.close());
        await expectLater(
          NaisteraImageProvider(
            http: ImageGenHttp(dio: dio),
            checkCurrent: () {
              if (!current) throw StateError('retired');
            },
          ).fetchModels(apiKey: 'SYNTHETIC_KEY'),
          throwsA(isA<StateError>()),
        );
        expect(adapter.requests, hasLength(1));
      },
    );
    for (final location in ['base', 'job', 'asset', 'error']) {
      test(
        'whole CURRENT encoded alias at $location refuses HTTP/second request and raw errors',
        () async {
          const alias = 'SYNTHETIC_PRIVATE_FULL_VALUE';
          final previous = activeErrorRedactor;
          activeErrorRedactor = SecretRedactor();
          addTearDown(() => activeErrorRedactor = previous);
          final encoded = Uri.encodeComponent(alias);
          final adapter = _NaisteraAdapter((request) {
            activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
            final response = switch (location) {
              'job' => {'job_id': 'job/$encoded'},
              'asset' => {
                'data_url': 'https://synthetic-cdn.invalid/$encoded.png',
              },
              'error' => {'status': 'failed', 'error': 'Echo $alias'},
              _ => {'data_url': 'data:image/png;base64,AQI='},
            };
            return ResponseBody.fromString(
              jsonEncode(response),
              200,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            );
          });
          final dio = Dio()..httpClientAdapter = adapter;
          addTearDown(() => dio.close());
          if (location == 'base')
            activeErrorRedactor = SecretRedactor(knownSecrets: const [alias]);
          await expectLater(
            NaisteraImageProvider(
              baseUrl: location == 'base'
                  ? 'https://synthetic-naistera.invalid/$encoded'
                  : 'https://synthetic-naistera.invalid',
              http: ImageGenHttp(dio: dio),
              pollInterval: Duration.zero,
            ).generate(
              apiKey: 'SYNTHETIC_ACCOUNT',
              model: 'grok',
              prompt: 'a cat',
              aspectRatio: '1:1',
            ),
            throwsA(predicate((Object? e) => !e.toString().contains(alias))),
          );
          expect(adapter.requests, hasLength(location == 'base' ? 0 : 1));
        },
      );
    }
    test(
      'asset uses separate unauthenticated no-redirect GET; signed query bytes unchanged',
      () async {
        const url =
            'https://synthetic-cdn.invalid/image.png?token=SIGNED%2fAa+Bb&X-Amz-Signature=ab%2Fcd';
        final api = _NaisteraAdapter(
          (_) => ResponseBody.fromString(
            jsonEncode({'data_url': url}),
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          ),
        );
        final asset = _NaisteraAdapter(
          (_) => ResponseBody.fromBytes([1, 2], 200),
        );
        final apiDio = Dio()..httpClientAdapter = api;
        final assetDio = Dio()..httpClientAdapter = asset;
        addTearDown(() {
          apiDio.close();
          assetDio.close();
        });
        final bytes =
            await NaisteraImageProvider(
              http: ImageGenHttp(dio: apiDio),
              assetHttp: ImageGenHttp(dio: assetDio),
            ).generate(
              apiKey: 'SYNTHETIC_ACCOUNT',
              model: 'grok',
              prompt: 'a cat',
              aspectRatio: '1:1',
            );
        expect(bytes, [1, 2]);
        expect(
          api.requests.single.headers['Authorization'],
          'Bearer SYNTHETIC_ACCOUNT',
        );
        expect(asset.requests.single.path, url);
        expect(
          asset.requests.single.headers.containsKey('Authorization'),
          isFalse,
        );
        expect(asset.requests.single.followRedirects, isFalse);
      },
    );
    test(
      'late poll retirement does not start a replacement generation or another poll',
      () async {
        var current = true;
        final adapter = _NaisteraAdapter((request) {
          if (request.method == 'GET') current = false;
          return ResponseBody.fromString(
            request.method == 'POST'
                ? '{"job_id":"job1"}'
                : '{"status":"completed","data_url":"data:image/png;base64,AQI="}',
            200,
            headers: {
              Headers.contentTypeHeader: ['application/json'],
            },
          );
        });
        final dio = Dio()..httpClientAdapter = adapter;
        addTearDown(() => dio.close());
        await expectLater(
          NaisteraImageProvider(
            http: ImageGenHttp(dio: dio),
            pollInterval: Duration.zero,
            checkCurrent: () {
              if (!current) throw StateError('retired');
            },
          ).generate(
            apiKey: 'SYNTHETIC_ACCOUNT',
            model: 'grok',
            prompt: 'a cat',
            aspectRatio: '1:1',
          ),
          throwsA(isA<StateError>()),
        );
        expect(adapter.requests.map((r) => r.method), ['POST', 'GET']);
        expect(adapter.requests.every((r) => !r.followRedirects), isTrue);
      },
    );
    for (final malformed in ['job%not-hex', 'bad\\job']) {
      test(
        'malformed returned job is refused before any polling ($malformed)',
        () async {
          final adapter = _NaisteraAdapter(
            (_) => ResponseBody.fromString(
              jsonEncode({'job_id': malformed}),
              200,
              headers: {
                Headers.contentTypeHeader: ['application/json'],
              },
            ),
          );
          final dio = Dio()..httpClientAdapter = adapter;
          addTearDown(() => dio.close());
          await expectLater(
            NaisteraImageProvider(
              http: ImageGenHttp(dio: dio),
              pollInterval: Duration.zero,
            ).generate(
              apiKey: 'SYNTHETIC_ACCOUNT',
              model: 'grok',
              prompt: 'a cat',
              aspectRatio: '1:1',
            ),
            throwsA(isA<StateError>()),
          );
          expect(adapter.requests, hasLength(1));
        },
      );
    }
  });
}
