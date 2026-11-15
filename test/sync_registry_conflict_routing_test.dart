import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_service.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';

import 'sync_lifecycle_test.dart' as fakes;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'explicit push routes a divergent registry tombstone to conflicts',
    () async {
      SharedPreferences.setMockInitialValues({});
      const sessionId = 'registry-full-sync-conflict';
      final chats = fakes.FakeChatStore();
      final characters = fakes.FakeCharacterStore();
      final registry = fakes.FakeMemoryEventRegistryStore();
      final cloud = fakes.FakeCloudAdapter();
      await chats.put(fakes.makeChat(sessionId));
      final previousPayload = fakes.fakeMemoryEventRegistry(sessionId, [
        'old-event',
      ]);
      final currentPayload = fakes.fakeMemoryEventRegistry(sessionId, [
        'new-event',
      ]);
      registry.data[sessionId] = currentPayload;
      final previous = SyncManifestEntry(
        type: 'memory_event_registry',
        id: sessionId,
        path: cloudPath('memory_event_registry', sessionId),
        updatedAt: 1,
        hash: SyncSerialization.computeSyncHash(previousPayload),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'gz_sync_manifest_v2',
        jsonEncode(
          SyncManifest(
            deviceId: 'local',
            createdAt: 1,
            lastSync: 1,
            entries: {previous.key: previous},
          ).toJson(),
        ),
      );
      final tombstone = SyncManifestEntry(
        type: 'memory_event_registry',
        id: sessionId,
        path: previous.path,
        updatedAt: 2000,
        hash: '',
        deleted: true,
      );
      cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        SyncManifest(
          deviceId: 'cloud',
          createdAt: 1,
          entries: {tombstone.key: tombstone},
        ).toJson(),
      );
      final service = SyncService(
        characterRepo: characters,
        chatRepo: chats,
        personaRepo: fakes.FakePersonaStore(),
        presetRepo: fakes.FakePresetStore(),
        apiRepo: fakes.FakeApiConfigStore(),
        memoryBookRepo: fakes.FakeMemoryBookStore(),
        lorebookRepo: fakes.FakeLorebookStore(),
        embeddingRepo: fakes.FakeEmbeddingStore(),
        imageStorage: fakes.FakeImageStore(),
        themePresetRepo: fakes.FakeThemePresetStore(),
        extensionPresetRepo: fakes.FakeExtensionPresetStore(),
        extensionsSettingsStore: fakes.FakeExtensionsSettingsStore(),
        infoBlockStore: fakes.FakeInfoBlockStore(),
        trackerSnapshotStore: fakes.FakeTrackerSnapshotStore(),
        trackerValueStore: fakes.FakeTrackerValueStore(),
        studioConfigStore: fakes.FakeStudioConfigStore(),
        memoryEventRegistryStore: registry,
        sessionDeletionStore: fakes.FakeSessionDeletionStore(chats),
        characterDeletionStore: fakes.FakeCharacterDeletionStore(characters),
        saveLorebookActivations: (_) async {},
        selectAdapter: (_) => cloud,
      );
      addTearDown(service.dispose);

      final pending = service.fullPushWithConflictPreflight();
      final publicationGuard = service.capturePublicationGuard();
      await pending;

      expect(service.status, SyncStatus.conflict);
      expect(publicationGuard(), isTrue);
      expect(service.lastError, isNull);
      expect(service.conflicts.map((conflict) => conflict.key), [
        tombstone.key,
      ]);
      expect(registry.data[sessionId], currentPayload);
    },
  );
}
