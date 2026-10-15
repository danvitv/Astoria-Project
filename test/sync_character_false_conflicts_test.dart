import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/gallery_entry.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_character_hash.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart'
    show
        SyncWorld,
        FakeCloudAdapter,
        FakeExtensionPresetStore,
        FakeExtensionsSettingsStore,
        FakeInfoBlockStore,
        FakeTrackerSnapshotStore,
        FakeTrackerValueStore;

const oldTime = 1700000000;
const card = Character(
  id: 'card-a',
  name: 'Synthetic card',
  description: 'Original text',
  updatedAt: oldTime,
  variantGroupId: 'group-a',
  variantName: 'First',
);

const authoredImage = GalleryEntry(
  id: 'image-a',
  characterId: 'card-a',
  imagePath: 'missing-gallery.png',
  label: 'Authored addition',
  createdAt: 1,
);

class DownloadCheckpointAdapter extends FakeCloudAdapter {
  void Function(String)? onDownload;

  @override
  Future<String> download(String path) async {
    final data = await super.download(path);
    onDownload?.call(path);
    return data;
  }
}

SyncEngine checkpointEngine(SyncWorld world, FakeCloudAdapter adapter) =>
    SyncEngine(
      adapter,
      world.manifestProvider,
      world.characters,
      world.chats,
      world.personas,
      world.presets,
      world.apiConfigs,
      world.memoryBooks,
      world.lorebooks,
      world.embeddings,
      world.images,
      world.uiThemes,
      FakeExtensionPresetStore(),
      FakeExtensionsSettingsStore(),
      FakeInfoBlockStore(),
      FakeTrackerSnapshotStore(),
      FakeTrackerValueStore(),
      world.studioConfigs,
      world.studioPresets,
      null,
      null,
      null,
      null,
      world.sessionDeletions,
      world.characterDeletions,
      (_) async {},
      null,
      null,
      null,
      0,
      Duration.zero,
    );

