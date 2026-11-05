import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/prompt_worker.dart';

String _echo(Object? input) => input as String;

void main() {
  late PromptWorker worker;
  late Directory fixture;

  setUp(() async {
    // Queue tests need no production tokenizer cache or application data.
    final base = Directory('${Directory.systemTemp.path}/opencode');
    await base.create(recursive: true);
    fixture = await base.createTemp('prompt-queue-test-');
    worker = await PromptWorker.createForTesting(appSupportPath: fixture.path);
    PromptWorker.requestTimeout = const Duration(milliseconds: 150);
  });

  tearDown(() async {
    worker.dispose();
    PromptWorker.requestTimeout = const Duration(seconds: 60);
    await fixture.delete(recursive: true);
  });

  test(
    'queued request survives active request timeout and worker restart',
    () async {
      final timedOut = worker.debugBlock(
        const Duration(milliseconds: 500),
        'slow',
      );
      final retained = worker.debugBlock(Duration.zero, 'retained');

      await expectLater(timedOut, throwsA(isA<TimeoutException>()));
      await expectLater(retained, completion('retained'));
    },
  );

  test(
    'foreground requests are dispatched before queued diagnostics',
    () async {
      PromptWorker.requestTimeout = const Duration(seconds: 2);
      final active = worker.debugBlock(
        const Duration(milliseconds: 100),
        'active',
      );
      final order = <String>[];
      final background = worker
          .debugBlock(Duration.zero, 'background')
          .then(order.add);
      final foreground = worker
          .debugBlock(
            Duration.zero,
            'foreground',
            priority: PromptWorkerPriority.foreground,
          )
          .then(order.add);

      await active;
      await Future.wait([background, foreground]);

      expect(order, ['foreground', 'background']);
    },
  );

  test(
    'timings label the job and separate queue wait without content',
    () async {
      PromptWorker.requestTimeout = const Duration(seconds: 2);
      final logs = <String>[];
      final previousPrint = debugPrint;
      debugPrint = (message, {wrapWidth}) {
        if (message != null) logs.add(message);
      };
      addTearDown(() => debugPrint = previousPrint);

      final active = worker.debugBlock(
        const Duration(milliseconds: 50),
        'active',
      );
      const content = 'synthetic-private-prompt';
      final queued = worker.runTokenized<String>(
        _echo,
        content,
        debugLabel: 'studio-final',
        payloadBytes: content.length,
      );
      await active;
      expect(await queued, content);

      final start = logs.singleWhere(
        (line) =>
            line.contains('start ') && line.contains('label=studio-final'),
      );
      final done = logs.singleWhere(
        (line) => line.contains('done ') && line.contains('label=studio-final'),
      );
      int milliseconds(String line, String key) =>
          int.parse(RegExp('$key=(\\d+)ms').firstMatch(line)!.group(1)!);
      expect(start, contains('priority=foreground'));
      expect(start, contains('cmd=runTokenized'));
      expect(milliseconds(start, 'queueWait'), greaterThan(0));
      expect(
        milliseconds(done, 'total'),
        milliseconds(start, 'queueWait') + milliseconds(done, 'took'),
      );
      expect(logs.join('\n'), isNot(contains(content)));
    },
  );
}
