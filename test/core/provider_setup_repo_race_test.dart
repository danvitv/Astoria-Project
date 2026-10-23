import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';

import 'provider_setup_repo_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  providerRepoTest(
    'create retirement at every observed SQL/vault/real AEAD await rolls back',
    (f) async {
      f.events.clear();
      expect(await f.create(f.draft()), isNotNull);
      final trace = List.of(f.events);
      expect(trace, isNotEmpty);
      for (var index = 0; index < trace.length; index++) {
        final fresh = ProviderRepoFixture();
        try {
          await fresh.seed();
          final before = await fresh.snapshot();
          final draft = fresh.draft();
          fresh.events.clear();
          var reached = false;
          fresh.hook = (_) async {
            if (fresh.events.length - 1 == index) {
              reached = true;
              fresh.current = false;
            }
          };
          expect(
            await fresh.create(draft),
            isNull,
            reason: 'Checkpoint $index ${trace[index]}',
          );
          expect(reached, isTrue);
          fresh.clearHooks();
          expect(await fresh.snapshot(), before);
          expect(fresh.pendingFences, 0);
        } finally {
          fresh.clearHooks();
          await fresh.db.close();
        }
      }
    },
  );

  for (final operation in ['update', 'undo-update', 'undo-create']) {
    providerRepoTest(
      '$operation retirement at every observed awaited boundary rolls back',
      (f) async {
        Future<Future<Object?> Function()> prepare(
          ProviderRepoFixture fixture,
        ) async {
          final created = (await fixture.create(fixture.draft()))!;
          if (operation == 'undo-create') {
            fixture.proof.known = fixture.proof.credentialAbsent =
                fixture.proof.referencesAbsent = true;
            return () => fixture.setup.undo(
              original: created,
              isCurrent: fixture.isCurrent,
            );
          }
          final observed = (await fixture.api.inspectKeyless(
            created.connectionId,
          ))!;
          if (operation == 'update') {
            return () => fixture.update(observed, fixture.patch());
          }
          final updated = (await fixture.update(observed, fixture.patch()))!;
          return () => fixture.setup.undo(
            original: updated,
            isCurrent: fixture.isCurrent,
          );
        }

        final run = await prepare(f);
        f.events.clear();
        expect(await run(), isNotNull);
        final trace = List.of(f.events);
        for (var index = 0; index < trace.length; index++) {
          final fresh = ProviderRepoFixture();
          try {
            await fresh.seed();
            final run = await prepare(fresh);
            final before = await fresh.snapshot();
            fresh.events.clear();
            var reached = false;
            fresh.hook = (_) async {
              if (fresh.events.length - 1 == index) {
                reached = true;
                fresh.current = false;
              }
            };
            expect(
              await run(),
              isNull,
              reason: '$operation $index ${trace[index]}',
            );
            expect(reached, isTrue);
            fresh.clearHooks();
            expect(await fresh.snapshot(), before);
            expect(fresh.pendingFences, 0);
            expect(fresh.proof.held, 0);
          } finally {
            fresh.clearHooks();
            await fresh.db.close();
          }
        }
      },
    );
  }

  for (final fault in [
    'reserve-encrypt',
    'row-insert',
    'settle-SQL',
    'outer-send',
  ]) {
    providerRepoTest(
      '$fault failure atomically rolls back row plus encrypted journal with safe error',
      (f) async {
        final before = await f.snapshot();
        if (fault == 'outer-send') {
          f.sql.beforeOuterSend = () async {
            expect(f.pendingFences, 1);
            throw StateError(ProviderRepoFixture.secretCanary);
          };
        } else {
          f.hook = (event) async {
            final matched = switch (fault) {
              'reserve-encrypt' =>
                event.startsWith('encrypt:') &&
                    event.contains('support_mutation_journal'),
              'row-insert' =>
                event.startsWith('insert:') && event.contains('api_configs'),
              _ =>
                event.startsWith('update:') &&
                    event.contains('support_mutation_journal'),
            };
            if (matched) throw StateError(ProviderRepoFixture.secretCanary);
          };
        }
        Object? error;
        try {
          await f.create(f.draft());
        } catch (caught) {
          error = caught;
        }
        expect(error, isA<KeylessApiConfigException>());
        for (final canary in [
          ProviderRepoFixture.secretCanary,
          ProviderRepoFixture.nameCanary,
          ProviderRepoFixture.urlCanary,
        ]) {
          expect('$error', isNot(contains(canary)));
        }
        f.clearHooks();
        expect(await f.snapshot(), before);
        expect(f.pendingFences, 0);
        expect(f.storage.operations, isNot(contains('delete')));
      },
    );
  }

  providerRepoTest(
    'journal reserve vault read failure cannot leave a row effect',
    (f) async {
      final before = await f.snapshot();
      f.storage.readError = StateError(ProviderRepoFixture.secretCanary);
      await expectLater(
        f.create(f.draft()),
        throwsA(isA<KeylessApiConfigException>()),
      );
      f.clearHooks();
      expect(await f.snapshot(), before);
    },
  );

  providerRepoTest(
    'pending fence stays held through outer commit, not inner journal settlement',
    (f) async {
      final draft = f.draft();
      var observed = 0;
      f.sql.beforeOuterSend = () async {
        observed++;
        expect(f.pendingFences, 1);
        expect(await f.api.inspectKeyless(draft.view.connectionId), isNull);
        expect(await f.row(draft.view.connectionId), isNotNull);
        expect((await f.journal('synthetic-create'))!.status, 'applied');
      };
      final created = (await f.create(draft))!;
      f.clearHooks();
      expect(
        observed,
        1,
        reason: 'Only the actual outer send, never journal savepoints.',
      );
      expect(f.pendingFences, 0);
      expect(
        (await f.api.inspectKeyless(created.connectionId))!.nativeOwned,
        isTrue,
      );
    },
  );

  providerRepoTest(
    'late actual commit completion retains original custody without renewed admission',
    (f) async {
      f.db.afterOuterCommit = () async {
        f.current = false;
      };
      final created = (await f.create(f.draft()))!;
      f.clearHooks();
      expect(created.status, SupportMutationStatus.applied);
      expect(await f.row(created.connectionId), isNotNull);
      expect((await f.journal(created.journalId))!.status, 'applied');
      expect(await f.create(f.draft(), journalId: 'retired-repeat'), isNull);
    },
  );

  providerRepoTest(
    'throw after actual commit is uncertain delivery, not rollback/refusal/retry',
    (f) async {
      final draft = f.draft();
      f.db.afterOuterCommit = () async {
        throw StateError(ProviderRepoFixture.secretCanary);
      };
      await expectLater(
        f.create(draft),
        throwsA(isA<KeylessApiConfigException>()),
      );
      f.clearHooks();
      expect(await f.row(draft.view.connectionId), isNotNull);
      expect((await f.journal('synthetic-create'))!.status, 'applied');
      expect(
        (await f.api.inspectKeyless(draft.view.connectionId))!.nativeOwned,
        isFalse,
        reason: 'Lost completion cannot invent native receipt custody.',
      );
      expect(await f.create(draft, journalId: 'no-hidden-retry'), isNull);
      expect(await f.journal('no-hidden-retry'), isNull);
    },
  );

  providerRepoTest(
    'reentrant row change at journal decrypt cannot fabricate exact applied receipt',
    (f) async {
      final draft = f.draft();
      final before = await f.snapshot();
      var reached = false;
      f.hook = (event) async {
        if (!event.startsWith('decrypt-after:') ||
            !event.contains('support_mutation_journal')) {
          return;
        }
        if (await f.row(draft.view.connectionId) == null) return;
        f.hook = null;
        reached = true;
        await f.change(
          draft.view.connectionId,
          const ApiConfigsCompanion(topK: Value(99)),
        );
      };
      expect(await f.create(draft), isNull);
      f.clearHooks();
      expect(reached, isTrue);
      expect(await f.snapshot(), before);
    },
  );

  providerRepoTest(
    'same-content ordinary mutation reentered during effect retires operation',
    (f) async {
      final draft = f.draft();
      final before = await f.snapshot();
      f.hook = (event) async {
        if (!event.startsWith('insert:') || !event.contains('api_configs')) {
          return;
        }
        f.hook = null;
        final row = (await f.api.getById(draft.view.connectionId))!;
        await f.api.put(row);
      };
      expect(await f.create(draft), isNull);
      f.clearHooks();
      expect(await f.snapshot(), before);
      expect(f.pendingFences, 0);
    },
  );

  providerRepoTest(
    'caller-owned outer transaction is refused before any new fence/effect',
    (f) async {
      final before = await f.snapshot();
      await f.db.transaction(() async {
        expect(await f.create(f.draft()), isNull);
        expect(f.pendingFences, 0);
      });
      expect(await f.snapshot(), before);
    },
  );

  providerRepoTest(
    'reentrant synchronous current callback cannot hide ordinary ABA behind true',
    (f) async {
      final draft = f.draft();
      final evidence = f.evidence(
        journalId: 'guard-reentry',
        action: SupportProviderSetupAction.create,
        after: draft.view,
      );
      final before = await f.snapshot();
      var reentered = false;
      bool current() {
        if (!reentered && f.pendingFences == 1) {
          reentered = true;
          final finish = f.api.onMutationStarted!.call();
          finish();
        }
        return true;
      }

      expect(
        await f.setup.create(
          draft: draft,
          pendingEvidence: evidence,
          isCurrent: current,
        ),
        isNull,
      );
      expect(reentered, isTrue);
      expect(await f.snapshot(), before);
      expect(f.pendingFences, 0);
    },
  );

  providerRepoTest(
    'row SQL CAS rejects same-owned-field interference after final latest read',
    (f) async {
      final created = (await f.create(f.draft()))!;
      final expected = (await f.api.inspectKeyless(created.connectionId))!;
      final before = await f.snapshot();
      var reached = false;
      f.hook = (event) async {
        if (!event.startsWith('select:') ||
            !event.contains('api_configs') ||
            event.contains('SELECT * FROM api_configs')) {
          return;
        }
        f.hook = null;
        reached = true;
        await f.change(
          created.connectionId,
          const ApiConfigsCompanion(name: Value('SYNTHETIC_INTERFERING_NAME')),
        );
      };
      expect(await f.update(expected, f.patch()), isNull);
      f.clearHooks();
      expect(reached, isTrue);
      expect(
        await f.snapshot(),
        before,
        reason:
            'The injected interfering write joins and rolls back with the outer transaction.',
      );
    },
  );

  providerRepoTest(
    'simultaneous same-ID attempts have exactly one saved row and receipt',
    (f) async {
      final draft = f.draft();
      final gate = JournalBarrier();
      var first = true;
      f.hook = (event) async {
        if (first &&
            event.startsWith('encrypt:') &&
            event.contains('support_mutation_journal')) {
          first = false;
          await gate.wait();
        }
      };
      final one = f.create(draft);
      await gate.entered.future;
      expect(await f.create(draft, journalId: 'competing-create'), isNull);
      gate.release.complete();
      expect(await one, isNotNull);
      f.clearHooks();
      expect((await f.db.select(f.db.apiConfigs).get()).length, 1);
      expect(await f.journal('competing-create'), isNull);
    },
  );
}
