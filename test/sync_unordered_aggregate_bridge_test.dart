import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/features/cloud_sync/adapters/ext_blocks_sync_stores.dart';
import 'package:glaze_flutter/features/cloud_sync/cloud_adapter.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_conflict.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_manifest.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_unordered_aggregate.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_unordered_aggregate_bridge.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart' as fixtures;

const _session = 'synthetic-session';

class _Cloud extends fixtures.FakeCloudAdapter {
  final uploads = <String>[];
  Future<void> Function(String)? afterDownload;
  Future<void> Function(String)? afterList;

  @override
  Future<String> download(String path) async {
    final raw = await super.download(path);
    await afterDownload?.call(path);
    return raw;
  }

  @override
  Future<List<CloudFileInfo>> listFolder(String path) async {
    final files = await super.listFolder(path);
    await afterList?.call(path);
    return files;
  }

  @override
  Future<void> upload(String path, String data) async {
    uploads.add(path);
    await super.upload(path, data);
  }
}

class _Graph extends MemoryGraphSyncStore {
  _Graph(super.db);
  int writes = 0;
  @override
  Future<void> applyBySessionId(String id, Map<String, dynamic> data) async {
    writes++;
    await super.applyBySessionId(id, data);
  }

  @override
  Future<void> deleteBySessionId(String id) async {
    writes++;
    await super.deleteBySessionId(id);
  }
}

class _Knowledge extends CharacterKnowledgeSyncStore {
  _Knowledge(super.db);
  int writes = 0;
  @override
  Future<void> applyBySessionId(String id, Map<String, dynamic> data) async {
    writes++;
    await super.applyBySessionId(id, data);
  }

  @override
  Future<void> deleteBySessionId(String id) async {
    writes++;
    await super.deleteBySessionId(id);
  }
}

class _Rig {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final world = fixtures.SyncWorld();
  final _Cloud cloud;
  late final graph = _Graph(db);
  late final knowledge = _Knowledge(db);
  late final builder = SyncManifestBuilder(
    characterRepo: world.characters,
    chatRepo: world.chats,
    personaRepo: world.personas,
    presetRepo: world.presets,
    apiRepo: world.apiConfigs,
    memoryBookRepo: world.memoryBooks,
    lorebookRepo: world.lorebooks,
    themePresetRepo: world.uiThemes,
    extensionPresetRepo: fixtures.FakeExtensionPresetStore(),
    extensionsSettingsStore: fixtures.FakeExtensionsSettingsStore(),
    infoBlockStore: fixtures.FakeInfoBlockStore(),
    trackerSnapshotStore: fixtures.FakeTrackerSnapshotStore(),
    trackerValueStore: fixtures.FakeTrackerValueStore(),
    studioConfigStore: world.studioConfigs,
    memoryGraphStore: graph,
    characterKnowledgeStore: knowledge,
  );
  late final engine = SyncEngine(
    cloud,
    builder,
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
    fixtures.FakeExtensionPresetStore(),
    fixtures.FakeExtensionsSettingsStore(),
    fixtures.FakeInfoBlockStore(),
    fixtures.FakeTrackerSnapshotStore(),
    fixtures.FakeTrackerValueStore(),
    world.studioConfigs,
    null,
    null,
    null,
    graph,
    knowledge,
    world.sessionDeletions,
    world.characterDeletions,
    (_) async {},
    null,
    null,
    null,
    0,
  );
  _Rig([_Cloud? adapter]) : cloud = adapter ?? _Cloud();

