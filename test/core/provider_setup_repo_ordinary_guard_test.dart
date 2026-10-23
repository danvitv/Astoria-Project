import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';

import 'provider_setup_repo_fixture.dart';
import 'provider_setup_repo_ordinary_fixture.dart';

ApiConfigRepo guardedRepo(
  ProviderRepoFixture f,
  ProviderFakeOrdinaryGuard guard,
) => ApiConfigRepo(
  f.db,
  ordinaryMutations: guard,
  onMutationStarted: f.observeMutation,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  providerRepoTest(
    'ordinary guard receives exact current row and normalized proposal before SQL',
    (f) async {
      const id = 'synthetic-ordinary-row';
      await f.api.put(
        const ApiConfig(
          id: id,
          name: 'SYNTHETIC_PREVIOUS',
          endpoint: 'https://synthetic.invalid/v1',
          model: 'synthetic-previous-model',
          apiKey: ProviderRepoFixture.secretCanary,
        ),
      );
      final existing = (await f.api.getById(id))!;
      final guard = ProviderFakeOrdinaryGuard(f);
      final repo = guardedRepo(f, guard);
      var checked = false;
      f.events.clear();
      f.native.observerZones.clear();
      guard.inspectPut = (previous, proposed) async {
        checked = true;
        expect(previous, existing);
        expect(
          proposed.endpoint,
          'https://synthetic.invalid/v1/chat/completions',
        );
        expect(
          proposed.embeddingEndpoint,
          'https://synthetic.invalid/v1/embeddings',
        );
        expect(f.pendingFences, 1);
        expect(f.native.observerZones, [true]);
        expect(
          f.events.where(
            (e) => e.startsWith('insert:') && e.contains('api_configs'),
          ),
          isEmpty,
        );
      };
      await repo.put(
        existing.copyWith(
          name: 'SYNTHETIC_ORDINARY_RENAME',
          endpoint: 'https://synthetic.invalid/v1',
          embeddingEndpoint: 'https://synthetic.invalid/v1',
        ),
      );
      expect(checked, isTrue);
      expect(guard.labels, [id]);
      expect(f.native.observerZones, [true, true]);
      expect((await f.row(id))!.endpoint, guard.puts.single.proposed.endpoint);
      expect(
        (await f.row(id))!.apiKey,
        ProviderRepoFixture.secretCanary,
        reason:
            'Actual legacy credentials keep their existing behavior; no migration.',
      );
    },
  );

  for (final action in ['put', 'putFromMap', 'delete']) {
    providerRepoTest(
      'ordinary $action denial occurs before SQL and releases held owner safely',
      (f) async {
        final created = (await f.create(f.draft()))!;
        final existing = (await f.api.getById(created.connectionId))!;
        final guard = ProviderFakeOrdinaryGuard(f)
          ..denyPut = true
          ..denyDelete = true;
        final repo = guardedRepo(f, guard);
        final before = await f.snapshot();
        final releases = f.native.releaseCalls;
        f.events.clear();
        Object? error;
        try {
          if (action == 'delete') {
            await repo.delete(existing.id);
          } else if (action == 'putFromMap') {
            await repo.putFromMap(
              existing.copyWith(name: 'SYNTHETIC_DENIED').toJson(),
            );
          } else {
            await repo.put(existing.copyWith(name: 'SYNTHETIC_DENIED'));
          }
        } catch (caught) {
          error = caught;
        }
        expect(error, isA<KeylessApiConfigException>());
        expect('$error', isNot(contains(ProviderRepoFixture.secretCanary)));
        expect(f.native.releaseCalls, releases + 1);
        expect(f.pendingFences, 0);
        expect(
          f.events.where(
            (e) =>
                (e.startsWith('insert:') || e.startsWith('delete:')) &&
                e.contains('api_configs'),
          ),
          isEmpty,
        );
        expect(await f.snapshot(), before);
      },
    );
  }

  providerRepoTest(
    'ordinary protected row key/embedding conflict never writes plaintext or disables unrelated ID',
    (f) async {
      final first = (await f.create(f.draft()))!;
      final second = (await f.create(
        f.draft(),
        journalId: 'synthetic-second',
      ))!;
      f.native.protectedConnections.addAll([
        first.connectionId,
        second.connectionId,
      ]);
      final guard = ProviderFakeOrdinaryGuard(f);
      final repo = guardedRepo(f, guard);
      final proposed = (await f.api.getById(first.connectionId))!;
      final before = await f.snapshot();
      await expectLater(
        repo.put(proposed.copyWith(apiKey: ProviderRepoFixture.secretCanary)),
        throwsA(isA<KeylessApiConfigException>()),
      );
      await expectLater(
        repo.put(
          proposed.copyWith(embeddingApiKey: ProviderRepoFixture.secretCanary),
        ),
        throwsA(isA<KeylessApiConfigException>()),
      );
      expect(await f.snapshot(), before);
      expect(guard.disabled, isEmpty);
      expect(
        f.native.protectedConnections,
        containsAll([first.connectionId, second.connectionId]),
      );
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  providerRepoTest(
    'ordinary route/model change and deletion disable only the actual affected ID without transfer/delete',
    (f) async {
      final first = (await f.create(f.draft()))!;
      final second = (await f.create(
        f.draft(),
        journalId: 'synthetic-second',
      ))!;
      f.native.protectedConnections.addAll([
        first.connectionId,
        second.connectionId,
      ]);
      final guard = ProviderFakeOrdinaryGuard(f);
      final repo = guardedRepo(f, guard);
      final proposed = (await f.api.getById(first.connectionId))!;
      await repo.put(
        proposed.copyWith(
          model: 'synthetic-other-model',
          endpoint: 'https://synthetic-other.invalid/v1',
        ),
      );
      expect(guard.labels, [first.connectionId]);
      expect(guard.disabled, {first.connectionId});
      expect((await f.row(first.connectionId))!.apiKey, '');
      expect((await f.row(second.connectionId))!.apiKey, '');
      await repo.delete(first.connectionId);
      expect(guard.deletes, [first.connectionId]);
      expect(guard.disabled, {first.connectionId});
      expect(await f.row(first.connectionId), isNull);
      expect(await f.row(second.connectionId), isNotNull);
      expect(
        f.native.protectedConnections,
        containsAll([first.connectionId, second.connectionId]),
        reason: 'DB deletion does not delete or move the protected record.',
      );
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );

  providerRepoTest(
    'guarded ordinary fence reaches true outer DB commit before native settlement',
    (f) async {
      final guard = ProviderFakeOrdinaryGuard(f);
      final repo = guardedRepo(f, guard);
      f.native.observerZones.clear();
      var commitReached = false;
      f.db.beforeOuterCommit = () async {
        commitReached = true;
        expect(f.pendingFences, 1);
        expect(f.native.observerZones, [true]);
      };
      await repo.put(
        const ApiConfig(
          id: 'synthetic-guarded-outer',
          name: 'SYNTHETIC_GUARDED',
          endpoint: 'https://synthetic.invalid/v1',
          model: 'synthetic-model',
        ),
      );
      f.clearHooks();
      expect(commitReached, isTrue);
      expect(f.native.observerZones, [true, true]);
      expect(f.native.releaseCalls, 1);
      expect(
        (await f.row('synthetic-guarded-outer'))!.name,
        'SYNTHETIC_GUARDED',
      );
    },
  );

  providerRepoTest(
    'guarded ordinary caller-owned outer transaction refuses early instead of settling an inner fence',
    (f) async {
      final guard = ProviderFakeOrdinaryGuard(f);
      final repo = guardedRepo(f, guard);
      final before = await f.snapshot();
      await f.db.transaction(() async {
        await expectLater(
          repo.put(const ApiConfig(id: 'synthetic-caller-outer')),
          throwsA(isA<KeylessApiConfigException>()),
        );
      });
      expect(guard.labels, isEmpty);
      expect(f.native.releaseCalls, 0);
      expect(f.pendingFences, 0);
      expect(await f.snapshot(), before);
    },
  );

  for (final id in ['synthetic-malformed', 42]) {
    providerRepoTest(
      'guarded malformed map starts original hook before decode, with label $id',
      (f) async {
        final guard = ProviderFakeOrdinaryGuard(f);
        final repo = guardedRepo(f, guard);
        final before = await f.snapshot();
        f.native.observerZones.clear();
        final releases = f.native.releaseCalls;
        await expectLater(
          repo.putFromMap({'id': id, 'name': 17}),
          throwsA(isA<KeylessApiConfigException>()),
        );
        expect(guard.labels, [id is String ? id : '']);
        expect(guard.puts, isEmpty);
        expect(f.native.observerZones, [true, true]);
        expect(f.native.releaseCalls, releases + 1);
        expect(f.pendingFences, 0);
        expect(await f.snapshot(), before);
      },
    );
  }

  providerRepoTest(
    'absent optional ordinary guard preserves legacy hook/decode/normalization contract',
    (f) async {
      var starts = 0;
      var finishes = 0;
      final observed = <ApiConfig>[];
      final repo = ApiConfigRepo(
        f.db,
        onConfigObserved: observed.add,
        onMutationStarted: () {
          starts++;
          return () {
            finishes++;
          };
        },
      );
      final malformed = <String, dynamic>{
        'id': 'synthetic-malformed',
        'name': 17,
      };
      Object? error;
      try {
        await repo.putFromMap(malformed);
      } catch (caught) {
        error = caught;
      }
      expect(error, isNotNull);
      expect(error, isNot(isA<KeylessApiConfigException>()));
      expect(starts, 1);
      expect(finishes, 1);
      expect(observed, isEmpty);
      f.events.clear();
      await repo.put(
        const ApiConfig(
          id: 'synthetic-legacy-default',
          name: 'SYNTHETIC_LEGACY',
          endpoint: 'https://synthetic.invalid/v1',
          model: 'synthetic-model',
          apiKey: ProviderRepoFixture.secretCanary,
        ),
      );
      expect(starts, 2);
      expect(finishes, 2);
      expect(observed.length, 2);
      expect(observed.first.endpoint, 'https://synthetic.invalid/v1');
      expect(
        observed.last.endpoint,
        'https://synthetic.invalid/v1/chat/completions',
      );
      expect(
        f.events.where(
          (e) => e.startsWith('select:') && e.contains('api_configs'),
        ),
        isEmpty,
        reason:
            'Null guard does not add previous-row reads or new guard behavior.',
      );
      await repo.delete('synthetic-legacy-default');
      expect(starts, 3);
      expect(finishes, 3);
      expect(f.native.releaseCalls, 0);
    },
  );
}
