import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_metadata_projection.dart';
import 'package:glaze_flutter/core/credentials/credential_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_route.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

void main() {
  // Synthetic fixtures only; the suffix includes the PAT alphabet's underscore.
  const pat = 'github_pat_SYNTHETIC_1234567890abcdef';
  const known = 'CaseSensitiveSynthetic42';
  const shortLabel = 'github_pat_demo';
  final removedPath = Uri.encodeComponent(SecretRedactor.removed);

  for (final injected in [false, true]) {
    group(injected ? 'injected known policy' : 'unknown default policy', () {
      late SecretRedactor redactor;
      SecretRedactor? previousErrorRedactor;

      setUp(() {
        previousErrorRedactor = activeErrorRedactor;
        redactor = SecretRedactor(knownSecrets: injected ? [known] : []);
        activeErrorRedactor = injected ? redactor : null;
      });

      tearDown(() => activeErrorRedactor = previousErrorRedactor);

      test('lone fine-grained PAT needs no other matching trigger', () {
        expect(redactor.redactText(pat), SecretRedactor.removed);
        expect(
          redactor.redactText('Rejected $pat alone'),
          'Rejected ${SecretRedactor.removed} alone',
        );
        expect(redactor.redactError(pat), SecretRedactor.removed);
      });

      test(
        'malformed JSON and non-secret named prose redact the PAT value',
        () {
          expect(
            redactor.redactText('{"message":"Rejected $pat'),
            '{"message":"Rejected ${SecretRedactor.removed}',
          );
          expect(
            redactor.redactText('message="Rejected $pat" next'),
            'message="Rejected ${SecretRedactor.removed}" next',
          );
        },
      );

      test('nested ordinary JSON values use the shared token matcher', () {
        final input = {
          'message': pat,
          'nested': [
            {'description': 'Rejected $pat', 'count': 3},
            [pat, shortLabel],
          ],
        };
        final expected = {
          'message': SecretRedactor.removed,
          'nested': [
            {'description': 'Rejected ${SecretRedactor.removed}', 'count': 3},
            [SecretRedactor.removed, shortLabel],
          ],
        };
        expect(redactor.redactJson(input), expected);
        expect(jsonDecode(redactor.redactText(jsonEncode(input))), expected);
      });

      test('literal and percent-encoded URL path segments redact PATs', () {
        final expected = 'https://provider.example/v1/$removedPath/chat';
        for (final segment in [pat, pat.replaceAll('_', '%5f')]) {
          final url = 'https://provider.example/v1/$segment/chat';
          expect(redactor.redactUrl(url), expected);
          expect(
            redactor.redactText('Rejected at $url'),
            'Rejected at $expected',
          );
          expect(redactor.redactJson({'endpoint': url}), {
            'endpoint': expected,
          });
        }
      });

      test(
        'connection projection shares text, nested JSON and URL coverage',
        () {
          final result = ConnectionMetadataProjection(redactor: redactor)
              .project(
                connectionId: 'connection-1',
                displayName: 'Provider $pat',
                endpoint: 'https://provider.example/v1/$pat',
                protocol: CredentialProtocol.openAiChatCompletions,
                credential: CredentialMetadata.absent,
                modelId: pat,
                diagnosticParameters: {
                  'nested': [
                    {'description': pat},
                  ],
                  'temperature': 0.4,
                },
              );
          expect(result['connectionId'], 'connection-1');
          expect(result['displayName'], 'Provider ${SecretRedactor.removed}');
          expect(
            result['endpoint'],
            'https://provider.example/v1/$removedPath',
          );
          expect(result['modelId'], SecretRedactor.removed);
          expect(result['credential'], {
            'configured': false,
            'characterCount': 0,
          });
          expect(result['diagnosticParameters'], {
            'nested': [
              {'description': SecretRedactor.removed},
            ],
            'temperature': 0.4,
          });
        },
      );

      test('formatError covers raw, native and provider error text', () {
        expect(formatError(pat), SecretRedactor.removed);
        expect(
          formatError(StateError('Rejected $pat alone')),
          'Bad state: Rejected ${SecretRedactor.removed} alone',
        );
        final options = RequestOptions(path: '/v1/chat');
        expect(
          formatError(DioException(requestOptions: options, message: pat)),
          SecretRedactor.removed,
        );
        for (final body in <Object>[
          {'message': 'Rejected $pat alone'},
          jsonEncode({'message': 'Rejected $pat alone'}),
          'Rejected $pat alone',
          '{"message":"Rejected $pat',
        ]) {
          final result = formatError(
            DioException.badResponse(
              statusCode: 400,
              requestOptions: options,
              response: Response<Object>(
                requestOptions: options,
                statusCode: 400,
                data: body,
              ),
            ),
          );
          expect(result, isNot(contains(pat)));
          expect(result, contains('Rejected ${SecretRedactor.removed}'));
        }
      });

      test(
        'short innocent PAT labels remain unless field policy redacts them',
        () {
          for (final label in [
            'github_pat_',
            shortLabel,
            'github_pat_${'x' * 21}',
          ]) {
            expect(redactor.redactText('Label $label'), 'Label $label');
            expect(redactor.redactJson({'label': label}), {'label': label});
            expect(
              redactor.redactUrl('https://provider.example/$label'),
              'https://provider.example/$label',
            );
            expect(formatError('Label $label'), 'Label $label');
          }
          expect(redactor.redactJson({'token': shortLabel}), {
            'token': SecretRedactor.removed,
          });
          expect(
            redactor.redactText('token=$shortLabel'),
            'token="${SecretRedactor.removed}"',
          );
          expect(
            redactor.redactText('github_pat_${'x' * 22}'),
            SecretRedactor.removed,
          );
        },
      );

      test('known literal matching stays case-sensitive', () {
        final expectedKnown = injected ? SecretRedactor.removed : known;
        expect(redactor.redactText(known), expectedKnown);
        expect(formatError(known), expectedKnown);
        final differentCase = known.toLowerCase();
        expect(redactor.redactText(differentCase), differentCase);
        expect(formatError(differentCase), differentCase);
        expect(redactor.redactJson({'label': differentCase}), {
          'label': differentCase,
        });
      });
    });
  }

  test(
    'known short PAT labels are literal secrets, not a global case fold',
    () {
      const label = 'github_pat_demo';
      final redactor = SecretRedactor(knownSecrets: [label]);
      expect(redactor.redactText(label), SecretRedactor.removed);
      expect(redactor.redactJson({'label': label}), {
        'label': SecretRedactor.removed,
      });
      expect(
        redactor.redactUrl('https://provider.example/$label'),
        'https://provider.example/$removedPath',
      );
      expect(redactor.redactText(label.toUpperCase()), label.toUpperCase());
    },
  );

  test('PAT replacements do not rescan inserted markers for known secrets', () {
    final redactor = SecretRedactor(knownSecrets: ['REDACTED']);
    expect(redactor.redactText('$pat REDACTED'), '[REDACTED] [REDACTED]');
    expect(redactor.redactText('message="$pat"'), 'message="[REDACTED]"');
    expect(redactor.redactJson({'message': pat}), {
      'message': SecretRedactor.removed,
    });
    expect(
      redactor.redactUrl('https://provider.example/$pat'),
      'https://provider.example/$removedPath',
    );
  });

  test('existing token families retain their minimum suffix lengths', () {
    final redactor = SecretRedactor();
    for (final prefix in ['sk-', 'ghp_', 'gho_', 'ghu_', 'ghs_', 'ghr_']) {
      expect(redactor.redactText('$prefix${'x' * 7}'), '$prefix${'x' * 7}');
      expect(redactor.redactText('$prefix${'x' * 8}'), SecretRedactor.removed);
    }
    for (final entry in {'AIza': 30, 'hf_': 20}.entries) {
      final short = '${entry.key}${'x' * (entry.value - 1)}';
      expect(redactor.redactText(short), short);
      expect(
        redactor.redactText('${entry.key}${'x' * entry.value}'),
        SecretRedactor.removed,
      );
    }
    expect(redactor.redactText('eyJx.x.x'), SecretRedactor.removed);
    expect(redactor.redactText('eyJ.x.x'), 'eyJ.x.x');
  });
}
