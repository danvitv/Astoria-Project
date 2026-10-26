import 'dart:async';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';

import '../../credentials/fake_credential_storage.dart';
import '../../llm/transport/_private_text_fixture.dart';
import 'support_native_input_fixture.dart'
    show NativeInputCipher, NativeInputSql;
import 'support_model_provider_fixture_isolation.dart';
import 'support_model_provider_fixture_http.dart';

export 'support_model_provider_fixture_isolation.dart';

/// OWN memory database/migration, fake vault, SAME AEAD cipher. Real Riverpod
/// workspace/native/model and API credential observation. No old model/native
/// fixture, default App/DB/env/catalog/key/bootstrap/capture/network evaluation.
final class ModelProviderFixture {
  ModelProviderFixture({bool nativeToolRuntime = true}) {
    db = _DeclaredModelProviderDatabase(
      NativeDatabase.memory().interceptWith(sql),
    );
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_provider',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    workspaceStore = SupportWorkspaceStore(repo, () => redaction.redactor);
    isolation.extraAllowed.add(_databaseChoice);
    isolation.extraAllowed.add(nativeProviderAdapterFactoryProvider);
    container = ProviderContainer(
      observers: [isolation],
      overrides: [
        if (!nativeToolRuntime)
          nativeProviderRuntimeProvider.overrideWithValue(null),
        _databaseChoice.overrideWith(() => _DatabaseChoice(db)),
        appDbProvider.overrideWith((ref) => ref.watch(_databaseChoice)),
        credentialStorageProvider.overrideWithValue(storage),
        credentialVaultProvider.overrideWithValue(vault),
        supportPayloadCipherProvider.overrideWithValue(cipher),
        supportRepoProvider.overrideWith(
          (ref) => SupportRepo(ref.watch(appDbProvider), cipher),
        ),
        connectionRevisionRegistryProvider.overrideWithValue(revisions),
        secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        supportSessionStoreProvider.overrideWith(
          (ref) => SupportWorkspaceStore(
            ref.watch(supportRepoProvider),
            () => redaction.redactor,
          ),
        ),
        supportModelPrivateAdapterFactoryProvider.overrideWithValue(newAdapter),
        nativeProviderAdapterFactoryProvider.overrideWithValue(
          () => isolation.block('undeclared native provider wire adapter'),
        ),
        supportConnectionMetadataProvider.overrideWith(
          (_) => isolation.block('bulk metadata/model startup'),
        ),
        llmRequestCaptureInstallationProvider.overrideWith(
          (_) => isolation.block('capture installation'),
        ),
        imageStorageProvider.overrideWith(
          (_) => isolation.block('image storage'),
        ),
        migrationServiceProvider.overrideWith(
          (_) => isolation.block('production migration service'),
        ),
      ],
    );
  }
  static const session = 'provider-session', otherSession = 'provider-other';
  static const rowKey = 'SYNTHETIC_PROVIDER_ROW_KEY_49283';
  static const staleVaultKey = 'SYNTHETIC_PROVIDER_STALE_VAULT_34897';
  static const secret = 'SYNTHETIC_PROVIDER_PRIVATE_VALUE_74892';
  static const excluded = 'SYNTHETIC_PROVIDER_UNSELECTED_91282';
  final isolation = ModelProviderIsolation();
  final storage = FakeCredentialStorage();
  final primitive = NativeInputCipher();
  final sql = NativeInputSql();
  final redaction = SecretRedactionCoordinator();
  final revisions = ConnectionRevisionRegistry();
  final adapters = <ModelProviderHttpAdapter>[];
  final adapterCreated = Completer<ModelProviderHttpAdapter>();
  final sends = <SupportModelUiSend>[];
  final emitters = <SupportModelUiEmitter>[];
  final barriers = <ModelProviderBarrier>[];
  final phases = <SupportModelRunView>[];
  final feeds = <List<SupportMessageItem>>[];
  final replacementDatabases = <AppDatabase>[];
  late final AppDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final SupportWorkspaceStore workspaceStore;
  late final ProviderContainer container;
  bool disposed = false, quiet = false;
  int httpStatus = 200;
  String Function()? response;
  ApiConfig api = const ApiConfig(
    id: 'provider-api',
    name: 'Synthetic provider',
    endpoint: 'https://provider.invalid/v1/chat/completions',
    apiKey: rowKey,
    model: 'profile-model-must-not-win',
    temperature: 1.4,
    maxTokens: 7777,
    topP: 0.61,
    frequencyPenalty: 0.2,
    presencePenalty: 0.3,
    sessionIdMode: 'always',
    cacheControlTtl: '5min',
    promptPostProcessing: 'merge',
  );
  SupportAssistantSettings settings = const SupportAssistantSettings(
    apiConfigId: 'provider-api',
    modelId: 'selected-native-model',
    temperature: 0.25,
    maxTokens: 512,
    reasoningEffort: SupportReasoningEffort.low,
  );
  SupportWorkspaceNotifier get workspace =>
      container.read(supportWorkspaceProvider.notifier);
  SupportWorkspaceState get state => container.read(supportWorkspaceProvider);
  SupportModelUiBridge get bridge =>
      container.read(supportModelUiBridgeProvider);

