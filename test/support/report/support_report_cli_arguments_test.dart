import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import '../../../tool/support_report_cli/arguments.dart';

void main() {
  test(
    'CLI accepts file custody paths but no private key material options',
    () {
      final args = SupportReportCliArguments.parse([
        'keygen',
        '--private',
        r'C:\synthetic\private.key',
        '--public',
        r'C:\synthetic\public.json',
        '--key-id',
        'synthetic-1',
      ]);
      expect(args.command, 'keygen');
      expect(args.options.containsKey('--secret'), isFalse);
    },
  );
  test(
    'unknown, duplicate, missing options and accidental key material fail without echo',
    () {
      for (final args in <List<String>>[
        [],
        ['keygen', '--secret', 'never-print-this-canary'],
        ['decode', '--private', 'a', '--public', 'b', '--public', 'c'],
        [
          'keygen',
          '--private',
          'a',
          '--public',
          'b',
          '--key-id',
          'unsafe label',
        ],
      ]) {
        try {
          SupportReportCliArguments.parse(args);
          fail('Expected refusal');
        } on SupportReportException catch (e) {
          expect(e.toString(), isNot(contains('never-print-this-canary')));
          expect(e.failure, SupportReportFailure.invalidArguments);
        }
      }
    },
  );
}
