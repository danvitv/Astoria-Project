import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redaction_coordinator.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/services/backup_service.dart';
import 'package:glaze_flutter/core/state/connection_revision_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/backup/backup_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_authorization_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_dependencies.dart';
import '../../backup/import_fence_fixture.dart';
import '../../credentials/fake_credential_storage.dart';
import 'support_permission_database_fixture.dart';

/// Actual native/controller/view, API and root backup providers. Every startup
/// port is replaced before evaluation: one memory DB, real AEAD, fake vault,
/// redaction owner, counted real settings store, fake images and synthetic files.
final class NativeObserverFixture {
  NativeObserverFixture._(this.imports) {
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    repo = PermissionPausedRepo(imports.db, SupportPayloadCipher(vault: vault));
    settings = ObserverSettingsStore(repo, () => redaction.redactor);
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(imports.db),
        supportRepoProvider.overrideWithValue(repo),
        credentialStorageProvider.overrideWithValue(storage),
        credentialVaultProvider.overrideWithValue(vault),
        secretRedactionCoordinatorProvider.overrideWithValue(redaction),
        imageStorageProvider.overrideWith((ref) async => imports.images),
        supportSessionStoreProvider.overrideWithValue(settings),
      ],
    );
  }
  static Future<NativeObserverFixture> create() async =>
      NativeObserverFixture._(await ImportFenceFixture.create());
  static const id = 'observer-support';
  static const original = ApiConfig(
    id: 'observer-api',
    name: 'Synthetic observer API',
    endpoint: 'https://observer.invalid/v1/chat/completions',
    apiKey: 'STATIC_OBSERVER_KEY_CANARY',
    model: 'observer-model',
  );
  final ImportFenceFixture imports;
  final storage = FakeCredentialStorage();
  final redaction = SecretRedactionCoordinator();
  late final CredentialVault vault;
  late final PermissionPausedRepo repo;
  late final ObserverSettingsStore settings;
  late final ProviderContainer container;
  ConnectionRevisionRegistry get revisions =>
      container.read(connectionRevisionRegistryProvider);
  ApiConfigRepo get api => container.read(apiConfigRepoProvider);
  SupportNativeRuntime get runtime =>
      container.read(supportNativeRuntimeProvider);
  SupportNativeConsentController get controller =>
      container.read(supportNativeConsentControllerProvider);
  SupportNativeView get view => container.read(supportNativeViewProvider);
  Future<BackupService> get backup =>
      container.read(backupServiceProvider.future);

  Future<void> seed() async {
    await repo.createSession(
      const SupportSession(
        id: id,
        title: 'Synthetic observer',
        createdAt: 1,
        updatedAt: 1,
      ),
    );
    await repo.appendMessage(
      const SupportMessage(
        id: 'observer-message',
        sessionId: id,
        role: 'user',
        body: 'STATIC_ENCRYPTED_OBSERVER_HISTORY',
        cardsJson: '[]',
        createdAt: 2,
      ),
    );
    await settings.changeSettings(
      id,
      (s) => s.copyWith(apiConfigId: original.id, modelId: original.model),
    );
    await api.put(original);
    final permissions = container.read(supportPermissionStoreProvider);
    await permissions.selectScopeFromNative(
      id,
      SupportPermissionScope(
        selectionRevision: 1,
        supportHistory: SupportMessageSelection(['observer-message']),
        safeCategories: [SupportSafeCategory.connections],
      ),
      isCurrent: () => true,
    );
    runtime.selectSession(id);
    expectSeed(await runtime.refresh());
    settings.reads = 0;
  }

  // Explicit setup invariant without importing the test framework in a helper.
  void expectSeed(bool value) {
    if (!value) throw StateError('Synthetic observer setup failed.');
  }

  Future<void> grant({bool model = false}) async {
    expectSeed(
      await controller.confirmRecipient((await controller.prepareReview())!),
    );
    final review = (await controller.prepareReview())!;
    expectSeed(
      await controller.setGrant(
        review,
        SupportPermission.readSafeSettings,
        true,
      ),
    );
    if (model) {
      expectSeed(
        await controller.setGrant(
          review,
          SupportPermission.modelSafeSettingsDiagnostics,
          true,
        ),
      );
    }
  }

  Future<SupportAuthorizationLease?> prepare(SupportPermissionUse use) =>
      runtime.authorization.prepare(
        supportSessionId: id,
        use: use,
        sources: [
          SupportPermissionSource.safeProjection(
            id,
            SupportSafeCategory.connections,
          ),
        ],
      );
  Future<void> inspect() async =>
      expectSeed(await runtime.inspectSelectedConnection(id, () => true));
  Future<void> close() async {
    container.dispose();
    redaction.dispose();
    await imports.close();
  }
}

/// Count/gate the real safe settings read used by the production resolver and
/// selected metadata loader. Passive observer events must never enter this port.
class ObserverSettingsStore extends SupportWorkspaceStore {
  ObserverSettingsStore(super.repo, super.redactor);
  int reads = 0;
  Future<void> Function()? afterRead;
  @override
  Future<SupportAssistantSettings?> readableSettingsFor(String id) async {
    reads++;
    final result = await super.readableSettingsFor(id);
    await afterRead?.call();
    return result;
  }
}
