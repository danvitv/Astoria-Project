import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:glaze_flutter/core/application/chat_source_mutation_registry.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/persona_repo.dart';
import 'package:glaze_flutter/core/db/repositories/lorebook_repo.dart';
import 'package:glaze_flutter/core/db/repositories/preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/llm/studio_controller_ontology.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/cleaner_settings.dart';
import 'package:glaze_flutter/core/models/ledger_settings.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_action_registry.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_metadata_policy.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_content_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'content_control_isolation.dart';
import 'content_control_native_gesture.dart';

export 'package:glaze_flutter/core/models/character.dart';
export 'package:glaze_flutter/core/models/persona.dart';
export 'package:glaze_flutter/core/models/lorebook.dart';
export 'package:glaze_flutter/core/models/preset.dart';
export 'package:glaze_flutter/core/models/studio_config.dart';
export 'package:glaze_flutter/features/support_assistant/models/support_app_action.dart';
export 'package:glaze_flutter/features/support_assistant/state/support_app_control_content_provider.dart';

final class ContentControlFixture {
  ContentControlFixture(this.block) {
    db = ContentMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    characters = CharacterRepo(db);
    personas = PersonaRepo(db);
    lorebooks = LorebookRepo(db);
    presets = PresetRepo(db);
    studio = StudioPresetRepo(db);
    gesture = ContentNativeGesture(sources);
  }
  static const private = 'SYNTHETIC_PRIVATE_CONTENT';
  final Never Function(String) block;
  final sql = ContentSqlBoundary();
  final sources = ChatSourceMutationRegistry();
  final redactor = SecretRedactor(
    knownSecrets: const ['SYNTHETIC_SECRET_VALUE'],
  );
  late final ContentMemoryDatabase db;
  late final CharacterRepo characters;
  late final PersonaRepo personas;
  late final LorebookRepo lorebooks;
  late final PresetRepo presets;
  late final StudioPresetRepo studio;
  late final ContentNativeGesture gesture;
  late ProviderContainer container;
  late SupportAppActionRegistry registry;
  bool current = true;
  int seq = 0;

  Future<void> initialize() async {
    SharedPreferences.setMockInitialValues({'presetOrder': '[]'});
    final prefs = await SharedPreferences.getInstance();
    final vault = CredentialVault(
      storage: ContentTrapStorage(block),
      buildChannel: 'synthetic_content',
    );
    final cipher = SupportPayloadCipher(
      vault: vault,
      cipher: ContentTrapCipher(block),
    );
    container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        characterRepoProvider.overrideWithValue(characters),
        personaRepoProvider.overrideWithValue(personas),
        lorebookRepoProvider.overrideWithValue(lorebooks),
        presetRepoProvider.overrideWithValue(presets),
        studioPresetRepoProvider.overrideWithValue(studio),
        sharedPreferencesProvider.overrideWith((ref) async => prefs),
        credentialVaultProvider.overrideWithValue(vault),
        supportPayloadCipherProvider.overrideWithValue(cipher),
        nativeProviderAdapterFactoryProvider.overrideWith(
          (ref) => block('native adapter factory'),
        ),
        supportAppControlContentMutationPortProvider.overrideWithValue(gesture),
      ],
    );
    await characters.put(
      const Character(
        id: 'character',
        name: private,
        description: private,
        systemPrompt: private,
        variantGroupId: 'character',
        extensions: {'privateNative': private},
        currentSessionIndex: 4,
      ),
    );
    await personas.put(
      const Persona(
        id: 'persona',
        name: private,
        prompt: private,
        displayName: private,
        createdAt: 1,
      ),
    );
    await lorebooks.put(
      const Lorebook(
        id: 'lorebook',
        name: private,
        description: private,
        entries: [
          LorebookEntry(
            id: 'entry',
            content: private,
            comment: private,
            keys: [private],
          ),
        ],
        settings: LorebookSettings(scanDepth: 10),
      ),
    );
    await presets.put(
      const Preset(
        id: 'collision',
        name: private,
        summaryPrompt: private,
        blocks: [
          PresetBlock(
            id: 'ordinary-block',
            name: private,
            role: 'system',
            content: private,
          ),
          PresetBlock(
            id: 'chat_history',
            name: private,
            role: 'system',
            content: private,
            isStatic: true,
          ),
        ],
      ),
    );
    await studio.upsert(
      StudioPreset(
        id: 'collision',
        name: private,
        agents: StudioControllerOntology.buildDefaultAgents(
          sessionId: 'synthetic',
          now: 1,
        ),
        blocks: const [
          StudioPresetBlock(
            id: 'studio-block',
            title: private,
            content: private,
          ),
          StudioPresetBlock(
            id: 'locked',
            title: private,
            content: private,
            locked: true,
          ),
          StudioPresetBlock(id: 'history', type: StudioBlockType.history),
        ],
        runtime: const StudioRuntimeSettings(
          cleaner: CleanerSettings(postCleanerBannedWords: private),
          ledger: LedgerSettings(studioLedgerModel: 'synthetic-model'),
        ),
      ),
    );
    registry = buildRegistry(
      container.read(supportAppControlContentAdaptersProvider),
    );
  }

  SupportAppActionRegistry buildRegistry(
    List<SupportAppActionAdapter> adapters,
  ) => SupportAppActionRegistry(
    adapters: adapters,
    isOriginalOwnerCurrent: () => current,
    metadata: SupportAppRedactedMetadataPolicy(currentRedactor: () => redactor),
  );

  SupportAppActionContext context() => SupportAppActionContext(
    runId: 'content-run',
    sessionId: 'support-session',
    cancelToken: CancelToken(),
    isCurrent: () => current,
    allowReversibleChanges: false,
    confirmation: gesture,
  );

  Future<NativeToolResult> call(
    String action,
    Map<String, Object?> args, {
    bool nativeGesture = false,
    SupportAppActionContext? original,
    SupportAppActionRegistry? gateway,
  }) {
    final source = original ?? context();
    if (nativeGesture)
      gesture.gesture(action: action, arguments: args, original: source);
    return (gateway ?? registry).execute(
      NativeToolCall(
        id: 'content_call_${seq++}',
        name: action,
        arguments: args,
      ),
      source,
    );
  }
}

final class ContentMemoryDatabase extends AppDatabase {
  ContentMemoryDatabase(super.executor) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final class ContentSqlBoundary extends QueryInterceptor {
  Future<void> Function()? afterNextSelect;
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runSelect(executor, statement, args);
    final hook = afterNextSelect;
    afterNextSelect = null;
    await hook?.call();
    return result;
  }
}
