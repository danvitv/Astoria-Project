import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_character_hash.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_character_world_equivalence.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_character_false_conflicts_test.dart'
    show
        card,
        authoredImage,
        oldTime,
        seedLegacy,
        DownloadCheckpointAdapter,
        checkpointEngine;
import 'sync_lifecycle_test.dart' show SyncWorld;

const remoteCard = Character(
  id: 'card-a',
  name: 'Synthetic card',
  description: 'Original text',
  updatedAt: oldTime,
  variantGroupId: 'group-a',
  variantName: 'First',
  extensions: {
    'world': 'synthetic-world-a',
    'authoredBinding': {'id': 'synthetic-binding', 'enabled': true},
  },
);

Character materialized(Character remote) =>
    remote.copyWith(world: remote.extensions['world'] as String);

Future<SyncManifestEntry> seed(
  SyncWorld world,
  Character remote, {
  bool legacy = true,
  bool cold = false,
  int avatarSize = 0,
}) async {
  final old = await seedLegacy(
    world,
    remote,
    cold: cold,
    avatarSize: avatarSize,
  );
  final entry = old.copyWith(
    hash: SyncCharacterHash.compute(
      remote.toJson(),
      avatarSize,
      legacy: legacy,
    ),
  );
  final manifest = SyncManifest.fromJson(
    jsonDecode(world.cloud.files[cloudPath('manifest', 'manifest')]!)
        as Map<String, dynamic>,
  ).copyWith(entries: {entry.key: entry});
  world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
    manifest.toJson(includeLocalState: false),
  );
  if (!cold) await world.manifestProvider.writeLocalManifest(manifest);
  world.characters.data[remote.id] = materialized(remote);
  return entry;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('real Drift repository materializes extension-only world', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final repo = CharacterRepo(db);
    expect(remoteCard.world, isNull);
    await repo.put(remoteCard);
    final local = (await repo.getById(remoteCard.id))!;
    expect(local.world == remoteCard.extensions['world'], isTrue);
    expect(local.extensions, remoteCard.extensions);
    expect(
      SyncCharacterHash.compute(local.toJson(), 0) ==
          SyncCharacterHash.compute(remoteCard.toJson(), 0),
      isFalse,
    );
    expect(
      SyncCharacterHash.compute(
            SyncCharacterWorldEquivalence.project(local.toJson())!,
            0,
          ) ==
          SyncCharacterHash.compute(
            SyncCharacterWorldEquivalence.project(remoteCard.toJson())!,
            0,
          ),
      isTrue,
    );
    await repo.put(remoteCard.copyWith(world: 'synthetic-override'));
    final override = (await repo.getById(remoteCard.id))!;
    expect(override.world == 'synthetic-override', isTrue);
    expect(override.extensions['world'] == override.world, isTrue);
    expect(
      override.extensions['authoredBinding'],
      remoteCard.extensions['authoredBinding'],
    );
  });

  for (final legacy in [false, true]) {
    for (final pushFirst in [false, true]) {
      for (final emptyTop in [false, true]) {
        test(
          'world materialization repeats legacy=$legacy push=$pushFirst empty=$emptyTop',
          () async {
            final world = SyncWorld();
            final remote = remoteCard.copyWith(world: emptyTop ? '' : null);
            final entry = await seed(world, remote, legacy: legacy);
            final localCard = world.characters.data[card.id]!;
            final original = world.cloud.files[entry.path];
            world.cloud.uploadFailures.add(entry.path);
            if (pushFirst) await world.engine.pushEntities(onProgress: (_) {});
            for (var i = 0; i < 3; i++) {
              await world.engine.pullEntities(
                onProgress: (_) {},
                onConflict: (_) => fail('Equivalent world must not conflict'),
              );
              await world.engine.pushEntities(onProgress: (_) {});
              final manifest = await world.manifestProvider.readLocalManifest();
              expect(manifest.entries[entry.key]?.hash, entry.hash);
              expect(manifest.entries[entry.key]?.updatedAt, entry.updatedAt);
              expect(
                manifest.acceptedLocalHashes[entry.key],
                SyncCharacterHash.compute(localCard.toJson(), 0),
              );
              expect(world.characters.data[card.id], localCard);
              expect(world.cloud.files[entry.path], original);
              expect(
                jsonDecode(
                  world.cloud.files[cloudPath('manifest', 'manifest')]!,
                ).containsKey('acceptedLocalHashes'),
                isFalse,
              );
            }
          },
        );
      }
    }
  }

  test('cold world proof preserves local materialized state', () async {
    final world = SyncWorld();
    await seed(world, remoteCard, cold: true);
    final local = world.characters.data[card.id]!;
    await world.engine.pullEntities(
      onProgress: (_) {},
      onConflict: (_) => fail('Unexpected cold conflict'),
    );
    expect(world.characters.data[card.id], local);
  });

  test(
    'two materialized devices preserve mixed old manifest entries',
    () async {
      final first = SyncWorld();
      final entry = await seed(first, remoteCard);
      final path = cloudPath('manifest', 'manifest');
      final old = SyncManifest.fromJson(
        jsonDecode(first.cloud.files[path]!) as Map<String, dynamic>,
      );
      final absent = entry.copyWith(
        id: 'cloud-only',
        path: cloudPath('character', 'cloud-only'),
      );
      final deleted = entry.copyWith(id: 'deleted', deleted: true, hash: '');
      first.cloud.files[path] = jsonEncode(
        old
            .copyWith(
              entries: {
                ...old.entries,
                absent.key: absent,
                deleted.key: deleted,
              },
            )
            .toJson(includeLocalState: false),
      );
      first.cloud.uploadFailures.add(entry.path);
      await first.engine.pushEntities(onProgress: (_) {});
      final second = SyncWorld();
      await second.manifestProvider.writeLocalManifest(old);
      second.characters.data[card.id] = materialized(
        remoteCard,
      ).copyWith(tokenCount: 777, currentSessionIndex: 4);
      second.cloud.files.addAll(first.cloud.files);
      second.cloud.uploadFailures.add(entry.path);
      await second.engine.pushEntities(onProgress: (_) {});
      final published = SyncManifest.fromJson(
        jsonDecode(second.cloud.files[path]!) as Map<String, dynamic>,
      );
      expect(published.entries[entry.key]?.hash, entry.hash);
      expect(published.entries[absent.key]?.hash, absent.hash);
      expect(published.entries[deleted.key]?.deleted, isTrue);
      expect(second.cloud.files[entry.path], first.cloud.files[entry.path]);
    },
  );

  test('nonempty portable gallery survives repeated world proof', () async {
    final world = SyncWorld();
    final remote = remoteCard.copyWith(gallery: [authoredImage]);
    final entry = await seed(world, remote);
    final local = materialized(remote).copyWith(
      gallery: [authoredImage.copyWith(imagePath: 'other-missing.png')],
    );
    world.characters.data[card.id] = local;
    world.cloud.uploadFailures.add(entry.path);
    for (var i = 0; i < 3; i++) {
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: (_) => fail('Portable gallery must remain equivalent'),
      );
      await world.engine.pushEntities(onProgress: (_) {});
      expect(world.characters.data[card.id], local);
      expect(
        jsonDecode(world.cloud.files[entry.path]!)['gallery'],
        remote.gallery.map((e) => e.toJson()).toList(),
      );
    }
  });

  test(
    'contradictory top and extension with different effective worlds conflict',
    () async {
      final world = SyncWorld();
      final remote = remoteCard.copyWith(world: 'synthetic-world-b');
      final entry = await seed(world, remote);
      final conflicts = <SyncConflict>[];
      await world.engine.pullEntities(
        onProgress: (_) {},
        onConflict: conflicts.add,
      );
      expect(conflicts.map((c) => c.key), [entry.key]);
      expect(
        (await world.manifestProvider.readLocalManifest()).acceptedLocalHashes,
        isEmpty,
      );
      await world.engine.pushEntities(onProgress: (_) {});
      expect(
        jsonDecode(world.cloud.files[entry.path]!)['world'],
        world.characters.data[card.id]!.world,
      );
    },
  );

  for (final edit in <String, Character Function(Character)>{
    'top override': (c) => c.copyWith(world: 'synthetic-world-b'),
    'linked world': (c) =>
        c.copyWith(extensions: {...c.extensions, 'world': 'synthetic-world-b'}),
    'authored binding': (c) => c.copyWith(
      extensions: {
        ...c.extensions,
        'authoredBinding': {'id': 'changed'},
      },
    ),
    'explicit clear': (c) => c.copyWith(world: null, extensions: {}),
    'gallery': (c) => c.copyWith(gallery: [authoredImage]),
  }.entries) {
    test(
      '${edit.key} after world acceptance conflicts and publishes',
      () async {
        final world = SyncWorld();
        final entry = await seed(world, remoteCard);
        await world.engine.pullEntities(
          onProgress: (_) {},
          onConflict: (_) => fail('Unexpected baseline conflict'),
        );
        final edited = edit
            .value(materialized(remoteCard))
            .copyWith(updatedAt: oldTime + 1);
        world.characters.data[card.id] = edited;
        final conflicts = <SyncConflict>[];
        await world.engine.pullEntities(
          onProgress: (_) {},
          onConflict: conflicts.add,
        );
        expect(conflicts.map((c) => c.key), [entry.key]);
        await world.engine.pushEntities(onProgress: (_) {});
        final payload = jsonDecode(world.cloud.files[entry.path]!);
        expect(payload['world'], edited.world);
        expect(payload['extensions'], edited.extensions);
        expect(
          payload['gallery'],
          edited.gallery.map((e) => e.toJson()).toList(),
        );
        expect(
          (await world.manifestProvider.readLocalManifest())
              .acceptedLocalHashes,
          isEmpty,
        );
      },
    );
  }

  for (final mutation in <String, void Function(Map<String, dynamic>)>{
    'unknown field': (j) => j['unknownAuthoredField'] = 'synthetic',
    'malformed top': (j) => j['world'] = 42,
    'malformed extension': (j) => j['extensions']['world'] = 42,
    'null extension world': (j) => j['extensions']['world'] = null,
    'unverified fingerprint': (j) => j['description'] = 'unpublished change',
  }.entries) {
    test('${mutation.key} cannot obtain a world accepted marker', () async {
      final world = SyncWorld();
      final entry = await seed(world, remoteCard);
      final payload =
          jsonDecode(world.cloud.files[entry.path]!) as Map<String, dynamic>;
      mutation.value(payload);
      world.cloud.files[entry.path] = jsonEncode(payload);
      final before = await world.manifestProvider.readLocalManifest();
      final conflicts = <SyncConflict>[];
      // Invalid model types may fail parsing elsewhere; neither path accepts.
      try {
        await world.engine.pullEntities(
          onProgress: (_) {},
          onConflict: conflicts.add,
        );
        expect(conflicts.map((c) => c.key), [entry.key]);
      } on TypeError {
        expect(
          (await world.manifestProvider.readLocalManifest()).toJson(),
          before.toJson(),
        );
      }
      expect(
        (await world.manifestProvider.readLocalManifest()).acceptedLocalHashes,
        isEmpty,
      );
    });
  }

  for (final editExtension in [false, true]) {
    test(
      'download guard rejects world edit extension=$editExtension',
      () async {
        final world = SyncWorld();
        final entry = await seed(world, remoteCard);
        final before = await world.manifestProvider.readLocalManifest();
        final adapter = DownloadCheckpointAdapter()
          ..files.addAll(world.cloud.files);
        final cloudBefore = Map<String, String>.from(adapter.files);
        final edited = editExtension
            ? materialized(remoteCard).copyWith(
                extensions: {...remoteCard.extensions, 'world': 'changed-link'},
              )
            : materialized(remoteCard).copyWith(world: 'changed-top');
        var hit = false;
        adapter.onDownload = (path) {
          if (path != entry.path) return;
          hit = true;
          adapter.onDownload = null;
          world.characters.data[card.id] = edited;
        };
        await expectLater(
          checkpointEngine(world, adapter).pushEntities(onProgress: (_) {}),
          throwsA(
            isA<StateError>().having(
              (e) => e.message,
              'message',
              'Character changed during sync hash upgrade; retry',
            ),
          ),
        );
        expect(hit, isTrue);
        expect(world.characters.data[card.id], edited);
        expect(adapter.files, cloudBefore);
        expect(
          (await world.manifestProvider.readLocalManifest()).toJson(),
          before.toJson(),
        );
      },
    );
  }

  test('avatar size cannot be hidden by matching effective world', () async {
    final root = Directory(
      '${Platform.environment['LOCALAPPDATA']}/Temp/opencode',
    );
    final directory = await root.createTemp('world-avatar-');
    addTearDown(() => directory.delete(recursive: true));
    final world = SyncWorld(imageDirectory: directory);
    await File('${directory.path}/avatar.png').writeAsBytes([1, 2, 3, 4]);
    final entry = await seed(
      world,
      remoteCard.copyWith(avatarPath: 'avatar.png'),
      avatarSize: 3,
    );
    final conflicts = <SyncConflict>[];
    await world.engine.pullEntities(
      onProgress: (_) {},
      onConflict: conflicts.add,
    );
    expect(conflicts.map((c) => c.key), [entry.key]);
    expect(
      (await world.manifestProvider.readLocalManifest()).acceptedLocalHashes,
      isEmpty,
    );
  });
}
