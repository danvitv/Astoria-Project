import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';

final class SupportReportCliArguments {
  SupportReportCliArguments._(this.command, this.options);
  final String command;
  final Map<String, String> options;
  static SupportReportCliArguments parse(List<String> args) {
    Never bad() => throw const SupportReportException(
      SupportReportFailure.invalidArguments,
    );
    if (args.isEmpty || !const ['keygen', 'decode'].contains(args.first)) bad();
    final expected = args.first == 'keygen'
        ? const {'--private', '--public', '--key-id'}
        : const {'--private', '--public', '--input'};
    if (args.length != 7) bad();
    final map = <String, String>{};
    for (var i = 1; i < args.length; i += 2) {
      if (!expected.contains(args[i]) ||
          map.containsKey(args[i]) ||
          args[i + 1].isEmpty ||
          args[i + 1].length > 4096 ||
          args[i + 1].contains('\u0000')) {
        bad();
      }
      map[args[i]] = args[i + 1];
    }
    if (!map.keys.toSet().containsAll(expected)) bad();
    if (args.first == 'keygen' &&
        !SupportReportRecipient.validKeyId(map['--key-id']!)) {
      bad();
    }
    return SupportReportCliArguments._(args.first, Map.unmodifiable(map));
  }
}
