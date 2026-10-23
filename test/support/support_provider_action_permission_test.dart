import 'package:flutter_test/flutter_test.dart';

import 'support_provider_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  providerActionTest(
    'local connections read works without model recipient or change grant',
    (f) async {
      await f.create();
      f.revoke(SupportPermission.confirmedSettingsChanges);
      final original = f.intent();
      final choice = await f.choice(original);
      expect(choice.value, isNotNull);
      expect(await f.service.projectReadiness(choice), isNotNull);
      expect(await f.service.prepareCreate(original, f.input()), isNull);
      expect(
        await f.service.prepareUpdate(
          choice,
          f.input(name: 'SYNTHETIC_RENAME'),
        ),
        isNull,
      );
      expect(f.context().recipient, isNull);
      expect(f.snapshot.preferences!.recipient, isNull);
    },
  );
  providerActionTest('change grant alone cannot read or create', (f) async {
    f.revoke(SupportPermission.readSafeSettings);
    expect(
      f.service.emit(
        controller: f.controller,
        uiLifetime: f.screen,
        isCurrent: () => true,
      ),
      isNull,
    );
    expect(f.idCalls, 0);
    expect(f.metadataCalls, 0);
    expect(f.operation, 0);
  });
  providerActionTest(
    'other safe category cannot substitute connections source selection',
    (f) async {
      f.scope = SupportPermissionScope(
        selectionRevision: 2,
        safeCategories: const [SupportSafeCategory.theme],
      );
      f.localEpoch++;
      expect(
        f.service.emit(
          controller: f.controller,
          uiLifetime: f.screen,
          isCurrent: () => true,
        ),
        isNull,
      );
      expect(f.idCalls, 0);
    },
  );
  for (final grant in [
    SupportPermission.readSafeSettings,
    SupportPermission.confirmedSettingsChanges,
  ]) {
    providerActionTest(
      'prepared approval retires after $grant revoke and ABA restore',
      (f) async {
        final before = await f.snapshotRows();
        final review = (await f.service.prepareCreate(f.intent(), f.input()))!;
        final approval = f.service.approve(review)!;
        f.revoke(grant);
        f.grants = {...f.grants, grant};
        f.localEpoch++;
        expect(
          (await f.service.execute(approval)).code,
          SupportProviderActionCode.refused,
        );
        expect(await f.snapshotRows(), before);
      },
    );
  }
  providerActionTest(
    'permission-read await retirement prevents native ID loader',
    (f) async {
      final original = f.intent();
      final barrier = JournalBarrier();
      f.policyReadHook = barrier.wait;
      final pending = f.service.observeConnections(
        original,
        SupportProviderPurpose.roleplay,
      );
      await barrier.entered.future;
      f.revoke(SupportPermission.readSafeSettings);
      barrier.release.complete();
      expect(await pending, isNull);
      expect(f.idCalls, 0);
    },
  );
  providerActionTest(
    'paused ID loader cannot publish after source selection retires',
    (f) async {
      await f.create();
      final original = f.intent();
      final barrier = JournalBarrier();
      f.idsReadHook = barrier.wait;
      final pending = f.service.observeConnections(
        original,
        SupportProviderPurpose.roleplay,
      );
      await barrier.entered.future;
      f.scope = SupportPermissionScope(
        selectionRevision: 2,
        safeCategories: const [SupportSafeCategory.connections],
      );
      f.localEpoch++;
      barrier.release.complete();
      expect(await pending, isNull);
    },
  );
  providerActionTest(
    'paused first-choice metadata cannot publish after original local scope retires',
    (f) async {
      await f.create();
      final original = f.intent();
      final before = await f.snapshotRows();
      final barrier = JournalBarrier();
      f.metadataHook = barrier.wait;
      final pending = f.service.observeConnections(
        original,
        SupportProviderPurpose.roleplay,
      );
      await barrier.entered.future;
      expect(f.metadataCalls, 1);
      f.scope = SupportPermissionScope(
        selectionRevision: 2,
        safeCategories: const [SupportSafeCategory.connections],
      );
      f.localEpoch++;
      barrier.release.complete();
      expect(await pending, isNull);
      expect(await f.snapshotRows(), before);
    },
  );
  providerActionTest(
    'paused metadata callback obeys local read revoke; never writes',
    (f) async {
      final applied = (await f.create()).applied!;
      final before = await f.snapshotRows();
      final barrier = JournalBarrier();
      f.metadataHook = barrier.wait;
      final pending = f.service.projectReadiness(applied);
      await barrier.entered.future;
      f.revoke(SupportPermission.readSafeSettings);
      barrier.release.complete();
      expect(await pending, isNull);
      expect(await f.snapshotRows(), before);
    },
  );
  for (final metadata in <SupportProviderReadiness?>[
    null,
    const SupportProviderReadiness(
      configurationSaved: false,
      credentialConfigured: false,
      characterCount: 0,
    ),
    const SupportProviderReadiness(
      configurationSaved: true,
      credentialConfigured: false,
      characterCount: 1,
    ),
    const SupportProviderReadiness(
      configurationSaved: true,
      credentialConfigured: true,
      characterCount: 0,
    ),
    const SupportProviderReadiness(
      configurationSaved: true,
      credentialConfigured: true,
      characterCount: -1,
    ),
    const SupportProviderReadiness(
      configurationSaved: true,
      credentialConfigured: true,
      characterCount: 65537,
    ),
  ]) {
    providerActionTest(
      'unusable constructor metadata never mints a saved choice ${metadata?.characterCount}/${metadata?.credentialConfigured}/${metadata?.configurationSaved}',
      (f) async {
        await f.create();
        final before = await f.snapshotRows();
        f.metadata = metadata;
        final connections = (await f.service.observeConnections(
          f.intent(),
          SupportProviderPurpose.roleplay,
        ))!;
        expect(connections.choices, isEmpty);
        expect(f.metadataCalls, 1);
        expect(await f.snapshotRows(), before);
      },
    );
  }
  providerActionTest(
    'recipient-only revision/redaction fence does not revoke safe local write',
    (f) async {
      final review = (await f.service.prepareCreate(f.intent(), f.input()))!;
      final approval = f.service.approve(review)!;
      f.recipientEpoch++;
      f.redaction.registerSecret('SYNTHETIC_UNRELATED_REGISTERED_SECRET');
      final result = await f.service.execute(approval);
      expect(result.code, SupportProviderActionCode.applied);
      expect(result.applied!.value, isNotNull);
    },
  );
  providerActionTest(
    'reentrant original scope callback cannot renew replaced intent',
    (f) async {
      final before = await f.snapshotRows();
      final review = (await f.service.prepareCreate(f.intent(), f.input()))!;
      final approval = f.service.approve(review)!;
      var called = false;
      f.ownerPredicateHook = () {
        if (!called) {
          called = true;
          f.service.retireIntents();
        }
      };
      expect(
        (await f.service.execute(approval)).code,
        SupportProviderActionCode.refused,
      );
      expect(await f.snapshotRows(), before);
    },
  );
  providerActionTest(
    'original root retirement inside view callback cannot emit new intent',
    (f) async {
      expect(
        f.service.emit(
          controller: f.controller,
          uiLifetime: f.screen,
          isCurrent: () {
            f.rootCurrent = false;
            return true;
          },
        ),
        isNull,
      );
    },
  );
}
