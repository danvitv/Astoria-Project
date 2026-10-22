import 'dart:async';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/connection_revision_registry.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_recipient_resolver.dart';

/// Synthetic memory DB only. No production providers, settings, vault or files.
final class RecipientResolutionFixture {
  RecipientResolutionFixture() {
    repo = GatedRecipientApiRepo(db, revisions);
    resolver = SupportRecipientResolver(
      apiRepo: repo,
      readSettings: (id) async {
        settingsReads++;
        if (settingsPort != null) return settingsPort!(id);
        return id == 'support-a' && sessionExists ? settings : null;
      },
      currentContext: () => context,
      revisions: revisions,
      redactor: () => redactor,
    );
  }
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final revisions = ConnectionRevisionRegistry();
  late final GatedRecipientApiRepo repo;
  late final SupportRecipientResolver resolver;
  SecretRedactor redactor = SecretRedactor();
  SupportRecipientContext? context = const SupportRecipientContext(
    supportSessionId: 'support-a',
    epoch: 1,
  );
  SupportAssistantSettings settings = const SupportAssistantSettings(
    apiConfigId: 'api-a',
    modelId: 'selected-model',
  );
  bool sessionExists = true;
  int settingsReads = 0;
  SupportRecipientSettingsReader? settingsPort;

  static const config = ApiConfig(
    id: 'api-a',
    name: 'Synthetic connection',
    endpoint: 'https://recipient.example/v1/chat/completions',
    apiKey: 'STATIC_CANARY_KEY_734291',
    model: 'saved-model',
  );

  void bumpContext([String session = 'support-a']) {
    context = SupportRecipientContext(
      supportSessionId: session,
      epoch: context!.epoch + 1,
    );
  }

  /// Simulates raw restored rows, deliberately bypassing the normal write hook.
  /// This is a test affordance, not a claimed production observation mechanism.
  Future<void> rawEndpoint(String endpoint) =>
      (db.update(db.apiConfigs)..where((t) => t.configId.equals('api-a')))
          .write(ApiConfigsCompanion(endpoint: Value(endpoint)));
}

final class GatedRecipientApiRepo extends ApiConfigRepo {
  GatedRecipientApiRepo(super.db, ConnectionRevisionRegistry revisions)
    : super(onMutationStarted: revisions.beginMutation);
  Future<void> Function()? afterRead;
  int rowReads = 0;
  @override
  Future<ApiConfig?> getById(String id) async {
    rowReads++;
    final row = await super.getById(id);
    await afterRead?.call();
    return row;
  }
}
