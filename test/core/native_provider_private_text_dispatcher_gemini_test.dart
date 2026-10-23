import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_request.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';

import 'native_provider_private_text_dispatcher_gemini_fixture.dart';

void _expectFinal(GeminiNativePrivateFixture f, CancelToken token) {
  final actual = f.records.single;
  final approved = Uri.parse(f.h.core.row.endpoint);
  final expected = f.expectedOriginal();
  expect(actual.method, 'POST');
  expect(actual.uri, approved.replace(query: 'alt=sse'));
  expect(actual.path, approved.replace(query: 'alt=sse').toString());
  expect(actual.baseUrl, isEmpty);
  expect(actual.query, isEmpty);
  expect(actual.extras, isEmpty);
  expect(actual.uri.queryParametersAll, {
    'alt': ['sse'],
  });
  expect(actual.path, isNot(contains('key=')));
  expect(actual.path, isNot(contains(nativeCanary)));
  expect(actual.headers['x-goog-api-key'], nativeCanary);
  expect(actual.headers['Authorization'], isNull);
  expect(actual.body, expected.bodyJson);
  expect(actual.upload, utf8.encode(expected.bodyJson));
  expect(jsonEncode(f.h.wires.single.body), expected.bodyJson);
  expect(actual.body, isNot(contains(nativeCanary)));
  expect(identical(actual.token, token), isTrue);
  expect(actual.redirects, isFalse);
  expect(actual.maxRedirects, 0);
  expect(f.h.adapters.single.closed, isTrue);
}

void _tamper(RequestOptions options, String mutation) {
  final original = options.uri;
  final key = original.queryParameters['key']!;
  final base = '${original.scheme}://${original.authority}${original.path}';
  switch (mutation) {
    case 'duplicate-key':
      options.path =
          '$base?key=${Uri.encodeComponent(key)}&key=${Uri.encodeComponent(key)}&alt=sse';
    case 'duplicate-alt':
      options.path = '$base?key=${Uri.encodeComponent(key)}&alt=sse&alt=sse';
    case 'mismatched-key':
      options.path = '$base?key=SYNTHETIC_WRONG_KEY&alt=sse';
    case 'mismatched-alt':
      options.path = '$base?key=${Uri.encodeComponent(key)}&alt=json';
    case 'query-map':
      options.queryParameters['key'] = key;
    case 'hidden-base-url':
      options.baseUrl =
          'https://synthetic.example/?key=${Uri.encodeComponent(key)}';
    case 'auth-header':
      options.headers['x-goog-api-key'] = key;
    case 'duplicate-header':
      options.headers['Content-Type'] = [
        'application/json',
        'application/json',
      ];
    case 'body':
      options.data = {
        'contents': [
          {
            'role': 'user',
            'parts': [
              {'text': 'UNAPPROVED_BODY'},
            ],
          },
        ],
      };
    case 'model-action':
      options.path =
          'https://generativelanguage.googleapis.com/v1beta/models/other-model:streamGenerateContent?key=${Uri.encodeComponent(key)}&alt=sse';
    case 'route':
      options.path =
          'https://synthetic.example/v1beta/models/other-model:streamGenerateContent?key=${Uri.encodeComponent(key)}&alt=sse';
    case 'method':
      options.method = 'GET';
    case 'redirect':
      options.followRedirects = true;
    case 'extras':
      options.extra['capture'] = true;
  }
}

