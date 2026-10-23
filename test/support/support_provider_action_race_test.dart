import 'package:flutter_test/flutter_test.dart';

import 'support_provider_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final boundary in [
    'vault-read',
    'encrypt:',
    'insert:',
    'update:',
    'decrypt-before:',
  ]) {
    for (final grant in [
      SupportPermission.readSafeSettings,
      SupportPermission.confirmedSettingsChanges,
    ]) {
      providerActionTest(
        '$boundary retirement of $grant rolls back both effect/journal',
        (f) async {
          final before = await f.snapshotRows();
          final review = (await f.service.prepareCreate(
            f.intent(),
            f.input(),
          ))!;
          final approval = f.service.approve(review)!;
          final barrier = JournalBarrier();
          var visited = false;
          f.hook = (event) async {
            if (!visited && event.startsWith(boundary)) {
              visited = true;
              await barrier.wait();
            }
          };
          final pending = f.service.execute(approval);
          await barrier.entered.future;
          f.revoke(grant);
          barrier.release.complete();
          final result = await pending;
          f.hook = null;
          expect(visited, isTrue);
          expect(result.code, SupportProviderActionCode.refused);
          expect(await f.snapshotRows(), before);
          expect(
            (await f.service.execute(approval)).code,
            SupportProviderActionCode.refused,
          );
        },
      );
    }
  }
  for (final kind in ['update', 'undo']) {
    final boundaries = kind == 'undo'
        ? ['vault-read', 'select:', 'decrypt-before:', 'update:']
        : [
            'vault-read',
            'select:',
            'encrypt:',
            'insert:',
            'update:',
            'decrypt-before:',
          ];
    for (final boundary in boundaries) {
      for (final grant in [
        SupportPermission.readSafeSettings,
        SupportPermission.confirmedSettingsChanges,
      ]) {
        providerActionTest(
          '$kind $boundary $grant revoke keeps original row/journal bytes',
          (f) async {
            final original = f.intent();
            await f.create(original: original);
            var review = (await f.service.prepareUpdate(
              await f.choice(original),
              f.input(name: 'SYNTHETIC_RENAME'),
            ))!;
            if (kind == 'undo') {
              final applied = (await f.service.execute(
                f.service.approve(review)!,
              )).applied!;
              review = (await f.service.prepareUndo(original, applied))!;
            }
            final before = await f.snapshotRows();
            final approval = f.service.approve(review)!;
            final barrier = JournalBarrier();
            var visited = false;
            f.hook = (event) async {
              if (!visited && event.startsWith(boundary)) {
                visited = true;
                await barrier.wait();
              }
            };
            final pending = f.service.execute(approval);
            await barrier.entered.future;
            f.revoke(grant);
            barrier.release.complete();
            final result = await pending;
            f.hook = null;
            expect(visited, isTrue);
            expect(result.code, SupportProviderActionCode.refused);
            expect(await f.snapshotRows(), before);
          },
        );
      }
    }
  }
  providerActionTest(
    'once execution reserves pending job before reentrant original-owner callback',
    (f) async {
      final original = f.intent();
      final first = (await f.service.prepareCreate(original, f.input()))!;
      final second = (await f.service.prepareCreate(
        original,
        f.input(name: 'SYNTHETIC_SECOND'),
      ))!;
      final a = f.service.approve(first)!, b = f.service.approve(second)!;
      Future<SupportProviderActionResult>? reentered;
      f.ownerPredicateHook = () {
        reentered ??= f.service.execute(b);
      };
      final result = await f.service.execute(a);
      f.ownerPredicateHook = null;
      expect(result.code, SupportProviderActionCode.applied);
      expect((await reentered!).code, SupportProviderActionCode.refused);
      expect(
        (await f.service.execute(b)).code,
        SupportProviderActionCode.refused,
      );
      expect((await f.db.select(f.db.apiConfigs).get()).length, 1);
    },
  );
  providerActionTest(
    'original late outer commit survives retirement, no replacement UI/receipt authority',
    (f) async {
      final original = f.intent();
      final review = (await f.service.prepareCreate(original, f.input()))!;
      final id = f.service.projectReview(review)!.after!.connectionId;
      final approval = f.service.approve(review)!;
      final barrier = JournalBarrier();
      f.db.afterOuterCommit = barrier.wait;
      final pending = f.service.execute(approval);
      await barrier.entered.future;
      final retired = f.service;
      retired.dispose();
      final replacement = f.newService();
      barrier.release.complete();
      final result = await pending;
      f.db.afterOuterCommit = null;
      try {
        expect(result.code, SupportProviderActionCode.applied);
        expect(result.applied, isNotNull);
        expect(result.applied!.value, isNull);
        expect(retired.projectResult(result), isNull);
        expect(replacement.projectResult(result), isNull);
        expect(replacement.canUndo(result.applied!), isFalse);
        expect((await f.row(id))!.name, ProviderActionFixture.privateName);
        expect(
          (await f.db.select(f.db.supportMutationJournal).get()).single.status,
          'applied',
        );
      } finally {
        replacement.dispose();
      }
    },
  );
  for (final afterCommit in [false, true]) {
    providerActionTest(
      'outer commit ${afterCommit ? 'delivery' : 'send'} fault is uncertain and never retried',
      (f) async {
        final before = await f.snapshotRows();
        final review = (await f.service.prepareCreate(f.intent(), f.input()))!;
        final id = f.service.projectReview(review)!.after!.connectionId;
        final approval = f.service.approve(review)!;
        var attempts = 0;
        Future<void> fail() async {
          attempts++;
          throw StateError(ProviderActionFixture.secret);
        }

        if (afterCommit) {
          f.sql.afterOuterSend = fail;
        } else {
          f.sql.beforeOuterSend = fail;
        }
        final result = await f.service.execute(approval);
        f.sql.beforeOuterSend = null;
        f.sql.afterOuterSend = null;
        expect(result.code, SupportProviderActionCode.storageUncertain);
        expect(result.applied, isNull);
        expect(attempts, 1);
        expect(f.operation, 1);
        expect(
          (await f.service.execute(approval)).code,
          SupportProviderActionCode.refused,
        );
        if (afterCommit) {
          expect(await f.row(id), isNotNull);
          expect(
            (await f.db.select(f.db.supportMutationJournal).get())
                .single
                .status,
            'applied',
          );
        } else {
          expect(await f.snapshotRows(), before);
        }
        expect(
          f.service.projectResult(result)!.code,
          SupportProviderActionCode.storageUncertain,
        );
      },
    );
  }
  providerActionTest(
    'native read unavailable never implies absence or retry permission',
    (f) async {
      final before = await f.snapshotRows();
      final review = (await f.service.prepareCreate(f.intent(), f.input()))!;
      final approval = f.service.approve(review)!;
      final reads = f.storage.reads;
      f.storage.readError = StateError(ProviderActionFixture.secret);
      final result = await f.service.execute(approval);
      f.storage.readError = null;
      expect(result.code, SupportProviderActionCode.refused);
      expect(result.applied, isNull);
      expect(f.storage.reads, reads + 1);
      expect(
        (await f.service.execute(approval)).code,
        SupportProviderActionCode.refused,
      );
      expect(f.storage.reads, reads + 1);
      expect(await f.snapshotRows(), before);
      expect(
        f.service.projectResult(result)!.preview!.after!.name,
        isNot(contains(ProviderActionFixture.secret)),
      );
    },
  );
}
