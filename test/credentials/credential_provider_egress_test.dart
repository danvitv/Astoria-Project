import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

import 'fake_credential_storage.dart';

final class _CaptureSink implements LlmRequestCaptureSink {
  final events = <LlmRequestCaptureEvent>[];
  @override
  void record(LlmRequestCaptureEvent event) => events.add(event);
}

void main() {
  const llm = 'CUSTOM_CANARY_LLM_ключ';
  const embedding = 'CUSTOM_CANARY_EMBED_🧪';
  const parameter = 'CUSTOM_CANARY_PARAMETER_секрет';
  const nested = 'CUSTOM_CANARY_NESTED_пароль';
  late ProviderContainer container;
  late _CaptureSink sink;

  setUp(() {
    container = ProviderContainer(
      overrides: [
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
      ],
    );
    sink = _CaptureSink();
    final previousSink = LlmRequestCapture.sink;
    LlmRequestCapture.sink = sink;
    addTearDown(() {
      container.dispose();
      LlmRequestCapture.sink = previousSink;
    });
  });

  void expectEgress(Iterable<String> secrets) {
    final probe = 'ordinary diagnostic ${secrets.join(' ')} still usable';
    final snapshot = container.read(secretRedactorProvider);
    final request = LlmRequestCapture.sanitizeRequest(
      ChatTransportRequest.fromApiConfig(
        const ApiConfig(id: 'capture', endpoint: 'https://provider.test/v1'),
        messages: [
          {'role': 'user', 'content': probe},
        ],
      ),
    );
    LlmRequestCapture.recordAuxiliary(
      stage: 'embeddings',
      endpoint: 'https://provider.test/v1',
      model: 'model',
      messages: [
        {'role': 'user', 'content': probe},
      ],
      params: {'description': probe},
    );
    final outputs = [
      snapshot.redactText(probe),
      jsonEncode(request.request),
      jsonEncode(sink.events.last.toJson()),
      formatError(probe),
    ];
    for (final output in outputs) {
      expect(output, contains('ordinary diagnostic'));
      expect(output, contains('still usable'));
      for (final secret in secrets) {
        expect(output, isNot(contains(secret)));
      }
    }
  }

  test(
    'sync registers every canary synchronously across all egress sinks',
    () async {
      final adapter = container.read(apiConfigCredentialAdapterProvider);
      final pending = adapter.syncConfigToVault(
        const ApiConfig(
          id: 'sync',
          apiKey: llm,
          embeddingApiKey: embedding,
          extraRequestParameters: [
            ExtraRequestParameter(key: 'x-api-key', value: parameter),
            ExtraRequestParameter(
              key: 'custom',
              value: '{"password":"$nested"}',
            ),
          ],
        ),
      );
      // No await and no test-side redactor assignment: registration precedes I/O.
      expectEgress([llm, embedding, parameter, nested]);
      await pending;
      const rotated = 'ROTATED_CUSTOM_CANARY';
      await adapter.syncConfigToVault(
        const ApiConfig(id: 'sync', apiKey: rotated),
      );
      await adapter.deleteConfigCredentials('sync');
      expectEgress([llm, embedding, parameter, nested, rotated]);
    },
  );

  test(
    'hydrate registers vault-only values and preserves legacy Drift fallback',
    () async {
      final vault = container.read(credentialVaultProvider);
      await vault.store(ApiConfigCredentialAdapter.llmSlot('hydrate'), llm);
      await vault.store(
        ApiConfigCredentialAdapter.embeddingSlot('hydrate'),
        embedding,
      );
      final adapter = container.read(apiConfigCredentialAdapterProvider);
      final hydrated = await adapter.hydrateFromVaultOrFallback(
        const ApiConfig(id: 'hydrate', apiKey: 'LEGACY_STALE_CANARY'),
      );
      expect(hydrated.apiKey, llm);
      expect(hydrated.embeddingApiKey, embedding);
      expectEgress([llm, embedding, 'LEGACY_STALE_CANARY']);
      const row = ApiConfig(id: 'legacy', apiKey: parameter);
      expect((await adapter.hydrateFromVaultOrFallback(row)).apiKey, parameter);
      expect(row.apiKey, parameter);
      expect(
        (await vault.metadata(
          ApiConfigCredentialAdapter.llmSlot('legacy'),
        )).configured,
        isTrue,
      );
      expectEgress([parameter]);
    },
  );

  test(
    'deletion registers previously unhydrated vault keys for old diagnostics',
    () async {
      final vault = container.read(credentialVaultProvider);
      await vault.store(ApiConfigCredentialAdapter.llmSlot('delete'), llm);
      await vault.store(
        ApiConfigCredentialAdapter.embeddingSlot('delete'),
        embedding,
      );
      await container
          .read(apiConfigCredentialAdapterProvider)
          .deleteConfigCredentials('delete');
      expect(
        (await vault.metadata(
          ApiConfigCredentialAdapter.llmSlot('delete'),
        )).configured,
        isFalse,
      );
      expectEgress([llm, embedding]);
    },
  );

  test(
    'metadata registration updates egress without any persistence call',
    () async {
      final adapter = container.read(apiConfigCredentialAdapterProvider);
      await adapter.projectMetadata(
        const ApiConfig(id: 'metadata', apiKey: llm),
      );
      expectEgress([llm]);
    },
  );

  test(
    'reactive consumers update without replacing adapter or vault state',
    () async {
      final observed = <SecretRedactor>[];
      container.listen(
        secretRedactorProvider,
        (_, next) => observed.add(next),
        fireImmediately: true,
      );
      final dependent = Provider<String>(
        (ref) => ref.watch(secretRedactorProvider).redactText(llm),
      );
      final values = <String>[];
      container.listen(
        dependent,
        (_, next) => values.add(next),
        fireImmediately: true,
      );
      final adapter = container.read(apiConfigCredentialAdapterProvider);
      final vault = container.read(credentialVaultProvider);
      await adapter.syncConfigToVault(
        const ApiConfig(id: 'reactive', apiKey: llm),
      );
      await container.pump();
      expect(observed.length, greaterThan(1));
      expect(values, [llm, SecretRedactor.removed]);
      expect(container.read(apiConfigCredentialAdapterProvider), same(adapter));
      expect(container.read(credentialVaultProvider), same(vault));
      expect(container.read(secretRedactorProvider), same(adapter.redactor));
    },
  );

  test(
    'ordinary >8k auxiliary trees survive with capture budgets and secrets gone',
    () async {
      await container
          .read(apiConfigCredentialAdapterProvider)
          .syncConfigToVault(const ApiConfig(id: 'large', apiKey: llm));
      final ordinary = 'ordinary prompt text ' * 1000;
      Object? deep = 'deep $llm';
      for (var i = 0; i < 20; i++) {
        deep = {'child': deep};
      }
      LlmRequestCapture.recordAuxiliary(
        stage: 'image',
        endpoint: 'https://provider.test',
        model: 'image',
        params: {
          'description': '$ordinary$llm end',
          'deep': deep,
          'rows': List.generate(600, (i) => 'row $i $llm'),
        },
      );
      final captured = sink.events.single.request;
      expect(captured['description'], '$ordinary[REDACTED] end');
      expect(captured['rows'], hasLength(600));
      expect(jsonEncode(captured), isNot(contains(llm)));
      expect(jsonEncode(captured), isNot(contains(SecretRedactor.limited)));
      expect(LlmRequestCapture.redactor!.maxInputLength, 200000);
      expect(LlmRequestCapture.redactor!.maxOutputLength, 400000);
      expect(LlmRequestCapture.redactor!.maxDepth, 32);
      expect(LlmRequestCapture.redactor!.maxNodes, 4096);
    },
  );
}
