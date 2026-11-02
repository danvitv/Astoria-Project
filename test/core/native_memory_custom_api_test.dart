import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/memory_custom_api_credential_owner.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/aux_retry_runner.dart';
import 'package:glaze_flutter/core/llm/memory_custom_api_publication.dart';
import 'package:glaze_flutter/core/llm/transport/memory_custom_api_transport.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/memory_custom_api_credentials_provider.dart';
import 'package:glaze_flutter/core/state/pipeline_settings_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/chat/memory_draft_generator.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import '../credentials/fake_credential_storage.dart';
import '../support/memory_setup/memory_setup_preferences_backing.dart';
import 'native_provider_consumer_memory_fixture.dart';

const _key = 'SYNTHETIC_NATIVE_CUSTOM_MEMORY_KEY';
const _url = 'https://synthetic.example/custom/exact-operation?tenant=1';

Future<void> _withCustom(
  Future<void> Function(
    NativeMemoryConsumerFixture fixture,
    ProviderContainer settings,
    MemoryCustomApiCredentialOwner owner,
    FakeCredentialStorage storage,
  )
  body,
) async {
  final isolation = NativeRoleplayIsolation();
  await isolation.run(() async {
    final f = NativeMemoryConsumerFixture(isolation);
    final initial = <String, Object>{
      'pipelineSettings': jsonEncode({
        'studioAgent': <String, dynamic>{},
        'memoryBookApi': {
          'generationSource': 'custom',
          'generationEndpoint': _url,
          'generationModel': 'synthetic-model',
          'generationApiKey': '',
        },
      }),
    };
    SharedPreferences.setMockInitialValues(initial);
    final previous = SharedPreferencesStorePlatform.instance;
    SharedPreferencesStorePlatform.instance = MemorySetupPreferencesBacking(
      initial,
    );
    ProviderContainer? settings;
    MemoryCustomApiCredentialOwner? owner;
    try {
      final prefs = await TrackedSharedPreferences.getInstance();
      final storage = FakeCredentialStorage();
      final vault = CredentialVault(storage: storage, buildChannel: 'dev');
      owner = MemoryCustomApiCredentialOwner(
        vault: vault,
        redaction: f.source.wire.core.redaction,
        originalPreferences: Future.value(prefs),
      );
      isolation.allowed.addAll({
        pipelineSettingsProvider,
        sharedPreferencesProvider,
        memoryCustomApiLegacySourceProvider,
        memoryCustomApiCredentialOwnerProvider,
        secretRedactionCoordinatorProvider,
      });
      settings = ProviderContainer(
        observers: [isolation],
        overrides: [
          sharedPreferencesProvider.overrideWith((_) async => prefs),
          memoryCustomApiLegacySourceProvider.overrideWithValue(owner.source),
          memoryCustomApiCredentialOwnerProvider.overrideWithValue(owner),
          secretRedactionCoordinatorProvider.overrideWithValue(
            f.source.wire.core.redaction,
          ),
        ],
      );
      await settings.read(pipelineSettingsProvider.notifier).load();
      f.source.wire.contentType = 'application/json';
      f.source.wire.response = nativeTransportJson('custom_chat_completion');
      await body(f, settings, owner, storage);
    } finally {
      settings?.dispose();
      owner?.dispose();
      await f.close();
      SharedPreferencesStorePlatform.instance = previous;
    }
  });
}

Future<MemoryDraft> _generate(
  NativeMemoryConsumerFixture f,
  ProviderContainer settings,
  MemoryCustomApiCredentialOwner owner,
) => f.own(
  MemoryDraftGenerator.settings(
    read: f.container.read,
    sources: f.source.sources,
    customApiOwner: owner,
    llm: AuxLlmClient(memoryCustomAdapterFactory: f.source.wire.adapter),
    isCurrent: () => f.source.runCurrent,
  ).generate(
    draft: const MemoryDraft(id: 'custom-draft', messageIds: ['m1']),
    settings: const MemoryBookSettings(),
    pipeline: settings.read(pipelineSettingsProvider),
    messages: const [
      ChatMessage(
        id: 'm1',
        role: 'user',
        content: 'Synthetic history',
        timestamp: 1,
      ),
    ],
    charId: 'character',
    sessionId: 'original-session',
    sessionVars: const {},
    cancelToken: CancelToken(),
  ),
);

