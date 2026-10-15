import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_metadata_projection.dart';
import 'package:glaze_flutter/core/credentials/credential_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_route.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';

final class _UnsafeObject {
  @override
  String toString() => throw StateError('toString must not execute');
  Map<String, Object?> toJson() => throw StateError('toJson must not execute');
}

void main() {
  const canary = 'TEST_CANARY_🔐_"\\_secret';
  late SecretRedactor redactor;
  setUp(() => redactor = SecretRedactor(knownSecrets: [canary]));

  test('known values disappear from prose, JSON, encoded text and errors', () {
    for (final input in [
      'request failed with $canary in payload',
      jsonEncode({
        'message': 'failed $canary',
        'nested': [
          {'arbitrary': canary},
        ],
      }),
      'escaped=${Uri.encodeComponent(canary)}',
      'escaped=${jsonEncode(canary)}',
    ]) {
      final result = redactor.redactText(input);
      expect(result, isNot(contains(canary)));
      expect(result, isNot(contains(Uri.encodeComponent(canary))));
      expect(result, isNot(contains(jsonEncode(canary))));
    }
    expect(redactor.redactError(StateError(canary)), isNot(contains(canary)));
    expect(redactor.redactError('error $canary'), isNot(contains(canary)));
    expect(
      redactor.redactError(_UnsafeObject()),
      contains(SecretRedactor.removed),
    );
    expect(redactor.toString(), 'SecretRedactor');
  });

  test('Authorization/basic/bearer patterns and token-like JSON names', () {
    for (final input in [
      'Authorization: Bearer UNKNOWN_TEST_TOKEN\nnext',
      'authorization="Basic UNKNOWN_TEST_TOKEN"',
      'Proxy-Authorization: Basic UNKNOWN_TEST_TOKEN',
      'failed Bearer UNKNOWN_TEST_TOKEN',
      'api_key="UNKNOWN_TEST_TOKEN"',
      'accessToken: UNKNOWN_TEST_TOKEN',
      'password = UNKNOWN_TEST_TOKEN',
    ]) {
      expect(redactor.redactText(input), isNot(contains('UNKNOWN_TEST_TOKEN')));
    }
    final output = redactor.redactJson({
      'extraParams': {
        'nested': [
          {'x-api-key': 'UNKNOWN_TEST_TOKEN'},
          {
            'refresh_token': {'deep': 'UNKNOWN_TEST_TOKEN'},
          },
          {'Authorization': 'UNKNOWN_TEST_TOKEN'},
          {'Cookie': 'UNKNOWN_TEST_TOKEN'},
        ],
      },
      'sampling': {'temperature': 0.4},
    });
    expect(jsonEncode(output), isNot(contains('UNKNOWN_TEST_TOKEN')));
    expect(jsonEncode(output), contains('0.4'));
  });

  test('URLs strip ALL userinfo/query/fragment, including unknown secrets', () {
    final value =
        'https://user:UNKNOWN@provider.example/v1/chat?api_key=UNKNOWN#UNKNOWN';
    expect(redactor.redactUrl(value), 'https://provider.example/v1/chat');
    final embedded = redactor.redactText('failed at $value');
    expect(embedded, contains('https://provider.example/v1/chat'));
    expect(embedded, isNot(contains('UNKNOWN')));
    final encoded = Uri.encodeComponent(canary);
    expect(
      redactor.redactUrl('https://provider.example/$encoded'),
      isNot(contains(encoded)),
    );
    final lowerPercent = encoded.replaceAllMapped(
      RegExp(r'%[A-Fa-f0-9]{2}'),
      (match) => match[0]!.toLowerCase(),
    );
    expect(
      redactor.redactUrl('https://provider.example/$lowerPercent'),
      contains(Uri.encodeComponent(SecretRedactor.removed)),
    );
    expect(
      redactor.redactUrl('http://[::1]:8080/chat?key=UNKNOWN'),
      'http://[::1]:8080/chat',
    );
  });

  test('malformed/relative/unsupported URLs fail closed', () {
    for (final value in [
      'not a url $canary',
      '/relative?key=UNKNOWN',
      'https://',
      'https://provider.example/%zz?key=UNKNOWN',
      'https://provider.example\\@evil.example?key=UNKNOWN',
      'file:///secret?key=UNKNOWN',
      'https://provider.example/ bad',
      'https://provider.example:99999/chat',
    ]) {
      expect(redactor.redactUrl(value), SecretRedactor.removed);
    }
  });

  test('known secret key names/path segments and longest overlaps', () {
    final local = SecretRedactor(
      knownSecrets: ['TEST_LONG_SECRET', 'TEST_LONG'],
    );
    expect(local.redactText('TEST_LONG_SECRET'), SecretRedactor.removed);
    expect(
      jsonEncode(local.redactJson({'TEST_LONG_SECRET': 'value'})),
      isNot(contains('TEST_LONG')),
    );
    expect(
      local.redactUrl('https://provider.example/TEST_LONG_SECRET'),
      isNot(contains('TEST_LONG')),
    );
    expect(
      redactor.redactText('sk-UNKNOWNTESTTOKEN ghp_UNKNOWNTESTTOKEN'),
      isNot(contains('UNKNOWNTESTTOKEN')),
    );
  });

  test('nested URL-named fields cannot pass malformed/query/fragment data', () {
    final output = redactor.redactJson({
      'params': [
        {'baseUrl': '/relative?value=UNKNOWN'},
        {'endpoint': 'https://provider.example?value=UNKNOWN#UNKNOWN'},
        {'callback_url': 'https://provider.example/%zz?value=UNKNOWN'},
      ],
    });
    expect(jsonEncode(output), isNot(contains('UNKNOWN')));
    expect(jsonEncode(output), contains('https://provider.example'));
  });

  test(
    'malformed quoted URL queries fail closed and markers are not rescanned',
    () {
      expect(
        redactor.redactText('failed https://provider.example?value="UNKNOWN"'),
        isNot(contains('UNKNOWN')),
      );
      final overlap = SecretRedactor(knownSecrets: ['REDACTED']);
      expect(overlap.redactText('literal REDACTED'), 'literal [REDACTED]');
      expect(
        SecretRedactor(knownSecrets: List.filled(257, '')).redactText('safe'),
        SecretRedactor.limited,
      );
    },
  );

  test(
    'single-pass known matching preserves structured output and literal markers',
    () {
      final local = SecretRedactor(
        knownSecrets: [
          'TEST_LONG_SECRET',
          'TEST_LONG',
          'R',
          'E',
          'D',
          'A',
          'C',
          'T',
          '[',
          ']',
        ],
      );
      expect(local.redactText('TEST_LONG_SECRET'), SecretRedactor.removed);
      expect(local.redactText('prefix R suffix'), 'prefix [REDACTED] suffix');
      expect(local.redactJson({'text': 'R', 'number': 42}), {
        'text': SecretRedactor.removed,
        'number': 42,
      });
      expect(local.redactJson(['R', 'plain']), [
        SecretRedactor.removed,
        'plain',
      ]);
      expect(local.redactText('R' * 100), SecretRedactor.removed * 100);
      final escaped = SecretRedactor(knownSecrets: ['a.b|c+']);
      expect(escaped.redactText('a.b|c+ aXb'), '[REDACTED] aXb');
    },
  );

  test(
    'plural and common URL fields fail closed and empty suffixes are stripped',
    () {
      for (final key in [
        'urls',
        'uris',
        'endpoints',
        'href',
        'origin',
        'host',
        'base_urls',
        'urlPrefix',
        'endpointConfig',
      ]) {
        expect(redactor.redactJson({key: '/relative?secret=UNKNOWN'}), {
          key: SecretRedactor.removed,
        });
        expect(
          redactor.redactJson({
            key: ['UNKNOWN'],
          }),
          {key: SecretRedactor.removed},
        );
      }
      for (final suffix in ['?', '#', '?#']) {
        expect(
          redactor.redactUrl('https://provider.example/chat$suffix'),
          'https://provider.example/chat',
        );
      }
    },
  );

  test(
    'Google and HuggingFace tokens and common base64 variants are redacted',
    () {
      for (final token in ['AIza${'x' * 30}', 'hf_${'x' * 20}']) {
        expect(redactor.redactText('failed $token'), 'failed [REDACTED]');
        expect(redactor.redactJson({'error': token}), {
          'error': SecretRedactor.removed,
        });
      }
      for (final value in [
        base64Encode(utf8.encode(canary)),
        base64UrlEncode(utf8.encode(canary)),
      ]) {
        expect(redactor.redactText('encoded $value'), 'encoded [REDACTED]');
      }
    },
  );

  test(
    'named values redact original data without altering replacement markers',
    () {
      final local = SecretRedactor(
        knownSecrets: ['R', 'E', 'D', 'A', 'C', 'T'],
      );
      expect(local.redactText('message="R"'), 'message="[REDACTED]"');
      expect(
        local.redactText('Authorization: Bearer UNKNOWN'),
        'Authorization: [REDACTED]',
      );
      expect(
        redactor.redactText(
          'location="https://provider.example?value=UNKNOWN"',
        ),
        isNot(contains('UNKNOWN')),
      );
      expect(
        redactor.redactText('authorization: bEaReR UNKNOWN'),
        'Authorization: [REDACTED]',
      );
    },
  );

  test('bounds, cycles, unknown objects and embedded JSON fail safely', () {
    final bounded = SecretRedactor(
      maxDepth: 2,
      maxNodes: 4,
      maxOutputLength: 64,
      maxInputLength: 128,
      knownSecrets: [canary],
    );
    final cyclic = <String, Object?>{};
    cyclic['cycle'] = cyclic;
    expect(
      jsonEncode(bounded.redactJson(cyclic)),
      contains(SecretRedactor.limited),
    );
    expect(bounded.redactText('a' * 129), SecretRedactor.limited);
    expect(bounded.redactText('a' * 65), SecretRedactor.limited);
    expect(bounded.redactJson(List.filled(10, canary)), SecretRedactor.limited);
    expect(
      jsonEncode(
        bounded.redactJson({
          'a': {
            'b': {'c': canary},
          },
        }),
      ),
      isNot(contains(canary)),
    );
    expect(redactor.redactJson(_UnsafeObject()), SecretRedactor.removed);
    expect(redactor.redactJson({'object': _UnsafeObject()}), {
      'object': SecretRedactor.removed,
    });
    var nested = canary;
    for (var i = 0; i < 20; i++) {
      nested = jsonEncode({'inner': nested});
    }
    expect(bounded.redactText(nested), SecretRedactor.limited);
    expect(
      SecretRedactor(
        knownSecrets: List.generate(257, (i) => '$i'),
      ).redactText('safe'),
      SecretRedactor.limited,
    );
  });

  test(
    'connection projection is an explicit DTO, not a generic config export',
    () {
      final projection = ConnectionMetadataProjection(redactor: redactor);
      final output = projection.project(
        connectionId: 'connection-1',
        displayName: 'Provider $canary',
        endpoint:
            'https://user:UNKNOWN@provider.example/v1?key=UNKNOWN#UNKNOWN',
        protocol: CredentialProtocol.openAiChatCompletions,
        credential: CredentialMetadata.fromSecret(canary),
        modelId: 'model',
        diagnosticParameters: {
          'temperature': 0.4,
          'nested': [
            {'apiKey': canary},
            {'other': 'failure $canary'},
          ],
        },
      );
      expect(jsonEncode(output), isNot(contains(canary)));
      expect(jsonEncode(output), isNot(contains('UNKNOWN')));
      expect(output['credential'], {
        'configured': true,
        'characterCount': canary.runes.length,
      });
      expect(output['endpoint'], 'https://provider.example/v1');
      expect(output.keys, [
        'connectionId',
        'displayName',
        'endpoint',
        'protocol',
        'credential',
        'modelId',
        'diagnosticParameters',
      ]);
    },
  );

  test('does NOT promise universal PII/obfuscated-secret detection', () {
    expect(
      redactor.redactText('person@example.test lives at 12 Example Street'),
      contains('person@example.test'),
    );
    expect(
      redactor.redactText('unknown arbitrary confidential prose'),
      'unknown arbitrary confidential prose',
    );
  });

  test(
    'snapshot extension retains base coverage, encodings and policy limits',
    () {
      final base = SecretRedactor(
        knownSecrets: [canary],
        maxInputLength: 12345,
        maxOutputLength: 1234,
        maxDepth: 3,
        maxNodes: 40,
      );
      const added = 'ADDITIONAL_PRIVATE_CANARY';
      final extended = base.withKnownSecrets([added]);
      expect(extended.maxInputLength, 12345);
      expect(extended.maxOutputLength, 1234);
      expect(extended.maxDepth, 3);
      expect(extended.maxNodes, 40);
      expect(base.redactText(added), added);
      for (final secret in [canary, added]) {
        expect(extended.redactText('failed $secret'), 'failed [REDACTED]');
        expect(extended.redactText(Uri.encodeComponent(secret)), '[REDACTED]');
        expect(
          extended.redactText(base64Encode(utf8.encode(secret))),
          '[REDACTED]',
        );
      }
      final capture = extended.withKnownSecrets(
        const [],
        maxInputLength: 200000,
        maxOutputLength: 400000,
        maxDepth: 32,
        maxNodes: 4096,
      );
      expect(capture.redactText('ordinary ' * 2000), 'ordinary ' * 2000);
      expect(capture.redactText('$canary $added'), '[REDACTED] [REDACTED]');
      expect(extended.redactText('ordinary ' * 2000), SecretRedactor.limited);
    },
  );

  test(
    'snapshot input is bounded, single-use and closed policies stay closed',
    () {
      var enumerations = 0;
      var visits = 0;
      Iterable<String> input() sync* {
        if (++enumerations > 1) throw StateError('second enumeration');
        visits++;
        yield canary;
      }

      final base = SecretRedactor(knownSecrets: input());
      final extended = base.withKnownSecrets(['new canary']);
      expect(extended.redactText(canary), '[REDACTED]');
      expect(enumerations, 1);
      expect(visits, 1);

      Iterable<String> infinite() sync* {
        while (true) {
          visits++;
          yield '';
        }
      }

      visits = 0;
      final exhausted = SecretRedactor(knownSecrets: infinite());
      expect(visits, 257);
      expect(exhausted.redactText('safe'), SecretRedactor.limited);
      var additionsRead = 0;
      Iterable<String> additions() sync* {
        additionsRead++;
        yield 'must not consume';
      }

      for (final closed in [
        exhausted,
        SecretRedactor(knownSecrets: ['a' * 100], maxInputLength: 64),
        SecretRedactor(knownSecrets: input()), // Enumeration throws.
        base.withKnownSecrets(infinite()),
        base.withKnownSecrets(const [], maxInputLength: 2),
      ]) {
        final raised = closed.withKnownSecrets(
          additions(),
          maxInputLength: 200000,
        );
        expect(raised.redactText('ordinary'), SecretRedactor.limited);
        expect(raised.redactJson({'ordinary': true}), SecretRedactor.limited);
        expect(
          raised.redactUrl('https://example.test'),
          SecretRedactor.limited,
        );
      }
      expect(additionsRead, 0);
      expect(
        () => base.withKnownSecrets(const [], maxNodes: 0),
        throwsFormatException,
      );
    },
  );
}
