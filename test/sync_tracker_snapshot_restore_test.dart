import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_queue.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart'
    show
        FakeCloudAdapter,
        FakeExtensionPresetStore,
        FakeExtensionsSettingsStore,
        FakeInfoBlockStore,
        FakeReconciliationStateStore,
        FakeTrackerSnapshotStore,
        FakeTrackerValueStore,
        InMemoryManifestProvider,
        SyncWorld;

const _sessionId = 'snapshot-restore';
final _snapshotKey = entryKey('tracker_snapshot', _sessionId);
final _chatKey = entryKey('chat', _sessionId);
final _manifestPath = cloudPath('manifest', 'manifest');
final _snapshotPath = cloudPath('tracker_snapshot', _sessionId);

Map<String, dynamic> _payload(int count) => {
  '__trackerSnapshots': true,
  'items': [
    for (var i = 0; i < count; i++)
      {
        'id': 'snapshot-$i',
        'sessionId': _sessionId,
        'messageId': 'message-$i',
        'swipeId': 0,
        'agentSwipeId': 0,
        'trackersJson': '[]',
      },
  ],
};

class _SnapshotStore extends FakeTrackerSnapshotStore {
  bool failImport = false;
  bool normalizeImports = false;
  int replacements = 0;

  @override
  Future<void> deleteBySessionId(String sid) async {
    if (failImport) throw StateError('Snapshot import failed');
    replacements++;
    await super.deleteBySessionId(sid);
  }

  @override
  Future<void> insertRaw(Map<String, dynamic> snapshot) async {
    await super.insertRaw({
      ...snapshot,
      if (normalizeImports) 'normalized': true,
    });
  }
}

class _Cloud extends FakeCloudAdapter {
  final uploadedPaths = <String>[];
  void Function(String)? beforeDownload;

  @override
  Future<void> upload(String path, String data) async {
    uploadedPaths.add(path);
    await super.upload(path, data);
  }

  @override
  Future<String> download(String path) async {
    beforeDownload?.call(path);
    return super.download(path);
  }
}

class _SnapshotWorld extends SyncWorld {
  final snapshots = _SnapshotStore();
  final restoreCloud = _Cloud();
  late final SyncEngine _engine;
  late final InMemoryManifestProvider _restoreManifestProvider;
  final reconciledSessions = <Set<String>>[];

  @override
  _Cloud get cloud => restoreCloud;

  @override
  InMemoryManifestProvider get manifestProvider => _restoreManifestProvider;

  _SnapshotWorld()
    : super(reconciliationStateStore: FakeReconciliationStateStore()) {
    _restoreManifestProvider = InMemoryManifestProvider(
      characterRepo: characters,
      chatRepo: chats,
      personaRepo: personas,
      presetRepo: presets,
      apiRepo: apiConfigs,
      memoryBookRepo: memoryBooks,
      lorebookRepo: lorebooks,
      themePresetRepo: uiThemes,
      trackerSnapshotStore: snapshots,
      studioConfigStore: studioConfigs,
      studioPresetStore: studioPresets,
      reconciliationStateStore: reconciliationStates,
    );
    _engine = SyncEngine(
      cloud,
      manifestProvider,
      characters,
      chats,
      personas,
      presets,
      apiConfigs,
      memoryBooks,
      lorebooks,
      embeddings,
      images,
      uiThemes,
      FakeExtensionPresetStore(),
      FakeExtensionsSettingsStore(),
      FakeInfoBlockStore(),
      snapshots,
      FakeTrackerValueStore(),
      studioConfigs,
      studioPresets,
      null,
      null,
      null,
      null,
      sessionDeletions,
      characterDeletions,
      (_) async {},
      reconciliationStates,
      null,
      (ids) async => reconciledSessions.add(Set.of(ids)),
      0,
      Duration.zero,
    );
  }

  @override
  SyncEngine get engine => _engine;

  SyncManifest get cloudManifest => SyncManifest.fromJson(
    jsonDecode(cloud.files[_manifestPath]!) as Map<String, dynamic>,
  );

  void setCloudManifest(SyncManifest manifest) {
    cloud.files[_manifestPath] = jsonEncode(
      manifest.toJson(includeLocalState: false),
    );
  }

