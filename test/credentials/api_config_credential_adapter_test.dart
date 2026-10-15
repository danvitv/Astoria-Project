import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/api_connection_metadata.dart';
import 'package:glaze_flutter/core/credentials/credential_broker.dart';
import 'package:glaze_flutter/core/credentials/credential_route.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';

import 'fake_credential_storage.dart';

void main() {
  const llmCanary = 'LLM_CANARY_🔐_ключ';
  const embCanary = 'EMB_CANARY_🧪_токен';
  const paramCanary = 'PARAM_CANARY_🗝️_секрет';
  const nestedCanary = 'NESTED_CANARY_🛡️_пароль';

  late FakeCredentialStorage storage;
  late CredentialVault vault;
  late SecretRedactor redactor;
  late CredentialBroker broker;
  late ApiConfigCredentialAdapter adapter;

  final llmRoute = CredentialRoute(
    endpoint: 'https://api.openai.com/v1/chat/completions',
    protocol: CredentialProtocol.openAiChatCompletions,
    purpose: CredentialPurpose.chat,
  );
  final embRoute = CredentialRoute(
    endpoint: 'https://api.openai.com/v1/embeddings',
    protocol: CredentialProtocol.openAiChatCompletions,
    purpose: CredentialPurpose.embeddings,
  );

  setUp(() {
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    redactor = SecretRedactor();
    broker = CredentialBroker(
      vault: vault,
      approve: (_, _) async => true,
      transport: (_, _) async {},
    );
    adapter = ApiConfigCredentialAdapter(
      vault: vault,
      redactor: redactor,
      broker: broker,
    );
  });

  test('deterministic slots use api_config.llm and api_config.embedding', () {
    final llm = ApiConfigCredentialAdapter.llmSlot('cfg-1');
    final emb = ApiConfigCredentialAdapter.embeddingSlot('cfg-1');
    expect(llm.domain, 'api_config.llm');
    expect(llm.id, 'cfg-1');
    expect(emb.domain, 'api_config.embedding');
    expect(emb.id, 'cfg-1');
    expect(llm, isNot(equals(emb)));
  });

  test(
    'syncConfigToVault stores/deletes slots, revokes changed broker slots, and registers secrets',
    () async {
      final config = ApiConfig(
        id: 'conn-1',
        name: 'Primary',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        apiKey: llmCanary,
        embeddingApiKey: embCanary,
        extraRequestParameters: const [
          ExtraRequestParameter(key: 'x_api_key', value: paramCanary),
          ExtraRequestParameter(
            key: 'custom_headers',
            value: '{"Authorization":"$nestedCanary"}',
          ),
          ExtraRequestParameter(key: 'temperature_hint', value: 'keep-me'),
        ],
      );

      await adapter.syncConfigToVault(config);

      final llmSlot = ApiConfigCredentialAdapter.llmSlot('conn-1');
      final embSlot = ApiConfigCredentialAdapter.embeddingSlot('conn-1');
      expect((await vault.metadata(llmSlot)).configured, isTrue);
      expect(
        (await vault.metadata(llmSlot)).characterCount,
        llmCanary.runes.length,
      );
      expect((await vault.metadata(embSlot)).configured, isTrue);
      expect(
        (await vault.metadata(embSlot)).characterCount,
        embCanary.runes.length,
      );

      // Verify secrets were registered with the adapter's redactor.
      final probe =
          'leaked $llmCanary and $embCanary and $paramCanary and $nestedCanary';
      final redacted = adapter.redactor.redactText(probe);
      expect(redacted, isNot(contains(llmCanary)));
      expect(redacted, isNot(contains(embCanary)));
      expect(redacted, isNot(contains(paramCanary)));
      expect(redacted, isNot(contains(nestedCanary)));

      // Bind broker handles to both slots.
      final llmHandle = await broker.bind(llmSlot, llmRoute);
      final embHandle = await broker.bind(embSlot, embRoute);

      // Syncing identical keys must NOT revoke active handles.
      await adapter.syncConfigToVault(config);
      expect((await broker.metadata(llmHandle)).configured, isTrue);
      expect((await broker.metadata(embHandle)).configured, isTrue);

      // Rotating apiKey revokes llmSlot handle while leaving embSlot handle active.
      await adapter.syncConfigToVault(
        config.copyWith(apiKey: 'ROTATED_LLM_SECRET'),
      );
      await expectLater(
        broker.metadata(llmHandle),
        throwsA(
          isA<CredentialBrokerException>().having(
            (e) => e.failure,
            'failure',
            CredentialBrokerFailure.revoked,
          ),
        ),
      );
      expect((await broker.metadata(embHandle)).configured, isTrue);

      // Clearing embeddingApiKey deletes the slot and revokes embSlot handle.
      await adapter.syncConfigToVault(
        config.copyWith(apiKey: 'ROTATED_LLM_SECRET', embeddingApiKey: '   '),
      );
      expect((await vault.metadata(embSlot)).configured, isFalse);
      await expectLater(
        broker.metadata(embHandle),
        throwsA(
          isA<CredentialBrokerException>().having(
            (e) => e.failure,
            'failure',
            CredentialBrokerFailure.revoked,
          ),
        ),
      );
    },
  );

  test(
    'hydrateFromVaultOrFallback prefers vault, seeds legacy Drift keys non-destructively, and registers secrets',
    () async {
      final legacyRow = ApiConfig(
        id: 'legacy-1',
        name: 'Legacy Connection',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        apiKey: llmCanary,
        embeddingApiKey: embCanary,
        extraRequestParameters: const [
          ExtraRequestParameter(key: 'access_token', value: paramCanary),
        ],
      );

      final llmSlot = ApiConfigCredentialAdapter.llmSlot('legacy-1');
      final embSlot = ApiConfigCredentialAdapter.embeddingSlot('legacy-1');
      expect((await vault.metadata(llmSlot)).configured, isFalse);
      expect((await vault.metadata(embSlot)).configured, isFalse);

      // 1. Vault is unconfigured -> seeds vault from legacy row without wiping row.
      final seeded = await adapter.hydrateFromVaultOrFallback(legacyRow);
      expect(seeded.apiKey, llmCanary);
      expect(seeded.embeddingApiKey, embCanary);
      expect(legacyRow.apiKey, llmCanary);
      expect(legacyRow.embeddingApiKey, embCanary);
      expect((await vault.metadata(llmSlot)).configured, isTrue);
      expect((await vault.metadata(embSlot)).configured, isTrue);

      // Redactor registered legacy + extraRequestParameters secrets.
      expect(
        adapter.redactor.redactText('$llmCanary $embCanary $paramCanary'),
        isNot(
          anyOf(
            contains(llmCanary),
            contains(embCanary),
            contains(paramCanary),
          ),
        ),
      );

      // 2. Vault has newer values -> vault takes priority over stale Drift row.
      const vaultOverrideLlm = 'VAULT_OVERRIDE_LLM_🔑';
      const vaultOverrideEmb = 'VAULT_OVERRIDE_EMB_🔑';
      await vault.store(llmSlot, vaultOverrideLlm);
      await vault.store(embSlot, vaultOverrideEmb);

      final hydrated = await adapter.hydrateFromVaultOrFallback(legacyRow);
      expect(hydrated.apiKey, vaultOverrideLlm);
      expect(hydrated.embeddingApiKey, vaultOverrideEmb);
      // Original rowConfig object remains non-destructively intact.
      expect(legacyRow.apiKey, llmCanary);
      expect(legacyRow.embeddingApiKey, embCanary);
      expect(
        adapter.redactor.redactText('$vaultOverrideLlm $vaultOverrideEmb'),
        isNot(anyOf(contains(vaultOverrideLlm), contains(vaultOverrideEmb))),
      );
    },
  );

  test(
    'deleteConfigCredentials deletes both vault slots and revokes broker handles',
    () async {
      final config = ApiConfig(
        id: 'del-1',
        apiKey: llmCanary,
        embeddingApiKey: embCanary,
      );
      await adapter.syncConfigToVault(config);

      final llmSlot = ApiConfigCredentialAdapter.llmSlot('del-1');
      final embSlot = ApiConfigCredentialAdapter.embeddingSlot('del-1');
      final llmHandle = await broker.bind(llmSlot, llmRoute);
      final embHandle = await broker.bind(embSlot, embRoute);

      await adapter.deleteConfigCredentials('del-1');

      expect((await vault.metadata(llmSlot)).configured, isFalse);
      expect((await vault.metadata(embSlot)).configured, isFalse);
      for (final handle in [llmHandle, embHandle]) {
        await expectLater(
          broker.metadata(handle),
          throwsA(
            isA<CredentialBrokerException>().having(
              (e) => e.failure,
              'failure',
              CredentialBrokerFailure.revoked,
            ),
          ),
        );
      }
    },
  );

  test(
    'projectMetadata & projectAllMetadata report rune counts, sanitize URLs, and never leak canaries',
    () async {
      // Config 1: Vault-seeded with Unicode secrets and credential-bearing URLs.
      const vaultLlmSecret = 'A🔐е\u0301_VAULT_SECRET';
      await vault.store(
        ApiConfigCredentialAdapter.llmSlot('proj-vault'),
        vaultLlmSecret,
      );
      final vaultConfig = ApiConfig(
        id: 'proj-vault',
        name: 'Vault Provider $vaultLlmSecret',
        providerId: 'openai',
        protocol: 'openai',
        endpoint:
            'https://user:$vaultLlmSecret@api.openai.com/v1/chat/completions?api_key=$vaultLlmSecret#frag',
        apiKey: '', // Empty on row, present in vault
        model: 'gpt-4o-$paramCanary',
        embeddingUseSame: false,
        embeddingEnabled: true,
        embeddingEndpoint:
            'https://api.openai.com/v1/embeddings?key=$embCanary#secret',
        embeddingApiKey: embCanary, // Legacy fallback on row
        embeddingModel: 'text-embedding-3-small',
        extraRequestParameters: const [
          ExtraRequestParameter(key: 'api_key', value: paramCanary),
        ],
      );

      // Config 2: Unconfigured empty keys and blank embedding endpoint.
      const unconfiguredConfig = ApiConfig(
        id: 'proj-empty',
        name: 'Unconfigured',
        endpoint: 'https://api.openai.com/v1/chat/completions',
      );

      final projection = await adapter.projectMetadata(vaultConfig);
      expect(projection, isA<ApiConnectionMetadata>());
      expect(projection.configured, isTrue);
      expect(projection.characterCount, vaultLlmSecret.runes.length);
      expect(projection.embeddingConfigured, isTrue);
      expect(projection.embeddingCharacterCount, embCanary.runes.length);
      expect(projection.endpoint, 'https://api.openai.com/v1/chat/completions');
      expect(
        projection.embeddingEndpoint,
        'https://api.openai.com/v1/embeddings',
      );

      final jsonString = jsonEncode(projection.toJson());
      final strOutput = projection.toString();
      for (final secret in [vaultLlmSecret, embCanary, paramCanary]) {
        expect(jsonString, isNot(contains(secret)));
        expect(strOutput, isNot(contains(secret)));
      }

      final all = await adapter.projectAllMetadata([
        vaultConfig,
        unconfiguredConfig,
      ]);
      expect(all, hasLength(2));
      expect(all[0], projection);
      expect(all[1].configured, isFalse);
      expect(all[1].characterCount, 0);
      expect(all[1].embeddingConfigured, isFalse);
      expect(all[1].embeddingCharacterCount, 0);
      expect(all[1].embeddingEndpoint, '');
    },
  );

  test(
    'Riverpod providers wire storage, vault, redactor, and adapter',
    () async {
      final container = ProviderContainer(
        overrides: [credentialStorageProvider.overrideWithValue(storage)],
      );
      addTearDown(container.dispose);

      final providedAdapter = container.read(
        apiConfigCredentialAdapterProvider,
      );
      final config = ApiConfig(
        id: 'provider-test',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        apiKey: llmCanary,
      );
      await providedAdapter.syncConfigToVault(config);
      expect(
        container.read(secretRedactorProvider).redactText(llmCanary),
        SecretRedactor.removed,
      );

      final providedVault = container.read(credentialVaultProvider);
      final meta = await providedVault.metadata(
        ApiConfigCredentialAdapter.llmSlot('provider-test'),
      );
      expect(meta.configured, isTrue);
      expect(meta.characterCount, llmCanary.runes.length);
    },
  );
}
