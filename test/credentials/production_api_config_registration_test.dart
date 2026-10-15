import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

import 'fake_credential_storage.dart';

void main() {
  // Plain alphanumeric/Unicode canaries that do NOT match any built-in regex
  // (no sk-, no bearer, no query param, no ghp_, etc.).
  const llmCanary = 'plaincustomkeyalpha99887766';
  const embCanary = 'plainembedkeybeta55443322';
  const directExtraCanary = 'plainextradirectgamma112233';
  const nestedExtraCanary = 'plainextranesteddelta445566';

  late AppDatabase db;
  late FakeCredentialStorage storage;

  setUp(() {
    LlmRequestCapture.redactor = null;
    activeErrorRedactor = null;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    storage = FakeCredentialStorage();
  });

  tearDown(() async {
    LlmRequestCapture.redactor = null;
    activeErrorRedactor = null;
    await db.close();
  });

  ProviderContainer createContainer() {
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        credentialStorageProvider.overrideWithValue(storage),
      ],
    );
    addTearDown(container.dispose);
    return container;
  }

  ApiConfig buildCanaryConfig({
    String id = 'cfg-prod-1',
    String apiKey = llmCanary,
    String embeddingApiKey = embCanary,
  }) {
    return ApiConfig(
      id: id,
      name: 'Production Canary Config',
      endpoint: 'https://api.example.org/v1/chat/completions',
      apiKey: apiKey,
      embeddingApiKey: embeddingApiKey,
      model: 'custom-model',
      extraRequestParameters: const [
        ExtraRequestParameter(
          key: 'x_custom_secret',
          value: directExtraCanary,
        ),
        ExtraRequestParameter(
          key: 'provider_options',
          value: '{"nested":{"api_key":"$nestedExtraCanary"}}',
        ),
      ],
    );
  }

  void expectCanariesRedacted(Iterable<String> secrets) {
    final probeText = 'Upstream failed with ${secrets.join(' and ')}';
    final request = ChatTransportRequest(
      endpoint: 'https://api.example.org/v1/chat/completions',
      apiKey: 'unused',
      model: 'model-x',
      messages: [
        {'role': 'user', 'content': probeText},
      ],
      maxTokens: 128,
      temperature: 0.7,
      topP: 1.0,
    );

    final sanitized = LlmRequestCapture.sanitizeRequest(request);
    final sanitizedJson = jsonEncode(sanitized.request);
    final formattedError = formatError(StateError(probeText));

    for (final secret in secrets) {
      expect(
        sanitizedJson,
        isNot(contains(secret)),
        reason: 'LlmRequestCapture.sanitizeRequest leaked $secret',
      );
      expect(
        formattedError,
        isNot(contains(secret)),
        reason: 'formatError leaked $secret',
      );
    }
    expect(sanitizedJson, contains(SecretRedactor.removed));
    expect(formattedError, contains(SecretRedactor.removed));
  }

  test(
    'put through apiConfigRepoProvider registers direct and nested secrets synchronously before await',
    () async {
      final container = createContainer();
      final repo = container.read(apiConfigRepoProvider);
      final config = buildCanaryConfig();

      // Start put() without awaiting first: synchronous registration must
      // already protect diagnostics before the DB write completes.
      final putFuture = repo.put(config);
      expectCanariesRedacted([
        llmCanary,
        embCanary,
        directExtraCanary,
        nestedExtraCanary,
      ]);
      await putFuture;

      expectCanariesRedacted([
        llmCanary,
        embCanary,
        directExtraCanary,
        nestedExtraCanary,
      ]);
    },
  );

  test(
    'getAll through apiConfigRepoProvider registers secrets from existing DB rows without manual redactor wiring',
    () async {
      // Seed directly via an unhooked repo (simulating pre-existing SQLite data
      // on cold start before any provider has observed the row).
      final seedRepo = ApiConfigRepo(db);
      await seedRepo.put(buildCanaryConfig(id: 'seeded-all'));

      // Before reading through apiConfigRepoProvider, non-regex canary is unknown.
      expect(formatError(StateError(llmCanary)), contains(llmCanary));

      final container = createContainer();
      final repo = container.read(apiConfigRepoProvider);
      final configs = await repo.getAll();
      expect(configs, hasLength(1));

      expectCanariesRedacted([
        llmCanary,
        embCanary,
        directExtraCanary,
        nestedExtraCanary,
      ]);
    },
  );

  test(
    'getById through apiConfigRepoProvider registers secrets and keeps Drift authoritative over vault',
    () async {
      final seedRepo = ApiConfigRepo(db);
      await seedRepo.put(buildCanaryConfig(id: 'seeded-by-id'));

      final container = createContainer();
      final vault = container.read(credentialVaultProvider);
      // Populate vault with stale keys for the same ID: getById/getAll must
      // NOT overwrite authoritative Drift values from vault.
      await vault.store(
        ApiConfigCredentialAdapter.llmSlot('seeded-by-id'),
        'STALE_VAULT_KEY_DO_NOT_USE',
      );

      // Even if secure storage later becomes unavailable, synchronous
      // redaction registration and Drift reads must succeed.
      storage.readError = StateError('secure storage offline');

      final repo = container.read(apiConfigRepoProvider);
      final loaded = await repo.getById('seeded-by-id');
      expect(loaded, isNotNull);
      expect(loaded!.apiKey, llmCanary);
      expect(loaded.embeddingApiKey, embCanary);

      expectCanariesRedacted([
        llmCanary,
        embCanary,
        directExtraCanary,
        nestedExtraCanary,
      ]);
    },
  );
}