  HttpClientAdapter newAdapter() {
    final adapter = ModelProviderHttpAdapter(
      PrivateFixtureAdapter(
        response?.call() ??
            (quiet ? '' : chatComplete('Safe synthetic answer')),
        status: httpStatus,
        quiet: quiet,
      ),
    );
    adapters.add(adapter);
    if (!adapterCreated.isCompleted) adapterCreated.complete(adapter);
    return adapter;
  }

  Future<void> initialize({bool configured = true, bool confirm = true}) async {
    // Declared creation ONLY. No production migration/seed/plugin hooks.
    await db.customSelect('SELECT 1').getSingle();
    await db.customStatement('PRAGMA busy_timeout = 0');
    redaction.registerSecret(secret);
    for (final id in [session, otherSession]) {
      await repo.createSession(
        SupportSession(id: id, title: 'Synthetic', createdAt: 1, updatedAt: 1),
      );
    }
    await repo.putMessage(
      const SupportMessage(
        id: 'old-excluded',
        sessionId: session,
        role: 'assistant',
        body: excluded,
        createdAt: 2,
      ),
    );
    await container.read(apiConfigRepoProvider).put(api);
    await container
        .read(apiConfigRepoProvider)
        .put(
          api.copyWith(
            id: 'unselected-api',
            name: excluded,
            apiKey: excluded,
            endpoint: 'https://unselected.invalid/v1/chat/completions',
          ),
        );
    await vault.store(
      ApiConfigCredentialAdapter.llmSlot(api.id),
      staleVaultKey,
    );
    if (configured) {
      await workspaceStore.changeSettings(session, (_) => settings);
    }
    container.listen(supportWorkspaceProvider, (_, next) {
      feeds.add(List.of(next.activeMessages));
    });
    workspace;
    await container.pump();
    await workspace.refresh();
    workspace.selectSession(session);
    await workspace.refresh();
    if (configured && confirm) await confirmRecipient();
    container.listen(
      supportModelRunViewProvider,
      (_, view) => phases.add(view),
    );
    bridge;
    await container.pump();
    sql.observations.clear();
    sql.writes.clear();
  }

  Future<void> confirmRecipient() async {
    final controller = container.read(supportNativeConsentControllerProvider);
    final review = await controller.prepareReview();
    expect(review, isNotNull);
    expect(await controller.confirmRecipient(review!), isTrue);
  }

  SupportModelUiEmitter emitter({
    Object? controller,
    Object? lifetime,
    bool Function()? current,
  }) {
    final emitter = bridge.bindEmitter(
      controller: controller ?? Object(),
      uiLifetime: lifetime ?? Object(),
      isEmitterCurrent: current ?? () => true,
    );
    emitters.add(emitter);
    return emitter;
  }

