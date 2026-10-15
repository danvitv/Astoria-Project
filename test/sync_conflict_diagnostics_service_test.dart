import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_service.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_conflict_diagnostics_test.dart' as fixtures;
import 'sync_lifecycle_test.dart' as fakes;

class WriteRejectingCloud extends fakes.FakeCloudAdapter {
  @override
  Future<void> ensureFolder(String path) async => fail('ensureFolder');
  @override
  Future<void> upload(String path, String data) async => fail('upload');
  @override
  Future<void> uploadBinary(String path, Uint8List data) async =>
      fail('uploadBinary');
  @override
  Future<Uint8List> downloadBinary(String path) async =>
      throw StateError('downloadBinary');
  @override
  Future<void> deleteFile(String path) async => fail('deleteFile');
  @override
  Future<void> deleteFolder(String path) async => fail('deleteFolder');
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'engine uses only injected text downloader; serialized manifest remains identical',
    () async {
      SharedPreferences.setMockInitialValues({});
      final world = fakes.SyncWorld();
      final c = fixtures.conflict('character');
      world.characters.data[c.id] = Character(id: c.id, name: fixtures.canary);
      const manifest = SyncManifest(
        deviceId: fixtures.canary,
        createdAt: 1,
        acceptedLocalHashes: {'synthetic': fixtures.canary},
      );
      await world.manifestProvider.writeLocalManifest(manifest);
      final before = jsonEncode(
        (await world.manifestProvider.readLocalManifest()).toJson(),
      );
      final cloud = WriteRejectingCloud();
      cloud.files[cloudPath(c.type, c.id)] = jsonEncode(
        world.characters.data[c.id]!.toJson(),
      );
      final beforeCloud = jsonEncode(cloud.files);
      final report = await world.engine.diagnoseConflicts([
        c,
      ], diagnosticDownload: cloud.download);
      expect(report.items.single.paths, isEmpty);
      expect(cloud.downloadCalls, [cloudPath(c.type, c.id)]);
      expect(cloud.listFolderCalls, isEmpty);
      expect(jsonEncode(cloud.files), beforeCloud);
      expect(
        jsonEncode((await world.manifestProvider.readLocalManifest()).toJson()),
        before,
      );
      expect(world.cloud.downloadCalls, isEmpty);
      expect(world.cloud.ensuredFolders, isEmpty);
    },
  );

  test(
    'service serializes concrete owners, preserves prefs/entities/conflicts, releases lock',
    () async {
      SharedPreferences.setMockInitialValues({
        'gz_sync_manifest': 'synthetic manifest',
        'gz_sync_pending_pull_manifest': 'synthetic pending',
        'gz_sync_tokens': 'synthetic tokens',
      });
      final prefs = await SharedPreferences.getInstance();
      Map<String, Object?> prefSnapshot() => {
        for (final key in prefs.getKeys()) key: prefs.get(key),
      };
      final beforePrefs = jsonEncode(prefSnapshot());
      final chars = fakes.FakeCharacterStore();
      final chats = fakes.FakeChatStore();
      final c = fixtures.conflict('character');
      chars.data[c.id] = Character(id: c.id, name: fixtures.canary);
      final beforeChars = jsonEncode(
        chars.data.map((k, v) => MapEntry(k, v.toJson())),
      );
      final entered = Completer<void>();
      final gate = Completer<String>();
      final service = SyncService(
        characterRepo: chars,
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
        sessionDeletionStore: fakes.FakeSessionDeletionStore(chats),
        characterDeletionStore: fakes.FakeCharacterDeletionStore(chars),
        saveLorebookActivations: (_) async =>
            fail('Unexpected preferences write'),
        diagnosticDownload: (_) {
          entered.complete();
          return gate.future;
        },
      );
      service.conflicts.add(c);
      final beforeConflicts = List.of(service.conflicts);
      final pending = service.diagnoseConflicts(service.conflicts);
      await entered.future;
      expect(service.operationInProgress, isTrue);
      expect(service.isDiagnosingConflicts, isTrue);
      for (final operation in <Future<void> Function()>[
        () async {
          await service.diagnoseConflicts([c]);
        },
        () => service.fullPush(),
        () => service.fullPull(),
        () => service.fullSync(),
        () => service.wipeCloudData(),
        () => service.resolveConflict(c, 'local'),
        () => service.resolveAllConflicts('cloud'),
        () => service.resolveAllConflictsAndApply('cloud', onProgress: (_) {}),
        () => service.applyPendingPullAfterResolve(onProgress: (_) {}),
        () => service.disconnect(),
        () => service.connectDropbox(),
        () => service.connectGDrive(),
        () => service.setProvider(SyncProvider.gdrive),
        () => service.init(),
        () async {
          await service.resolveGDriveFolderId();
        },
        () => service.setAutoSync(true),
      ]) {
        await expectLater(operation(), throwsStateError);
      }
      expect(await service.tryAutoPush(), isFalse);
      await service.incrementMessageCounter();
      gate.completeError(StateError(fixtures.canary));
      final report = await pending;
      expect(report.items.single.status, SyncDiagnosticStatus.cloudReadFailed);
      expect(report.toSafeText(), isNot(contains(fixtures.canary)));
      expect(service.operationInProgress, isFalse);
      expect(service.isDiagnosingConflicts, isFalse);
      expect(service.status, SyncStatus.idle);
      expect(service.lastError, isNull);
      expect(service.lastSyncTime, isNull);
      expect(service.conflicts, beforeConflicts);
      expect(jsonEncode(prefSnapshot()), beforePrefs);
      expect(
        jsonEncode(chars.data.map((k, v) => MapEntry(k, v.toJson()))),
        beforeChars,
      );
      final second = await service.diagnoseConflicts([
        fixtures.conflict('api_presets'),
      ]);
      expect(second.items.single.status, SyncDiagnosticStatus.unsupported);
      expect(service.operationInProgress, isFalse);
    },
  );
}
