import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/character_deletion_store.dart';
import 'package:glaze_flutter/core/application/session_deletion_store.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/models/gallery_entry.dart';
import 'package:glaze_flutter/core/models/lorebook.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/persona.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_repo_interfaces.dart';
import 'package:glaze_flutter/features/extensions/models/extension_preset.dart';
import 'package:glaze_flutter/features/extensions/models/extensions_settings.dart';
import 'package:glaze_flutter/features/extensions/models/info_block.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_read_port.dart';
import 'package:glaze_flutter/core/preferences/tracked_shared_preferences.dart';

class _FakeApiConfigStore implements SyncApiConfigStore {
  final Map<String, ApiConfig> data = {};

  @override
  Future<List<ApiConfig>> getAll() async => data.values.toList();

  @override
  Future<ApiConfig?> getById(String id) async => data[id];

  @override
  Future<void> put(ApiConfig config) async {
    data[config.id] = config;
  }

  @override
  Future<void> delete(String id) async {
    data.remove(id);
  }
}

class _FakeCloudAdapter implements CloudAdapter {
  final Map<String, String> files = {};

  @override
  Future<bool> isConnected() async => true;
  @override
  Future<void> ensureFolder(String path) async {}
  @override
  Future<void> upload(String path, String data) async => files[path] = data;
  @override
  Future<void> uploadBinary(String path, Uint8List data) async {}
  @override
  Future<String> download(String path) async {
    final value = files[path];
    if (value == null) throw CloudFileNotFoundException(path);
    return value;
  }

  @override
  Future<Uint8List> downloadBinary(String path) async => Uint8List(0);
  @override
  Future<void> deleteFile(String path) async => files.remove(path);
  @override
  Future<void> deleteFolder(String path) async {}
  @override
  Future<List<CloudFileInfo>> listFolder(String path) async => const [];
  @override
  Future<Map<String, dynamic>?> getAccountInfo() async => const {};
  @override
  Future<void> invalidateFolderCache() async {}
}

class _SimpleManifestProvider implements SyncManifestProvider {
  SyncManifest manifest = const SyncManifest(deviceId: 'local', createdAt: 0);

  @override
  Future<SyncManifest> buildLocalManifest({
    SyncManifest? cloudManifest,
    bool applyAcceptedHashes = true,
  }) async => manifest;

  @override
  Future<SyncManifest> readLocalManifest() async => manifest;

  @override
  Future<void> writeLocalManifest(SyncManifest value) async {
    manifest = value;
  }

  @override
  Future<void> clearLocalManifest() async {
    manifest = const SyncManifest(deviceId: 'local', createdAt: 0);
  }

  @override
  Future<void> clearDeleted() async {}

  @override
  Future<bool> isDeleted(String type, String id) async => false;

  @override
  Future<String> getDeviceId() async => 'local';
}

class _NoopCharacterStore implements SyncCharacterStore {
  @override
  Future<List<Character>> getAll() async => const [];
  @override
  Future<Character?> getById(String id) async => null;
  @override
  Future<void> put(Character character) async {}
  @override
  Future<void> updateAvatarPath(String id, String path) async {}
  @override
  Future<void> updateGallery(String id, List<GalleryEntry> gallery) async {}
  @override
  Future<void> delete(String id) async {}
}

class _NoopChatStore implements SyncChatStore {
  @override
  Future<List<SessionMetadata>> getAllSessionMetadata() async => const [];
  @override
  Future<ChatSession?> getById(String id) async => null;
  @override
  Future<void> put(ChatSession session) async {}
  @override
  Future<void> delete(String id) async {}
}

class _NoopPersonaStore implements SyncPersonaStore {
  @override
  Future<List<Persona>> getAll() async => const [];
  @override
  Future<Persona?> getById(String id) async => null;
  @override
  Future<void> put(Persona persona) async {}
  @override
  Future<void> updateAvatarPath(String id, String path) async {}
  @override
  Future<void> delete(String id) async {}
}

class _NoopPresetStore implements SyncPresetStore {
  @override
  Future<List<Preset>> getAll() async => const [];
  @override
  Future<Preset?> getById(String id) async => null;
  @override
  Future<void> put(Preset preset) async {}
  @override
  Future<void> delete(String id) async {}
}