final class _ClosingAdapter implements HttpClientAdapter {
  _ClosingAdapter(this.inner, this.afterClose, {this.onFetch});
  final HttpClientAdapter inner;
  final void Function() afterClose;
  final void Function(RequestOptions)? onFetch;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? stream,
    Future<void>? cancelFuture,
  ) {
    onFetch?.call(options);
    return inner.fetch(options, stream, cancelFuture);
  }

  @override
  void close({bool force = false}) {
    inner.close(force: true);
    afterClose();
  }
}

void main() {
  test(
    'actual settings -> keyless DTO -> existing draft -> ephemeral native POST',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      final entry = await owner.setApiKey(
        _key,
        settings: api,
        isCurrent: () => true,
      );
      expect(entry.verifiedCommit, true);
      expect(api.generationApiKey, '');
      expect(
        settings.read(pipelineSettingsProvider).toJson().toString(),
        isNot(contains(_key)),
      );
      f.source.wire.response = nativeTransportJson(
        'custom_chat_completion',
        text: 'Visible $_key',
        reasoning: 'Reasoning $_key',
      );
      final draft = await _generate(f, settings, owner);
      expect(draft.content, contains('Visible'));
      expect(draft.content, isNot(contains(_key)));
      expect(f.source.wire.wires.length, 1);
      final wire = f.source.wire.wires.single;
      expect(wire.uri, Uri.parse(_url));
      expect(wire.method, 'POST');
      expect(
        wire.headers.entries
            .singleWhere((entry) => entry.key.toLowerCase() == 'authorization')
            .value,
        'Bearer $_key',
      );
      expect(wire.body.toString(), isNot(contains(_key)));
      expect(f.source.wire.legacy.requests, isEmpty);
      expect(
        f.source.repo.reads,
        0,
      ); // Saved Memory purpose is not a custom grant.
    }),
  );

  test(
    'tampered URI operation refuses before adapter dispatch',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(_key, settings: api, isCurrent: () => true);
      final original = owner.capture(api, isCurrent: () => true);
      await expectLater(
        AuxLlmClient(
          memoryCustomAdapterFactory: f.source.wire.adapter,
        ).callOnce(
          config: AuxApiConfig(
            apiKey: '',
            endpoint: 'https://synthetic.example/custom/other-operation',
            model: api.generationModel,
            protocol: 'custom_chat_completion',
            memoryCustomApi: original,
          ),
          prompt: 'Synthetic',
          maxTokens: 100,
          temperature: 0,
          timeoutMs: 0,
        ),
        throwsA(isA<NativeProviderException>()),
      );
      expect(f.source.wire.wires, isEmpty);
      expect(f.source.wire.adapters, isEmpty);
    }),
  );

  test(
    'each auxiliary retry retains original custom custody; raw callbacks are safe',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(_key, settings: api, isCurrent: () => true);
      final original = owner.capture(api, isCurrent: () => true);
      final config = AuxApiConfig(
        apiKey: '',
        endpoint: api.generationEndpoint,
        model: api.generationModel,
        protocol: 'custom_chat_completion',
        memoryCustomApi: original,
      );
      final client = AuxLlmClient(
        memoryCustomAdapterFactory: f.source.wire.adapter,
        retryPolicy: const AuxRetryPolicy(maxAttempts: 2, backoffDelays: []),
      );
      f.source.wire.response = nativeTransportJson(
        'custom_chat_completion',
        text: 'Visible $_key',
        reasoning: 'Reasoning $_key',
      );
      final raw = <String>[];
      await client.callOnce(
        config: config,
        prompt: 'Synthetic',
        maxTokens: 100,
        temperature: 0,
        timeoutMs: 0,
        onRawResponse: (reasoning, json) {
          raw.addAll([reasoning ?? '', json ?? '']);
        },
      );
      expect(raw, isNotEmpty);
      expect(raw.join(), isNot(contains(_key)));
      f.source.wire.status = 503;
      final previousWires = f.source.wire.wires.length;
      final outcome = await client.callOnceWithLog(
        config: config,
        prompt: 'Synthetic',
        maxTokens: 100,
        temperature: 0,
        timeoutMs: 0,
        onAttemptStart: (attempt, _) async {
          if (attempt == 2) {
            await owner.setApiKey(
              'SYNTHETIC_ROTATED_RETRY_KEY',
              settings: api,
              isCurrent: () => true,
            );
          }
        },
      );
      expect(outcome.isOk, false);
      expect(outcome.lastError, isA<CredentialVaultAdmissionDenied>());
      expect(f.source.wire.wires.length, previousWires + 1);
      expect(outcome.attempts.length, 2);
      expect(outcome.attempts.toString(), isNot(contains(_key)));
    }),
  );

  for (final change in ['key rotation', 'ordinary settings']) {
    test(
      'held actual native response refuses late completion: $change',
      () => _withCustom((f, settings, owner, storage) async {
        final api = settings.read(pipelineSettingsProvider).memoryBookApi;
        await owner.setApiKey(_key, settings: api, isCurrent: () => true);
        final gate = f.newGate();
        f.source.wire.beforeResponse = gate.hold;
        final pending = _generate(f, settings, owner);
        await f.waitUntilGateEntered(gate, pending);
        if (change == 'key rotation') {
          await owner.setApiKey(
            'SYNTHETIC_ROTATED_KEY',
            settings: api,
            isCurrent: () => true,
          );
        } else {
          final globals = settings.read(pipelineSettingsProvider);
          await settings
              .read(pipelineSettingsProvider.notifier)
              .save(
                globals.copyWith(
                  memoryBookApi: api.copyWith(generationTemperature: 0.7),
                ),
              );
        }
        gate.release();
        await expectLater(
          pending,
          throwsA(isA<CredentialVaultAdmissionDenied>()),
        );
        expect(f.source.wire.wires.length, 1);
        expect(f.source.wire.legacy.requests, isEmpty);
      }),
    );
  }

  test(
    'dependent publication re-redacts CURRENT aliases and rejects rotation',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(_key, settings: api, isCurrent: () => true);
      final original = owner.capture(api, isCurrent: () => true);
      final snapshot = original.captureRedactor();
      const lateKey = 'SYNTHETIC_LATE_OTHER_SECRET';
      f.source.wire.core.redaction.registerSecret(lateKey);
      final sanitized = sanitizeCustomMemoryDraft(
        const MemoryDraft(
          id: 'draft',
          content: lateKey,
          keys: [lateKey],
          keyParagraphs: {
            lateKey: [1],
          },
        ),
        original,
        snapshot,
      );
      expect(sanitized.content, isNot(contains(lateKey)));
      expect(sanitized.keys.join(), isNot(contains(lateKey)));
      expect(sanitized.keyParagraphs.keys.join(), isNot(contains(lateKey)));
      await owner.setApiKey(
        'SYNTHETIC_ROTATED_KEY',
        settings: api,
        isCurrent: () => true,
      );
      expect(
        () => sanitizeCustomMemoryDraft(sanitized, original, snapshot),
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
    }),
  );

  test(
    'native adapter close re-redacts entire cached failure before 500-char attempt clipping',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(_key, settings: api, isCurrent: () => true);
      final original = owner.capture(api, isCurrent: () => true);
      const lateKey =
          'SYNTHETIC_LATE_CLOSE_ALIAS_CROSSING_FIVE_HUNDRED_CHARACTERS';
      const prefix = 'SYNTHETIC_LATE';
      final options = RequestOptions(
        path: _url,
        headers: {'Authorization': 'Bearer $_key'},
      );
      final probe = DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
        message: 'MARK',
      ).toString();
      final padding = List.filled(480 - probe.indexOf('MARK'), 'x').join();
      final message = '$padding$lateKey original=$_key';
      f.source.wire.fetchError = DioException(
        requestOptions: options,
        type: DioExceptionType.receiveTimeout,
        message: message,
        error: StateError('SYNTHETIC_PRIVATE_ERROR_CAUSE'),
      );
      final closes = <bool>[];
      final client = AuxLlmClient(
        retryPolicy: const AuxRetryPolicy(maxAttempts: 2, backoffDelays: []),
        memoryCustomAdapterFactory: () =>
            _ClosingAdapter(f.source.wire.adapter(), () {
              closes.add(true);
              f.source.wire.core.redaction.registerSecret(lateKey);
            }),
      );
      final outcome = await client.callOnceWithLog(
        config: AuxApiConfig(
          apiKey: '',
          endpoint: api.generationEndpoint,
          model: api.generationModel,
          protocol: 'custom_chat_completion',
          memoryCustomApi: original,
        ),
        prompt: 'Synthetic',
        maxTokens: 100,
        temperature: 0,
        timeoutMs: 0,
      );
      expect(closes, [true, true]);
      expect(outcome.isOk, false);
      expect(outcome.lastError, isA<DioException>());
      final error = outcome.lastError! as DioException;
      expect(error.type, DioExceptionType.receiveTimeout);
      expect(error.requestOptions.path, '');
      expect(error.requestOptions.headers, isEmpty);
      expect(error.error, isNull);
      expect(outcome.attempts, hasLength(2)); // Dio timeout remains retryable.
      for (final text in [
        error.toString(),
        ...outcome.attempts.map((attempt) => attempt.error!),
      ]) {
        expect(text, isNot(contains(_key)));
        expect(text, isNot(contains(prefix)));
        expect(text, isNot(contains(lateKey)));
        expect(text, isNot(contains(_url)));
        expect(text, isNot(contains('SYNTHETIC_PRIVATE_ERROR_CAUSE')));
      }
      expect(
        outcome.attempts.every((attempt) => attempt.error!.length <= 501),
        true,
      );
      expect(f.source.wire.wires, hasLength(2));
    }),
  );

  test(
    'native error delivery refuses custody retired during adapter close',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(_key, settings: api, isCurrent: () => true);
      final original = owner.capture(api, isCurrent: () => true);
      Future<MemoryCustomApiAuthSummary>? rotation;
      f.source.wire.fetchError = DioException(
        requestOptions: RequestOptions(path: _url),
        type: DioExceptionType.receiveTimeout,
        message: 'SYNTHETIC_RETIRED_CACHED_ERROR',
      );
      final errors = <Object>[];
      final pending = f.own(
        MemoryCustomApiTransport(
          original,
          adapterFactory: () => _ClosingAdapter(f.source.wire.adapter(), () {
            // Native intent retires the original synchronously, before vault IO.
            rotation = owner.setApiKey(
              'SYNTHETIC_CLOSE_ROTATED_KEY',
              settings: api,
              isCurrent: () => true,
            );
          }),
        ).stream(
          request: ChatTransportRequest(
            apiKey: '',
            endpoint: api.generationEndpoint,
            model: api.generationModel,
            maxTokens: api.generationMaxTokens ?? 1024,
            temperature: api.generationTemperature ?? 0.2,
            topP: 1.0,
            stream: false,
            messages: const [
              {'role': 'user', 'content': 'Synthetic'},
            ],
          ),
          cancelToken: CancelToken(),
          onError: errors.add,
        ),
      );
      await expectLater(
        pending,
        throwsA(isA<CredentialVaultAdmissionDenied>()),
      );
      await rotation;
      expect(errors, isEmpty); // Not merely hidden by a later auxiliary guard.
      expect(original.isCurrent(), false);
      expect(f.source.wire.wires, hasLength(1));
    }),
  );

  test(
    'native custom HTTP 408 retry retains original endpoint and custody with no redirect',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(_key, settings: api, isCurrent: () => true);
      final original = owner.capture(api, isCurrent: () => true);
      f.source.wire.status = 408;
      final dispatches = <RequestOptions>[];
      final pending =
          AuxLlmClient(
            retryPolicy: const AuxRetryPolicy(
              maxAttempts: 1,
              backoffDelays: [],
            ),
            memoryCustomAdapterFactory: () => _ClosingAdapter(
              f.source.wire.adapter(),
              () {},
              onFetch: dispatches.add,
            ),
          ).callOnceWithLog(
            config: AuxApiConfig(
              apiKey: '',
              endpoint: api.generationEndpoint,
              model: api.generationModel,
              protocol: 'custom_chat_completion',
              memoryCustomApi: original,
            ),
            prompt: 'Synthetic',
            maxTokens: 100,
            temperature: 0,
            timeoutMs: 0,
          );
      final outcome = await pending;
      expect(outcome.isOk, false);
      expect(outcome.attempts, hasLength(1));
      expect(outcome.attempts.single.statusCode, 408);
      expect((outcome.lastError! as DioException).response!.statusCode, 408);
      expect(
        f.source.wire.wires,
        hasLength(2),
      ); // Existing inner transport retry.
      expect(dispatches, hasLength(2));
      for (final options in dispatches) {
        expect(options.followRedirects, false);
        expect(options.maxRedirects, 0);
      }
      for (final wire in f.source.wire.wires) {
        expect(wire.uri, Uri.parse(_url));
        expect(wire.method, 'POST');
        expect(
          wire.headers.entries
              .singleWhere(
                (entry) => entry.key.toLowerCase() == 'authorization',
              )
              .value,
          'Bearer $_key',
        );
      }
      expect(original.isCurrent(), true);
      expect(f.source.wire.adapters, hasLength(1));
      expect(f.source.wire.legacy.requests, isEmpty);
    }),
  );

  test(
    'cleared native key refuses actual draft with no legacy fallback',
    () => _withCustom((f, settings, owner, storage) async {
      final api = settings.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(_key, settings: api, isCurrent: () => true);
      await owner.setApiKey('', settings: api, isCurrent: () => true);
      await expectLater(
        _generate(f, settings, owner),
        throwsA(isA<CredentialVaultException>()),
      );
      expect(storage.values.values.single, '');
      expect(f.source.wire.wires, isEmpty);
      expect(f.source.wire.legacy.requests, isEmpty);
    }),
  );

  test(
    'native throw-after-persist is explicit unknown commit, never pre-start denial',
    () => _withCustom((f, settings, owner, storage) async {
      final native = MemoryCustomApiCredentialOwner(
        vault: f.source.wire.core.genericVault,
        redaction: f.source.wire.core.redaction,
        originalPreferences: settings.read(sharedPreferencesProvider.future),
        originalSource: owner.source,
      );
      try {
        f.source.wire.core.storage.writeThenThrow = true;
        final summary = await native.setApiKey(
          _key,
          settings: settings.read(pipelineSettingsProvider).memoryBookApi,
          isCurrent: () => true,
        );
        expect(summary.unknownCommit, true);
        expect(summary.verifiedCommit, false);
        expect(f.source.wire.core.storage.values.values.single, contains(_key));
        expect(f.source.wire.wires, isEmpty);
      } finally {
        native.dispose();
      }
    }),
  );
}
