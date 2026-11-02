import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/credential_slot.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/llm/transport/native_provider_transport.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/native_provider_runtime.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_connection_metadata_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_resolver.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';

import '../core/native_provider_fixture.dart' show NativeProviderFakeStorage;
import '../core/native_provider_transport_fixture.dart' show nativeTransportRow;
import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_model_fixture.dart'
    show ModelFixtureQueue, ModelObservedAdapter;
import 'helpers/support_native_input_fixture.dart'
    show NativeInputCipher, NativeInputSql;

/// Flat synthetic native root: SAME actual ApiConfigRepo, vault, coordinator,
/// mutation bridge and source owner; actual workspace/policy/recipient services,
/// AEAD and private H/T/S. Only the last HTTP delegate and storage are fake.
/// Never constructs an app/provider graph, OS vault, production DB or socket.
final class SupportProviderModelFixture {
  SupportProviderModelFixture._({sqlite.Database? originalNativeConnection}) {
    // Select the original executor before repositories, ROOT or providers.
    db = originalNativeConnection == null
        ? _ProviderModelDatabase(sql)
        : _ProviderModelDatabase.opened(originalNativeConnection, sql);
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    native = newNativeRoot();
    apiRepo = ApiConfigRepo(
      db,
      onMutationStarted: () => native.onApiMutationStarted(),
      onConfigObserved: (row) {
        redaction.registerSecret(row.apiKey);
        redaction.registerSecret(row.embeddingApiKey);
      },
      keylessMutations: native.keylessMutations,
      ordinaryMutations: native.ordinaryMutations,
    );
    workspace = SupportWorkspaceStore(repo, () => redaction.redactor);
    permissions = SupportPermissionStore(
      repo,
      newIdentity: () => 'native-policy',
    );
    runtime = SupportNativeRuntime(
      permissions: permissions,
      resolveRecipient: (id) => resolver.resolve(id),
      loadSelectedConnection: (id, current) => metadata.loadSelected(
        id,
        resolver,
        workspace.readableSettingsFor,
        isCurrent: current,
      ),
      configurationRevision: () => revisions.revision,
      configurationStable: () => revisions.isStable,
    );
    resolver = SupportRecipientResolver(
      apiRepo: apiRepo,
      readSettings: workspace.readableSettingsFor,
      currentContext: () => runtime.recipientContext,
      revisions: revisions,
      redactor: () => redaction.redactor,
    );
    unlisten = revisions.subscribe(runtime.invalidateConfiguration);
  }

  static const key = 'SYNTHETIC_NATIVE_ASTORIA_🔐_кириллица_e\u0301';
  static const excluded = 'SYNTHETIC_EXCLUDED_HISTORY';
  final storage = NativeProviderFakeStorage();
  final primitive = NativeInputCipher();
  final sql = NativeInputSql();
  final revisions = ConnectionRevisionRegistry();
  final queue = ModelFixtureQueue();
  final adapters = <ModelObservedAdapter>[];
  final published = <SupportModelMessage>[];
  final phases = <SupportModelPhase>[];
  final controller = Object(), uiLifetime = Object();
  late final AppDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final ApiConfigRepo apiRepo;
  late final SupportWorkspaceStore workspace;
  late final SupportPermissionStore permissions;
  late final SupportNativeRuntime runtime;
  late final SupportRecipientResolver resolver;
  late final void Function() unlisten;
  SecretRedactionCoordinator redaction = SecretRedactionCoordinator();
  late NativeProviderRuntime native;
  SupportModelService? _service;
  SupportModelService get service => _service!;
  late ApiConfig api;
  late SupportAssistantSettings settings;
  late String session;
  bool rootCurrent = true, emitter = true, draft = true, owner = true;
  bool quiet = false;
  bool? fetchInQueue;
  int serial = 0, dispatcherConstructions = 0;
  String? response;
  void Function()? onFactory, onFetch, onDispatcher;
  final activity = Completer<void>();

  NativeProviderRuntime newNativeRoot() => NativeProviderRuntime(
    vault: vault,
    redaction: redaction,
    revisions: revisions,
    readSavedConnection: (id) => apiRepo.getById(id),
    adapterFactory: adapter,
    isOriginalRoot: () => rootCurrent,
  );