  Future<void> seedAcceptedCut({int version = 16}) async {
    await chats.put(
      const ChatSession(
        id: _sessionId,
        characterId: 'card',
        sessionIndex: 0,
        updatedAt: 1000,
        messages: [
          ChatMessage(id: 'message-0', role: 'assistant', content: 'Hi'),
        ],
      ),
    );
    snapshots.data[_sessionId] = (_payload(47)['items'] as List)
        .cast<Map<String, dynamic>>()
        .toList();
    reconciliationStates!.data[_sessionId] = {
      'runs': <dynamic>[],
      'checkpoints': [
        {'id': 'checkpoint-before-rewrite'},
        {'id': 'checkpoint-after-rewrite'},
      ],
    };
    final raw = await manifestProvider.buildLocalManifest(
      applyAcceptedHashes: false,
    );
    final complete = _payload(108);
    final cloudEntries = {
      ...raw.entries,
      _snapshotKey: raw.entries[_snapshotKey]!.copyWith(
        hash: SyncSerialization.computeSyncHash(complete),
        updatedAt: 1000,
      ),
    };
    final baseline = raw.copyWith(
      version: version,
      lastSync: 1000,
      createdAt: 1,
      entries: cloudEntries,
      acceptedLocalHashes: {_snapshotKey: raw.entries[_snapshotKey]!.hash},
    );
    await manifestProvider.writeLocalManifest(baseline);
    setCloudManifest(baseline);
    cloud.files[_snapshotPath] = jsonEncode(complete);
    cloud.files[cloudPath('chat', _sessionId)] = jsonEncode(
      chats.data[_sessionId]!.toJson(),
    );
  }

  Future<List<SyncConflict>> pull() async {
    final conflicts = <SyncConflict>[];
    await engine.pullEntities(onProgress: (_) {}, onConflict: conflicts.add);
    return conflicts;
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'v16 migration derives only nonempty accepted snapshot restore markers',
    () {
      final entries = <String, SyncManifestEntry>{};
      final accepted = <String, String>{};
      for (final type in [
        'tracker_snapshot',
        'tracker_value',
        'reconciliation_state',
      ]) {
        final entry = SyncManifestEntry(
          type: type,
          id: _sessionId,
          path: cloudPath(type, _sessionId),
          updatedAt: 1000,
          hash: 'cloud',
        );
        entries[entry.key] = entry;
        accepted[entry.key] = 'raw-local-$type';
      }
      final empty = entries[_snapshotKey]!.copyWith(id: 'empty');
      final deleted = entries[_snapshotKey]!.copyWith(
        id: 'deleted',
        deleted: true,
      );
      entries[empty.key] = empty;
      entries[deleted.key] = deleted;
      accepted[empty.key] = '';
      accepted[deleted.key] = 'deleted-local';
      final old = SyncManifest(
        version: 16,
        deviceId: 'device',
        createdAt: 1,
        entries: entries,
        acceptedLocalHashes: accepted,
      );
      final migrated = SyncManifest.fromJson(old.toJson());
      expect(migrated.acceptedLocalHashes, accepted);
      expect(migrated.trackerSnapshotRestoreHashes, {
        _snapshotKey: accepted[_snapshotKey],
      });
      final updated = migrated.copyWith(version: 17);
      expect(
        SyncManifest.fromJson(updated.toJson()).trackerSnapshotRestoreHashes,
        migrated.trackerSnapshotRestoreHashes,
      );
      expect(
        updated.toJson(includeLocalState: false),
        isNot(contains('trackerSnapshotRestoreHashes')),
      );
      expect(
        updated.toJson(includeLocalState: false),
        isNot(contains('acceptedLocalHashes')),
      );
      expect(
        SyncManifest.fromJson(
          old.copyWith(version: 17).toJson(),
        ).trackerSnapshotRestoreHashes,
        isEmpty,
      );
    },
  );

