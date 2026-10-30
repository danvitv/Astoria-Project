import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/sync_session_consistency_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_queue.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';

import 'sync_lifecycle_test.dart' as fixtures;

const _session = 'real-snapshot-restore';
final _snapshotKey = entryKey('tracker_snapshot', _session);
final _snapshotPath = cloudPath('tracker_snapshot', _session);

TrackerSnapshot _snapshot(int index) => TrackerSnapshot(
  sessionId: _session,
  messageId: 'message-$index',
  committed: true,
  createdAt: 1000 + index,
  trackers: [
    Tracker(
      sessionId: _session,
      name: 'scene.location',
      value: 'location-$index',
      scope: 'ledger',
      provenance: 'message-$index',
      basisRevisionNumber: 1,
      basisRevisionHash: 'canon',
      updatedAt: 1000 + index,
    ),
  ],
);

class _Snapshots extends TrackerSnapshotSyncStore {
  _Snapshots(super.repo);
  Future<void> Function()? beforeReplace;

  @override
  Future<void> replaceBySessionId(
    String sessionId,
    List<TrackerSnapshot> snapshots, {
    List<TrackerSnapshot>? expectedSnapshots,
    ChatSession? expectedChat,
    void Function()? checkCurrent,
  }) async {
    await beforeReplace?.call();
    await super.replaceBySessionId(
      sessionId,
      snapshots,
      expectedSnapshots: expectedSnapshots,
      expectedChat: expectedChat,
      checkCurrent: checkCurrent,
    );
  }
}

class _Rig {
  _Rig() {
    manifest = fixtures.InMemoryManifestProvider(
      characterRepo: world.characters,
      chatRepo: chats,
      personaRepo: world.personas,
      presetRepo: world.presets,
      apiRepo: world.apiConfigs,
      memoryBookRepo: world.memoryBooks,
      lorebookRepo: world.lorebooks,
      themePresetRepo: world.uiThemes,
      trackerSnapshotStore: snapshots,
      studioConfigStore: world.studioConfigs,
    );
    engine = SyncEngine(
      world.cloud,
      manifest,
      world.characters,
      chats,
      world.personas,
      world.presets,
      world.apiConfigs,
      world.memoryBooks,
      world.lorebooks,
      world.embeddings,
      world.images,
      world.uiThemes,
      fixtures.FakeExtensionPresetStore(),
      fixtures.FakeExtensionsSettingsStore(),
      fixtures.FakeInfoBlockStore(),
      snapshots,
      fixtures.FakeTrackerValueStore(),
      world.studioConfigs,
      null,
      null,
      null,
      null,
      null,
      world.sessionDeletions,
      world.characterDeletions,
      (_) async {},
      null,
      null,
      SyncSessionConsistencyRepo(db).reconcile,
      0,
      Duration.zero,
    );
  }

  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final world = fixtures.SyncWorld();
  late final chats = ChatRepo(db);
  late final repo = TrackerSnapshotRepo(db);
  late final snapshots = _Snapshots(repo);
  late final fixtures.InMemoryManifestProvider manifest;
  late final SyncEngine engine;

  Future<void> seed() async {
    await chats.put(
      ChatSession(
        id: _session,
        characterId: 'card',
        sessionIndex: 0,
        updatedAt: 1000,
        messages: [
          for (var index = 0; index < 213; index++)
            ChatMessage(
              id: 'message-$index',
              role: 'assistant',
              content: 'answer-$index',
              agentSwipes: [AgentSwipe(content: 'answer-$index')],
              triggeredLorebooks: const [
                TriggeredEntry(id: 'lore', name: 'Lore'),
              ],
              triggeredMemories: const [
                TriggeredEntry(id: 'memory', name: 'Memory'),
              ],
            ),
        ],
      ),
    );
    for (var index = 0; index < 47; index++) {
      await repo.upsert(_snapshot(index));
    }
    final local = await manifest.buildLocalManifest(applyAcceptedHashes: false);
    final complete = {
      '__trackerSnapshots': true,
      'items': [
        for (var index = 107; index >= 0; index--) _snapshot(index).toJson(),
      ],
    };
    final baseline = local.copyWith(
      version: 16,
      lastSync: 1000,
      entries: {
        ...local.entries,
        _snapshotKey: local.entries[_snapshotKey]!.copyWith(
          hash: SyncSerialization.computeSyncHash(complete),
          updatedAt: 1000,
        ),
      },
      acceptedLocalHashes: {_snapshotKey: local.entries[_snapshotKey]!.hash},
    );
    await manifest.writeLocalManifest(baseline);
    world.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
      baseline.toJson(includeLocalState: false),
    );
    world.cloud.files[_snapshotPath] = jsonEncode(complete);
    world.cloud.files[cloudPath('chat', _session)] = jsonEncode(
      (await chats.getById(_session))!.toJson(),
    );
  }

  Future<void> pull() => engine.pullEntities(
    onProgress: (_) {},
    onConflict: (_) => fail('Unexpected conflict'),
  );
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test(
    'snapshot adapter emits decodable nested JSON with unchanged wire hash',
    () async {
      final rig = _Rig();
      addTearDown(rig.db.close);
      await rig.repo.upsert(_snapshot(0));
      final stored = (await rig.repo.getBySessionId(_session)).single;
      final row = (await rig.snapshots.getBySessionId(_session)).single;
      expect((row['trackers'] as List).single, isA<Map<String, dynamic>>());
      expect(TrackerSnapshot.fromJson(row), stored);
      expect(jsonEncode(row), jsonEncode(stored.toJson()));
      expect(
        SyncSerialization.computeSyncHash(row),
        SyncSerialization.computeSyncHash(stored.toJson()),
      );
    },
  );

  test(
    'real repositories restore 47 to 108 nonempty snapshots and do not repeat',
    () async {
      final rig = _Rig();
      addTearDown(rig.db.close);
      await rig.seed();
      final chatBefore = jsonEncode(
        (await rig.chats.getById(_session))!.toJson(),
      );
      final expected = [
        for (var index = 107; index >= 0; index--) _snapshot(index),
      ];
      await rig.pull();
      expect(await rig.repo.getBySessionId(_session), expected);
      expect(
        jsonEncode((await rig.chats.getById(_session))!.toJson()),
        chatBefore,
      );
      expect(
        (await rig.manifest.readLocalManifest()).trackerSnapshotRestoreHashes,
        isEmpty,
      );
      rig.world.cloud.downloadCalls.clear();
      await rig.pull();
      expect(rig.world.cloud.downloadCalls, [
        cloudPath('manifest', 'manifest'),
      ]);
      expect(await rig.repo.getBySessionId(_session), expected);
    },
  );

  test(
    'real restore still rejects a local snapshot edit after service validation',
    () async {
      final rig = _Rig();
      addTearDown(rig.db.close);
      await rig.seed();
      final authored = _snapshot(46).copyWith(
        trackers: [_snapshot(46).trackers.single.copyWith(value: 'authored')],
      );
      rig.snapshots.beforeReplace = () => rig.repo.upsert(authored);
      await expectLater(
        rig.pull(),
        throwsA(
          isA<SyncQueueAggregateError>().having(
            (error) => error.toString(),
            'message',
            contains('Snapshots changed during tracker snapshot restore'),
          ),
        ),
      );
      final current = await rig.repo.getBySessionId(_session);
      expect(current, hasLength(47));
      expect(current.first, authored);
      expect(
        (await rig.manifest.readLocalManifest()).trackerSnapshotRestoreHashes,
        contains(_snapshotKey),
      );
    },
  );
}
