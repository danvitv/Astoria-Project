import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

typedef ThemeScreenGuard = Future<T> Function<T>(Future<T> Function() body);

/// Scheduling only: the original fixture supplies its guards and scope owner.
final class ThemeScreenTurns {
  ThemeScreenTurns({required this.guarded, required this.active}) {
    addTearDown(() {
      _retired = true;
      for (final timer in _handoffs) {
        timer.cancel();
      }
      _handoffs.clear();
    });
  }

  final ThemeScreenGuard guarded;
  final bool Function() active;
  final _handoffs = <Timer>{};
  bool _retired = false;

  void _checkActive() {
    if (!active()) throw StateError('Requires original isolation scope.');
  }

  /// REAL work can finish after Flutter's last automatic FAKE microtask flush.
  /// Hand back once after runAsync and its REAL continuations have drained. This drains
  /// only queued microtasks: no timer advance, frame or operation completion.
  Future<T?> _runAsync<T>(
    WidgetTester tester,
    Future<T> Function() work,
  ) async {
    Zone? real;
    try {
      return await tester.runAsync(
        () => guarded(() {
          real = Zone.current;
          return work();
        }),
      );
    } finally {
      final zone = real;
      if (zone != null && !_retired) {
        late final Timer handoff;
        handoff = zone.createTimer(Duration.zero, () {
          _handoffs.remove(handoff);
          if (!_retired && tester.binding.inTest) {
            tester.binding.asyncBarrier();
          }
        });
        _handoffs.add(handoff);
      }
    }
  }

  /// Invoke exactly once in REAL, but never await an owned operation there.
  _Issued<T> _issue<T>(
    FutureOr<T> Function() issue, {
    required String label,
    void Function()? beforeIssue,
    void Function()? afterIssue,
    void Function(bool failed)? onObserved,
  }) {
    final box = _Issued<T>();
    try {
      _checkActive();
      beforeIssue?.call();
      box.issued = true;
      final original = issue();
      if (original is Future<T>) {
        box.pending = ThemeScreenSignal<T>(
          original,
          label,
          onObserved: onObserved,
        );
      } else {
        box.value = original;
        box.hasValue = true; // null / void is a successfully issued value.
      }
      afterIssue?.call();
    } catch (error, stack) {
      box.error = error;
      box.trace = stack;
    }
    return box; // Synchronous box, not a Future.value(original) wrapper.
  }

  Future<_Issued<T>> _issueTurn<T>(
    WidgetTester tester,
    _Issued<T> Function() body,
  ) async {
    _checkActive();
    final box = await _runAsync(tester, () async => body());
    _checkActive();
    if (box == null) {
      throw StateError('Original REAL issue did not return its box.');
    }
    if (box.error != null) Error.throwWithStackTrace(box.error!, box.trace!);
    if (!box.issued) throw StateError('Original operation was not issued.');
    return box;
  }

  Future<T> action<T>(WidgetTester tester, FutureOr<T> Function() issue) async {
    final box = await _issueTurn(
      tester,
      () => _issue(issue, label: 'owned action'),
    );
    _checkActive();
    final pending = box.pending;
    if (pending != null) return finish(tester, pending);
    if (!box.hasValue) {
      throw StateError('Original synchronous value was not retained.');
    }
    return box.value;
  }

  Future<ThemeScreenSignal<T>> signal<T>(
    WidgetTester tester,
    Future<T> Function() issue, {
    required String label,
    void Function()? beforeIssue,
    void Function()? afterIssue,
    void Function(bool failed)? onObserved,
  }) async {
    final box = await _issueTurn<T>(
      tester,
      () => _issue<T>(
        issue,
        label: label,
        beforeIssue: beforeIssue,
        afterIssue: afterIssue,
        onObserved: onObserved,
      ),
    );
    _checkActive();
    return box.pending!;
  }

  /// Independent REAL event: action -> finish must never recurse through action.
  Future<void> _realTurn(WidgetTester tester) =>
      _realAwait(tester, () => Future<void>.delayed(Duration.zero));

  Future<T> finish<T>(WidgetTester tester, ThemeScreenSignal<T> signal) async {
    _checkActive();
    for (var turn = 0; turn < 1024; turn++) {
      if (signal.done) return signal.result();
      await tester.pump(); // FAKE microtasks/frames, never inside runAsync.
      _checkActive();
      await _realTurn(tester);
      _checkActive();
    }
    if (signal.done) return signal.result();
    throw StateError(
      'Original ${signal.label} did not finish in 1024 owned turns.',
    );
  }

  /// Initial DB/cipher/FIFO/provider graph MUST finish fully in REAL before mount.
  Future<void> initialize(WidgetTester tester, Future<void> Function() work) =>
      _realAwait(tester, work);

  /// Await the actual tester Future, including its TestAsyncUtils guard closure.
  /// No fake pump is allowed until this distinct path has returned.
  Future<void> gesture(WidgetTester tester, Future<void> Function() work) =>
      _realAwait(tester, work);

  Future<void> _realAwait(
    WidgetTester tester,
    Future<void> Function() work,
  ) async {
    _checkActive();
    var issued = false;
    Object? failure;
    StackTrace? trace;
    await _runAsync(tester, () async {
      try {
        _checkActive();
        issued = true;
        await work();
        _checkActive();
      } catch (error, stack) {
        failure = error;
        trace = stack;
      }
    });
    _checkActive();
    if (failure != null) Error.throwWithStackTrace(failure!, trace!);
    if (!issued) throw StateError('Original REAL operation was not issued.');
  }
}

final class _Issued<T> {
  bool issued = false, hasValue = false;
  late T value;
  ThemeScreenSignal<T>? pending;
  Object? error;
  StackTrace? trace;
}

/// One observer on the EXACT original Future; original errors/stacks are retained.
final class ThemeScreenSignal<T> {
  ThemeScreenSignal(
    this.original,
    this.label, {
    void Function(bool failed)? onObserved,
  }) {
    unawaited(
      original.then<void>(
        (value) {
          _value = value;
          done = true;
          onObserved?.call(false);
        },
        onError: (Object error, StackTrace trace) {
          _error = error;
          _trace = trace;
          done = true;
          onObserved?.call(true);
        },
      ),
    );
  }
  final Future<T> original;
  final String label;
  bool done = false;
  late T _value;
  Object? _error;
  StackTrace? _trace;
  T result() {
    if (_error != null) Error.throwWithStackTrace(_error!, _trace!);
    return _value;
  }
}
