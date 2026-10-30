import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_queue.dart';

void main() {
  test('Abort/Reset cannot give a retry the newer queue generation', () async {
    final queue = SyncQueue();
    final attempted = Completer<void>();
    var calls = 0;
    final pending = queue.enqueue(() async {
      calls++;
      if (!attempted.isCompleted) attempted.complete();
      throw Exception('503');
    });
    final rejected = expectLater(pending, throwsStateError);
    await attempted.future;
    queue.abort();
    queue.reset();
    await rejected;
    expect(calls, 1);
    expect(queue.pendingCount, 0);
    expect(await queue.enqueue(() async => 'new work'), 'new work');
    expect(queue.pendingCount, 0);
  });

  test(
    'an old batch cannot schedule its remaining task after Abort/Reset',
    () async {
      final queue = SyncQueue();
      final started = Completer<void>();
      final finish = Completer<void>();
      var remainingCalls = 0;
      final pending = queue.enqueueAll(
        [
          () async {
            started.complete();
            await finish.future;
          },
          () async {
            remainingCalls++;
          },
        ],
        concurrency: 1,
        delayMs: 0,
      );
      final rejected = expectLater(pending, throwsStateError);
      await started.future;
      queue.abort();
      queue.reset();
      finish.complete();
      await rejected;
      expect(remainingCalls, 0);
      expect(queue.pendingCount, 0);
    },
  );

  test('Reset also invalidates a task paused before execution', () async {
    final queue = SyncQueue()..pause();
    var called = false;
    final pending = queue.enqueue(() async {
      called = true;
    });
    final rejected = expectLater(pending, throwsStateError);
    queue.reset();
    await rejected;
    expect(called, isFalse);
  });
}
