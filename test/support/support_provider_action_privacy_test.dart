import 'package:flutter_test/flutter_test.dart';

import 'support_provider_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final field in ['name', 'model', 'endpoint']) {
    providerActionTest(
      'known secret $field never enters review/evidence/effect',
      (f) async {
        final before = await f.snapshotRows();
        const canary = 'SYNTHETIC_CONTAMINATION';
        f.redaction.registerSecret(canary);
        final draft = f.input(
          name: field == 'name' ? canary : 'SYNTHETIC_SAFE_NAME',
          model: field == 'model' ? canary : 'synthetic-model',
          endpoint: field == 'endpoint'
              ? 'https://synthetic.invalid/$canary/v1/chat/completions'
              : null,
        );
        expect(await f.service.prepareCreate(f.intent(), draft), isNull);
        expect(await f.snapshotRows(), before);
        expect(f.operation, 0);
      },
    );
  }
  providerActionTest(
    'new known value hides retained review and rejects old Apply',
    (f) async {
      final before = await f.snapshotRows();
      final review = (await f.service.prepareCreate(f.intent(), f.input()))!;
      final approval = f.service.approve(review)!;
      f.redaction.registerSecret(ProviderActionFixture.privateName);
      expect(f.service.projectReview(review), isNull);
      expect(
        (await f.service.execute(approval)).code,
        SupportProviderActionCode.refused,
      );
      expect(await f.snapshotRows(), before);
    },
  );
  providerActionTest(
    'actual cold restart registers secret-name BEFORE first choice or projection',
    (f) async {
      const canary = 'SYNTHETIC_EXISTING_NAME';
      String visibleFields(SupportProviderSetupValue value) => [
        value.connectionId,
        value.name,
        value.protocol,
        value.endpoint,
        value.model,
      ].join('|');

      final hidden = (await f.create(draft: f.input(name: canary))).applied!;
      final id = hidden.value!.connectionId;
      await f.create(draft: f.input(name: 'SYNTHETIC_SAFE_OTHER_NAME'));
      await f.saveSyntheticNativeKey(id, canary);
      final before = await f.snapshotRows();
      final operation = f.operation;
      f.restartNative();
      f.useRealMetadata = true;
      final original = f.intent();
      expect(f.redaction.redactor.redactText(canary), canary);
      expect(f.metadataCalls, 0);
      final reads = f.storage.reads;
      SupportProviderConnections? first;
      Object? publicError;
      try {
        first = await f.service.observeConnections(
          original,
          SupportProviderPurpose.roleplay,
        );
      } catch (error) {
        publicError = error;
      }
      expect(publicError, isNull);
      expect('$publicError', isNot(contains(canary)));
      expect(first, isNotNull);
      expect(f.metadataCalls, 2);
      expect(f.storage.reads, greaterThan(reads));
      expect(f.redaction.redactor.redactText(canary), isNot(canary));
      final choice = first!.choices.single;
      final value = choice.value!;
      expect(value.name, 'SYNTHETIC_SAFE_OTHER_NAME');
      expect(value.connectionId, isNot(id));
      expect(visibleFields(value), isNot(contains(canary)));
      // The real metadata read/redactor fence does not renew an N1 receipt or
      // retire this original local scope. Only the OTHER safe row is reviewable.
      final review = (await f.service.prepareUpdate(
        choice,
        f.input(name: 'SYNTHETIC_SAFE_OTHER_RENAME'),
      ))!;
      final projected = f.service.projectReview(review)!;
      expect(projected.before!.name, 'SYNTHETIC_SAFE_OTHER_NAME');
      expect(projected.after!.name, 'SYNTHETIC_SAFE_OTHER_RENAME');
      expect(
        '${visibleFields(projected.before!)}|${visibleFields(projected.after!)}',
        isNot(contains(canary)),
      );
      f.service.cancel(review);
      expect(await f.service.projectReadiness(hidden), isNull);
      expect(f.context().recipient, isNull);
      expect(f.operation, operation);
      expect(await f.snapshotRows(), before);
      for (final journal
          in await f.db.select(f.db.supportMutationJournal).get()) {
        expect(journal.toJson().toString(), isNot(contains(canary)));
      }
      expect((await f.row(id))!.name, canary);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );
  providerActionTest(
    'post-native-preflight admission reprojects whole before-state even with injected metadata',
    (f) async {
      final applied = (await f.create()).applied!;
      final id = applied.value!.connectionId;
      // A user can enter a secret equal to an existing label. The trusted native
      // key owner registers it immediately; a restarted owner must discover it too.
      await f.saveSyntheticNativeKey(id, ProviderActionFixture.privateName);
      f.restartNative();
      // Deliberately injected metadata does NOT read/register the protected
      // record. This separate failsafe keeps final native admission covered.
      f.useRealMetadata = false;
      final original = f.intent();
      final choice = await f.choice(original);
      final review = (await f.service.prepareUpdate(
        choice,
        f.input(name: 'SYNTHETIC_SAFE_RENAME'),
      ))!;
      expect(f.service.projectReview(review), isNotNull);
      final before = await f.snapshotRows();
      final reads = f.storage.reads;
      final approval = f.service.approve(review)!;
      final result = await f.service.execute(approval);
      expect(result.code, SupportProviderActionCode.refused);
      expect(f.storage.reads, greaterThan(reads));
      expect(
        f.redaction.redactor.redactText(ProviderActionFixture.privateName),
        isNot(ProviderActionFixture.privateName),
      );
      expect(f.service.projectReview(review), isNull);
      expect(await f.snapshotRows(), before);
      expect(f.storage.operations, isNot(contains('delete')));
    },
  );
  for (final failure in ['unavailable', 'corrupt']) {
    providerActionTest(
      'real cold metadata $failure skips saved choice, never fabricates absence',
      (f) async {
        final applied = (await f.create()).applied!;
        final id = applied.value!.connectionId;
        await f.saveSyntheticNativeKey(id, ProviderActionFixture.secret);
        f.restartNative();
        f.useRealMetadata = true;
        final before = await f.snapshotRows();
        if (failure == 'unavailable') {
          f.storage.readError = StateError(ProviderActionFixture.secret);
        } else {
          final slot = f.storage.values.keys.singleWhere(
            (key) => key.contains('native_llm'),
          );
          // Synthetic protected bytes only; no real storage/default key reader.
          f.storage.values[slot] = '{SYNTHETIC_CORRUPT_RECORD';
        }
        final observed = await f.service.observeConnections(
          f.intent(),
          SupportProviderPurpose.roleplay,
        );
        expect(observed, isNotNull);
        expect(observed!.choices, isEmpty);
        expect('$observed', isNot(contains(ProviderActionFixture.secret)));
        expect(f.metadataCalls, 1);
        f.storage.readError = null;
        expect(await f.snapshotRows(), before);
        expect(f.storage.operations, isNot(contains('delete')));
      },
    );
  }
  providerActionTest(
    'throwing constructor metadata skips unknown row without public secret error',
    (f) async {
      await f.create();
      final before = await f.snapshotRows();
      f.metadataHook = () async {
        throw StateError(ProviderActionFixture.secret);
      };
      final connections = await f.service.observeConnections(
        f.intent(),
        SupportProviderPurpose.roleplay,
      );
      expect(connections, isNotNull);
      expect(connections!.choices, isEmpty);
      expect('$connections', isNot(contains(ProviderActionFixture.secret)));
      expect(await f.snapshotRows(), before);
    },
  );
  providerActionTest(
    'current redaction hides applied label/ID without restoring authority',
    (f) async {
      final result = await f.create();
      final id = result.applied!.value!.connectionId;
      f.redaction.registerSecret(id);
      expect(result.applied!.value, isNull);
      expect(f.service.projectResult(result), isNull);
      expect(await f.service.projectReadiness(result.applied!), isNull);
      expect((await f.row(id))!.name, ProviderActionFixture.privateName);
      expect(result.code, SupportProviderActionCode.applied);
    },
  );
  providerActionTest(
    'real metadata reports Unicode runes and never provider verification',
    (f) async {
      final result = await f.create();
      final id = result.applied!.value!.connectionId;
      const nativeKey = 'SYNTHETIC_NATIVE_KEY_🐈‍⬛';
      await f.saveSyntheticNativeKey(id, nativeKey);
      f.useRealMetadata = true;
      final readiness = (await f.service.projectReadiness(result.applied!))!;
      expect(readiness.configurationSaved, isTrue);
      expect(readiness.credentialConfigured, isTrue);
      expect(readiness.characterCount, nativeKey.runes.length);
      expect(readiness.verification, SupportProviderVerification.notTested);
      expect(
        f.service.projectResult(result)!.preview!.after!.name,
        isNot(contains(nativeKey)),
      );
      expect((await f.row(id))!.apiKey, '');
    },
  );
  providerActionTest(
    'metadata callback cannot manufacture probe/model-list proof',
    (f) async {
      final result = await f.create();
      f.metadata = const SupportProviderReadiness(
        configurationSaved: true,
        credentialConfigured: true,
        characterCount: 7,
        verification: SupportProviderVerification.generationVerified,
      );
      final readiness = (await f.service.projectReadiness(result.applied!))!;
      expect(readiness.characterCount, 7);
      expect(readiness.verification, SupportProviderVerification.notTested);
    },
  );
}
