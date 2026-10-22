import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';

void main() {
  test(
    'begin and every nested settlement notify synchronously after state',
    () {
      final registry = ConnectionRevisionRegistry();
      final initial = registry.revision;
      final states = <(int, bool)>[];
      final unsubscribe = registry.subscribe(
        () => states.add((registry.revision, registry.isStable)),
      );
      expect(states, isEmpty);
      final first = registry.beginMutation();
      expect(states, [(initial + 1, false)]);
      final second = registry.beginMutation();
      first();
      first();
      second();
      expect(states, [
        (initial + 1, false),
        (initial + 2, false),
        (initial + 3, false),
        (initial + 4, true),
      ]);
      for (var i = 0; i < 20; i++) {
        expect(registry.revision, initial + 4);
        expect(registry.isStable, isTrue);
      }
      unsubscribe();
      unsubscribe();
      registry.beginMutation()();
      expect(states.length, 4);
      registry.dispose();
    },
  );

  test('independent subscriptions can unsubscribe during dispatch safely', () {
    final registry = ConnectionRevisionRegistry();
    var calls = 0;
    void listener() => calls++;
    late void Function() removeSecond;
    final removeFirst = registry.subscribe(() => removeSecond());
    removeSecond = registry.subscribe(listener);
    final removeThird = registry.subscribe(listener);
    final settle = registry.beginMutation();
    expect(calls, 1);
    removeFirst();
    removeThird();
    settle();
    expect(calls, 1);
    expect(registry.isStable, isTrue);
    registry.dispose();
  });

  test(
    'throwing observer cannot abort real writes or log raw error text',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final registry = ConnectionRevisionRegistry();
      addTearDown(registry.dispose);
      final repo = ApiConfigRepo(db, onMutationStarted: registry.beginMutation);
      var healthyCalls = 0;
      final printed = <String>[];
      registry.subscribe(
        () => throw StateError('STATIC_OBSERVER_ERROR_783941'),
      );
      registry.subscribe(() => healthyCalls++);
      await runZoned(
        () async {
          await repo.put(const ApiConfig(id: 'ordinary'));
          await repo.delete('ordinary');
          await expectLater(
            repo.putFromMap(const {'id': 123}),
            throwsA(anything),
          );
        },
        zoneSpecification: ZoneSpecification(
          print: (self, parent, zone, line) => printed.add(line),
        ),
      );
      expect(healthyCalls, 6);
      expect(registry.isStable, isTrue);
      expect(printed, isEmpty);
      expect(await repo.getById('ordinary'), isNull);
    },
  );

  test(
    'dispose invalidates once, removes observers and settlements stay safe',
    () {
      final registry = ConnectionRevisionRegistry();
      final initial = registry.revision;
      final states = <(int, bool)>[];
      final unsubscribe = registry.subscribe(
        () => states.add((registry.revision, registry.isStable)),
      );
      final first = registry.beginMutation();
      final second = registry.beginMutation();
      registry.dispose();
      registry.dispose();
      expect(states.last, (initial + 3, false));
      first();
      second();
      second();
      expect(registry.revision, initial + 5);
      expect(registry.isStable, isFalse);
      unsubscribe();
      registry.subscribe(() => fail('closed registry notified'))();
      registry.beginMutation()();
      expect(registry.revision, initial + 7);
      expect(states.length, 3);
      expect(registry.isStable, isFalse);
    },
  );

  test(
    'observer can dispose during begin without breaking admitted settlement',
    () {
      final registry = ConnectionRevisionRegistry();
      registry.subscribe(registry.dispose);
      final settle = registry.beginMutation();
      final closedRevision = registry.revision;
      settle();
      settle();
      expect(registry.revision, closedRevision + 1);
      expect(registry.isStable, isFalse);
    },
  );

  test(
    'provider disposal closes old registry, admitted real DB put still settles',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(db.close);
      final container = ProviderContainer();
      final registry = container.read(connectionRevisionRegistryProvider);
      final repo = ApiConfigRepo(db, onMutationStarted: registry.beginMutation);
      var notifications = 0;
      registry.subscribe(() => notifications++);
      final write = repo.put(const ApiConfig(id: 'admitted'));
      final pendingRevision = registry.revision;
      container.dispose();
      expect(registry.isStable, isFalse);
      expect(notifications, 2);
      await write;
      expect(registry.revision, pendingRevision + 2);
      expect(registry.isStable, isFalse);
      expect(notifications, 2);
      expect((await repo.getById('admitted'))?.id, 'admitted');
      final nextContainer = ProviderContainer();
      addTearDown(nextContainer.dispose);
      final next = nextContainer.read(connectionRevisionRegistryProvider);
      expect(next, isNot(same(registry)));
      expect(next.isStable, isTrue);
    },
  );
}