  Future<void> seed({bool reverse = false}) async {
    final ids = List.generate(16, (i) => i);
    for (final i in reverse ? ids.reversed : ids) {
      await db
          .into(db.characterKnowledgeFactRows)
          .insert(
            CharacterKnowledgeFactRowsCompanion.insert(
              id: 'fact-$i',
              chatSessionId: _session,
              knowerKey: 'a',
              subjectKey: 'b',
              factClass: 'knowledge',
              predicate: 'knows',
              object: 'synthetic-$i',
              epistemicState: 'confirmed',
              lifecycle: Value(i.isEven ? 'active' : 'retracted'),
              basisRevision: const Value(2),
              basisRevisionHash: const Value('r'),
            ),
          );
      if (i < 3) {
        await db
            .into(db.memoryCatalogRows)
            .insert(
              MemoryCatalogRowsCompanion.insert(
                id: 'catalog-$i',
                chatSessionId: _session,
                memoryEntryId: 'entry-$i',
                entryRevision: const Value('revision'),
                sourceHash: const Value('source'),
              ),
            );
        await db
            .into(db.memoryEntityRows)
            .insert(
              MemoryEntityRowsCompanion.insert(
                id: 'entity-$i',
                chatSessionId: _session,
                memoryEntryId: 'entry-$i',
                name: 'synthetic-$i',
              ),
            );
        await db
            .into(db.memorySalienceRows)
            .insert(
              MemorySalienceRowsCompanion.insert(
                id: 'salience-$i',
                chatSessionId: _session,
                memoryEntryId: 'entry-$i',
              ),
            );
        await db
            .into(db.memoryConsolidationRows)
            .insert(
              MemoryConsolidationRowsCompanion.insert(
                id: 'consolidation-$i',
                chatSessionId: _session,
              ),
            );
      }
    }
    await db
        .into(db.memoryCadenceRows)
        .insert(MemoryCadenceRowsCompanion.insert(chatSessionId: _session));
    await db
        .into(db.characterSessionBaselineRows)
        .insert(
          CharacterSessionBaselineRowsCompanion.insert(
            chatSessionId: _session,
            characterId: 'synthetic-card',
            baselineCardJson: '{}',
            baselineHash: 'baseline',
          ),
        );
  }

  Future<Map<String, dynamic>> payload(String type) async =>
      (type == 'memory_graph'
      ? await graph.getBySessionId(_session)
      : await knowledge.getBySessionId(_session))!;

  Future<SyncManifest> publishLegacy({bool cold = false}) async {
    final local = await builder.buildLocalManifest(applyAcceptedHashes: false);
    final entries = <String, SyncManifestEntry>{};
    for (final type in ['memory_graph', 'character_knowledge']) {
      final payload = _permuted(await this.payload(type));
      final entry = local.entries[entryKey(type, _session)]!.copyWith(
        hash: SyncSerialization.computeSyncHash(payload),
        updatedAt: 10,
      );
      entries[entry.key] = entry;
      cloud.files[entry.path] = jsonEncode(payload);
    }
    final remote = local.copyWith(version: 16, entries: entries, lastSync: 10);
    cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
      remote.toJson(includeLocalState: false),
    );
    await builder.writeLocalManifest(
      local.copyWith(
        lastSync: cold ? 0 : 10,
        entries: {
          for (final e in local.entries.values)
            e.key: e.copyWith(updatedAt: 20),
        },
      ),
    );
    return remote;
  }
}

Map<String, dynamic> _permuted(Map<String, dynamic> input) {
  Object? visit(Object? value, {bool rows = false}) {
    if (value is Map) {
      return {
        for (final key in value.keys.toList().reversed)
          key as String: visit(
            value[key],
            rows: const {
              'facts',
              'catalog',
              'entities',
              'salience',
              'cadence',
              'consolidation',
            }.contains(key),
          ),
      };
    }
    if (value is List) {
      return [for (final item in rows ? value.reversed : value) visit(item)];
    }
    return value;
  }

  return visit(input) as Map<String, dynamic>;
}

