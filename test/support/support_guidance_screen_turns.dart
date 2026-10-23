import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

typedef GuidanceGuard = Future<T> Function<T>(Future<T> Function() work);

/// Only schedules/observes ORIGINAL futures. Never completes a held job for it.
final class GuidanceScreenTurns {
  GuidanceScreenTurns(this.guard);
  final GuidanceGuard guard;

  Future<T> real<T>(WidgetTester tester, Future<T> Function() work) async {
    late T value;
    var completed = false;
    Object? error;
    StackTrace? trace;
    // Await the ORIGINAL work, including enterText's nested tester/binding idle
    // scopes, before returning from runAsync. A detached timer must never call
    // asyncBarrier: it verifies ALL test scopes and can falsely retire another
    // correctly awaited gesture. Queue driving belongs to the explicit pump /
    // REAL-event loop below, not an out-of-band scope-verification callback.
    await tester.runAsync(
      () => guard(() async {
        try {
          value = await work();
          completed = true;
        } catch (failure, stack) {
          error = failure;
          trace = stack;
        }
      }),
    );
    if (error != null) Error.throwWithStackTrace(error!, trace!);
    if (!completed) {
      throw StateError('Original guarded REAL work did not finish.');
    }
    return value;
  }

  Future<void> until(
    WidgetTester tester,
    bool Function() reached, {
    required String label,
    GuidanceJob<dynamic>? original,
  }) async {
    for (var turn = 0; turn < 100; turn++) {
      if (reached()) return;
      if (original?.done == true) {
        original!.result();
        throw StateError('Original $label settled before its gate.');
      }
      await tester.pump(const Duration(milliseconds: 16));
      await real(tester, () => Future<void>.delayed(Duration.zero));
    }
    expect(reached(), isTrue, reason: '100 dual-queue frames: $label');
  }

  Future<GuidanceJob<T>> issue<T>(
    WidgetTester tester,
    Future<T> Function() work,
  ) => real(tester, () async => GuidanceJob(work()));

  Future<T> join<T>(WidgetTester tester, Future<T> Function() work) async {
    final job = await issue(tester, work);
    await until(tester, () => job.done, label: 'original job settlement');
    return job.result();
  }
}

final class GuidanceJob<T> {
  GuidanceJob(this.original) {
    unawaited(
      original.then<void>(
        (value) {
          _value = value;
          done = true;
        },
        onError: (Object error, StackTrace trace) {
          _error = error;
          _trace = trace;
          done = true;
        },
      ),
    );
  }
  final Future<T> original;
  bool done = false;
  late T _value;
  Object? _error;
  StackTrace? _trace;
  T result() {
    if (!done) throw StateError('Original job has not settled.');
    if (_error != null) Error.throwWithStackTrace(_error!, _trace!);
    return _value;
  }
}