class _NoopMemoryBookStore implements SyncMemoryBookStore {
  @override
  Future<List<MemoryBook>> getAll() async => const [];
  @override
  Future<MemoryBook?> getBySessionId(String sessionId) async => null;
  @override
  Future<void> put(MemoryBook book) async {}
  @override
  Future<void> deleteBySessionId(String sessionId) async {}
}

class _NoopLorebookStore implements SyncLorebookStore {
  @override
  Future<List<Lorebook>> getAll() async => const [];
  @override
  Future<Lorebook?> getById(String id) async => null;
  @override
  Future<void> put(Lorebook lorebook) async {}
  @override
  Future<void> putAll(List<Lorebook> lorebooks) async {}
  @override
  Future<void> delete(String id) async {}
}

class _NoopEmbeddingStore implements SyncEmbeddingStore {
  @override
  Future<void> deleteBySourceId(String sourceId) async {}
}

class _NoopImageStore implements SyncImageStore {
  @override
  String? absolutePath(String? relativePath) => relativePath;
  @override
  Future<String> saveBytes(
    Uint8List bytes,
    String subfolder,
    String filename,
    String ext,
  ) async => '$subfolder/$filename.$ext';
}

class _NoopThemePresetStore implements SyncThemePresetStore {
  @override
  Future<List<ThemePreset>> getAll() async => const [];
  @override
  Future<void> putAll(List<ThemePreset> presets) async {}
}

class _NoopExtensionPresetStore implements SyncExtensionPresetStore {
  @override
  Future<List<ExtensionPreset>> getAll() async => const [];
  @override
  Future<ExtensionPreset?> getById(String id) async => null;
  @override
  Future<void> put(ExtensionPreset preset) async {}
  @override
  Future<void> delete(String id) async {}
}

class _NoopExtensionsSettingsStore implements SyncExtensionsSettingsStore {
  @override
  Future<ExtensionsSettings> get() async => const ExtensionsSettings();
  @override
  Future<void> put(ExtensionsSettings settings) async {}
}

class _NoopInfoBlockStore implements SyncInfoBlockStore {
  @override
  Future<List<String>> getAllSessionIds() async => const [];
  @override
  Future<List<InfoBlock>> getBySessionId(String sessionId) async => const [];
  @override
  Future<void> deleteBySessionId(String sessionId) async {}
  @override
  Future<void> insert(InfoBlock block) async {}
}

class _NoopTrackerSnapshotStore implements SyncTrackerSnapshotStore {
  @override
  Future<List<String>> getAllSessionIds() async => const [];
  @override
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId) async =>
      const [];
  @override
  Future<void> deleteBySessionId(String sessionId) async {}
  @override
  Future<void> insertRaw(Map<String, dynamic> snapshot) async {}
}

class _NoopTrackerValueStore implements SyncTrackerValueStore {
  @override
  Future<List<String>> getAllSessionIds() async => const [];
  @override
  Future<List<Map<String, dynamic>>> getBySessionId(String sessionId) async =>
      const [];
  @override
  Future<void> deleteBySessionId(String sessionId) async {}
  @override
  Future<void> insertRaw(Map<String, dynamic> tracker) async {}
}

class _NoopStudioConfigStore implements SyncStudioConfigStore {
  @override
  Future<List<StudioConfig>> getAll() async => const [];
  @override
  Future<StudioConfig?> getById(String id) async => null;
  @override
  Future<void> put(StudioConfig config) async {}
  @override
  Future<void> delete(String id) async {}
}

class _NoopSessionDeletionStore implements SessionDeletionStore {
  @override
  Future<void> deleteSession(String sessionId) async {}
}

class _NoopCharacterDeletionStore implements CharacterDeletionStore {
  @override
  Future<CharacterDeletionResult> deleteCharacters(
    Set<String> characterIds,
  ) async => CharacterDeletionResult(
    characterIds: characterIds,
    sessionIds: const {},
    studioConfigSessionIds: const {},
    detachedLorebookIds: const {},
  );
}