  SupportConnectionMetadataService get metadata =>
      SupportConnectionMetadataService(
        apiRepo,
        () => redaction.redactor,
        nativeMetadata: native.credentialReader,
        nativeMetadataIsCurrent: () => native.isCurrent,
      );

  static Future<SupportProviderModelFixture> create({
    String protocol = 'openai',
    bool customResponses = false,
    bool storeKey = true,
    bool prepared = false,
    String? storedNativeRecord,
    Set<NativeProviderPurpose> purposes = const {NativeProviderPurpose.astoria},
    sqlite.Database? originalNativeConnection,
  }) async {
    final f = SupportProviderModelFixture._(
      originalNativeConnection: originalNativeConnection,
    );
    try {
      await f.db.customSelect('SELECT 1').getSingle();
      await f.db.customStatement('PRAGMA busy_timeout = 0');
      f.api = nativeTransportRow(protocol).copyWith(
        name: 'Synthetic connection',
        topP: 0.61,
        useResponsesApi: protocol == 'openai_responses' || customResponses,
        endpoint: customResponses
            ? 'https://synthetic.example/v1/responses'
            : nativeTransportRow(protocol).endpoint,
      );
      await f.apiRepo.put(f.api);
      f.api = (await f.apiRepo.getById(f.api.id))!;
      if (prepared) await f.markPrepared();
      if (storeKey) await f.store(purposes);
      if (storedNativeRecord != null) {
        // Only a caller-declared SYNTHETIC fake-storage record. It is never
        // decoded here or obtained from runtime/application credentials.
        f.storage.values[f.nativeStorageKey] = storedNativeRecord;
      }
      f.session = await f.workspace.create('Synthetic workspace');
      f.settings = SupportAssistantSettings(
        apiConfigId: f.api.id,
        modelId: f.api.model,
        maxTokens: 512,
        temperature: 0.25,
        reasoningEffort: SupportReasoningEffort.off,
      );
      await f.workspace.changeSettings(f.session, (_) => f.settings);
      f.runtime.selectSession(f.session);
      await f.reconfirm();
      f._service = f.newService();
      return f;
    } catch (_) {
      await f.close();
      rethrow;
    }
  }

  Future<void> store(Set<NativeProviderPurpose> purposes) async {
    final reference = native.auth.referenceFor(api, purposes.first)!;
    final lifetime = NativeProviderViewLifetime(isCurrent: () => rootCurrent);
    NativeProviderDestinationApproval? approval;
    if (native.routes.requiresCustomDestinationApproval(reference.connection)) {
      approval = native.routes.confirmCustomDestination(
        native.routes.reviewCustomDestination(
          connection: reference.connection,
          purposes: purposes,
          lifetime: lifetime,
        ),
      );
    }
    final review = await native.secretEntry.review(
      connection: reference,
      purposes: purposes,
      lifetime: lifetime,
      destinationApproval: approval,
    );
    await native.credentials.storeFromNativeEntry(
      permit: native.secretEntry.confirmNativeEntry(review),
      secret: key,
    );
  }

  Future<void> markPrepared() async {
    final admission = native.mutations.admit(
      expected: native.mutations.observe()!,
      isOriginalOwner: () => rootCurrent,
    )!;
    await native.mutations.runOwned(
      admission: admission,
      operation: (lease) => native.credentials.markPreparedForNativeCreate(
        lease: lease,
        connectionId: api.id,
      ),
    );
  }

  String get nativeStorageKey =>
      'app.astoria.credentials.v1.dev.${CredentialSlot(domain: 'api_config.native_llm', id: api.id).storageSuffix}';

  Future<void> reconfirm() async {
    await runtime.refresh(resolve: true);
    final selected = runtime.recipient as SupportResolvedRecipient;
    await permissions.selectRecipientFromNative(
      session,
      selected.recipient,
      isCurrent: () => rootCurrent,
    );
    await runtime.refresh(resolve: true);
    runtime.recipientConfirmed = true; // Explicit synthetic native user review.
  }

