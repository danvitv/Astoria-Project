import 'dart:async';
import 'dart:isolate';

import 'package:glaze_flutter/core/credentials/secret_redactor.dart';

import 'legacy_redaction_reference.dart';

final class RedactionCase {
  const RedactionCase(
    this.text, {
    this.knownSecrets = const [],
    this.maxInputLength = 65536,
    this.maxOutputLength = 65536,
    this.url = false,
    this.beforeFix = false,
  });

  final String text;
  final List<String> knownSecrets;
  final int maxInputLength;
  final int maxOutputLength;
  final bool url;
  // Optional parent-only comparison, never selected by the regression suite.
  final bool beforeFix;
}

/// Pure synthetic jobs only. A timer in the receiving isolate can interrupt a
/// synchronous matcher loop by killing ONLY the isolate created here. No
/// process, application owner, DB, plugin, network or environment access.
Future<List<String>> redactWithWatchdog(List<RedactionCase> cases) async {
  final replies = ReceivePort();
  Isolate? owned;
  try {
    owned = await Isolate.spawn(
      _redactBatch,
      (replies.sendPort, cases),
      onError: replies.sendPort,
      onExit: replies.sendPort,
      errorsAreFatal: true,
      debugName: 'synthetic-redaction-watchdog',
    );
    final result = await replies.first.timeout(
      const Duration(seconds: 12),
      onTimeout: () => throw TimeoutException(
        'Synthetic redaction exceeded the broad 12-second watchdog',
      ),
    );
    if (result is! (List<String>,)) {
      throw StateError('Synthetic redaction isolate did not return results');
    }
    return result.$1;
  } finally {
    owned?.kill(priority: Isolate.immediate);
    replies.close();
  }
}

void _redactBatch((SendPort, List<RedactionCase>) job) {
  final results = <String>[];
  for (final fixture in job.$2) {
    final redactor = SecretRedactor(
      knownSecrets: fixture.knownSecrets,
      maxInputLength: fixture.maxInputLength,
      maxOutputLength: fixture.maxOutputLength,
    );
    if (fixture.beforeFix) {
      // The frozen reference is plain-text only. Long comparisons belong only
      // in this owned isolate, never in a test runner or application isolate.
      final original = fixture.text.length > fixture.maxInputLength
          ? SecretRedactor.limited
          : legacyRedactPlain(fixture.text, fixture.knownSecrets);
      results.add(
        original.length > fixture.maxOutputLength
            ? SecretRedactor.limited
            : original,
      );
    } else {
      results.add(
        fixture.url
            ? redactor.redactUrl(fixture.text)
            : redactor.redactText(fixture.text),
      );
    }
  }
  Isolate.exit(job.$1, (results,));
}