  test(
    'v16 accepted 47-row cut restores all 108 snapshots without deleting chat',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      final chat = world.chats.data[_sessionId];
      final checkpoints = jsonEncode(
        world.reconciliationStates!.data[_sessionId],
      );

      expect(await world.pull(), isEmpty);

      expect(world.snapshots.data[_sessionId], _payload(108)['items']);
      expect(world.chats.data[_sessionId], chat);
      expect(world.sessionDeletions.deletedSessionIds, isEmpty);
      expect(
        jsonEncode(world.reconciliationStates!.data[_sessionId]),
        checkpoints,
      );
      expect(world.reconciledSessions, [
        {_sessionId},
      ]);
      final local = await world.manifestProvider.readLocalManifest();
      expect(local.version, 17);
      expect(local.trackerSnapshotRestoreHashes, isEmpty);
      expect(local.acceptedLocalHashes, isNot(contains(_snapshotKey)));

      world.cloud.downloadCalls.clear();
      expect(await world.pull(), isEmpty);
      expect(world.cloud.downloadCalls, [_manifestPath]);
      expect(world.snapshots.replacements, 1);
    },
  );

  test(
    'push-first preserves repair and never uploads the cut aggregate',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      final complete = world.cloud.files[_snapshotPath];
      final previous = await world.manifestProvider.readLocalManifest();

      await world.engine.pushEntities(onProgress: (_) {});

      final pushed = await world.manifestProvider.readLocalManifest();
      expect(pushed.version, 17);
      expect(
        pushed.trackerSnapshotRestoreHashes,
        previous.trackerSnapshotRestoreHashes,
      );
      expect(
        pushed.acceptedLocalHashes[_snapshotKey],
        previous.acceptedLocalHashes[_snapshotKey],
      );
      expect(world.restoreCloud.uploadedPaths, isNot(contains(_snapshotPath)));
      expect(world.cloud.files[_snapshotPath], complete);
      expect(
        world.cloudManifest.entries[_snapshotKey]!.hash,
        previous.entries[_snapshotKey]!.hash,
      );
      expect(world.cloudManifest.trackerSnapshotRestoreHashes, isEmpty);

      expect(await world.pull(), isEmpty);
      expect(world.snapshots.data[_sessionId], hasLength(108));
      expect(
        (await world.manifestProvider.readLocalManifest())
            .trackerSnapshotRestoreHashes,
        isEmpty,
      );
    },
  );

  test('push-first also preserves a newer cloud snapshot hash', () async {
    final world = _SnapshotWorld();
    await world.seedAcceptedCut();
    final newer = _payload(109);
    world.cloud.files[_snapshotPath] = jsonEncode(newer);
    world.setCloudManifest(
      world.cloudManifest.copyWith(
        entries: {
          ...world.cloudManifest.entries,
          _snapshotKey: world.cloudManifest.entries[_snapshotKey]!.copyWith(
            hash: SyncSerialization.computeSyncHash(newer),
            updatedAt: 2000,
          ),
        },
      ),
    );

    await world.engine.pushEntities(onProgress: (_) {});

    expect(world.restoreCloud.uploadedPaths, isNot(contains(_snapshotPath)));
    expect(world.cloud.files[_snapshotPath], jsonEncode(newer));
    expect(
      world.cloudManifest.entries[_snapshotKey]!.hash,
      SyncSerialization.computeSyncHash(newer),
    );
    expect(await world.pull(), isEmpty);
    expect(world.snapshots.data[_sessionId], hasLength(109));
  });

  test(
    'push-first cannot erase a cloud-only owning chat advance during repair',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      final baseline = await world.manifestProvider.readLocalManifest();
      final oldChat = world.chats.data[_sessionId]!;
      final advanced = oldChat.copyWith(
        updatedAt: 2000,
        messages: [
          ...oldChat.messages,
          const ChatMessage(
            id: 'message-108',
            role: 'assistant',
            content: 'Newest cloud turn',
          ),
        ],
      );
      await world.chats.put(advanced);
      final advancedManifest = await world.manifestProvider.buildLocalManifest(
        applyAcceptedHashes: false,
      );
      await world.chats.put(oldChat);
      final complete = _payload(109);
      final cloud = world.cloudManifest;
      world.setCloudManifest(
        cloud.copyWith(
          entries: {
            ...cloud.entries,
            _chatKey: advancedManifest.entries[_chatKey]!,
            _snapshotKey: cloud.entries[_snapshotKey]!.copyWith(
              hash: SyncSerialization.computeSyncHash(complete),
              updatedAt: 2000,
            ),
          },
        ),
      );
      final chatPath = cloudPath('chat', _sessionId);
      world.cloud.files[chatPath] = jsonEncode(advanced.toJson());
      world.cloud.files[_snapshotPath] = jsonEncode(complete);
      final published = Map<String, String>.from(world.cloud.files);

      await expectLater(
        world.engine.pushEntities(onProgress: (_) {}),
        throwsA(
          isA<StateError>().having(
            (error) => error.message,
            'message',
            contains('Pull required'),
          ),
        ),
      );

      expect(world.restoreCloud.uploadedPaths, isEmpty);
      expect(world.cloud.files, published);
      final unchanged = await world.manifestProvider.readLocalManifest();
      expect(
        unchanged.entries[_chatKey]!.toJson(),
        baseline.entries[_chatKey]!.toJson(),
      );
      expect(
        unchanged.trackerSnapshotRestoreHashes,
        baseline.trackerSnapshotRestoreHashes,
      );
      expect(await world.pull(), isEmpty);
      expect(world.chats.data[_sessionId], advanced);
      expect(world.snapshots.data[_sessionId], complete['items']);
      expect(
        (await world.manifestProvider.readLocalManifest())
            .trackerSnapshotRestoreHashes,
        isEmpty,
      );
    },
  );

  test(
    'locally edited snapshots abandon repair and keep ordinary conflicts',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      world.snapshots.data[_sessionId]!.add({
        'id': 'authored-local-snapshot',
        'sessionId': _sessionId,
      });
      final built = await world.manifestProvider.buildLocalManifest(
        cloudManifest: world.cloudManifest,
      );
      expect(built.trackerSnapshotRestoreHashes, isEmpty);
      expect(built.acceptedLocalHashes, isNot(contains(_snapshotKey)));

      final conflicts = await world.pull();

      expect(conflicts.map((c) => c.key), [_snapshotKey]);
      expect(world.snapshots.data[_sessionId], hasLength(48));
      expect(world.cloud.downloadCalls, isNot(contains(_snapshotPath)));
    },
  );

  test(
    'failed download preserves pending restore and original local snapshots',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      world.cloud.downloadFailures.add(_snapshotPath);
      await expectLater(world.pull(), throwsA(isA<SyncQueueAggregateError>()));

      expect(world.snapshots.data[_sessionId], _payload(47)['items']);
      expect(
        (await world.manifestProvider.readLocalManifest())
            .trackerSnapshotRestoreHashes,
        contains(_snapshotKey),
      );
      world.cloud.downloadFailures.clear();
      expect(await world.pull(), isEmpty);
      expect(world.snapshots.data[_sessionId], hasLength(108));
    },
  );

  test('failed import preserves pending restore for a later pull', () async {
    final world = _SnapshotWorld();
    await world.seedAcceptedCut();
    await world.engine.pushEntities(onProgress: (_) {});
    world.snapshots.failImport = true;
    await expectLater(world.pull(), throwsA(isA<SyncQueueAggregateError>()));
    expect(
      (await world.manifestProvider.readLocalManifest())
          .trackerSnapshotRestoreHashes,
      contains(_snapshotKey),
    );
    world.snapshots.failImport = false;
    expect(await world.pull(), isEmpty);
    expect(world.snapshots.data[_sessionId], hasLength(108));
  });

  test(
    'malformed later cloud snapshot fails before local history replacement',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      final malformed = _payload(108);
      (malformed['items'] as List).add({'sessionId': _sessionId});
      world.cloud.files[_snapshotPath] = jsonEncode(malformed);
      final cloud = world.cloudManifest;
      world.setCloudManifest(
        cloud.copyWith(
          entries: {
            ...cloud.entries,
            _snapshotKey: cloud.entries[_snapshotKey]!.copyWith(
              hash: SyncSerialization.computeSyncHash(malformed),
            ),
          },
        ),
      );

      await expectLater(world.pull(), throwsA(isA<SyncQueueAggregateError>()));

      expect(world.snapshots.data[_sessionId], _payload(47)['items']);
      expect(world.snapshots.replacements, 0);
      expect(
        (await world.manifestProvider.readLocalManifest())
            .trackerSnapshotRestoreHashes,
        contains(_snapshotKey),
      );
    },
  );

  test(
    'pending snapshot repair waits for a cloud-only owning chat advance',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      final advanced = world.chats.data[_sessionId]!.copyWith(
        updatedAt: 2000,
        messages: [
          ...world.chats.data[_sessionId]!.messages,
          const ChatMessage(
            id: 'message-1',
            role: 'assistant',
            content: 'Next',
          ),
        ],
      );
      final original = world.chats.data[_sessionId]!;
      await world.chats.put(advanced);
      final raw = await world.manifestProvider.buildLocalManifest(
        applyAcceptedHashes: false,
      );
      await world.chats.put(original);
      world.chats.putDelay = const Duration(milliseconds: 30);
      final cloud = world.cloudManifest;
      world.setCloudManifest(
        cloud.copyWith(
          entries: {...cloud.entries, _chatKey: raw.entries[_chatKey]!},
        ),
      );
      world.cloud.files[cloudPath('chat', _sessionId)] = jsonEncode(
        advanced.toJson(),
      );
      world.restoreCloud.beforeDownload = (path) {
        if (path == _snapshotPath && world.chats.data[_sessionId] != advanced) {
          throw StateError('Snapshot restore saw the old owning chat');
        }
      };

      expect(await world.pull(), isEmpty);

      expect(world.chats.data[_sessionId], advanced);
      expect(world.snapshots.data[_sessionId], hasLength(108));
    },
  );

  test(
    'successful normalized import clears only its one-time restore marker',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      world.snapshots.normalizeImports = true;
      expect(await world.pull(), isEmpty);
      final restored = await world.manifestProvider.readLocalManifest();
      expect(restored.trackerSnapshotRestoreHashes, isEmpty);
      expect(restored.acceptedLocalHashes, contains(_snapshotKey));
      world.cloud.downloadCalls.clear();

      expect(await world.pull(), isEmpty);
      expect(world.cloud.downloadCalls, [_manifestPath]);
      expect(world.snapshots.replacements, 1);
    },
  );

  test(
    'applyPendingPull restores an accepted cut from cached cloud manifest',
    () async {
      final world = _SnapshotWorld();
      await world.seedAcceptedCut();
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'gz_sync_pending_pull_manifest',
        jsonEncode(world.cloudManifest.toJson(includeLocalState: false)),
      );
      world.cloud.downloadFailures.add(_manifestPath);

      await world.engine.applyPendingPull(onProgress: (_) {});

      expect(world.snapshots.data[_sessionId], hasLength(108));
      expect(world.cloud.downloadCalls, [_snapshotPath]);
      expect(
        (await world.manifestProvider.readLocalManifest())
            .trackerSnapshotRestoreHashes,
        isEmpty,
      );
      expect(prefs.containsKey('gz_sync_pending_pull_manifest'), isFalse);
    },
  );

  for (final pending in [false, true]) {
    test(
      '${pending ? 'pending' : 'normal'} pull defers snapshots for a locally edited owning chat',
      () async {
        final world = _SnapshotWorld();
        await world.seedAcceptedCut();
        final authored = world.chats.data[_sessionId]!.copyWith(
          updatedAt: 3000,
        );
        await world.chats.put(authored);

        if (pending) {
          await world.engine.applyPendingPull(onProgress: (_) {});
        } else {
          expect((await world.pull()).map((c) => c.key), [_chatKey]);
        }

        expect(world.chats.data[_sessionId], authored);
        expect(world.snapshots.data[_sessionId], hasLength(47));
        expect(world.cloud.downloadCalls, isNot(contains(_snapshotPath)));
        expect(
          (await world.manifestProvider.readLocalManifest())
              .trackerSnapshotRestoreHashes,
          contains(_snapshotKey),
        );
      },
    );
  }

  for (final deleted in [false, true]) {
    test(
      'snapshot repair does not import with ${deleted ? 'deleted' : 'absent'} cloud chat',
      () async {
        final world = _SnapshotWorld();
        await world.seedAcceptedCut();
        final entries = {...world.cloudManifest.entries};
        if (deleted) {
          entries[_chatKey] = entries[_chatKey]!.copyWith(
            deleted: true,
            hash: '',
            updatedAt: 2000,
          );
          // Keep a genuine local chat edit: cloud deletion is an ordinary conflict.
          await world.chats.put(
            world.chats.data[_sessionId]!.copyWith(updatedAt: 3000),
          );
        } else {
          entries.remove(_chatKey);
        }
        world.setCloudManifest(world.cloudManifest.copyWith(entries: entries));

        await world.pull();

        expect(world.snapshots.data[_sessionId], hasLength(47));
        expect(world.cloud.downloadCalls, isNot(contains(_snapshotPath)));
        expect(world.sessionDeletions.deletedSessionIds, isEmpty);
      },
    );
  }

  test('snapshot edit during restore download is not overwritten', () async {
    final world = _SnapshotWorld();
    await world.seedAcceptedCut();
    world.restoreCloud.beforeDownload = (path) {
      if (path == _snapshotPath) {
        world.snapshots.data[_sessionId]!.add({
          'id': 'edit-during-download',
          'sessionId': _sessionId,
        });
      }
    };

    await expectLater(world.pull(), throwsA(isA<SyncQueueAggregateError>()));

    expect(world.snapshots.data[_sessionId], hasLength(48));
    expect(world.snapshots.replacements, 0);
  });
}