class _Unsupported {
  int calls = 0;
  Object toJson() {
    calls++;
    throw StateError('must not execute');
  }
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));
  for (final type in ['memory_graph', 'character_knowledge']) {
    test(
      '$type failed conflict resolution preserves rows and manifest',
      () async {
        final rig = _Rig();
        addTearDown(rig.db.close);
        await rig.seed();
        final before = await rig.payload(type);
        final local = await rig.builder.buildLocalManifest();
        await rig.builder.writeLocalManifest(local);
        final prefs = await SharedPreferences.getInstance();
        final manifestBefore = prefs.getString('gz_sync_manifest_v2');
        final malformed =
            jsonDecode(jsonEncode(before)) as Map<String, dynamic>;
        if (type == 'memory_graph') {
          // Earlier tables are already replaced when this last table fails.
          (malformed['catalog'] as List).first['memoryEntryId'] = 'replacement';
          (malformed['consolidation'] as List).last['createdAt'] = 'invalid';
        } else {
          (malformed['facts'] as List).first['object'] = 'replacement';
          (malformed['baseline'] as Map)['createdAt'] = 'invalid';
        }
        final key = entryKey(type, _session);
        final localEntry = local.entries[key]!;
        final cloudEntry = localEntry.copyWith(
          hash: SyncSerialization.computeSyncHash(malformed),
          updatedAt: localEntry.updatedAt + 1,
        );
        rig.cloud.files[cloudEntry.path] = jsonEncode(malformed);

        await expectLater(
          rig.engine.resolveConflict(
            SyncConflict(
              key: key,
              type: type,
              id: _session,
              localEntry: localEntry,
              cloudEntry: cloudEntry,
              name: 'Synthetic aggregate',
            ),
            'cloud',
          ),
          throwsA(anything),
        );
        expect(await rig.payload(type), before);
        expect(prefs.getString('gz_sync_manifest_v2'), manifestBefore);
      },
    );
  }
  test(
    'two devices keep legacy cloud through three alternating cycles',
    () async {
      final cloud = _Cloud();
      final a = _Rig(cloud);
      final b = _Rig(cloud);
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      await a.seed();
      final remote = await a.publishLegacy();
      final prefs = await SharedPreferences.getInstance();
      var aState = prefs.getString('gz_sync_manifest_v2')!;
      await prefs.remove('gz_sync_manifest_v2');
      await b.seed(reverse: true);
      await b.builder.writeLocalManifest(
        (await b.builder.buildLocalManifest()).copyWith(lastSync: 0),
      );
      var bState = prefs.getString('gz_sync_manifest_v2')!;
      for (var i = 0; i < 3; i++) {
        for (final rig in [a, b]) {
          await prefs.setString(
            'gz_sync_manifest_v2',
            rig == a ? aState : bState,
          );
          await rig.engine.pushEntities(onProgress: (_) {});
          await rig.engine.pullEntities(
            onProgress: (_) {},
            onConflict: (_) => fail('conflict'),
          );
          if (rig == a) {
            aState = prefs.getString('gz_sync_manifest_v2')!;
          } else {
            bState = prefs.getString('gz_sync_manifest_v2')!;
          }
        }
      }
      for (final entry in remote.entries.values) {
        expect(cloud.uploads.contains(entry.path), isFalse);
        expect(cloud.downloadCalls.where((p) => p == entry.path).length, 2);
      }
      expect(
        a.graph.writes +
            a.knowledge.writes +
            b.graph.writes +
            b.knowledge.writes,
        0,
      );
    },
  );

  test('stale raw manifest cannot choose an authoritative marker', () async {
    final rig = _Rig();
    addTearDown(rig.db.close);
    await rig.seed();
    final remote = await rig.publishLegacy();
    final local = await rig.builder.buildLocalManifest(
      applyAcceptedHashes: false,
    );
    await rig.db
        .update(rig.db.memoryCatalogRows)
        .write(const MemoryCatalogRowsCompanion(sourceHash: Value('edit')));
    final bridge = SyncUnorderedAggregateBridge(
      download: rig.cloud.download,
      readLocal: (type, id) async => rig.payload(type),
      isDeleted: (_, _) async => false,
    );
    await expectLater(bridge.bridge(local, remote), throwsStateError);
    expect(rig.cloud.downloadCalls, isEmpty);
  });

  test(
    'valid cloud payload hash mismatch blocks engine before uploads',
    () async {
      final rig = _Rig();
      addTearDown(rig.db.close);
      await rig.seed();
      await rig.publishLegacy();
      final path = cloudPath('character_knowledge', _session);
      final payload =
          jsonDecode(rig.cloud.files[path]!) as Map<String, dynamic>;
      (payload['facts'] as List).removeLast();
      rig.cloud.files[path] = jsonEncode(payload);
      await expectLater(
        rig.engine.pushEntities(onProgress: (_) {}),
        throwsStateError,
      );
      expect(rig.cloud.uploads, isEmpty);
      expect(
        (await rig.builder.readLocalManifest()).acceptedLocalHashes,
        isEmpty,
      );
    },
  );

  test('unsupported local objects never execute JSON hooks', () async {
    final rig = _Rig();
    addTearDown(rig.db.close);
    await rig.seed();
    final remote = await rig.publishLegacy();
    final local = await rig.builder.buildLocalManifest(
      applyAcceptedHashes: false,
    );
    final object = _Unsupported();
    final bridge = SyncUnorderedAggregateBridge(
      download: rig.cloud.download,
      readLocal: (type, id) async => {
        ...await rig.payload(type),
        'unsupported': object,
      },
      isDeleted: (_, _) async => false,
    );
    final result = await bridge.bridge(local, remote);
    expect(result.acceptedLocalHashes, isEmpty);
    expect(object.calls, 0);
    expect(rig.cloud.downloadCalls, isEmpty);
  });

  test(
    'push preserves cloud-only rows, tombstones and explicit local deletion',
    () async {
      final rig = _Rig();
      addTearDown(rig.db.close);
      await rig.seed();
      final remote = await rig.publishLegacy();
      final cloudOnly = SyncManifestEntry(
        type: 'memory_graph',
        id: 'cloud-only',
        path: cloudPath('memory_graph', 'cloud-only'),
        updatedAt: 5,
        hash: 'old',
      );
      final tombstone = cloudOnly.copyWith(id: 'tombstone', deleted: true);
      rig.cloud.files[cloudPath('manifest', 'manifest')] = jsonEncode(
        remote
            .copyWith(
              entries: {
                ...remote.entries,
                cloudOnly.key: cloudOnly,
                tombstone.key: tombstone,
              },
            )
            .toJson(includeLocalState: false),
      );
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        'gz_sync_deleted_entries',
        jsonEncode([
          {'type': 'character_knowledge', 'id': _session},
        ]),
      );
      await rig.knowledge.deleteBySessionId(_session);
      await rig.engine.pushEntities(onProgress: (_) {});
      final published = SyncManifest.fromJson(
        jsonDecode(rig.cloud.files[cloudPath('manifest', 'manifest')]!)
            as Map<String, dynamic>,
      );
      expect(published.entries[cloudOnly.key]!.hash == cloudOnly.hash, isTrue);
      expect(published.entries[tombstone.key]!.deleted, isTrue);
      expect(
        published.entries.containsKey(
          entryKey('character_knowledge', _session),
        ),
        isFalse,
      );
      expect(
        (await rig.builder.readLocalManifest()).acceptedLocalHashes.containsKey(
          entryKey('character_knowledge', _session),
        ),
        isFalse,
      );
    },
  );
  for (final first in ['pull', 'push', 'pending', 'cold']) {
    test(
      'real Drift permutations align $first and three repeat cycles',
      () async {
        final rig = _Rig();
        addTearDown(rig.db.close);
        await rig.seed();
        final remote = await rig.publishLegacy(cold: first == 'cold');
        final originals = Map<String, String>.from(rig.cloud.files);
        final hashes = {
          for (final type in ['memory_graph', 'character_knowledge'])
            entryKey(type, _session): SyncSerialization.computeSyncHash(
              await rig.payload(type),
            ),
        };
        final conflicts = <SyncConflict>[];
        if (first == 'push') {
          await rig.engine.pushEntities(onProgress: (_) {});
        } else if (first == 'pending') {
          await rig.engine.applyPendingPull(onProgress: (_) {});
        } else {
          await rig.engine.pullEntities(
            onProgress: (_) {},
            onConflict: conflicts.add,
          );
        }
        for (var i = 0; i < 3; i++) {
          await rig.engine.pullEntities(
            onProgress: (_) {},
            onConflict: conflicts.add,
          );
          await rig.engine.pushEntities(onProgress: (_) {});
        }
        expect(conflicts, isEmpty);
        expect(rig.graph.writes + rig.knowledge.writes, 0);
        final aligned = await rig.builder.readLocalManifest();
        for (final entry in remote.entries.values) {
          expect(aligned.entries[entry.key]!.hash == entry.hash, isTrue);
          expect(aligned.entries[entry.key]!.updatedAt, 10);
          expect(
            aligned.acceptedLocalHashes[entry.key] == hashes[entry.key],
            isTrue,
          );
          expect(rig.cloud.files[entry.path] == originals[entry.path], isTrue);
          expect(rig.cloud.uploads.contains(entry.path), isFalse);
          expect(
            rig.cloud.downloadCalls.where((p) => p == entry.path).length,
            1,
          );
        }
        expect(
          jsonDecode(
            rig.cloud.files[cloudPath('manifest', 'manifest')]!,
          ).containsKey('acceptedLocalHashes'),
          isFalse,
        );
      },
    );
  }

  test(
    'two real backing stores retain different insertion orders and stable IDs',
    () async {
      final a = _Rig();
      final b = _Rig();
      addTearDown(a.db.close);
      addTearDown(b.db.close);
      await a.seed();
      await b.seed(reverse: true);
      for (final type in ['memory_graph', 'character_knowledge']) {
        final left = await a.payload(type);
        final right = await b.payload(type);
        expect(
          SyncSerialization.computeSyncHash(left) !=
              SyncSerialization.computeSyncHash(right),
          isTrue,
        );
        expect(
          SyncUnorderedAggregate.equivalent(
            type: type,
            sessionId: _session,
            local: left,
            cloud: right,
          ),
          isTrue,
        );
      }
    },
  );

  for (final field in [
    'predicate',
    'lifecycle',
    'basisRevision',
    'basisRevisionHash',
    'baselineHash',
    'sourceHash',
    'entryRevision',
  ]) {
    test(
      'real $field edit conflicts then publishes without unrelated replacement',
      () async {
        final rig = _Rig();
        addTearDown(rig.db.close);
        await rig.seed();
        final remote = await rig.publishLegacy();
        await rig.engine.pullEntities(
          onProgress: (_) {},
          onConflict: (_) => fail('conflict'),
        );
        final type = ['sourceHash', 'entryRevision'].contains(field)
            ? 'memory_graph'
            : 'character_knowledge';
        if (type == 'memory_graph') {
          await (rig.db.update(
            rig.db.memoryCatalogRows,
          )..where((r) => r.id.equals('catalog-0'))).write(
            MemoryCatalogRowsCompanion(
              sourceHash: Value(field == 'sourceHash' ? 'edit' : 'source'),
              entryRevision: Value(
                field == 'entryRevision' ? 'edit' : 'revision',
              ),
            ),
          );
        } else if (field == 'baselineHash') {
          await rig.db
              .update(rig.db.characterSessionBaselineRows)
              .write(
                const CharacterSessionBaselineRowsCompanion(
                  baselineHash: Value('edit'),
                ),
              );
        } else {
          await (rig.db.update(
            rig.db.characterKnowledgeFactRows,
          )..where((r) => r.id.equals('fact-0'))).write(
            CharacterKnowledgeFactRowsCompanion(
              predicate: Value(field == 'predicate' ? 'edit' : 'knows'),
              lifecycle: Value(field == 'lifecycle' ? 'retained' : 'active'),
              basisRevision: Value(field == 'basisRevision' ? 3 : 2),
              basisRevisionHash: Value(
                field == 'basisRevisionHash' ? 'edit' : 'r',
              ),
            ),
          );
        }
        final conflicts = <SyncConflict>[];
        await rig.engine.pullEntities(
          onProgress: (_) {},
          onConflict: conflicts.add,
        );
        expect(conflicts.map((c) => c.type), contains(type));
        await rig.engine.pushEntities(onProgress: (_) {});
        final entry = remote.entries[entryKey(type, _session)]!;
        expect(
          SyncSerialization.computeSyncHash(
                jsonDecode(rig.cloud.files[entry.path]!),
              ) ==
              SyncSerialization.computeSyncHash(await rig.payload(type)),
          isTrue,
        );
        expect(rig.graph.writes + rig.knowledge.writes, 0);
      },
    );
  }

  for (final change in ['edit', 'reorder', 'delete', 'listing']) {
    test('network $change aborts before acceptance or publication', () async {
      final rig = _Rig();
      addTearDown(rig.db.close);
      await rig.seed();
      await rig.publishLegacy();
      final prefs = await SharedPreferences.getInstance();
      final before = prefs.getString('gz_sync_manifest_v2');
      Future<void> mutate(String path) async {
        rig.cloud.afterDownload = null;
        rig.cloud.afterList = null;
        if (change == 'delete') {
          await rig.knowledge.deleteBySessionId(_session);
        } else if (change == 'reorder') {
          final payload = _permuted(await rig.payload('character_knowledge'));
          await rig.knowledge.applyBySessionId(_session, payload);
        } else {
          await rig.db
              .update(rig.db.characterKnowledgeFactRows)
              .write(
                const CharacterKnowledgeFactRowsCompanion(
                  predicate: Value('edit'),
                ),
              );
        }
      }

      if (change == 'listing') {
        rig.cloud.afterList = mutate;
      } else {
        rig.cloud.afterDownload = (path) async {
          if (path == cloudPath('character_knowledge', _session)) {
            await mutate(path);
          }
        };
      }
      await expectLater(
        rig.engine.pushEntities(onProgress: (_) {}),
        throwsStateError,
      );
      expect(prefs.getString('gz_sync_manifest_v2') == before, isTrue);
      expect(rig.cloud.uploads, isEmpty);
    });
  }

  for (final invalid in [
    'duplicate',
    'owner',
    'marker',
    'shape',
    'added',
    'removed',
    'nested',
    'unknown',
    'oversized',
    'malformed',
    'hash',
  ]) {
    test('$invalid cloud obtains no representation acceptance', () async {
      final rig = _Rig();
      addTearDown(rig.db.close);
      await rig.seed();
      final remote = await rig.publishLegacy();
      final entry = remote.entries[entryKey('character_knowledge', _session)]!;
      final payload = _permuted(await rig.payload('character_knowledge'));
      final facts = payload['facts'] as List;
      switch (invalid) {
        case 'duplicate':
          facts.add(facts.first);
        case 'owner':
          (facts.first as Map)['chatSessionId'] = 'other';
        case 'marker':
          payload['__characterKnowledge'] = false;
        case 'shape':
          payload['facts'] = <String, dynamic>{};
        case 'added':
          facts.add({...facts.first as Map, 'id': 'added'});
        case 'removed':
          facts.removeLast();
        case 'nested':
          payload['nested'] = [2, 1];
        case 'unknown':
          payload['unknown'] = 'significant';
        case 'oversized':
          payload['unknown'] = 'x' * (SyncUnorderedAggregate.maxBytes + 1);
        case 'malformed':
        case 'hash':
      }
      final changed = entry.copyWith(
        hash: invalid == 'hash'
            ? entry.hash
            : SyncSerialization.computeSyncHash(payload),
      );
      rig.cloud.files[entry.path] = invalid == 'malformed'
          ? '{'
          : jsonEncode(payload);
      if (invalid == 'hash') (payload['facts'] as List).removeLast();
      if (invalid == 'hash') rig.cloud.files[entry.path] = jsonEncode(payload);
      final cloud = remote.copyWith(
        entries: {...remote.entries, entry.key: changed},
      );
      final local = await rig.builder.buildLocalManifest(
        applyAcceptedHashes: false,
      );
      final bridge = SyncUnorderedAggregateBridge(
        download: rig.cloud.download,
        readLocal: (type, id) async => rig.payload(type),
        isDeleted: (_, _) async => false,
      );
      if (invalid == 'hash') {
        await expectLater(bridge.bridge(local, cloud), throwsStateError);
      } else {
        final result = await bridge.bridge(local, cloud);
        expect(result.acceptedLocalHashes.containsKey(entry.key), isFalse);
      }
    });
  }
}