Future<SyncManifestEntry> seedLegacy(
  SyncWorld world,
  Character remote, {
  String? acceptedHash,
  bool cold = false,
  int avatarSize = 0,
}) async {
  world.characters.data[remote.id] = remote;
  final entry = SyncManifestEntry(
    type: 'character',
    id: remote.id,
    path: cloudPath('character', remote.id),
    updatedAt: oldTime * 1000,
    hash: SyncCharacterHash.compute(remote.toJson(), avatarSize, legacy: true),
  );
  final manifest = SyncManifest(
    version: 16,
    deviceId: 'old-device',
    createdAt: 1,
    lastSync: cold ? 0 : 1,
    entries: {entry.key: entry},
    acceptedLocalHashes: acceptedHash == null ? {} : {entry.key: acceptedHash},
  );
  world.cloud.files[entry.path] = jsonEncode(remote.toJson());
  world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
    manifest.toJson(includeLocalState: false),
  );
  if (!cold) await world.manifestProvider.writeLocalManifest(manifest);
  return entry;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  for (final pushFirst in [false, true]) {
    for (final change in <String, Character Function(Character)>{
      'session': (c) => c.copyWith(currentSessionIndex: 6),
      'tokens': (c) => c.copyWith(tokenCount: 999),
      'timestamp units': (c) => c.copyWith(updatedAt: oldTime * 1000),
      'metadata timestamp': (c) =>
          c.copyWith(updatedAt: oldTime * 1000 + 90000),
    }.entries) {
      test(
        '${change.key}, pushFirst=$pushFirst stays aligned repeatedly',
        () async {
          final world = SyncWorld();
          final entry = await seedLegacy(world, card);
          world.characters.data[card.id] = change.value(card);
          final originalPayload = world.cloud.files[entry.path];
          world.cloud.uploadFailures.add(
            entry.path,
          ); // Any re-push fails the test.
          final conflicts = <SyncConflict>[];
          if (pushFirst) await world.engine.pushEntities(onProgress: (_) {});
          for (var cycle = 0; cycle < 3; cycle++) {
            await world.engine.pullEntities(
              onProgress: (_) {},
              onConflict: conflicts.add,
            );
            await world.engine.pushEntities(onProgress: (_) {});
            final local = await world.manifestProvider.readLocalManifest();
            expect(local.entries[entry.key]?.hash, entry.hash);
            expect(local.entries[entry.key]?.updatedAt, entry.updatedAt);
            expect(
              local.acceptedLocalHashes[entry.key],
              SyncCharacterHash.compute(change.value(card).toJson(), 0),
            );
          }
          expect(conflicts, isEmpty);
          expect(world.characters.data[card.id], change.value(card));
          expect(world.cloud.files[entry.path], originalPayload);
          final cloud =
              jsonDecode(world.cloud.files[cloudPath('manifest', 'manifest')]!)
                  as Map;
          expect(cloud.containsKey('acceptedLocalHashes'), isFalse);
        },
      );
    }
  }

  for (final edit in <String, Character Function(Character)>{
    'text': (c) => c.copyWith(description: 'Real edit'),
    'variant': (c) => c.copyWith(variantName: 'Second', variantOrder: 2),
    'gallery': (c) => c.copyWith(
      gallery: [
        const GalleryEntry(
          id: 'image-a',
          characterId: 'card-a',
          imagePath: 'missing.png',
          label: 'New',
          createdAt: 1,
        ),
      ],
    ),
  }.entries) {
    test('${edit.key} after upgrade still conflicts and pushes', () async {
      final world = SyncWorld();
      await seedLegacy(world, card);
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) => fail('unexpected'),
      );
      world.characters.data[card.id] = edit
          .value(card)
          .copyWith(updatedAt: oldTime + 1);
      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: conflicts.add,
      );
      expect(conflicts.map((c) => c.id), [card.id]);
      await world.engine.pushEntities(onProgress: (_) {});
      final payload = jsonDecode(
        world.cloud.files[cloudPath('character', card.id)]!,
      );
      expect(payload['variantName'], edit.value(card).variantName);
      expect(payload['description'], edit.value(card).description);
      expect(
        payload['gallery'],
        edit.value(card).gallery.map((image) => image.toJson()).toList(),
      );
      expect(
        (await world.manifestProvider.readLocalManifest()).acceptedLocalHashes,
        isEmpty,
      );
    });
  }

  test('cold start metadata equivalence does not replace local card', () async {
    final world = SyncWorld();
    await seedLegacy(world, card, cold: true);
    world.characters.data[card.id] = card.copyWith(
      tokenCount: 99,
      currentSessionIndex: 4,
    );
    await world.engine.pullEntities(
      onProgress: (_) {},
      onConflict: (_) => fail('unexpected'),
    );
    expect(world.characters.data[card.id]?.currentSessionIndex, 4);
  });

  test(
    'cold start with real content difference keeps existing cloud policy',
    () async {
      final world = SyncWorld();
      await seedLegacy(world, card, cold: true);
      world.characters.data[card.id] = card.copyWith(
        description: 'Unsynced local',
      );
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) => fail('unexpected'),
      );
      expect(world.characters.data[card.id]?.description, card.description);
    },
  );

  test(
    'legacy gallery payload plus metadata drift upgrades without upload',
    () async {
      final world = SyncWorld();
      final remote = card.copyWith(
        gallery: [
          const GalleryEntry(
            id: 'old-image',
            characterId: 'card-a',
            imagePath: 'gone.png',
            label: 'Old',
            createdAt: 1,
          ),
        ],
      );
      final entry = await seedLegacy(world, remote);
      world.characters.data[card.id] = remote.copyWith(currentSessionIndex: 3);
      world.cloud.uploadFailures.add(entry.path);
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) => fail('unexpected'),
      );
      await world.engine.pushEntities(onProgress: (_) {});
      world.characters.data[card.id] = remote.copyWith(
        gallery: [remote.gallery.single.copyWith(label: 'Real label edit')],
      );
      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: conflicts.add,
      );
      expect(conflicts, hasLength(1));
    },
  );

  test(
    'two upgraded devices retain old cloud entry and cloud-only tombstone',
    () async {
      final first = SyncWorld();
      final entry = await seedLegacy(first, card);
      final manifestPath = cloudPath('manifest', 'manifest');
      final original = SyncManifest.fromJson(
        jsonDecode(first.cloud.files[manifestPath]!) as Map<String, dynamic>,
      );
      final absent = entry.copyWith(
        id: 'cloud-only',
        path: cloudPath('character', 'cloud-only'),
      );
      final deleted = entry.copyWith(id: 'deleted', deleted: true, hash: '');
      first.cloud.files[manifestPath] = jsonEncode(
        original
            .copyWith(
              entries: {
                ...original.entries,
                absent.key: absent,
                deleted.key: deleted,
              },
            )
            .toJson(includeLocalState: false),
      );
      final second = SyncWorld();
      await second.manifestProvider.writeLocalManifest(original);
      first.characters.data[card.id] = card.copyWith(currentSessionIndex: 1);
      second.characters.data[card.id] = card.copyWith(tokenCount: 100);
      await first.engine.pushEntities(onProgress: (_) {});
      second.cloud.files.addAll(first.cloud.files);
      second.cloud.uploadFailures.add(entry.path);
      await second.engine.pushEntities(onProgress: (_) {});
      final cloud = SyncManifest.fromJson(
        jsonDecode(second.cloud.files[manifestPath]!) as Map<String, dynamic>,
      );
      expect(cloud.entries[entry.key]?.hash, entry.hash);
      expect(cloud.entries[absent.key]?.hash, absent.hash);
      expect(cloud.entries[deleted.key]?.deleted, isTrue);
    },
  );

  test(
    'same title variants remain distinct; dirty legacy marker cannot hide edit',
    () async {
      final world = SyncWorld();
      final entry = await seedLegacy(world, card, acceptedHash: 'stale-marker');
      final second = card.copyWith(id: 'card-b', variantName: 'Second');
      world.characters.data[second.id] = second;
      world.characters.data[card.id] = card.copyWith(description: 'Edit');
      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: conflicts.add,
      );
      expect(conflicts.map((c) => c.key), [entry.key]);
      await world.engine.pushEntities(onProgress: (_) {});
      expect(
        world.cloud.files.containsKey(cloudPath('character', second.id)),
        isTrue,
      );
    },
  );

  test(
    'legacy intentionally accepted representation upgrades without re-push',
    () async {
      final world = SyncWorld();
      final local = card.copyWith(description: 'Intentionally normalized');
      final entry = await seedLegacy(
        world,
        card,
        acceptedHash: SyncCharacterHash.compute(
          local.toJson(),
          0,
          legacy: true,
        ),
      );
      world.characters.data[card.id] = local;
      world.cloud.uploadFailures.add(entry.path);
      await world.engine.pushEntities(onProgress: (_) {});
      world.characters.data[card.id] = local.copyWith(
        tokenCount: 77,
        currentSessionIndex: 9,
      );
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) => fail('unexpected'),
      );
      await world.engine.pushEntities(onProgress: (_) {});
    },
  );

  test(
    'avatar byte-size change cannot pass legacy equivalence bridge',
    () async {
      final root = Platform.isWindows
          ? Directory('${Platform.environment['LOCALAPPDATA']}/Temp/opencode')
          : Directory.systemTemp;
      final directory = await root.createTemp('sync-card-test-');
      addTearDown(() => directory.delete(recursive: true));
      final world = SyncWorld(imageDirectory: directory);
      final image = File('${directory.path}/avatar.png');
      await image.writeAsBytes([1, 2, 3]);
      await seedLegacy(
        world,
        card.copyWith(avatarPath: 'avatar.png'),
        avatarSize: 3,
      );
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) => fail('unexpected'),
      );
      await image.writeAsBytes([1, 2, 3, 4]);
      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: conflicts.add,
      );
      expect(conflicts, hasLength(1));
      await world.engine.pushEntities(onProgress: (_) {});
      expect(
        world.cloud.files['$cloudBase/gallery/${card.id}/avatar.png']?.length,
        4,
      );
    },
  );

  test(
    'missing old avatar plus metadata drift does not re-push card',
    () async {
      final world = SyncWorld();
      final remote = card.copyWith(avatarPath: 'missing.png');
      final entry = await seedLegacy(world, remote, avatarSize: 3);
      world.characters.data[card.id] = remote.copyWith(tokenCount: 89);
      world.cloud.uploadFailures.add(entry.path);
      await world.engine.pushEntities(onProgress: (_) {});
      expect(
        (await world.manifestProvider.readLocalManifest())
            .entries[entry.key]
            ?.hash,
        entry.hash,
      );
    },
  );

  test('missing avatars gallery addition requires card upload', () async {
    final world = SyncWorld();
    final remote = card.copyWith(avatarPath: 'missing.png');
    final entry = await seedLegacy(world, remote, avatarSize: 3);
    world.characters.data[card.id] = remote.copyWith(
      gallery: [authoredImage],
      updatedAt: oldTime + 1,
    );
    final before = await world.manifestProvider.readLocalManifest();
    final payload = world.cloud.files[entry.path];
    world.cloud.uploadFailures.add(entry.path);

    await expectLater(
      world.engine.pushEntities(onProgress: (_) {}),
      throwsA(
        predicate<Object>(
          (error) => error.toString().contains('Upload failed: ${entry.path}'),
        ),
      ),
    );
    expect(world.cloud.files[entry.path], payload);
    expect(
      (await world.manifestProvider.readLocalManifest()).toJson(),
      before.toJson(),
    );
  });

  test('missing avatars portable gallery metadata does not re-push', () async {
    final world = SyncWorld();
    final remote = card.copyWith(
      avatarPath: 'missing.png',
      gallery: [authoredImage],
    );
    final entry = await seedLegacy(world, remote, avatarSize: 3);
    final localCard = remote.copyWith(
      gallery: [authoredImage.copyWith(imagePath: 'other-missing.png')],
      tokenCount: 89,
      currentSessionIndex: 4,
      updatedAt: oldTime + 1,
    );
    world.characters.data[card.id] = localCard;
    final payload = world.cloud.files[entry.path];
    world.cloud.uploadFailures.add(entry.path);
    for (var cycle = 0; cycle < 3; cycle++) {
      await world.engine.pushEntities(onProgress: (_) {});
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) => fail('Portable gallery metadata must stay aligned'),
      );
      expect(world.characters.data[card.id], localCard);
      expect(world.cloud.files[entry.path], payload);
      final local = await world.manifestProvider.readLocalManifest();
      expect(local.entries[entry.key]?.hash, entry.hash);
      expect(
        local.acceptedLocalHashes[entry.key],
        SyncCharacterHash.compute(localCard.toJson(), 0),
      );
    }
  });

  for (final edit in <String, List<GalleryEntry> Function(List<GalleryEntry>)>{
    'addition': (_) => [authoredImage],
    'label': (images) => [
      images.first.copyWith(label: 'Edited label'),
      images.last,
    ],
    'order': (images) => images.reversed.toList(),
    'id': (images) => [images.first.copyWith(id: 'replacement'), images.last],
    'createdAt': (images) => [images.first.copyWith(createdAt: 9), images.last],
    'removal': (_) => [],
  }.entries) {
    test('missing avatars gallery ${edit.key} publishes repeatedly', () async {
      final world = SyncWorld();
      final remote = card.copyWith(
        avatarPath: 'missing.png',
        gallery: edit.key == 'addition'
            ? []
            : [authoredImage, authoredImage.copyWith(id: 'image-b')],
      );
      final entry = await seedLegacy(world, remote, avatarSize: 3);
      final edited = remote.copyWith(
        gallery: edit.value(remote.gallery),
        updatedAt: oldTime + 1,
      );
      world.characters.data[card.id] = edited;

      await world.engine.pushEntities(onProgress: (_) {});
      final published = world.cloud.files[entry.path];
      final payload = jsonDecode(published!) as Map<String, dynamic>;
      expect(
        payload['gallery'],
        edited.gallery.map((image) => image.toJson()).toList(),
      );
      final local = await world.manifestProvider.readLocalManifest();
      expect(
        local.entries[entry.key]?.hash,
        SyncCharacterHash.compute(edited.toJson(), 0),
      );
      expect(local.acceptedLocalHashes.containsKey(entry.key), isFalse);
      // Once published, a repeated card upload is also an error.
      world.cloud.uploadFailures.add(entry.path);
      for (var cycle = 0; cycle < 3; cycle++) {
        await world.engine.pullEntities(
          onProgress: (_) {},
          onConflict: (_) => fail('Published gallery must not conflict'),
        );
        await world.engine.pushEntities(onProgress: (_) {});
        expect(world.characters.data[card.id], edited);
        expect(world.cloud.files[entry.path], published);
        expect(
          (await world.manifestProvider.readLocalManifest()).acceptedLocalHashes
              .containsKey(entry.key),
          isFalse,
        );
      }
    });
  }

  test('bridge rejects local edit during cloud card download', () async {
    final world = SyncWorld();
    final remote = card.copyWith(gallery: [authoredImage]);
    final entry = await seedLegacy(world, remote);
    world.characters.data[card.id] = remote.copyWith(tokenCount: 89);
    final before = await world.manifestProvider.readLocalManifest();
    final adapter = DownloadCheckpointAdapter()
      ..files.addAll(world.cloud.files);
    final cloudBefore = Map<String, String>.from(adapter.files);
    final edited = remote.copyWith(
      description: 'Authored during download',
      updatedAt: oldTime + 1,
    );
    var checkpointHit = false;
    adapter.onDownload = (path) {
      if (path != entry.path) return;
      checkpointHit = true;
      adapter.onDownload = null;
      world.characters.data[card.id] = edited;
    };
    final engine = checkpointEngine(world, adapter);
    await expectLater(
      engine.pushEntities(onProgress: (_) {}),
      throwsA(
        isA<StateError>().having(
          (error) => error.message,
          'message',
          'Character changed during sync hash upgrade; retry',
        ),
      ),
    );
    expect(checkpointHit, isTrue);
    expect(world.characters.data[card.id], edited);
    expect(
      (await world.manifestProvider.readLocalManifest()).toJson(),
      before.toJson(),
    );
    expect(adapter.files, cloudBefore);

    await engine.pushEntities(onProgress: (_) {});
    expect(
      jsonDecode(adapter.files[entry.path]!)['description'],
      edited.description,
    );
    expect(
      (await world.manifestProvider.readLocalManifest()).acceptedLocalHashes
          .containsKey(entry.key),
      isFalse,
    );
  });
}
