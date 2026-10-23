import 'dart:async';
import 'dart:convert';
import 'dart:io';

// The installed Flutter test scheduler already depends on fake_async. This
// bounded scheduling probe uses that SAME package; it adds no dependency.
// ignore: depend_on_referenced_packages
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support_theme_screen_fixture.dart';
import 'support_theme_screen_isolation.dart';
import 'support_theme_screen_turns.dart';

void main() {
  test(
    'completed FAKE source after REAL event starves until actual microtask flush',
    () async {
      final fake = FakeAsync();
      late Future<int> original;
      var resumed = false, timerFired = false;
      fake.run((_) {
        original = Future<int>.syncValue(7);
        Timer(Duration.zero, () => timerFired = true);
      });
      final entered =
          Completer<void>(); // Ambient test zone, not a new error zone.
      final pending = () async {
        await Future<void>.delayed(Duration.zero);
        entered.complete();
        final value = await original;
        resumed = true;
        return value;
      }();
      try {
        await entered.future;
        expect(resumed, isFalse);
        expect(fake.microtaskCount, greaterThan(0));
        expect(fake.nonPeriodicTimerCount, 1);
        expect(timerFired, isFalse);
        fake.flushMicrotasks();
        expect(await pending, 7);
        expect(resumed, isTrue);
        expect(timerFired, isFalse);
        expect(fake.microtaskCount, 0);
        expect(fake.nonPeriodicTimerCount, 1);
        fake.elapse(Duration.zero);
        expect(timerFired, isTrue);
        expect(fake.microtaskCount, 0);
        expect(fake.pendingTimers, isEmpty);
      } finally {
        await entered.future;
        fake.flushMicrotasks();
        fake.elapse(Duration.zero);
        await pending; // Drain the ACTUAL suspended operation, even after failure.
      }
    },
  );

  test(
    'zero FAKE timer is independent of completed-source microtask delivery',
    () {
      final fake = FakeAsync();
      late ThemeScreenSignal<void> signal;
      var fired = false;
      fake.run((_) {
        final original = Future<void>.delayed(
          Duration.zero,
          () => fired = true,
        );
        signal = ThemeScreenSignal(original, 'independent zero FAKE timer');
      });
      try {
        fake.flushMicrotasks();
        expect(fired, isFalse);
        expect(signal.done, isFalse);
        expect(fake.microtaskCount, 0);
        expect(fake.nonPeriodicTimerCount, 1);
        fake.elapse(Duration.zero);
        expect(fired, isTrue);
        expect(signal.done, isTrue);
        signal.result();
        expect(fake.pendingTimers, isEmpty);
        expect(fake.microtaskCount, 0);
      } finally {
        fake.elapse(Duration.zero);
        fake.flushMicrotasks();
        signal.result();
      }
    },
  );

  _noDbTurnsTest(
    'boxed action completes original FAKE source after REAL event exactly once',
    (tester, turns, isolation) async {
      final completedFake = Future<int>.syncValue(7);
      late Future<int> original;
      var calls = 0, entered = false, resumed = false;
      final value = await turns.action(tester, () {
        calls++;
        original = () async {
          await Future<void>.delayed(Duration.zero);
          entered = true;
          final value = await completedFake;
          resumed = true;
          return value;
        }();
        return original;
      });
      expect(value, 7);
      expect(calls, 1);
      expect(entered, isTrue);
      expect(resumed, isTrue);
      expect(await original, 7);
    },
  );

  _noDbTurnsTest('signal observes exact pending FAKE microtask Future once', (
    tester,
    turns,
    isolation,
  ) async {
    var calls = 0, observations = 0;
    final original = Future<int>.microtask(() => 11);
    final signal = await turns.signal(
      tester,
      () {
        calls++;
        return original;
      },
      label: 'pending FAKE microtask',
      onObserved: (failed) {
        expect(failed, isFalse);
        observations++;
      },
    );
    expect(signal.original, same(original));
    expect(await turns.finish(tester, signal), 11);
    expect(calls, 1);
    expect(observations, 1);
  });

  _noDbTurnsTest('boxed action completes original REAL event Future', (
    tester,
    turns,
    isolation,
  ) async {
    var calls = 0;
    expect(
      await turns.action(tester, () {
        calls++;
        return Future<int>.delayed(Duration.zero, () => 13);
      }),
      13,
    );
    expect(calls, 1);
  });

  _noDbTurnsTest(
    'boxed scalar nullable and synchronous void values retain issued discriminant',
    (tester, turns, isolation) async {
      var calls = 0;
      expect(
        await turns.action(tester, () {
          calls++;
          return 17;
        }),
        17,
      );
      expect(
        await turns.action<int?>(tester, () {
          calls++;
          return null;
        }),
        isNull,
      );
      await turns.action<void>(tester, () {
        calls++;
      });
      expect(calls, 3);
    },
  );

  _noDbTurnsTest(
    'boxed synchronous throw retains original error stack and one invocation',
    (tester, turns, isolation) async {
      final failure = StateError('SYNTHETIC_SYNC_ERROR');
      final trace = StackTrace.fromString('SYNTHETIC_ORIGINAL_SYNC_STACK');
      var calls = 0;
      try {
        await turns.action<int>(tester, () {
          calls++;
          Error.throwWithStackTrace(failure, trace);
        });
        fail('Original synchronous error must be rethrown.');
      } catch (error, stack) {
        expect(error, same(failure));
        expect(stack.toString(), trace.toString());
      }
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  _noDbTurnsTest(
    'single original observer retains asynchronous error and original stack',
    (tester, turns, isolation) async {
      final failure = StateError('SYNTHETIC_ASYNC_ERROR');
      final trace = StackTrace.fromString('SYNTHETIC_ORIGINAL_ASYNC_STACK');
      late Future<int> original;
      var calls = 0, observations = 0;
      final signal = await turns.signal(
        tester,
        () {
          calls++;
          original = () async {
            await Future<void>.delayed(Duration.zero);
            Error.throwWithStackTrace(failure, trace);
          }();
          return original;
        },
        label: 'original async error',
        onObserved: (failed) {
          expect(failed, isTrue);
          observations++;
        },
      );
      expect(signal.original, same(original));
      try {
        await turns.finish(tester, signal);
        fail('Original asynchronous error must be rethrown.');
      } catch (error, stack) {
        expect(error, same(failure));
        expect(stack.toString(), trace.toString());
      }
      expect(calls, 1);
      expect(observations, 1);
      expect(tester.takeException(), isNull);
    },
  );

  _noDbTurnsTest(
    'boxed action externally rethrows original asynchronous error stack exactly once',
    (tester, turns, isolation) async {
      final failure = StateError('SYNTHETIC_ACTION_ASYNC_ERROR');
      final trace = StackTrace.fromString(
        'SYNTHETIC_ACTION_ORIGINAL_ASYNC_STACK',
      );
      var calls = 0;
      try {
        await turns.action<int>(tester, () {
          calls++;
          return () async {
            await Future<void>.delayed(Duration.zero);
            Error.throwWithStackTrace(failure, trace);
          }();
        });
        fail('Original asynchronous action error must be rethrown.');
      } catch (error, stack) {
        expect(error, same(failure));
        expect(stack.toString(), trace.toString());
      }
      expect(calls, 1);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'owned scope denies before issue and after original awaited completion',
    (tester) async {
      final isolation = ThemeScreenIsolation();
      var active = false, calls = 0;
      final turns = ThemeScreenTurns(
        guarded: isolation.guarded,
        active: () => active,
      );
      await isolation.run(() async {
        await expectLater(
          turns.action(tester, () {
            calls++;
            return 7;
          }),
          throwsStateError,
        );
        expect(calls, 0);
        active = true;
        late Future<int> original;
        try {
          await expectLater(
            turns.action(tester, () {
              calls++;
              original = () async {
                await Future<void>.delayed(Duration.zero);
                active =
                    false; // THIS test owns its predicate, not fixture internals.
                return 7;
              }();
              return original;
            }),
            throwsStateError,
          );
        } finally {
          await tester.pump();
          expect(await original, 7);
        }
        expect(active, isFalse);
        expect(calls, 1);
        expect(tester.takeException(), isNull);
      });
    },
  );

  for (final boundary in ['file', 'HTTP', 'socket']) {
    testWidgets(
      'same guarded $boundary denial before issue after await and through cleanup',
      (tester) async {
        final isolation = ThemeScreenIsolation();
        var active = true;
        final turns = ThemeScreenTurns(
          guarded: isolation.guarded,
          active: () => active,
        );
        final expected = switch (boundary) {
          'file' => 'file/default DB',
          'HTTP' => 'HTTP/model construction',
          _ => 'socket.connect',
        };
        FutureOr<void> denied() => switch (boundary) {
          'file' => () {
            File('SYNTHETIC_NEVER_CREATED');
          }(),
          'HTTP' => () {
            HttpClient();
          }(),
          _ => Socket.connect('synthetic.invalid', 1),
        };
        // Expected tripwires are retained, not removed to satisfy isolation.run's
        // zero-attempt success contract. No provider, DB, or native call is issued.
        await isolation.guarded(() async {
          await expectLater(
            turns.action<void>(tester, denied),
            throwsStateError,
          );
          await expectLater(
            turns.action<void>(tester, () async {
              await Future<void>.delayed(Duration.zero);
              await denied();
            }),
            throwsStateError,
          );
          expect(await turns.action(tester, () => 19), 19);
          try {
            // Original-scope cleanup remains guarded and active after an await.
            await expectLater(
              turns.action<void>(tester, () async {
                await Future<void>.delayed(Duration.zero);
                await denied();
              }),
              throwsStateError,
            );
          } finally {
            active = false;
          }
          expect(isolation.attempts, [expected, expected, expected]);
          expect(tester.takeException(), isNull);
        });
      },
    );
  }

  _noDbTurnsTest(
    'fully REAL initialization and actual tester tap drag guards close before FAKE pumps',
    (tester, turns, isolation) async {
      var initialized = false, taps = 0, drag = 0.0;
      await turns.initialize(tester, () async {
        await Future<void>.delayed(Duration.zero);
        initialized = true;
      });
      expect(initialized, isTrue);
      const target = ValueKey('owned-no-db-gesture');
      await tester.pumpWidget(
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: GestureDetector(
              key: target,
              behavior: HitTestBehavior.opaque,
              onTap: () => taps++,
              onPanUpdate: (details) => drag += details.delta.dy,
              child: const SizedBox(width: 180, height: 180),
            ),
          ),
        ),
      );
      late Future<void> originalTap, originalDrag;
      var tapFinished = false, dragFinished = false;
      await turns.gesture(tester, () async {
        originalTap = tester.tap(find.byKey(target));
        await originalTap;
        tapFinished = true;
      });
      expect(tapFinished, isTrue);
      TestAsyncUtils.guardSync();
      await tester.pump();
      expect(taps, 1);
      await turns.gesture(tester, () async {
        originalDrag = tester.dragFrom(
          tester.getCenter(find.byKey(target)),
          const Offset(0, -60),
        );
        await originalDrag;
        dragFinished = true;
      });
      expect(dragFinished, isTrue);
      TestAsyncUtils.guardSync();
      await tester.pump();
      expect(drag, lessThan(0));
      expect(taps, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      await turns.action<void>(
        tester,
        () {},
      ); // Guarded original-scope cleanup.
      TestAsyncUtils.guardSync();
      expect(tester.takeException(), isNull);
    },
  );

  _noDbTurnsTest(
    'actual FAKE zero timer needs explicit zero elapse not microtask-only pump',
    (tester, turns, isolation) async {
      var fired = false;
      final original = Future<void>.delayed(Duration.zero, () => fired = true);
      final signal = await turns.signal(
        tester,
        () => original,
        label: 'actual FAKE zero timer',
      );
      try {
        expect(signal.original, same(original));
        await tester.pump();
        expect(fired, isFalse);
        expect(signal.done, isFalse);
        await tester.pump(
          Duration.zero,
        ); // Separate explicit affordance, NOT driver policy.
        expect(fired, isTrue);
        expect(signal.done, isTrue);
        await turns.finish(tester, signal);
      } finally {
        await tester.pump(Duration.zero);
        await turns.finish(tester, signal);
      }
    },
  );

  testWidgets(
    'actual declared-memory SQL baseline completes after REAL event then completed FAKE source',
    (tester) async {
      final f = ThemeScreenFixture();
      const tables = [
        'support_sessions',
        'support_messages',
        'support_context_blocks',
        'support_mutation_journal',
        'support_reports',
      ];
      late String before;
      late Map<String, dynamic> decodedBefore;
      late Map<String, String> vaultBefore;
      late int controlledStart;
      var callbacks = 0;
      await f.run(tester, () async {
        // f.run has already FULLY REAL-initialized its actual DB/cipher/FIFOs,
        // SAME AEAD/FakeVault, complete provider/router graph, and mounted in FAKE.
        before = await f.action(tester, f.baseline);
        vaultBefore = Map.of(f.storage.values);
        expect(vaultBefore, hasLength(1));
        decodedBefore = jsonDecode(before) as Map<String, dynamic>;
        expect((decodedBefore['tables'] as Map<String, dynamic>).keys, tables);
        expect(decodedBefore.keys, ['tables', 'theme', 'active', 'vault']);
        final completedFake = Future<int>.syncValue(7);
        await f.action<void>(tester, () {
          f.sql.event = (event) async {
            // Existing ScreenThemeSql calls this AFTER actual super.runSelect.
            expect(event, startsWith('select:SELECT * FROM support_'));
            await Future<void>.delayed(Duration.zero);
            expect(await completedFake, 7);
            callbacks++;
          };
        });
        controlledStart = f.sql.statements.length;
        expect(await f.action(tester, f.baseline), before);
        expect(callbacks, 5);
        expect(f.storage.values, vaultBefore);
        expect(f.theme.store.checkedWrites, isEmpty);
        expect(f.theme.store.ordinaryWrites, isEmpty);
        expect(f.backing.activeId, 'a');
        expect(f.isolation.attempts, isEmpty);
        // Leave original handles and hook removal to unchanged f.run cleanup.
      });
      expect(
        f.sql.statements.skip(controlledStart),
        [for (final table in tables) 'SELECT * FROM $table ORDER BY rowid'],
        reason:
            'No SQL writes or extra baseline queries, INCLUDING original cleanup.',
      );
      expect(callbacks, 5);
      expect(f.storage.values, vaultBefore);
      expect(
        f.backing.presets.map((preset) => preset.toJson()).toList(),
        decodedBefore['theme'],
      );
      expect(f.backing.activeId, decodedBefore['active']);
      expect(f.theme.store.checkedWrites, isEmpty);
      expect(f.theme.store.ordinaryWrites, isEmpty);
      expect(f.isolation.attempts, isEmpty);
      expect(f.disposed, isTrue);
      expect(f.theme.providerDisposed, isTrue);
      expect(tester.takeException(), isNull);
    },
  );
}

/// No DB/provider composition/native operation. The SAME original isolation
/// guards surround setup, every REAL issue/await, fake pumps, and cleanup.
void _noDbTurnsTest(
  String name,
  Future<void> Function(WidgetTester, ThemeScreenTurns, ThemeScreenIsolation)
  body,
) {
  testWidgets(name, (tester) async {
    final isolation = ThemeScreenIsolation();
    var active = true;
    final turns = ThemeScreenTurns(
      guarded: isolation.guarded,
      active: () => active,
    );
    await isolation.run(() async {
      try {
        await body(tester, turns, isolation);
      } finally {
        await turns.action<void>(tester, () {});
        active = false;
      }
    });
  });
}
