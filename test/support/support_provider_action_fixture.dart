import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/native_provider_mutation_bridge.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_provider_action_service.dart';

import '../core/provider_setup_repo_fixture.dart'
    show ProviderMemoryDatabase, ProviderControlledSql;
import '../credentials/fake_credential_storage.dart';
import 'helpers/support_mutation_journal_fixture.dart'
    show JournalControlledCipher;

export 'helpers/support_mutation_journal_fixture.dart' show JournalBarrier;
export 'package:glaze_flutter/features/support_assistant/services/support_provider_action_service.dart';
export 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
export 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';

void providerActionTest(
  String name,
  Future<void> Function(ProviderActionFixture) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String label) {
      attempts.add(label);
      throw StateError('Outside synthetic provider action fixture.');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final f = ProviderActionFixture();
            try {
              await f.seed();
              await body(f);
            } finally {
              f.clearHooks();
              f.service.dispose();
              f.mutations.dispose();
              f.redaction.dispose();
              await f.db.close();
              await messenger.platformMessagesFinished;
              expect(attempts, isEmpty);
            }
          },
          createFile: (_) => block('file/default DB'),
          createDirectory: (_) => block('directory'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HTTP'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

/// REAL NativeOwner + ROOT lease bridge, real AEAD + declared memory SQLite.
/// Only the native API-row reader, permissions, ID projection and metadata input
/// are explicitly injected. No default provider graph/model recipient/resolver.
final class ProviderActionFixture {
  ProviderActionFixture() {
    db = ProviderMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_provider_action',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    support = SupportRepo(db, cipher);
    composeNative();
    sql.event = event;
    primitive.event = event;
    storage.beforeRead = () => event('vault-read');
    storage.beforeWrite = () => event('vault-write');
  }

  void composeNative() {
    mutations = NativeConnectionMutationOwner(redaction: redaction);
    routes = NativeProviderRoutePolicy(redaction: redaction);
    nativeVault = NativeProviderCredentialVault(
      vault: vault,
      redaction: redaction,
      mutations: mutations,
      routePolicy: routes,
    );
    bridge = NativeProviderKeylessMutationBridge(
      mutations: mutations,
      credentials: nativeVault,
      readSavedConnection: (id) => api.getById(id),
      isRootCurrent: () => rootCurrent,
    );
    api = ApiConfigRepo(
      db,
      keylessMutations: bridge,
      onMutationStarted: mutations.onMutationStarted,
    );
    setup = SupportProviderSetupRepo(
      db: db,
      apiRepo: api,
      supportRepo: support,
    );
    service = newService();
  }

  void restartNative() {
    service.dispose();
    mutations.dispose();
    redaction.dispose();
    redaction = SecretRedactionCoordinator();
    composeNative();
  }

  static const sessionId = 'synthetic-provider-actions';
  static const privateName = 'SYNTHETIC_PROVIDER_PRIVATE_LABEL';
  static const secret = 'SYNTHETIC_NATIVE_SECRET_CANARY';
  final storage = FakeCredentialStorage();
  final sql = ProviderControlledSql();
  final primitive = JournalControlledCipher();
  var redaction = SecretRedactionCoordinator();
  late final ProviderMemoryDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo support;
  late ApiConfigRepo api;
  late SupportProviderSetupRepo setup;
  late NativeConnectionMutationOwner mutations;
  late NativeProviderRoutePolicy routes;
  late NativeProviderCredentialVault nativeVault;
  late NativeProviderKeylessMutationBridge bridge;
  late SupportProviderActionService service;
  final controller = Object(), screen = Object();
  final events = <String>[];
  Future<void> Function(String)? hook;
  bool rootCurrent = true, scopeCurrent = true, screenCurrent = true;
  int localEpoch = 1, recipientEpoch = 1, operation = 0;
  int metadataCalls = 0, idCalls = 0;
  bool useRealMetadata = false;
  void Function()? ownerPredicateHook;
  Future<void> Function()? policyReadHook;
  Future<void> Function()? idsReadHook;
  Future<void> Function()? metadataHook;
  SupportProviderReadiness? metadata = const SupportProviderReadiness(
    configurationSaved: true,
    credentialConfigured: false,
    characterCount: 0,
  );
  SupportPermissionScope scope = SupportPermissionScope(
    selectionRevision: 1,
    safeCategories: const [SupportSafeCategory.connections],
  );
  Set<SupportPermission> grants = {
    SupportPermission.readSafeSettings,
    SupportPermission.confirmedSettingsChanges,
  };
  SupportPermissionSnapshot get snapshot => SupportPermissionSnapshot(
    SupportPermissionAvailability.available,
    SupportPermissionPreferences(
      supportSessionId: sessionId,
      policyIdentity: 'synthetic-local-policy',
      revision: recipientEpoch,
      scope: scope,
      grants: grants,
    ),
  );
  SupportNativePermissionContext context() => SupportNativePermissionContext(
    supportSessionId: sessionId,
    epoch: localEpoch,
    scope: scope,
  );
  bool originalOwner() {
    ownerPredicateHook?.call();
    return rootCurrent && scopeCurrent;
  }

  SupportProviderActionService newService() => SupportProviderActionService(
    apiRepo: api,
    setupRepo: setup,
    routePolicy: routes,
    currentPermissions: () => snapshot,
    currentLocalContext: context,
    readPermissions: (_) async {
      await event('permission-read');
      await policyReadHook?.call();
      return snapshot;
    },
    currentRedactor: () => redaction.redactor,
    isOriginalScopeCurrent: originalOwner,
    readConnectionIds: (current) async {
      idCalls++;
      await idsReadHook?.call();
      if (!current()) throw StateError('Synthetic stale ID read.');
      final rows = await db.select(db.apiConfigs).get();
      if (!current()) throw StateError('Synthetic stale ID result.');
      return rows.map((r) => r.configId).toList();
    },
    readReadiness: (id, purpose, current) async {
      metadataCalls++;
      await metadataHook?.call();
      if (useRealMetadata) {
        if (!current()) return null;
        final saved = await api.getById(id);
        if (!current() || saved == null) return null;
        final nativePurpose = switch (purpose) {
          SupportProviderPurpose.roleplay => NativeProviderPurpose.roleplay,
          SupportProviderPurpose.studio => NativeProviderPurpose.studio,
          SupportProviderPurpose.memoryBooks =>
            NativeProviderPurpose.memoryBooks,
          SupportProviderPurpose.astoria => NativeProviderPurpose.astoria,
        };
        final reference = NativeSavedConnectionAuthIssuer(
          mutations: mutations,
        ).referenceFor(saved, nativePurpose);
        if (!current() || reference == null) return null;
        final observation = await NativeProviderCredentialMetadataReader(
          credentials: nativeVault,
        ).inspectSavedConnection(connection: reference, isCurrent: current);
        if (!current() ||
            (observation.state != NativeProviderCredentialState.absent &&
                observation.state != NativeProviderCredentialState.ready)) {
          return null;
        }
        return SupportProviderReadiness(
          configurationSaved: true,
          credentialConfigured: observation.metadata.configured,
          characterCount: observation.metadata.characterCount,
        );
      }
      return current() ? metadata : null;
    },
    newOperationId: () => 'synthetic-provider-operation-${++operation}',
    now: () => 3,
  );
  Future<void> seed() => support.createSession(
    const SupportSession(
      id: sessionId,
      title: 'SYNTHETIC_SUPPORT_TITLE',
      createdAt: 1,
      updatedAt: 1,
    ),
  );
  Future<void> event(String name) async {
    events.add(name);
    await hook?.call(name);
  }

  void revoke(SupportPermission grant) {
    localEpoch++;
    grants = Set.of(grants)..remove(grant);
  }

  SupportProviderUiIntent intent([SupportProviderActionService? s]) =>
      (s ?? service).emit(
        controller: controller,
        uiLifetime: screen,
        isCurrent: () => screenCurrent,
      )!;
  SupportProviderSetupInput input({
    String name = privateName,
    String protocol = 'openai',
    String? endpoint,
    String model = 'synthetic-model',
    SupportProviderPurpose purpose = SupportProviderPurpose.roleplay,
    int maxTokens = 512,
    int contextSize = 4096,
    double temperature = 0.7,
  }) => SupportProviderSetupInput(
    purpose: purpose,
    name: name,
    protocol: protocol,
    endpoint: endpoint ?? routes.standardEndpointFor(protocol, model),
    model: model,
    maxTokens: maxTokens,
    contextSize: contextSize,
    temperature: temperature,
  );
  Future<SupportProviderActionResult> create({
    SupportProviderUiIntent? original,
    SupportProviderSetupInput? draft,
  }) async {
    final review = await service.prepareCreate(
      original ?? intent(),
      draft ?? input(),
    );
    expect(review, isNotNull);
    if (review!.destinationKind == SupportProviderDestinationKind.customHttps) {
      expect(service.confirmCustomDestination(review), isNotNull);
    }
    final approval = service.approve(review);
    expect(approval, isNotNull);
    return service.execute(approval!);
  }

  Future<SupportProviderChoice> choice(
    SupportProviderUiIntent original, {
    SupportProviderPurpose purpose = SupportProviderPurpose.roleplay,
  }) async =>
      (await service.observeConnections(original, purpose))!.choices.single;
  Future<ApiConfigRow?> row(String id) => (db.select(
    db.apiConfigs,
  )..where((t) => t.configId.equals(id))).getSingleOrNull();
  Future<String> snapshotRows() async => jsonEncode({
    'api': (await db.select(db.apiConfigs).get())
        .map((r) => r.toJson())
        .toList(),
    'journal': (await db.select(db.supportMutationJournal).get())
        .map((r) => r.toJson())
        .toList(),
    'sessions': (await db.select(db.supportSessions).get())
        .map((r) => r.toJson())
        .toList(),
  });
  Future<void> saveSyntheticNativeKey(String id, String value) async {
    // Trusted synthetic modal/owner lane, NOT a feature-service key argument.
    final saved = (await api.getById(id))!;
    final reference = NativeSavedConnectionAuthIssuer(
      mutations: mutations,
    ).referenceFor(saved, NativeProviderPurpose.roleplay)!;
    final issuer = NativeProviderSecretEntryIssuer(
      mutations: mutations,
      routePolicy: routes,
      readSavedConnection: api.getById,
    );
    final review = await issuer.review(
      connection: reference,
      purposes: {NativeProviderPurpose.roleplay},
      lifetime: NativeProviderViewLifetime(isCurrent: () => rootCurrent),
    );
    await nativeVault.storeFromNativeEntry(
      permit: issuer.confirmNativeEntry(review),
      secret: value,
    );
  }

  void clearHooks() {
    hook = null;
    ownerPredicateHook = null;
    policyReadHook = null;
    idsReadHook = null;
    metadataHook = null;
    storage.readError = null;
    storage.writeError = null;
    db.beforeOuterCommit = null;
    db.afterOuterCommit = null;
    sql.beforeOuterSend = null;
    sql.afterOuterSend = null;
  }
}
