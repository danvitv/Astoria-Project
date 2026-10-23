import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/llm/memory_studio_service.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_agent_providers.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/state/studio_turn_config_resolver.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/providers/prompt_build_providers.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';

import 'native_provider_consumer_roleplay_isolation.dart';
import 'native_provider_source_fixture.dart';

export 'native_provider_consumer_roleplay_isolation.dart';
export 'native_provider_source_fixture.dart';

final _syntheticBackendProvider = Provider<NativeRoleplaySyntheticBackend>(
  (_) => throw StateError('Declare the synthetic backend before graph startup'),
);
final _actualRefProvider = Provider<Ref>((ref) => ref);

/// Real Riverpod Ref and real native runtime over ONLY declared fake storage.
/// Payload/collector overrides are the pre-isolate boundary for these stale
/// preparation tests, not an alternate prompt implementation or success proof.
final class NativeRoleplaySyntheticBackend {
  NativeRoleplaySyntheticBackend(ChatSession session, this.isolation) {
    _notifier = _DeclaredChatNotifier(session);
    runtime = NativeProviderRuntime(
      vault: wire.core.genericVault,
      redaction: wire.core.redaction,
      revisions: revisions,
      readSavedConnection: (id) async => id == row.id ? row : null,
      adapterFactory: wire.adapter,
      isOriginalRoot: () => rootCurrent,
    );
    isolation.allowed.addAll({
      _syntheticBackendProvider,
      _actualRefProvider,
      nativeProviderRuntimeProvider,
      chatProvider(session.characterId),
      memoryStudioServiceProvider,
      studioTurnConfigResolverProvider,
      apiListProvider,
      activeApiConfigProvider,
    });
    try {
      container = ProviderContainer(
        observers: [isolation],
        overrides: [
          _syntheticBackendProvider.overrideWithValue(this),
          nativeProviderRuntimeProvider.overrideWithValue(runtime),
          nativeProviderAdapterFactoryProvider.overrideWithValue(wire.adapter),
          credentialStorageProvider.overrideWithValue(wire.core.storage),
          credentialVaultProvider.overrideWithValue(wire.core.genericVault),
          secretRedactionCoordinatorProvider.overrideWithValue(
            wire.core.redaction,
          ),
          apiConfigCredentialAdapterProvider.overrideWith(
            (_) => isolation.block('unexpected legacy credential adapter'),
          ),
          appDbProvider.overrideWith((_) => isolation.block('default DB')),
          apiConfigRepoProvider.overrideWith(
            (_) => isolation.block('default API repo'),
          ),
          sharedPreferencesProvider.overrideWith(
            (_) => isolation.block('preferences'),
          ),
          characterRepoProvider.overrideWith(
            (_) => isolation.block('character read'),
          ),
          presetRepoProvider.overrideWith(
            (_) => isolation.block('preset read'),
          ),
          personaRepoProvider.overrideWith(
            (_) => isolation.block('persona read'),
          ),
          imageStorageProvider.overrideWith(
            (_) => isolation.block('image/files'),
          ),
          migrationServiceProvider.overrideWith(
            (_) => isolation.block('migration'),
          ),
          llmRequestCaptureInstallationProvider.overrideWith(
            (_) => isolation.block('capture installation'),
          ),
          promptPayloadBuilderProvider.overrideWith(
            (_) => isolation.block('payload/isolate boundary'),
          ),
          promptInputsCollectorProvider.overrideWith(
            (_) => isolation.block('collector/isolate boundary'),
          ),
          chatProvider(session.characterId).overrideWith(() => _notifier),
          memoryStudioServiceProvider.overrideWithValue(
            _UnusedStudioService(isolation),
          ),
          apiListProvider.overrideWith(() => _DeclaredApiList(this)),
          activeApiConfigProvider.overrideWith(
            (ref) => ref.read(_syntheticBackendProvider).row,
          ),
          studioTurnConfigResolverProvider.overrideWith((ref) {
            final backend = ref.read(_syntheticBackendProvider);
            final originalRoot = ref.read(nativeProviderRuntimeProvider)!;
            return StudioTurnConfigResolver(
              sources: originalRoot.sources,
              isCurrent: () =>
                  ref.mounted && backend.runCurrent && backend.rootCurrent,
              readPipelineSettings: () => const PipelineSettings(),
              readStudioFeatureEnabled: () => false,
              loadApiConfigs: () async {
                await ref.read(apiListProvider.future);
              },
              readApiConfigs: () => [backend.row],
              readActiveApiConfig: () => ref.read(activeApiConfigProvider),
              loadActivePresetId: () => isolation.block('Studio preset load'),
              loadPreset: (_) => isolation.block('Studio preset read'),
              loadDefaultPreset: () => isolation.block('Studio default preset'),
            );
          }),
        ],
      );
    } catch (_) {
      rootCurrent = false;
      runtime.dispose();
      wire.core.mutations.dispose();
      revisions.dispose();
      wire.core.redaction.dispose();
      rethrow;
    }
  }

