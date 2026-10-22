import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_native_view.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_connection_metadata_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_consent_controller.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_native_runtime.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_resolver.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/models/support_consent_selection.dart';
import 'support_permission_database_fixture.dart';

/// Real encrypted memory DB; fake vault only; actual resolver/selected metadata.
final class NativeFixture {
  NativeFixture() {
    api = NativeSpyApiRepo(database, revisions);
    workspace = SupportWorkspaceStore(database.repoB, () => redactor);
    resolver = SupportRecipientResolver(
      apiRepo: api,
      readSettings: _readSettings,
      currentContext: () => runtime.recipientContext,
      revisions: revisions,
      redactor: () => redactor,
    );
    final metadata = SupportConnectionMetadataService(api, () => redactor);
    runtime = SupportNativeRuntime(
      permissions: database.a,
      resolveRecipient: resolver.resolve,
      loadSelectedConnection: (id, current) async {
        selectedLoads++;
        await beforeSelected?.call();
        if (!current()) return null;
        return metadata.loadSelected(
          id,
          resolver,
          _readSettings,
          isCurrent: current,
        );
      },
      configurationRevision: () => revisions.revision,
      configurationStable: () => revisions.isStable,
    );
    final selector = SupportConsentSelectionRepo(
      db: database.db,
      supportRepo: database.repoB,
      currentRedactor: () => redactor,
    );
    controller = SupportNativeConsentController(
      runtime: runtime,
      readMessages: (source, id, offset) => messagesPort != null
          ? messagesPort!(source, id, offset)
          : source == SupportConsentSelectionSource.support
          ? selector.listSupportMessages(sessionId: id, offset: offset)
          : selector.listRoleplayMessages(sessionId: id, offset: offset),
    );
  }
  static const id = PermissionDatabaseFixture.id;
  static const canary = 'STATIC_NATIVE_KEY_CANARY_72931';
  final database = PermissionDatabaseFixture();
  final revisions = ConnectionRevisionRegistry();
  SecretRedactor redactor = SecretRedactor(knownSecrets: [canary]);
  late final NativeSpyApiRepo api;
  late final SupportWorkspaceStore workspace;
  late final SupportRecipientResolver resolver;
  late final SupportNativeRuntime runtime;
  late final SupportNativeConsentController controller;
  int selectedLoads = 0;
  Future<void> Function()? beforeSelected;
  SupportNativeMessageReader? messagesPort;
  SupportRecipientSettingsReader? settingsPort;
  int settingsReads = 0;
  Future<SupportAssistantSettings?> _readSettings(String id) async {
    settingsReads++;
    return settingsPort == null
        ? workspace.readableSettingsFor(id)
        : settingsPort!(id);
  }

  SupportConnectionInspection? get inspection => runtime.inspection;

  Future<void> seed() async {
    await database.seed();
    await database.b.selectScopeFromNative(
      id,
      SupportPermissionScope(
        selectionRevision: 2,
        supportHistory: SupportMessageSelection(['synthetic-message']),
        safeCategories: [SupportSafeCategory.connections],
      ),
      isCurrent: () => true,
    );
    await api.put(
      const ApiConfig(
        id: 'synthetic-connection',
        name: 'Synthetic selected connection',
        endpoint: 'https://synthetic.invalid/v1/chat/completions',
        apiKey: canary,
        model: 'stored-model',
      ),
    );
    await api.put(
      const ApiConfig(
        id: 'unselected-connection',
        name: 'Unselected private label',
        endpoint: 'https://unselected.invalid/v1/chat/completions',
        apiKey: 'STATIC_UNSELECTED_KEY',
        model: 'other',
      ),
    );
    await workspace.changeSettings(
      id,
      (s) => s.copyWith(
        apiConfigId: 'synthetic-connection',
        modelId: 'synthetic-model',
      ),
    );
    runtime.selectSession(id);
    await runtime.refresh();
    api.ids.clear();
    settingsReads = 0;
  }

  Future<void> close() async {
    runtime.dispose();
    await database.close();
  }
}

final class NativeSpyApiRepo extends ApiConfigRepo {
  NativeSpyApiRepo(
    PermissionDatabaseFixture fixture,
    ConnectionRevisionRegistry revisions,
  ) : super(fixture.db, onMutationStarted: revisions.beginMutation);
  final ids = <String>[];
  int bulkReads = 0;
  Future<void> Function()? afterRead;
  @override
  Future<ApiConfig?> getById(String id) async {
    ids.add(id);
    final result = await super.getById(id);
    await afterRead?.call();
    return result;
  }

  @override
  Future<List<ApiConfig>> getAll() {
    bulkReads++;
    return super.getAll();
  }
}
