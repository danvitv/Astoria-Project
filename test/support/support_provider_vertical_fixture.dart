import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/llm/transport/chat_transport_request.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_provider_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_provider_ui_binding.dart';

import 'support_provider_action_fixture.dart';

export 'package:glaze_flutter/features/support_assistant/state/support_provider_ui_binding.dart';
export 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';

/// ACTUAL ApiConfigRepo provider association + actual C/P/Service/lease/vault.
/// The only IO is explicit memory SQLite/FakeStorage and a recording wire adapter.
final class ProviderVerticalFixture {
  final backing = ProviderActionFixture();
  final requests = <RequestOptions>[];
  ProviderContainer? _container;
  ProviderContainer get container => _container!;
  final bindings = <SupportProviderUiBinding>[];
  bool uiCurrent = true;

  ApiConfigRepo get api => container.read(apiConfigRepoProvider);
  NativeProviderRuntime get native =>
      container.read(nativeProviderRuntimeProvider)!;
  SupportNativeConsentController get controller =>
      container.read(supportNativeConsentControllerProvider);

  Future<void> initialize({bool permissions = true}) async {
    await backing.seed();
    final store = SupportPermissionStore(backing.support);
    await store.selectScopeFromNative(
      ProviderActionFixture.sessionId,
      SupportPermissionScope(
        selectionRevision: 1,
        safeCategories: const [SupportSafeCategory.connections],
      ),
      isCurrent: () => true,
    );
    if (permissions) {
      for (final right in [
        SupportPermission.readSafeSettings,
        SupportPermission.confirmedSettingsChanges,
      ]) {
        await store.setGrantFromNative(
          ProviderActionFixture.sessionId,
          right,
          true,
          isCurrent: () => true,
        );
      }
    }
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    _container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(backing.db),
        credentialVaultProvider.overrideWithValue(backing.vault),
        secretRedactionCoordinatorProvider.overrideWithValue(backing.redaction),
        sharedPreferencesProvider.overrideWith((ref) async => prefs),
        nativeProviderAdapterFactoryProvider.overrideWithValue(
          () => ProviderVerticalAdapter(requests),
        ),
      ],
    );
    controller.runtime.selectSession(ProviderActionFixture.sessionId);
    await controller.runtime.refresh();
    expect(controller.runtime.localActionsAvailable, isTrue);
    expect(container.read(nativeProviderRuntimeProvider), isNotNull);
    expect(
      identical(native, container.read(nativeProviderRuntimeProvider)),
      isTrue,
    );
  }

  SupportProviderUiBinding bind() {
    final binding = SupportProviderUiBinding(
      controller: controller,
      service: container.read(supportProviderActionServiceProvider)!,
      native: native,
      api: api,
      redaction: backing.redaction,
      isOriginalUi: () => uiCurrent,
    );
    bindings.add(binding);
    return binding;
  }

  SupportProviderSetupInput input({String name = 'Synthetic provider'}) =>
      SupportProviderSetupInput(
        purpose: SupportProviderPurpose.roleplay,
        name: name,
        protocol: 'openai',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        model: 'synthetic-model',
        maxTokens: 512,
        contextSize: 32768,
        temperature: 0.7,
      );

  Future<String> send(SupportProviderConnectionHandle handle) async {
    final source = native.sources.captureOriginalStamp();
    final row = (await api.getById(handle.value!.connectionId))!;
    final prepared = await native.sources.prepare(
      originalStamp: source,
      configuration: row,
      purpose: NativeProviderPurpose.roleplay,
      isCurrent: () => uiCurrent,
    );
    expect(prepared.configuration.apiKey, isEmpty);
    expect(prepared.configuration.embeddingApiKey, isEmpty);
    final done = Completer<String>();
    await native.transports
        .pick('openai')
        .stream(
          request: ChatTransportRequest.fromApiConfig(
            prepared.configuration,
            messages: const [
              {'role': 'user', 'content': 'Synthetic request'},
            ],
            savedConnectionAuth: prepared.savedConnectionAuth,
            nativeSourceIsCurrent: () => prepared.isCurrent && uiCurrent,
          ),
          onComplete: (text, reasoning, {rawResponseJson}) =>
              done.complete(text),
          onError: (error) =>
              done.completeError(StateError('Synthetic wire refused')),
        );
    return done.future;
  }

  Future<void> close() async {
    for (final binding in bindings) {
      binding.dispose();
    }
    _container?.dispose();
    backing.clearHooks();
    backing.service.dispose();
    backing.mutations.dispose();
    backing.redaction.dispose();
    await backing.db.close();
  }
}

final class ProviderVerticalAdapter implements HttpClientAdapter {
  ProviderVerticalAdapter(this.requests);
  final List<RequestOptions> requests;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    await requestStream?.drain<void>();
    requests.add(options);
    return ResponseBody.fromString(
      'data: {"choices":[{"index":0,"delta":{"content":"Synthetic reply"},"finish_reason":null}]}\n\n'
      'data: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\n'
      'data: [DONE]\n\n',
      200,
      headers: {
        'content-type': ['text/event-stream'],
      },
    );
  }

  @override
  void close({bool force = false}) {}
}

void providerVerticalTest(
  String name,
  Future<void> Function(ProviderVerticalFixture) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String kind) {
      attempts.add(kind);
      throw StateError('Outside declared synthetic provider vertical');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('platform');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final f = ProviderVerticalFixture();
            try {
              await f.initialize();
              await body(f);
            } finally {
              await f.close();
              await messenger.platformMessagesFinished;
              expect(attempts, isEmpty);
            }
          },
          createFile: (_) => block('file/default DB'),
          createDirectory: (_) => block('directory'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HTTP/default transport'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}