void main() {
  late _FakeApiConfigStore apiRepo;
  late _FakeCloudAdapter cloud;
  late _SimpleManifestProvider manifestProvider;
  late SyncEngine engine;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    apiRepo = _FakeApiConfigStore();
    cloud = _FakeCloudAdapter();
    manifestProvider = _SimpleManifestProvider();
    engine = SyncEngine(
      cloud,
      manifestProvider,
      _NoopCharacterStore(),
      _NoopChatStore(),
      _NoopPersonaStore(),
      _NoopPresetStore(),
      apiRepo,
      _NoopMemoryBookStore(),
      _NoopLorebookStore(),
      _NoopEmbeddingStore(),
      _NoopImageStore(),
      _NoopThemePresetStore(),
      _NoopExtensionPresetStore(),
      _NoopExtensionsSettingsStore(),
      _NoopInfoBlockStore(),
      _NoopTrackerSnapshotStore(),
      _NoopTrackerValueStore(),
      _NoopStudioConfigStore(),
      null,
      null,
      null,
      null,
      null,
      _NoopSessionDeletionStore(),
      _NoopCharacterDeletionStore(),
      (_) async {},
      null,
      null,
      null,
      0,
    );
  });

  Future<void> pullCloudConfigs(List<ApiConfig> configs) async {
    final items = configs.map((c) => c.toJson()).toList();
    final payload = {'__singleton': true, 'items': items};
    final path = cloudPath('api_presets', 'api_presets');
    cloud.files[path] = jsonEncode(payload);
    final cloudManifest = SyncManifest(
      deviceId: 'cloud-device',
      createdAt: 2000,
      apiKeysIncluded: false,
      entries: {
        'api_presets:api_presets': SyncManifestEntry(
          type: 'api_presets',
          id: 'api_presets',
          path: path,
          updatedAt: 2000,
          hash: SyncSerialization.computeApiPresetsHash(items),
        ),
      },
    );
    cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
      cloudManifest.toJson(),
    );
    await engine.pullEntities(onProgress: (_) {}, onConflict: (_) {});
  }

  test(
    'saved preferences native owner: actual local-storage sync intent precedes queue admission and preserves unrelated keys',
    () async {
      final prefs = await TrackedSharedPreferences.getInstance();
      await prefs.setString('pipelineSettings', 'old saved pipeline');
      final port = SavedPreferencesReadPort(
        original: Future.value(prefs),
        loaded: prefs,
        producerCurrent: () => true,
      );
      final old = port.capture('savedPipelinePreferences');
      final unrelated = port.capture('savedGlobalVariables');
      final payload = {
        '__localStorage': true,
        'pipelineSettings': '{}',
        'activeStudioPresetId': 'synthetic-synced-studio',
        'gz_global_regex_scripts': '[]',
        'gz_studio_regex_scripts': '[]',
      };
      final path = cloudPath('local_storage', 'local_storage');
      cloud.files[path] = jsonEncode(payload);
      cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        SyncManifest(
          deviceId: 'synthetic-cloud',
          createdAt: 2000,
          entries: {
            'local_storage:local_storage': SyncManifestEntry(
              type: 'local_storage',
              id: 'local_storage',
              path: path,
              updatedAt: 2000,
              hash: SyncSerialization.computeSyncHash(payload),
            ),
          },
        ).toJson(),
      );
      var beforeQueue = false;
      await engine.pullEntities(
        onConflict: (_) => fail('Unexpected conflict'),
        onProgress: (p) {
          if (p.current == 0 && p.total == 1) {
            beforeQueue = true;
            expect(prefs.getString('pipelineSettings'), 'old saved pipeline');
            expect(port.isCurrent(old), false);
            expect(port.capture('savedPipelinePreferences').current, false);
            expect(port.isCurrent(unrelated), true);
          }
        },
      );
      expect(beforeQueue, true);
      expect(prefs.getString('pipelineSettings'), '{}');
      expect(
        prefs.getString('activeStudioPresetId'),
        'synthetic-synced-studio',
      );
      expect(prefs.getString('gz_global_regex_scripts'), '[]');
      expect(prefs.getString('gz_studio_regex_scripts'), '[]');
      expect(port.isCurrent(old), false);
      expect(port.capture('savedPipelinePreferences').current, true);
      expect(port.isCurrent(unrelated), true);
    },
  );

  test(
    'preserves local apiKey, embeddingApiKey, query secrets, and extraRequestParameters secrets when route matches',
    () async {
      await apiRepo.put(
        const ApiConfig(
          id: 'cfg-match',
          name: 'Local OpenAI',
          protocol: 'openai',
          endpoint:
              'https://api.openai.com/v1/chat/completions?api_key=query-llm-secret',
          apiKey: 'sk-local-llm-key',
          model: 'gpt-4o',
          embeddingUseSame: false,
          embeddingEnabled: true,
          embeddingEndpoint:
              'https://api.openai.com/v1/embeddings?api_key=query-emb-secret',
          embeddingApiKey: 'sk-local-emb-key',
          extraRequestParameters: [
            ExtraRequestParameter(
              key: 'Authorization',
              value: 'Bearer local-header-secret',
            ),
            ExtraRequestParameter(key: 'custom_flag', value: 'true'),
          ],
        ),
      );

      // Cloud update changes model/name with stripped keys on the same route.
      await pullCloudConfigs(const [
        ApiConfig(
          id: 'cfg-match',
          name: 'Updated Name',
          protocol: 'openai',
          endpoint: 'https://api.openai.com/v1/chat/completions?api_key=',
          apiKey: '',
          model: 'gpt-4.1',
          embeddingUseSame: false,
          embeddingEnabled: true,
          embeddingEndpoint: 'https://api.openai.com/v1/embeddings?api_key=',
          embeddingApiKey: '',
          extraRequestParameters: [
            ExtraRequestParameter(key: 'Authorization', value: ''),
            ExtraRequestParameter(key: 'custom_flag', value: 'true'),
          ],
        ),
      ]);

      final updated = apiRepo.data['cfg-match']!;
      expect(updated.name, 'Updated Name');
      expect(updated.model, 'gpt-4.1');
      expect(updated.apiKey, 'sk-local-llm-key');
      expect(updated.embeddingApiKey, 'sk-local-emb-key');
      expect(
        updated.endpoint,
        'https://api.openai.com/v1/chat/completions?api_key=query-llm-secret',
      );
      expect(
        updated.embeddingEndpoint,
        'https://api.openai.com/v1/embeddings?api_key=query-emb-secret',
      );
      expect(
        updated.extraRequestParameters.first.value,
        'Bearer local-header-secret',
      );
    },
  );

  test(
    'drops local apiKey and embeddingApiKey when keyless cloud update changes host, path, or protocol',
    () async {
      const localTemplate = ApiConfig(
        id: 'cfg-1',
        protocol: 'openai',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        apiKey: 'sk-local-secret',
        embeddingUseSame: true,
        embeddingApiKey: 'sk-local-emb-secret',
        extraRequestParameters: [
          ExtraRequestParameter(key: 'api_key', value: 'param-secret'),
          ExtraRequestParameter(
            key: 'nested',
            value: '{"access_token":"nested-secret","safe":"ok"}',
          ),
        ],
      );

      // 1. Host change -> drops keys and strips secret parameters / query keys.
      await apiRepo.put(localTemplate);
      await pullCloudConfigs(const [
        ApiConfig(
          id: 'cfg-1',
          protocol: 'openai',
          endpoint:
              'https://attacker.example/v1/chat/completions?api_key=leaked',
          apiKey: '',
          embeddingUseSame: true,
          embeddingApiKey: '',
          extraRequestParameters: [
            ExtraRequestParameter(key: 'api_key', value: 'param-secret'),
            ExtraRequestParameter(
              key: 'nested',
              value: '{"access_token":"nested-secret","safe":"ok"}',
            ),
          ],
        ),
      ]);
      final afterHostChange = apiRepo.data['cfg-1']!;
      expect(afterHostChange.apiKey, isEmpty);
      expect(afterHostChange.embeddingApiKey, isEmpty);
      expect(afterHostChange.endpoint, isNot(contains('leaked')));
      expect(afterHostChange.extraRequestParameters[0].value, isEmpty);
      expect(
        afterHostChange.extraRequestParameters[1].value,
        isNot(contains('nested-secret')),
      );

      // 2. Path change -> drops keys.
      await apiRepo.put(
        localTemplate.copyWith(
          endpoint: 'https://proxy.example/tenant-a/v1/chat/completions',
        ),
      );
      await pullCloudConfigs(const [
        ApiConfig(
          id: 'cfg-1',
          protocol: 'openai',
          endpoint: 'https://proxy.example/tenant-b/v1/chat/completions',
          apiKey: '',
          embeddingUseSame: true,
          embeddingApiKey: '',
        ),
      ]);
      expect(apiRepo.data['cfg-1']!.apiKey, isEmpty);
      expect(apiRepo.data['cfg-1']!.embeddingApiKey, isEmpty);

      // 3. Protocol change -> drops keys.
      await apiRepo.put(localTemplate);
      await pullCloudConfigs(const [
        ApiConfig(
          id: 'cfg-1',
          protocol: 'anthropic',
          endpoint: 'https://api.openai.com/v1/messages',
          apiKey: '',
          embeddingUseSame: true,
          embeddingApiKey: '',
        ),
      ]);
      expect(apiRepo.data['cfg-1']!.apiKey, isEmpty);
      expect(apiRepo.data['cfg-1']!.embeddingApiKey, isEmpty);
    },
  );

  test(
    'shared embedding preservation requires the same trimmed pinned preset',
    () async {
      const local = ApiConfig(
        id: 'cfg-pinned',
        protocol: 'openai',
        endpoint:
            'https://api.openai.com/v1/chat/completions?api_key=llm-query-secret',
        apiKey: 'local-llm-secret',
        embeddingUseSame: true,
        embeddingLlmPresetId: ' pinned-a ',
        embeddingEndpoint:
            'https://embedding.example/v1/embeddings?api_key=embedding-query-secret',
        embeddingApiKey: 'local-embedding-secret',
      );

      for (final pinnedId in ['pinned-a', 'pinned-b', '']) {
        await apiRepo.put(local);
        await pullCloudConfigs([
          local.copyWith(
            apiKey: '',
            endpoint: 'https://api.openai.com/v1/chat/completions?api_key=',
            embeddingApiKey: '',
            embeddingLlmPresetId: pinnedId,
            embeddingEndpoint:
                'https://embedding.example/v1/embeddings?api_key=cloud-query-secret',
          ),
        ]);

        final updated = apiRepo.data[local.id]!;
        expect(updated.apiKey, local.apiKey);
        expect(updated.endpoint, contains('llm-query-secret'));
        expect(
          updated.embeddingApiKey,
          pinnedId == 'pinned-a' ? local.embeddingApiKey : '',
        );
        expect(
          updated.embeddingEndpoint,
          isNot(contains('cloud-query-secret')),
        );
        expect(
          updated.embeddingEndpoint,
          isNot(contains('embedding-query-secret')),
        );
      }
    },
  );

  test(
    'dedicated embedding route guard drops local embeddingApiKey when embedding endpoint or mode changes',
    () async {
      const localDedicated = ApiConfig(
        id: 'cfg-emb',
        protocol: 'openai',
        endpoint: 'https://api.openai.com/v1/chat/completions',
        apiKey: 'sk-local-llm',
        embeddingUseSame: false,
        embeddingEnabled: true,
        embeddingEndpoint: 'https://embeddings.trusted.example/v1/embeddings',
        embeddingApiKey: 'sk-local-emb',
      );

      // 1. Dedicated embedding host changes while LLM route stays the same:
      // LLM key is preserved, embedding key is dropped.
      await apiRepo.put(localDedicated);
      await pullCloudConfigs(const [
        ApiConfig(
          id: 'cfg-emb',
          protocol: 'openai',
          endpoint: 'https://api.openai.com/v1/chat/completions',
          apiKey: '',
          embeddingUseSame: false,
          embeddingEnabled: true,
          embeddingEndpoint:
              'https://attacker.example/v1/embeddings?key=should-strip',
          embeddingApiKey: '',
        ),
      ]);
      final afterEmbHostChange = apiRepo.data['cfg-emb']!;
      expect(afterEmbHostChange.apiKey, 'sk-local-llm');
      expect(afterEmbHostChange.embeddingApiKey, isEmpty);
      expect(
        afterEmbHostChange.embeddingEndpoint,
        isNot(contains('should-strip')),
      );

      // 2. Flipping embeddingUseSame from true to false drops local embeddingApiKey.
      await apiRepo.put(localDedicated.copyWith(embeddingUseSame: true));
      await pullCloudConfigs(const [
        ApiConfig(
          id: 'cfg-emb',
          protocol: 'openai',
          endpoint: 'https://api.openai.com/v1/chat/completions',
          apiKey: '',
          embeddingUseSame: false,
          embeddingEnabled: true,
          embeddingEndpoint: 'https://embeddings.trusted.example/v1/embeddings',
          embeddingApiKey: '',
        ),
      ]);
      expect(apiRepo.data['cfg-emb']!.apiKey, 'sk-local-llm');
      expect(apiRepo.data['cfg-emb']!.embeddingApiKey, isEmpty);
    },
  );
}