  SupportModelUiSend send({
    SupportModelUiEmitter? from,
    String text = 'Actual native question',
    int revision = 1,
    bool Function()? draftCurrent,
  }) {
    final send = (from ?? emitter()).send(
      text: text,
      draftRevision: revision,
      isDraftCurrent: draftCurrent ?? () => true,
    );
    sends.add(send);
    return send;
  }

  Future<SupportModelPreview> preview(SupportModelUiSend send) async {
    expect(await send.accepted, isTrue);
    final preparation = await send.prepared;
    expect(preparation.reason, SupportModelRefusal.none);
    expect(preparation.preview, isNotNull);
    return preparation.preview!;
  }

  ModelProviderBarrier barrier() {
    final barrier = ModelProviderBarrier();
    barriers.add(barrier);
    return barrier;
  }

  /// New declared-schema initialized owner. NO production DB or lazy migrations.
  Future<void> replaceDatabase() async {
    final replacement = _DeclaredModelProviderDatabase(NativeDatabase.memory());
    replacementDatabases.add(replacement);
    await replacement.customSelect('SELECT 1').getSingle();
    await replacement.customStatement('PRAGMA busy_timeout = 0');
    container.read(_databaseChoice.notifier).replace(replacement);
    bridge; // Reconcile actual appDb/native/workspace/model dependency chain.
    await container.pump();
  }

  /// Seed a NEW synthetic row secret via the sanctioned observer-free repo.
  /// The selected actual getById must prime the real coordinator and retire the
  /// original emitted provider rather than transplant it onto a fresh issuer.
  Future<void> seedUnobservedKey(String key) async {
    api = api.copyWith(apiKey: key);
    await ApiConfigRepo(db).put(api);
  }

  Future<void> grantHistory(
    SupportPermissionScope scope,
    Iterable<SupportPermission> grants,
  ) async {
    final runtime = container.read(supportNativeRuntimeProvider);
    await runtime.permissions.selectScopeFromNative(
      session,
      scope,
      isCurrent: () => true,
    );
    await runtime.refresh(resolve: true);
    await confirmRecipient();
    for (final grant in grants) {
      final controller = container.read(supportNativeConsentControllerProvider);
      final review = (await controller.prepareReview())!;
      expect(await controller.setGrant(review, grant, true), isTrue);
    }
    await container.pump();
  }

  Future<void> close() async {
    primitive.beforeDecrypt = null;
    primitive.afterEncrypt = null;
    sql.afterSelect = null;
    sql.afterWrite = null;
    storage.beforeRead = null;
    storage.beforeWrite = null;
    storage.readError = null;
    storage.writeError = null;
    for (final barrier in barriers) {
      barrier.release();
    }
    for (final emitter in emitters) {
      emitter.retire();
    }
    for (final send in sends) {
      send.stop();
    }
    if (!disposed) {
      disposed = true;
      container.dispose();
    }
    // Keep BOTH overrides and tripwires through original once-terminal cleanup.
    for (final send in sends) {
      await send.finished;
    }
    for (final replacement in replacementDatabases) {
      await replacement.close();
    }
    await db.close();
    revisions.dispose();
    redaction.dispose();
  }

  Future<void> run(
    Future<void> Function(ModelProviderFixture) body, {
    bool configured = true,
    bool confirm = true,
  }) => isolation.run(() async {
    try {
      await initialize(configured: configured, confirm: confirm);
      await body(this);
    } finally {
      await close();
    }
  });
}

final class _DeclaredModelProviderDatabase extends AppDatabase {
  _DeclaredModelProviderDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final _databaseChoice = NotifierProvider<_DatabaseChoice, AppDatabase>(
  () => throw StateError('Synthetic database choice must be overridden.'),
);

final class _DatabaseChoice extends Notifier<AppDatabase> {
  _DatabaseChoice(this.initial);
  final AppDatabase initial;
  @override
  AppDatabase build() => initial;
  void replace(AppDatabase database) => state = database;
}