  final NativeRoleplayIsolation isolation;
  final wire = NativeTransportHarness('openai');
  final revisions = ConnectionRevisionRegistry();
  final gate = NativeSourceHeldGate();
  final pending = <Future<void>>[];
  late final NativeProviderRuntime runtime;
  late final ProviderContainer container;
  late final _DeclaredChatNotifier _notifier;
  bool runCurrent = true;
  bool rootCurrent = true;
  ApiConfig get row => wire.core.row;
  Ref get ref => container.read(_actualRefProvider);
  NativeSavedConnectionSourceResolver get sources => runtime.sources;
  CancelToken? get token => _notifier.token;

  Future<void> initialize() async {
    await container.read(chatProvider(_notifier.session.characterId).future);
  }

  Future<void> waitUntilGateEntered<T>(Future<T> job) => Future.any<void>([
    gate.entered.future,
    job.then<void>(
      (_) =>
          throw StateError('Roleplay job completed before entering its gate'),
    ),
  ]);

  Future<void> store() async {
    final reference = runtime.auth.referenceFor(
      row,
      NativeProviderPurpose.roleplay,
    )!;
    final review = await runtime.secretEntry.review(
      connection: reference,
      purposes: const {NativeProviderPurpose.roleplay},
      lifetime: wire.core.lifetime,
    );
    await runtime.credentials.storeFromNativeEntry(
      permit: runtime.secretEntry.confirmNativeEntry(review),
      secret: nativeCanary,
    );
  }

  Future<T> own<T>(Future<T> future) {
    pending.add(
      future.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
    );
    return future;
  }

  Future<void> close() async {
    runCurrent = false;
    rootCurrent = false;
    _notifier.token?.cancel('Synthetic fixture cleanup');
    gate.release();
    try {
      await Future.wait(pending);
      expect(wire.wires, isEmpty);
      expect(wire.adapters, isEmpty);
    } finally {
      try {
        container.dispose();
      } finally {
        runtime.dispose();
        wire.core.mutations.dispose();
        revisions.dispose();
        wire.core.redaction.dispose();
      }
    }
  }
}

final class _DeclaredChatNotifier extends ChatNotifier {
  _DeclaredChatNotifier(this.session) : super(session.characterId);
  final ChatSession session;
  CancelToken? token;
  @override
  Future<ChatState> build() async =>
      ChatState(session: session, isGenerating: true);
  @override
  void setCancelToken(CancelToken token, {required int genId}) {
    this.token = token;
  }
}

final class _DeclaredApiList extends ApiListNotifier {
  _DeclaredApiList(this.backend);
  final NativeRoleplaySyntheticBackend backend;
  @override
  Future<List<ApiConfig>> build() async {
    final original = backend.row;
    await backend.gate.hold();
    return [original];
  }
}

final class _UnusedStudioService implements MemoryStudioService {
  _UnusedStudioService(this.isolation);
  final NativeRoleplayIsolation isolation;
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      isolation.block('Studio execution');
}
