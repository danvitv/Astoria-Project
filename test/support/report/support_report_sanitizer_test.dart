import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/features/support_assistant/services/report/support_report_sanitizer.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';

void main() {
  test(
    'known secrets and structural credentials are stripped including nested JSON strings',
    () {
      final sanitizer = SupportReportSanitizer(
        SecretRedactor(knownSecrets: ['synthetic-canary-token']),
      );
      final safe = sanitizer.sanitize({
        'text': 'Bearer synthetic-canary-token',
        'nested': {
          'apiKey': 'unknown-canary-credential',
          'message': 'ordinary prose',
        },
        'encoded': jsonEncode({
          'authorization': 'another-canary-credential',
          'text': 'synthetic-canary-token',
        }),
      });
      final json = jsonEncode(safe);
      expect(json, isNot(contains('synthetic-canary-token')));
      expect(json, isNot(contains('unknown-canary-credential')));
      expect(json, isNot(contains('another-canary-credential')));
      expect(json, contains('ordinary prose'));
    },
  );
  test(
    'unregistered structured auth vault authority and custody are excluded in personal JSON and JSON strings',
    () {
      final sanitizer = SupportReportSanitizer(SecretRedactor());
      final protected = {
        'auth': 'AUTH_CANARY',
        'vault': {'key': 'VAULT_CANARY'},
        'authority': {'owner': 'OWNER_CANARY', 'receipt': 'RECEIPT_CANARY'},
        'rowId': 'ROW_CANARY',
        'sourceHash': 'HASH_CANARY',
        'text': 'Ordinary commentary',
        'settings': [
          {'Key': 'Authorization', 'Value': 'ALIASED_CANARY'},
          {'na-me': 'vault', 'value': 'NAMED_CANARY'},
        ],
      };
      final safe = jsonEncode(
        sanitizer.sanitize({
          'content': protected,
          'encoded': jsonEncode({
            'content': jsonEncode(protected),
            'text': 'Nested commentary',
          }),
        }),
      );
      for (final canary in [
        'AUTH',
        'VAULT',
        'OWNER',
        'RECEIPT',
        'ROW',
        'HASH',
        'ALIASED',
        'NAMED',
      ]) {
        expect(safe, isNot(contains('${canary}_CANARY')));
      }
      expect(safe, contains('Ordinary commentary'));
      expect(safe, contains('Nested commentary'));
    },
  );
  test('JSON strings cannot reset the shared structural depth budget', () {
    Object nested = {'auth': 'BUDGET_AUTH_CANARY', 'text': 'ordinary'};
    for (var i = 0; i < 9; i++) {
      nested = {'content': jsonEncode(nested)};
    }
    expect(
      () => SupportReportSanitizer(SecretRedactor()).sanitize(nested),
      throwsA(isA<SupportReportException>()),
    );
  });
  test(
    'JSON string wrappers receive the same structural policy and shared budget',
    () {
      final sanitizer = SupportReportSanitizer(SecretRedactor());
      final structured = {
        'apiKey': 'UNREGISTERED_CANARY',
        'auth': {'owner': 'OWNER_CANARY'},
        'text': 'Visible wrapped commentary',
      };
      final safe = jsonEncode(
        sanitizer.sanitize({'text': jsonEncode(jsonEncode(structured))}),
      );
      expect(safe, isNot(contains('UNREGISTERED_CANARY')));
      expect(safe, isNot(contains('OWNER_CANARY')));
      expect(safe, contains('Visible wrapped commentary'));
      var wrapped = jsonEncode(structured);
      for (var i = 0; i < 18; i++) {
        wrapped = jsonEncode(wrapped);
      }
      expect(
        () => sanitizer.sanitize({'text': wrapped}),
        throwsA(isA<SupportReportException>()),
      );
    },
  );
  test(
    'unknown personal prose remains personal, not claimed universally safe',
    () {
      final sanitizer = SupportReportSanitizer(SecretRedactor());
      expect(
        sanitizer.sanitize('A personal fictional scene.'),
        'A personal fictional scene.',
      );
    },
  );
}
