import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_permission_store.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_resolver.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_settings_codec.dart';

import '../../credentials/fake_credential_storage.dart';
import '../../llm/transport/_private_text_fixture.dart';
import 'reserved_text_admission_fixture.dart';
import 'support_native_input_fixture.dart'
    show NativeInputCipher, NativeInputSql;

/// Flat, initialized, declared-schema native memory DB (or explicit owning A/B
/// fixture). ONE install cipher owner, fake storage, actual API/registry/runtime/
/// redactor and actual private native transport over observed fake adapters.
/// No App/default DB/production migration/bootstrap/env/OS vault/socket.
final class SupportModelFixture {
  SupportModelFixture._(this.native) {
    db =
        native?.db ??
        _ModelDatabase(NativeDatabase.memory().interceptWith(sql));
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_model_service',
    );
    cipher =
        native?.cipher ?? SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    apiRepo = ApiConfigRepo(
      db,
      onMutationStarted: revisions.beginMutation,
      onConfigObserved: (api) {
        redaction.registerSecret(api.apiKey);
      },
    );
    store = SupportPermissionStore(
      repo,
      newIdentity: () => 'synthetic-policy',
      now: () => 1,
    );
    runtime = SupportNativeRuntime(
      permissions: store,
      resolveRecipient: (id) => resolver.resolve(id),
      loadSelectedConnection: (_, _) async => null,
      configurationRevision: () => revisions.revision,
      configurationStable: () => revisions.isStable,
    );
    resolver = SupportRecipientResolver(
      apiRepo: apiRepo,
      readSettings: (id) async {
        final parent = await repo.getSessionById(id);
        if (parent == null || parent.isLocked) return null;
        return const SupportWorkspaceSettingsCodec().decode(
          await repo.getContextBlockById(
            const SupportWorkspaceSettingsCodec().idFor(id),
          ),
        );
      },
      currentContext: () => runtime.recipientContext,
      revisions: revisions,
      redactor: () => redaction.redactor,
    );
  }
  static const session = 'session';
  static const vaultKey = 'fixture-credential';
  static const rowKey = 'SYNTHETIC_LEGACY_KEY_001';
  static const newRowKey = 'SYNTHETIC_NEW_ROW_KEY_772';
  static const unselected = 'SYNTHETIC_UNSELECTED_BODY_831';
  static const secret = 'SYNTHETIC_PERSONAL_SECRET_994';
  final ReservedTextAdmissionFixture? native;
  final storage = FakeCredentialStorage();
  final primitive = NativeInputCipher();
  final sql = NativeInputSql();
  final revisions = ConnectionRevisionRegistry();
  final redaction = SecretRedactionCoordinator();
  final queue = ModelFixtureQueue();
  final timers = <ModelManualTimer>[];
  final adapters = <ModelObservedAdapter>[];
  final published = <SupportModelMessage>[];
  final phases = <SupportModelPhase>[];
  final activity = Completer<void>();
  final controller = Object(), uiLifetime = Object();
  late final AppDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  late final ApiConfigRepo apiRepo;
  late final SupportPermissionStore store;
  late final SupportNativeRuntime runtime;
  late final SupportRecipientResolver resolver;
  late SupportModelService service;
  bool _serviceCreated = false;
  ApiConfig api = const ApiConfig(
    id: 'selected-api',
    name: 'SYNTHETIC_CONNECTION_METADATA_542',
    endpoint: 'https://fixture.invalid/v1/chat/completions',
    apiKey: rowKey,
    model: 'profile-model-not-selected',
    temperature: 1.3,
    maxTokens: 7777,
    topP: 0.61,
    topK: 4,
    frequencyPenalty: 0.2,
    presencePenalty: 0.3,
    cacheControlTtl: '5min',
    sessionIdMode: 'always',
    promptPostProcessing: 'merge',
  );
  SupportAssistantSettings settings = const SupportAssistantSettings(
    apiConfigId: 'selected-api',
    modelId: 'fixture-model',
    temperature: 0.25,
    maxTokens: 512,
    reasoningEffort: SupportReasoningEffort.low,
  );
  bool owner = true, emitter = true, draft = true, observeBusy = false;
  bool? fetchInQueue, fetchWriterBusy;
  int serial = 0;
  String? nextUserId;
  String Function()? responseBody;
  bool quiet = false;
  int status = 200;
  void Function()? onFactory, onFetch;

  static Future<SupportModelFixture> create({
    ReservedTextAdmissionFixture? native,
    SupportPermissionScope? scope,
    Iterable<SupportPermission> grants = const [],
    bool confirmed = true,
    String protocol = 'openai',
    bool responses = false,
    bool manualTimers = false,
  }) async {
    final f = SupportModelFixture._(native);
    try {
      await f.db.customSelect('SELECT 1').getSingle();
      await f.db.customStatement('PRAGMA busy_timeout = 0');
      if (await f.repo.getSessionById(session) == null) {
        await f.repo.createSession(
          const SupportSession(
            id: session,
            title: 'Synthetic',
            createdAt: 1,
            updatedAt: 1,
          ),
        );
      }
      f.api = f.api.copyWith(
        protocol: protocol,
        useResponsesApi: responses,
        // The native persistence normalizer binds Gemini's saved route to the
        // API row model. Seed the actual selected stream route, not a fake URI.
        model: protocol == 'gemini' ? f.settings.modelId! : f.api.model,
        endpoint: switch (protocol) {
          'anthropic' => 'https://fixture.invalid/v1/messages',
          'gemini' =>
            'https://fixture.invalid/v1beta/models/fixture-model:streamGenerateContent',
          'openai_responses' => 'https://fixture.invalid/v1/responses',
          'custom_chat_completion' when responses =>
            'https://fixture.invalid/v1/responses',
          _ => 'https://fixture.invalid/v1/chat/completions',
        },
      );
      await f.apiRepo.put(f.api);
      f.api = (await f.apiRepo.getById(f.api.id))!;
      await f.vault.store(
        ApiConfigCredentialAdapter.llmSlot(f.api.id),
        vaultKey,
      );
      await f.saveSettings();
      f.runtime.selectSession(session);
      await f.runtime.refresh(resolve: true);
      final resolved = f.runtime.recipient as SupportResolvedRecipient;
      final policy = SupportPermissionPreferences(
        supportSessionId: session,
        policyIdentity: 'synthetic-policy',
        revision: 1,
        scope: scope,
        recipient: resolved.recipient,
        grants: grants,
      );
      await f.repo.putContextBlock(
        const SupportPermissionCodec().encode(policy, 1),
      );
      await f.runtime.refresh(resolve: true);
      f.runtime.recipientConfirmed = confirmed;
      f.service = f.newService(manualTimers: manualTimers);
      f._serviceCreated = true;
      return f;
    } catch (_) {
      await f.close();
      rethrow;
    }
  }

  SupportModelService newService({
    bool manualTimers = false,
    SupportTextAdmissionContract? contract =
        SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
  }) => SupportModelService(
    db: db,
    writeCipher: cipher,
    apiRepo: apiRepo,
    revisions: revisions,
    redaction: redaction,
    runtime: runtime,
    isOwnerCurrent: () => owner,
    writes: queue,
    admissionContract: contract,
    newId: () {
      serial++;
      return serial % 3 == 1 && nextUserId != null
          ? nextUserId!
          : 'native-$serial';
    },
    now: () => 20,
    scheduleTimer: (duration, callback) {
      if (!manualTimers) return Timer(duration, callback);
      final timer = ModelManualTimer(duration, callback);
      timers.add(timer);
      return timer;
    },
    onMessage: published.add,
    onPhase: (phase) {
      phases.add(phase);
      if (phase == SupportModelPhase.activity && !activity.isCompleted) {
        activity.complete();
      }
    },
    adapterFactory: () {
      onFactory?.call();
      final adapter = ModelObservedAdapter(
        PrivateFixtureAdapter(
          responseBody?.call() ??
              switch (api.protocol) {
                'anthropic' => anthropicComplete('Synthetic reply'),
                'gemini' => geminiText('Synthetic reply', finish: 'STOP'),
                'openai_responses' => responsesComplete('Synthetic reply'),
                'custom_chat_completion' when api.useResponsesApi =>
                  responsesComplete('Synthetic reply'),
                _ => chatComplete('Synthetic reply'),
              },
          status: status,
          quiet: quiet,
        ),
        () {
          fetchInQueue = queue.active;
          if (observeBusy) fetchWriterBusy = native!.otherWriterBusy();
          onFetch?.call();
        },
      );
      adapters.add(adapter);
      return adapter;
    },
  );

  Future<void> saveSettings() => repo.putContextBlock(
    const SupportWorkspaceSettingsCodec().encode(
      session,
      settings,
      1,
      redaction.redactor,
    ),
  );
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
    if (emission.intent == null) {
      throw StateError('Synthetic emission refused: ${emission.reason.name}');
    }
    return service.beginSend(emission.intent!);
  }

  Future<void> history(
    String id, {
    String role = 'user',
    String? runId,
    String body = 'Selected history',
    int time = 2,
  }) => repo.putMessage(
    SupportMessage(
      id: id,
      sessionId: session,
      role: role,
      body: body,
      runId: runId,
      createdAt: time,
    ),
  );

  /// Sanctioned repository seed deliberately NOT observed by the old coordinator
  /// until its actual getById. Only for pre-emission cold-key/provider controls.
  Future<void> seedUnobservedRowKey() async {
    api = api.copyWith(apiKey: newRowKey);
    await ApiConfigRepo(db).put(api);
  }

  Future<void> reconfirmRecipient() async {
    await runtime.refresh(resolve: true);
    final review = runtime.recipient as SupportResolvedRecipient;
    await store.selectRecipientFromNative(
      session,
      review.recipient,
      isCurrent: () => true,
    );
    await runtime.refresh(resolve: true);
    runtime.recipientConfirmed = true;
  }

  Future<void> game({
    String role = 'user',
    String body = 'Selected game',
  }) async {
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'synthetic-character',
            name: 'Synthetic',
            description: const Value(unselected),
          ),
        );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: 'synthetic-game',
            characterId: 'synthetic-character',
            sessionIndex: 0,
            messagesJson: jsonEncode([
              {
                'id': 'game-selected',
                'role': role,
                'content': body,
                'timestamp': 1,
                'reasoning': unselected,
                'imagePath': unselected,
              },
              {
                'id': 'game-excluded',
                'role': 'user',
                'content': unselected,
                'timestamp': 2,
              },
            ]),
            sessionVarsJson: const Value('{"private":"$unselected"}'),
          ),
        );
  }

  Future<void> close() async {
    if (_serviceCreated) service.dispose();
    runtime.dispose();
    revisions.dispose();
    redaction.dispose();
    if (native != null) {
      await native!.close();
    } else {
      await db.close();
    }
  }
}

final class _ModelDatabase extends AppDatabase {
  _ModelDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final class ModelFixtureQueue implements SupportModelWriteScheduler {
  final delegate = SupportModelWriteQueue();
  bool active = false;
  int entries = 0;
  @override
  Future<T> enqueue<T>(Future<T> Function() work) => delegate.enqueue(() async {
    active = true;
    entries++;
    try {
      return await work();
    } finally {
      active = false;
    }
  });
}

final class ModelObservedAdapter implements HttpClientAdapter {
  ModelObservedAdapter(this.delegate, this.atFetch);
  final PrivateFixtureAdapter delegate;
  final void Function() atFetch;
  int calls = 0;
  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    calls++;
    atFetch(); // Actual synchronous native adapter-fetch boundary.
    return delegate.fetch(options, requestStream, cancelFuture);
  }

  @override
  void close({bool force = false}) => delegate.close(force: force);
}

final class ModelManualTimer implements Timer {
  ModelManualTimer(this.duration, this.callback);
  final Duration duration;
  final void Function() callback;
  bool _active = true;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
  @override
  void cancel() => _active = false;
  void fire() {
    if (_active) {
      _active = false;
      callback();
    }
  }
}