void main() {
  test(
    'actual Gemini accepted original authorization sees only original approved recipient',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      final token = CancelToken();
      final auth = f.h.core.reference(NativeProviderPurpose.astoria);
      final request = f.h.request(
        auth: auth,
        purpose: NativeProviderPurpose.astoria,
      );
      f.authorization = (handoff) async {
        expect(handoff.recipient, Uri.parse(f.h.core.row.endpoint));
        expect(handoff.model, f.h.core.row.model);
        expect(handoff.attempt, 1);
        expect(handoff.recipient.hasQuery, isFalse);
        // TEST-ONLY inspection of the original DIO owner proves the accepted
        // query-auth request was not silently replaced before authorization.
        expect(token.requestOptions!.uri, f.expectedOriginal().wireUri);
        expect(token.requestOptions!.uri.queryParametersAll['key'], [
          nativeCanary,
        ]);
        expect(token.requestOptions!.headers['x-goog-api-key'], isNull);
        return true;
      };
      final result = await f.run(token: token, auth: auth, request: request);
      expect(result.status, PrivateTextStatus.complete);
      expect(result.text, 'Visible text ');
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(result.reason, PrivateTextReason.none);
      expect(f.handoffs, hasLength(1));
      expect(f.capsules, isEmpty);
      _expectFinal(f, token);
      expect(request.apiKey, isEmpty);
      expect(f.h.core.row.apiKey, isEmpty);
      expect(identical(request.savedConnectionAuth, auth), isTrue);
      expect(request.savedConnectionId, f.h.core.row.id);
    },
  );

  test(
    'original Gemini capsule admits once without weak authorizer or body substitution',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      final token = CancelToken();
      f.authorization = (_) async =>
          throw StateError('Weak authorization must not run');
      f.admission = (capsule) async {
        expect(capsule.isCurrent, isTrue);
        expect(capsule.handoff.recipient, Uri.parse(f.h.core.row.endpoint));
        expect(token.requestOptions!.uri, f.expectedOriginal().wireUri);
        expect(
          jsonEncode(token.requestOptions!.data),
          f.expectedOriginal().bodyJson,
        );
        expect(token.requestOptions!.headers['x-goog-api-key'], isNull);
        capsule.dispatch();
        expect(capsule.isCurrent, isFalse);
        expect(() => capsule.dispatch(), throwsA(isA<PrivateTextFailure>()));
        return true;
      };
      final result = await f.run(token: token);
      expect(result.status, PrivateTextStatus.complete);
      expect(result.dispatch, PrivateTextDispatch.admitted);
      expect(f.handoffs, isEmpty);
      expect(f.capsules, hasLength(1));
      _expectFinal(f, token);
      expect(
        () => f.capsules.single.dispatch(),
        throwsA(isA<PrivateTextFailure>()),
      );
      expect(f.h.wires, hasLength(1));
    },
  );

  final mutations = [
    'duplicate-key',
    'duplicate-alt',
    'mismatched-key',
    'mismatched-alt',
    'query-map',
    'hidden-base-url',
    'auth-header',
    'duplicate-header',
    'body',
    'model-action',
    'route',
    'method',
    'redirect',
    'extras',
  ];
  for (final mutation in mutations) {
    test(
      'original Gemini request rejects $mutation before actual delegation',
      () async {
        final f = GeminiNativePrivateFixture();
        await f.store();
        final token = CancelToken();
        f.authorization = (_) async {
          _tamper(token.requestOptions!, mutation);
          return true;
        };
        final result = await f.run(token: token);
        expect(result.status, PrivateTextStatus.error);
        // Accepted checks reject most mutations before adapter invocation. Raw
        // baseUrl/extras checks additionally belong to this new native seam; an
        // original weak-path adapter invocation is not a fabricated zero admission.
        expect(
          result.dispatch,
          anyOf(PrivateTextDispatch.notAdmitted, PrivateTextDispatch.admitted),
        );
        expect(f.records, isEmpty);
        expect(f.h.wires, isEmpty);
        expect(result.toString(), isNot(contains(nativeCanary)));
      },
    );
    test(
      'Gemini final-factory $mutation recheck denies zero-wire AFTER original capsule dispatch',
      () async {
        final f = GeminiNativePrivateFixture();
        await f.store();
        final token = CancelToken();
        f.admission = (capsule) async {
          capsule.dispatch();
          return true;
        };
        f.h.onFactory = () => _tamper(token.requestOptions!, mutation);
        final result = await f.run(token: token);
        expect(result.status, PrivateTextStatus.error);
        expect(result.dispatch, PrivateTextDispatch.admittedFailed);
        expect(result.reason, PrivateTextReason.admittedFailed);
        expect(result.text, isEmpty);
        expect(f.records, isEmpty);
        expect(f.h.wires, isEmpty);
        expect(f.h.adapters, hasLength(1));
        expect(f.h.adapters.single.closed, isTrue);
        expect(result.toString(), isNot(contains(nativeCanary)));
      },
    );
  }

  test(
    'final factory reentering ORIGINAL once capsule does not issue a wire',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      f.admission = (capsule) async {
        capsule.dispatch();
        return true;
      };
      f.h.onFactory = () => f.capsules.single.dispatch();
      final result = await f.run();
      expect(result.dispatch, PrivateTextDispatch.admittedFailed);
      expect(result.text, isEmpty);
      expect(f.h.wires, isEmpty);
      expect(f.records, isEmpty);
      expect(f.capsules.single.isCurrent, isFalse);
    },
  );

  for (final stop in [true, false]) {
    for (final gate in ['authorization', 'admission']) {
      test(
        '$gate held Gemini ${stop ? 'Stop' : 'source fence'} prevents late dispatch',
        () async {
          final f = GeminiNativePrivateFixture();
          await f.store();
          final entered = Completer<void>();
          final release = Completer<void>();
          final done = Completer<void>();
          if (gate == 'authorization') {
            f.authorization = (_) async {
              entered.complete();
              await release.future;
              done.complete();
              return true;
            };
          } else {
            f.admission = (capsule) async {
              entered.complete();
              await release.future;
              try {
                capsule.dispatch();
              } on PrivateTextFailure {
                /* Retired original cannot start. */
              }
              done.complete();
              return true;
            };
          }
          final token = CancelToken();
          final pending = f.run(token: token);
          await entered.future;
          if (stop) {
            token.cancel();
          } else {
            f.h.core.ordinaryMutation();
          }
          release.complete();
          final result = await pending;
          await done.future;
          expect(result.status, PrivateTextStatus.stopped);
          expect(result.dispatch, PrivateTextDispatch.notAdmitted);
          expect(f.records, isEmpty);
          expect(f.h.wires, isEmpty);
          if (f.capsules.isNotEmpty) {
            expect(f.capsules.single.isCurrent, isFalse);
          }
        },
      );
    }
  }

  test(
    'source disposal during actual final factory closes prepared adapter before zero-wire denial',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      f.admission = (capsule) async {
        capsule.dispatch();
        return true;
      };
      f.h.onFactory = f.h.core.mutations.dispose;
      final result = await f.run();
      expect(result.status, isNot(PrivateTextStatus.complete));
      expect(f.h.wires, isEmpty);
      expect(f.records, isEmpty);
      expect(f.h.adapters.single.closed, isTrue);
    },
  );

  test(
    'Gemini split echo is sanitized by ACTUAL unchanged text guard before outcome',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      final first = {
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': 'before ${nativeCanary.substring(0, 12)}'},
              ],
            },
          },
        ],
      };
      final last = {
        'candidates': [
          {
            'content': {
              'role': 'model',
              'parts': [
                {'text': '${nativeCanary.substring(12)} after'},
                {'text': nativeCanary, 'thought': true},
              ],
            },
            'finishReason': 'STOP',
          },
        ],
      };
      final bytes = utf8.encode(
        'data: ${jsonEncode(first)}\n\ndata: ${jsonEncode(last)}\n\n',
      );
      f.h.responseStream = Stream.fromIterable(
        bytes.map((byte) => Uint8List.fromList([byte])),
      );
      var activities = 0;
      final result = await f.run(
        activity: () {
          activities++;
        },
      );
      expect(result.status, PrivateTextStatus.complete);
      expect(result.text, 'before [REDACTED] after');
      expect(result.text, isNot(contains(nativeCanary)));
      expect(activities, 1);
      expect(f.h.updates, isEmpty);
      expect(f.h.completions, isEmpty);
      expect(f.h.wires, hasLength(1));
    },
  );

  test(
    'native Gemini readiness exports actual Unicode count, never envelope/query/key DTO',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      final original = f.h.core.reference(NativeProviderPurpose.astoria);
      final observation = await f.h.core.credentials.inspectSavedConnection(
        connection: original,
        isCurrent: () => true,
      );
      expect(observation.state, NativeProviderCredentialState.ready);
      expect(observation.metadata.toJson(), {
        'configured': true,
        'characterCount': nativeCanary.runes.length,
      });
      expect(observation.metadata.characterCount, isNot(nativeCanary.length));
      expect(original.toString(), isNot(contains(nativeCanary)));
      expect(
        jsonEncode(observation.metadata.toJson()),
        isNot(contains(nativeCanary)),
      );
      expect(
        f.h
            .request(auth: original, purpose: NativeProviderPurpose.astoria)
            .apiKey,
        isEmpty,
      );
    },
  );

  test(
    'started original Gemini failure remains admittedFailed after its final await',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      f.admission = (capsule) async {
        capsule.dispatch();
        return true;
      };
      f.h.fetchError = StateError(nativeCanary);
      final result = await f.run();
      expect(result.dispatch, PrivateTextDispatch.admittedFailed);
      expect(result.reason, PrivateTextReason.admittedFailed);
      expect(result.status, PrivateTextStatus.error);
      expect(result.text, isEmpty);
      expect(result.toString(), isNot(contains(nativeCanary)));
      expect(f.h.wires, hasLength(1));
      expect(f.h.adapters.single.closed, isTrue);
    },
  );

  test(
    'source retirement after actual Gemini fetch preserves original dispatch custody, no late activity',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      final entered = Completer<void>();
      final release = Completer<void>();
      f.admission = (capsule) async {
        capsule.dispatch();
        return true;
      };
      f.h.beforeResponse = () async {
        entered.complete();
        await release.future;
      };
      var activities = 0;
      final pending = f.run(
        activity: () {
          activities++;
        },
      );
      await entered.future;
      f.h.core.mutations.dispose();
      release.complete();
      final result = await pending;
      expect(f.h.wires, hasLength(1));
      expect(f.records, hasLength(1));
      expect(result.status, isNot(PrivateTextStatus.complete));
      expect(
        result.dispatch,
        anyOf(PrivateTextDispatch.admitted, PrivateTextDispatch.admittedFailed),
      );
      expect(activities, 0);
      expect(f.h.adapters.single.closed, isTrue);
      expect(f.capsules.single.isCurrent, isFalse);
    },
  );

  test(
    'frozen ORIGINAL Gemini body survives mutable keyless input during authorization',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      final messages = <Map<String, dynamic>>[
        {'role': 'user', 'content': 'original prompt'},
      ];
      final original = f.h.core.reference(NativeProviderPurpose.astoria);
      final request = f.h.request(
        auth: original,
        purpose: NativeProviderPurpose.astoria,
        messages: messages,
      );
      final expected = f.expectedOriginal(
        messages: const [
          {'role': 'user', 'content': 'original prompt'},
        ],
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      f.authorization = (_) async {
        entered.complete();
        await release.future;
        return true;
      };
      final pending = f.run(auth: original, request: request);
      await entered.future;
      messages.single['content'] = 'UNAPPROVED_REPLACEMENT';
      release.complete();
      final result = await pending;
      expect(result.status, PrivateTextStatus.complete);
      expect(f.records.single.body, expected.bodyJson);
      expect(f.records.single.body, isNot(contains('UNAPPROVED_REPLACEMENT')));
      expect(request.apiKey, isEmpty);
      expect(identical(request.savedConnectionAuth, original), isTrue);
    },
  );

  test(
    'original Gemini deadline scheduler/capsule remains authoritative during held admission',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      final entered = Completer<void>();
      final release = Completer<void>();
      final done = Completer<void>();
      late void Function() expire;
      f.onDeadline = (duration, callback) {
        expect(duration, PrivateTextLimits.deadline);
        expire = callback;
      };
      f.admission = (capsule) async {
        entered.complete();
        await release.future;
        try {
          capsule.dispatch();
        } on PrivateTextFailure {
          /* No late wire after original deadline. */
        }
        done.complete();
        return true;
      };
      final pending = f.run();
      await entered.future;
      expire();
      final result = await pending;
      release.complete();
      await done.future;
      expect(result.reason, PrivateTextReason.deadline);
      expect(result.status, PrivateTextStatus.error);
      expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      expect(f.records, isEmpty);
      expect(f.h.wires, isEmpty);
      expect(f.capsules.single.isCurrent, isFalse);
    },
  );

  test(
    'Gemini source mismatch/foreign authority and request extras never admit an auth bridge',
    () async {
      final f = GeminiNativePrivateFixture();
      await f.store();
      for (final request in [
        f.h.request(
          purpose: NativeProviderPurpose.astoria,
          model: 'other-model',
        ),
        f.h.request(
          purpose: NativeProviderPurpose.astoria,
          endpoint: '${f.h.core.row.endpoint}?key=SYNTHETIC&alt=sse',
        ),
        f.h.request(
          purpose: NativeProviderPurpose.astoria,
          schema: const {'type': 'object'},
        ),
        f.h.request(purpose: NativeProviderPurpose.astoria, tools: const []),
      ]) {
        final result = await f.run(
          auth: request.savedConnectionAuth,
          request: request,
        );
        expect(result.status, PrivateTextStatus.error);
        expect(result.dispatch, PrivateTextDispatch.notAdmitted);
      }
      final foreign = GeminiNativePrivateFixture();
      await foreign.store();
      final foreignRef = foreign.h.core.reference(
        NativeProviderPurpose.astoria,
      );
      final foreignResult = await f.run(
        auth: foreignRef,
        request: foreign.h.request(
          auth: foreignRef,
          purpose: NativeProviderPurpose.astoria,
        ),
      );
      expect(foreignResult.dispatch, PrivateTextDispatch.notAdmitted);
      f.h.core.row = f.h.core.row.copyWith(
        extraRequestParameters: [
          const ExtraRequestParameter(
            key: 'headers.x-goog-api-key',
            value: 'SYNTHETIC_OVERRIDE',
          ),
        ],
      );
      final ref = f.h.core.reference(NativeProviderPurpose.astoria);
      final extra = await f.run(
        auth: ref,
        request: ChatTransportRequest.fromApiConfig(
          f.h.core.row,
          savedConnectionAuth: ref,
          messages: const [
            {'role': 'user', 'content': 'safe'},
          ],
        ),
      );
      expect(extra.status, PrivateTextStatus.error);
      expect(extra.dispatch, PrivateTextDispatch.notAdmitted);
      expect(f.records, isEmpty);
      expect(f.h.wires, isEmpty);
    },
  );
}