  SupportModelService newService() {
    final originalRoot = native, originalRedactor = redaction.redactor;
    return SupportModelService(
      db: db,
      writeCipher: cipher,
      apiRepo: apiRepo,
      revisions: revisions,
      redaction: redaction,
      runtime: runtime,
      isOwnerCurrent: () =>
          owner &&
          originalRoot.isCurrent &&
          identical(originalRedactor, redaction.redactor),
      writes: queue,
      admissionContract:
          SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
      nativeSources: originalRoot.sources,
      nativeMetadata: originalRoot.credentialReader,
      nativeDispatcher: (inner) {
        dispatcherConstructions++;
        onDispatcher?.call();
        return NativeProviderPrivateTextDispatcher(
          credentials: originalRoot.credentials,
          authIssuer: originalRoot.auth,
          mutations: originalRoot.mutations,
          routes: originalRoot.routes,
          privateTextTransport: inner,
        );
      },
      adapterFactory: adapter,
      newId: () => 'synthetic-native-${++serial}',
      onMessage: published.add,
      onPhase: (phase) {
        phases.add(phase);
        if (phase == SupportModelPhase.activity && !activity.isCompleted) {
          activity.complete();
        }
      },
    );
  }

  HttpClientAdapter adapter() {
    onFactory?.call();
    final wire = ModelObservedAdapter(
      PrivateFixtureAdapter(
        response ??
            switch (api.protocol) {
              'anthropic' => anthropicComplete('Synthetic native reply'),
              'gemini' => geminiText('Synthetic native reply', finish: 'STOP'),
              'openai_responses' => responsesComplete('Synthetic native reply'),
              'custom_chat_completion' when api.useResponsesApi =>
                responsesComplete('Synthetic native reply'),
              _ => chatComplete('Synthetic native reply'),
            },
        quiet: quiet,
      ),
      () {
        fetchInQueue = queue.active;
        onFetch?.call();
      },
    );
    adapters.add(wire);
    return wire;
  }

  Future<SupportModelInputEmission> emit([String text = 'Native question']) =>
      service.emitInput(
        controller: controller,
        uiLifetime: uiLifetime,
        draftRevision: 1,
        text: text,
        isEmitterCurrent: () => emitter,
        isDraftCurrent: () => draft,
      );

  Future<SupportModelSubmission> submit([
    String text = 'Native question',
  ]) async {
    final emission = await emit(text);
    if (emission.intent == null) throw StateError('Synthetic input denied');
    return service.beginSend(emission.intent!);
  }

  Future<void> selectHistory({required bool model}) async {
    for (final (id, text) in [
      ('selected-old', 'Selected native history'),
      ('excluded-old', excluded),
    ]) {
      await repo.putMessage(
        SupportMessage(
          id: id,
          sessionId: session,
          role: 'user',
          body: text,
          createdAt: 1,
        ),
      );
    }
    await permissions.selectScopeFromNative(
      session,
      SupportPermissionScope(
        selectionRevision: 1,
        supportHistory: SupportMessageSelection(['selected-old']),
        safeCategories: const [SupportSafeCategory.connections],
      ),
      isCurrent: () => true,
    );
    await permissions.setGrantFromNative(
      session,
      SupportPermission.modelSupportHistory,
      model,
      isCurrent: () => true,
    );
    // The synthetic native user reviews the NEW scoped recipient after selecting
    // history. Never reuse the old recipient approval across a scope revision.
    await reconfirm();
  }

  Future<String> rawMessages() async => jsonEncode(
    (await db.select(db.supportMessages).get())
        .map((row) => row.toJson())
        .toList(),
  );

  Future<void> close() async {
    storage.beforeRead = null;
    _service?.dispose();
    unlisten();
    runtime.dispose();
    native.dispose();
    revisions.dispose();
    redaction.dispose();
    await db.close();
  }
}

final class _ProviderModelDatabase extends AppDatabase {
  _ProviderModelDatabase(NativeInputSql interceptor)
    : super.nativeMemoryForTesting(interceptor: interceptor);
  _ProviderModelDatabase.opened(
    sqlite.Database connection,
    NativeInputSql interceptor,
  ) : super.openedNativeForTesting(
        connection,
        interceptor: interceptor,
        closeUnderlyingOnClose: false,
      );
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (m) => m.createAll(),
    beforeOpen: super.migration.beforeOpen,
  );
}
