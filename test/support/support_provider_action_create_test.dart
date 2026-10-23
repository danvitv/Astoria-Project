import 'package:flutter_test/flutter_test.dart';

import 'support_provider_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  providerActionTest(
    'prepare/cancel have zero effects; native confirm saves exact keyless row',
    (f) async {
      final original = f.intent();
      final before = await f.snapshotRows();
      final vaultBefore = List.of(f.storage.operations);
      final review = (await f.service.prepareCreate(original, f.input()))!;
      final preview = f.service.projectReview(review)!;
      expect(preview.before, isNull);
      expect(preview.after!.connectionId, startsWith('native-'));
      expect(preview.after!.name, ProviderActionFixture.privateName);
      expect(await f.snapshotRows(), before);
      expect(f.storage.operations, vaultBefore);
      expect(f.metadataCalls, 0);
      f.service.cancel(review);
      expect(f.service.approve(review), isNull);
      expect(await f.snapshotRows(), before);

      final second = (await f.service.prepareCreate(original, f.input()))!;
      final value = f.service.projectReview(second)!.after!;
      expect(value.connectionId, isNot(preview.after!.connectionId));
      final approval = f.service.approve(second)!;
      expect(f.service.approve(second), isNull);
      final result = await f.service.execute(approval);
      expect(result.code, SupportProviderActionCode.applied);
      expect(
        (await f.service.execute(approval)).code,
        SupportProviderActionCode.refused,
      );
      final row = (await f.row(value.connectionId))!;
      expect(row.name, value.name);
      expect(row.endpoint, value.endpoint);
      expect(row.protocol, value.protocol);
      expect(row.providerId, 'openai');
      expect(row.model, value.model);
      expect(row.apiKey, '');
      expect(row.embeddingApiKey, '');
      expect(row.embeddingEnabled, isFalse);
      expect(row.embeddingUseSame, isFalse);
      expect(row.embeddingEndpoint, '');
      expect(row.embeddingModel, '');
      expect(row.embeddingLlmPresetId, '');
      expect(row.extraRequestParametersJson, '[]');
      expect(row.sessionIdMode, 'off');
      expect(row.maxTokens, value.maxTokens);
      expect(row.contextSize, value.contextSize);
      expect(row.temperature, value.temperature);
      expect(f.service.canUndo(result.applied!), isFalse);
      expect(await f.service.prepareUndo(original, result.applied!), isNull);
      final journal =
          (await f.db.select(f.db.supportMutationJournal).get()).single;
      expect(journal.domain, 'provider.setup');
      expect(journal.targetId, value.connectionId);
      expect(journal.status, 'applied');
      expect(journal.toJson().toString(), isNot(contains(value.name)));
      final record = (await f.support.getMutationsForSession(
        ProviderActionFixture.sessionId,
      )).single;
      expect(record.afterJson, contains(value.name));
      expect(record.afterJson, contains(value.endpoint));
      expect(record.afterJson, isNot(contains('apiKey')));
      expect(f.storage.operations, isNot(contains('delete')));
      // Root writes a protected deny-only preparation marker BEFORE DB create,
      // separately from the support AEAD installation key, never a credential.
      expect(
        f.storage.values.keys.any((k) => k.contains('native_prepared')),
        isTrue,
      );
      expect(
        f.storage.values.keys.any((k) => k.contains('native_llm')),
        isFalse,
      );
    },
  );

  providerActionTest(
    'cancel after final approval prevents native persistence',
    (f) async {
      final before = await f.snapshotRows();
      final review = (await f.service.prepareCreate(f.intent(), f.input()))!;
      final approval = f.service.approve(review)!;
      f.service.cancel(review);
      expect(
        (await f.service.execute(approval)).code,
        SupportProviderActionCode.refused,
      );
      expect(await f.snapshotRows(), before);
    },
  );

  for (final protocol in [
    'openai',
    'openai_responses',
    'anthropic',
    'gemini',
    'openrouter',
    'custom_chat_completion',
  ]) {
    providerActionTest(
      'exact standard default for $protocol needs no custom receipt',
      (f) async {
        final review = (await f.service.prepareCreate(
          f.intent(),
          f.input(protocol: protocol),
        ))!;
        expect(review.destinationKind, SupportProviderDestinationKind.standard);
        expect(f.service.confirmCustomDestination(review), isNull);
        final result = await f.service.execute(f.service.approve(review)!);
        expect(result.code, SupportProviderActionCode.applied);
        final row = (await f.row(result.applied!.value!.connectionId))!;
        expect(row.useResponsesApi, protocol == 'openai_responses');
        expect(row.apiKey, '');
      },
    );
  }

  for (final purpose in SupportProviderPurpose.values) {
    providerActionTest(
      '$purpose records setup purpose but assigns/tests nothing',
      (f) async {
        final original = f.intent();
        final result = await f.create(
          original: original,
          draft: f.input(purpose: purpose),
        );
        expect(result.applied!.purpose, purpose);
        final readiness = await f.service.projectReadiness(result.applied!);
        expect(readiness!.configurationSaved, isTrue);
        expect(readiness.credentialConfigured, isFalse);
        expect(readiness.characterCount, 0);
        expect(readiness.verification, SupportProviderVerification.notTested);
        final session = (await f.db.select(f.db.supportSessions).get()).single;
        expect(session.activeApiConfigId, isNull);
        expect(session.activeModelId, isNull);
      },
    );
  }
}
