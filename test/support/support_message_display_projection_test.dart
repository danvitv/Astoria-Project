import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_message_display_projection.dart';

const _canary = 'SYNTHETIC_DISPLAY_🔐_"\\_CANARY';
const _unavailable =
    'Текст сообщения недоступен: не удалось безопасно отобразить.';
const _tooLong = 'Текст сообщения недоступен: превышен лимит длины.';

final class _UnformattableError implements Exception {
  bool formatted = false;

  @override
  String toString() {
    formatted = true;
    throw StateError('Arbitrary error formatting must not run.');
  }
}

void main() {
  test('fixed labels and inclusive display allowance are exact', () {
    expect(SupportMessageDisplayProjection.maxTextLength, 65536);
    expect(SupportMessageDisplayProjection.tooLong, _tooLong);
    expect(SupportMessageDisplayProjection.unavailable, _unavailable);
  });

  for (final unicode in [false, true]) {
    test('exact 65536 UTF16 ${unicode ? 'Unicode' : 'ASCII'} is intact', () {
      final body = unicode ? '🧪' * 32768 : 'x' * 65536;
      final diagnostic = SecretRedactor();
      expect(body.length, 65536);
      expect(diagnostic.redactText(body), SecretRedactor.limited);
      final display = SupportMessageDisplayProjection(redactor: diagnostic);
      expect(display.project(body), body);
      expect(diagnostic.maxOutputLength, 8192);
      expect(diagnostic.redactText(body), SecretRedactor.limited);
    });

    test('65537 UTF16 ${unicode ? 'Unicode' : 'ASCII'} refuses whole body', () {
      final body = unicode ? '${'🧪' * 32768}x' : 'x' * 65537;
      final display = SupportMessageDisplayProjection(
        redactor: SecretRedactor(knownSecrets: ['x']),
      );
      expect(body.length, 65537);
      expect(display.project(body), _tooLong);
    });
  }

  test('scoped feed limits do not retain smaller diagnostic text budgets', () {
    final diagnostic = SecretRedactor(
      knownSecrets: ['SYNTHETIC_KNOWN'],
      maxInputLength: 32,
      maxOutputLength: 32,
    );
    final body = '${'p' * 10000} SYNTHETIC_KNOWN';
    final display = SupportMessageDisplayProjection(redactor: diagnostic);
    expect(display.project(body), '${'p' * 10000} [REDACTED]');
    expect(diagnostic.maxInputLength, 32);
    expect(diagnostic.maxOutputLength, 32);
    expect(diagnostic.redactText(body), SecretRedactor.limited);
  });

  test(
    'known values and encoded variants use the injected immutable policy',
    () {
      final display = SupportMessageDisplayProjection(
        redactor: SecretRedactor(knownSecrets: [_canary]),
      );
      for (final value in [
        _canary,
        Uri.encodeComponent(_canary),
        Uri.encodeFull(_canary),
        jsonEncode(_canary).substring(1, jsonEncode(_canary).length - 1),
        base64Encode(utf8.encode(_canary)),
        base64UrlEncode(utf8.encode(_canary)),
      ]) {
        expect(
          display.project('before $value after'),
          'before [REDACTED] after',
        );
      }
    },
  );

  test(
    'a new projection covers new credentials without mutating old snapshots',
    () {
      final original = SecretRedactor(knownSecrets: ['SYNTHETIC_OLD']);
      final oldDisplay = SupportMessageDisplayProjection(redactor: original);
      final newest = original.withKnownSecrets(['SYNTHETIC_NEW']);
      final newDisplay = SupportMessageDisplayProjection(redactor: newest);
      const body = 'SYNTHETIC_OLD SYNTHETIC_NEW';
      expect(oldDisplay.project(body), '[REDACTED] SYNTHETIC_NEW');
      expect(newDisplay.project(body), '[REDACTED] [REDACTED]');
      expect(oldDisplay.project(body), '[REDACTED] SYNTHETIC_NEW');
      expect(original.redactText(body), '[REDACTED] SYNTHETIC_NEW');
    },
  );

  test('generic URL and JSON changes have explicit safe goldens', () {
    final display = SupportMessageDisplayProjection(redactor: SecretRedactor());
    expect(
      display.project(
        'before https://user:UNKNOWN@example.invalid/path?q=UNKNOWN#UNKNOWN after',
      ),
      'before https://example.invalid/path after',
    );
    expect(
      display.project(
        '{ "message": "ordinary", "password": "UNKNOWN", '
        '"endpoint": "https://user:UNKNOWN@example.invalid/p?q=UNKNOWN#UNKNOWN" }',
      ),
      '{"message":"ordinary","password":"[REDACTED]",'
      '"endpoint":"https://example.invalid/p"}',
    );
    expect(display.project('file:///synthetic/UNKNOWN'), '[REDACTED]');
    expect(
      display.project('[IMG:https://example.invalid/image.png]'),
      '[IMG:https://example.invalid/image.png%5D',
    );
  });

  test(
    'emphasis, backticks, controls and Unicode stay text after sanitation',
    () {
      final display = SupportMessageDisplayProjection(
        redactor: SecretRedactor(knownSecrets: [_canary]),
      );
      expect(
        display.project('**bold** *italic*\n\t\r🧪\u200d`$_canary`'),
        '**bold** *italic*\n\t\r🧪\u200d`[REDACTED]`',
      );
      expect(display.project(''), '');
    },
  );

  test('raw error-shaped strings are sanitized, never a raw fallback', () {
    final display = SupportMessageDisplayProjection(
      redactor: SecretRedactor(knownSecrets: [_canary]),
    );
    expect(
      display.project('Failure ($_canary)\nAuthorization: Bearer UNKNOWN'),
      'Failure ([REDACTED])\nAuthorization: [REDACTED]',
    );
    final error = _UnformattableError();
    expect(
      () => (display as dynamic).project(error),
      throwsA(isA<TypeError>()),
    );
    expect(error.formatted, isFalse);
  });

  test('closed secret-count policy stays closed under raised feed limits', () {
    final closed = SecretRedactor(knownSecrets: List.filled(257, ''));
    final display = SupportMessageDisplayProjection(redactor: closed);
    for (final body in ['', 'safe', _canary, 'x' * 65536]) {
      expect(display.project(body), _unavailable);
    }
    expect(display.project('x' * 65537), _tooLong);
    expect(closed.redactText('safe'), SecretRedactor.limited);
  });

  test(
    'oversize registered secret cannot reopen through scoped input limits',
    () {
      final closed = SecretRedactor(
        knownSecrets: ['x' * 33],
        maxInputLength: 32,
      );
      final display = SupportMessageDisplayProjection(redactor: closed);
      expect(display.project('safe x'), _unavailable);
    },
  );

  test(
    'throwing secret enumeration is consumed once, with no error formatting',
    () {
      final error = _UnformattableError();
      var enumerations = 0;
      Iterable<String> secrets() sync* {
        enumerations++;
        yield _canary;
        throw error;
      }

      final closed = SecretRedactor(knownSecrets: secrets());
      final display = SupportMessageDisplayProjection(redactor: closed);
      expect(display.project('Failure $_canary'), _unavailable);
      expect(display.project('plain'), _unavailable);
      expect(enumerations, 1);
      expect(error.formatted, isFalse);
    },
  );

  test('projection has no credential or policy getter', () {
    final dynamic display = SupportMessageDisplayProjection(
      redactor: SecretRedactor(knownSecrets: [_canary]),
    );
    expect(() => display.knownSecrets, throwsA(isA<NoSuchMethodError>()));
    expect(() => display.redactor, throwsA(isA<NoSuchMethodError>()));
    expect(() => display.apiKey, throwsA(isA<NoSuchMethodError>()));
  });

  test(
    'nested depth exhaustion rejects whole JSON, not its partial safe text',
    () {
      final policy = SecretRedactor(maxDepth: 1);
      const body = '{"safe":"ordinary","nested":{"leaf":"value"}}';
      final partial = policy.redactText(body);
      expect(partial, contains('ordinary'));
      expect(partial, contains(SecretRedactor.limited));
      expect(
        SupportMessageDisplayProjection(redactor: policy).project(body),
        _unavailable,
      );
    },
  );

  test(
    'node exhaustion and literal limit markers never become partial paint',
    () {
      final display = SupportMessageDisplayProjection(
        redactor: SecretRedactor(maxNodes: 2),
      );
      expect(display.project('[1,2,3]'), _unavailable);
      for (final body in [
        SecretRedactor.limited,
        'before ${SecretRedactor.limited} after',
        '{"safe":"ordinary","note":"${SecretRedactor.limited}"}',
      ]) {
        expect(display.project(body), _unavailable);
      }
    },
  );

  test(
    'marker expansion admits 65536 but rejects 65540 output units whole',
    () {
      final display = SupportMessageDisplayProjection(
        redactor: SecretRedactor(knownSecrets: ['x']),
      );
      final admitted = '${'[REDACTED]' * 6553}......';
      expect(admitted.length, 65536);
      expect(display.project('${'x' * 6553}......'), admitted);
      expect(display.project('x' * 6554), _unavailable);
      expect(display.project('x' * 65536), _unavailable);
    },
  );

  test(
    'URL percent-encoding expansion cannot exceed the whole display budget',
    () {
      const prefix = 'https://example.invalid/';
      final body = '$prefix${'🧪' * ((65536 - prefix.length) ~/ 2)}';
      expect(body.length, lessThanOrEqualTo(65536));
      final display = SupportMessageDisplayProjection(
        redactor: SecretRedactor(),
      );
      expect(display.project(body), _unavailable);
    },
  );

  test(
    'adversarial exact-boundary named suffix is sanitized without clipping',
    () {
      const suffix = ' password=SYNTHETIC_UNKNOWN';
      final prefix = 'a' * (65536 - suffix.length);
      final body = '$prefix$suffix';
      expect(body.length, 65536);
      final display = SupportMessageDisplayProjection(
        redactor: SecretRedactor(),
      );
      expect(display.project(body), '$prefix password="[REDACTED]"');
      expect(display.project('${body}x'), _tooLong);
    },
  );

  test('adversarial exact-boundary unsupported scheme is fixed redaction', () {
    const tail = '://user:UNKNOWN@example.invalid?q=UNKNOWN';
    final body = '${'a' * (65536 - tail.length)}$tail';
    final display = SupportMessageDisplayProjection(redactor: SecretRedactor());
    expect(body.length, 65536);
    expect(display.project(body), '[REDACTED]');
    expect(display.project('${body}x'), _tooLong);
  });

  test(
    'full 256-value policy admits boundary near-matches and a final known value',
    () {
      final policy = SecretRedactor(
        knownSecrets: List.generate(256, (index) => '${'a' * 128}${index}b'),
      );
      final display = SupportMessageDisplayProjection(redactor: policy);
      final near = 'a' * 65536;
      expect(display.project(near), near);
      final known = '${'a' * 128}255b';
      final prefix = 'a' * (65536 - known.length);
      expect(display.project('$prefix$known'), '$prefix[REDACTED]');
      expect(display.project('${near}a'), _tooLong);
    },
  );
}
