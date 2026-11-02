import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_payload_transport.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart'
    show SyncProgress;
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart'
    show FakeCloudAdapter, FakeReconciliationStateStore, SyncWorld, makeChat;

const _chunkBytes = 768 * 1024;
const _compressionThreshold = 512 * 1024;
const _maxDecodedBytes = 128 * 1024 * 1024;
const _sessionId = 'transport-session';

class _RecordingCloudAdapter extends FakeCloudAdapter {
  final uploadCalls = <String>[];
  int partUploadCount = 0;
  int? failPartUploadNumber;
  void Function()? afterEnsureFolder;
  void Function(String path)? afterUpload;

  @override
  Future<void> ensureFolder(String path) async {
    await super.ensureFolder(path);
    afterEnsureFolder?.call();
  }

  @override
  Future<void> upload(String path, String data) async {
    uploadCalls.add(path);
    if (path.contains('.parts/')) {
      partUploadCount++;
      if (partUploadCount == failPartUploadNumber) {
        throw StateError('Interrupted part upload');
      }
    }
    await super.upload(path, data);
    afterUpload?.call(path);
  }
}

String _noise({int seed = 42}) {
  // Two MiB of seeded bytes produce several compressed pieces, without a
  // huge random fixture. Most large-payload bytes below are cheap repetition.
  final random = Random(seed);
  final bytes = Uint8List(2 * 1024 * 1024);
  for (var i = 0; i < bytes.length; i++) {
    bytes[i] = random.nextInt(256);
  }
  return base64Encode(bytes);
}

Map<String, dynamic> _state(String text) => {
  '__reconciliationState': true,
  'schemaVersion': 2,
  'sessionId': _sessionId,
  'runs': <dynamic>[],
  'collectors': [
    {'id': 'collector', 'response': text},
  ],
};

ChatSession _chat(String text) => ChatSession(
  id: _sessionId,
  characterId: 'transport-character',
  sessionIndex: 7,
  updatedAt: 1000,
  messages: [
    const ChatMessage(
      id: 'earlier-hidden-message',
      role: 'user',
      content: 'Earlier history must survive Ж 🐈',
      isHidden: true,
    ),
    ChatMessage(
      id: 'assistant',
      role: 'assistant',
      content: text,
      reasoning: 'Private reasoning Ж 🐈',
      swipes: const ['Previous variation', 'Alternate variation'],
      swipeId: 1,
      swipesMeta: const [
        {'reasoning': 'Previous reasoning', 'tokens': 19},
        {'reasoning': 'Alternate reasoning', 'tokens': 23},
      ],
      agentSwipes: const [
        AgentSwipe(
          content: 'Cleaned variation',
          kind: 'cleaned',
          reasoning: 'Cleaner reasoning',
          parentSwipeId: 1,
        ),
      ],
      studioOutputs: const [
        {'tracker': 'state', 'response': 'Unmodified output'},
      ],
      imagePath: 'images/original.png',
      extraImagePaths: const ['images/second.png'],
      imageHidden: true,
      memoryCoverage: const {
        'book': <String>['fact'],
      },
    ),
  ],
  sessionVars: const {'historyAnchor': 'earlier-hidden-message'},
  authorsNote: const AuthorsNote(content: 'Author Ж'),
  summary: const ChatSummary(content: 'Summary 🐈'),
  draft: 'Unsent draft',
  lastScrollAnchor: const {'messageId': 'assistant', 'offset': 12},
);

SyncManifestEntry _entry(
  Map<String, dynamic> data, {
  String type = 'reconciliation_state',
}) => SyncManifestEntry(
  type: type,
  id: _sessionId,
  path: cloudPath(type, _sessionId),
  updatedAt: 1000,
  hash: SyncSerialization.computeSyncHash(data),
);

Map<String, dynamic> _root(FakeCloudAdapter cloud, SyncManifestEntry entry) =>
    jsonDecode(cloud.files[entry.path]!) as Map<String, dynamic>;

List<Map<String, dynamic>> _chunks(Map<String, dynamic> root) =>
    (root['chunks'] as List).cast<Map<String, dynamic>>();

String _partPath(SyncManifestEntry entry, Map<String, dynamic> chunk) =>
    '${entry.path}.parts/${chunk['hash']}.b64';

Map<String, dynamic> _payloadWithUtf8Size(int bytes) {
  final overhead = utf8.encode(jsonEncode({'text': ''})).length;
  final textBytes = bytes - overhead;
  return {'text': '${'Ж' * (textBytes ~/ 2)}${'x' * (textBytes % 2)}'};
}

void main() {
  late final noise = _noise();
  late final mediumPayload = _state(noise);
  late final mediumEntry = _entry(mediumPayload);
  late final mediumChatPayload = _chat(noise).toJson();
  late final mediumChatEntry = _entry(mediumChatPayload, type: 'chat');
  late Map<String, String> chunkedFiles;
  late Map<String, String> chatFiles;

  FakeCloudAdapter chunkedCloud() =>
      FakeCloudAdapter()..files.addAll(chunkedFiles);

  FakeCloudAdapter chatCloud() => FakeCloudAdapter()..files.addAll(chatFiles);

  setUpAll(() async {
    final cloud = FakeCloudAdapter();
    await SyncPayloadTransport.upload(cloud, mediumEntry, mediumPayload);
    chunkedFiles = Map.of(cloud.files);
    expect(_chunks(_root(cloud, mediumEntry)).length, greaterThan(1));
    final chats = FakeCloudAdapter();
    await SyncPayloadTransport.upload(
      chats,
      mediumChatEntry,
      mediumChatPayload,
    );
    chatFiles = Map.of(chats.files);
    expect(_chunks(_root(chats, mediumChatEntry)).length, greaterThan(1));
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  test('small reconciliation payload retains exact legacy JSON', () async {
    final cloud = _RecordingCloudAdapter();
    final data = _state('Legacy Ж 🐈 text');
    final entry = _entry(data);

    await SyncPayloadTransport.upload(cloud, entry, data);

    expect(cloud.files, {entry.path: jsonEncode(data)});
    expect(cloud.uploadCalls, [entry.path]);
    expect(await SyncPayloadTransport.download(cloud, entry), data);
    expect(cloud.downloadCalls, [entry.path]);
  });

  group('chat payload transport', () {
    test('small real chat stays plain with no extra cloud calls', () async {
      final cloud = _RecordingCloudAdapter();
      final data = _chat('Small Ж 🐈 reply').toJson();
      final entry = _entry(data, type: 'chat');
      final json = jsonEncode(data);

      await SyncPayloadTransport.upload(cloud, entry, data);

      expect(cloud.files, {entry.path: json});
      expect(cloud.uploadCalls, [entry.path]);
      expect(cloud.ensuredFolders, isEmpty);
      expect(cloud.downloadCalls, isEmpty);
      expect(cloud.listFolderCalls, isEmpty);
      final downloaded = await SyncPayloadTransport.download(cloud, entry);
      expect(jsonEncode(downloaded), json);
      expect(jsonEncode(ChatSession.fromJson(downloaded).toJson()), json);
      expect(cloud.downloadCalls, [entry.path]);
    });

    test('legacy large plain chat remains readable without parts', () async {
      final cloud = FakeCloudAdapter();
      final data = _chat('Legacy Ж 🐈 reply. ' * 50000).toJson();
      final entry = _entry(data, type: 'chat');
      final json = jsonEncode(data);
      expect(utf8.encode(json).length, greaterThan(_compressionThreshold));
      expect(utf8.encode(json).length, lessThan(maxSyncPayloadBytes));
      cloud.files[entry.path] = json;

      final downloaded = await SyncPayloadTransport.download(cloud, entry);

      expect(jsonEncode(ChatSession.fromJson(downloaded).toJson()), json);
      expect(cloud.downloadCalls, [entry.path]);
      cloud.downloadCalls.clear();
      expect(
        jsonEncode(
          await SyncPayloadTransport.download(cloud, entry, rawPayload: json),
        ),
        json,
      );
      expect(cloud.downloadCalls, isEmpty);
    });

    test(
      'real chat over 30 MiB roundtrips all history reasoning and swipes',
      () async {
        final cloud = _RecordingCloudAdapter()
          ..requireEnsuredParentForUpload = true;
        await cloud.ensureFolder('$cloudBase/chats');
        final original = _chat('Reply Ж 🐈');
        final content = 'c' * (1024 * 1024);
        final reasoning = 'r' * (1024 * 1024);
        final alternative = 'a' * (1024 * 1024);
        final session = original.copyWith(
          messages: [
            original.messages.first,
            for (var i = 0; i < 5; i++)
              original.messages.last.copyWith(
                id: 'assistant-$i',
                content: content,
                reasoning: reasoning,
                swipes: [content, alternative],
                swipesMeta: [
                  {'reasoning': reasoning, 'tokens': 111, 'time': 'original'},
                  {'reasoning': 'Alternate reasoning Ж', 'tokens': 222},
                ],
                agentSwipes: [
                  AgentSwipe(
                    content: content,
                    kind: 'cleaned',
                    reasoning: reasoning,
                    parentSwipeId: 1,
                  ),
                ],
                studioOutputs: [
                  {'tracker': 'state', 'response': i == 0 ? noise : 'State Ж'},
                ],
              ),
          ],
        );
        final data = session.toJson();
        final json = jsonEncode(data);
        final jsonBytes = utf8.encode(json);
        final entry = _entry(data, type: 'chat');
        expect(jsonBytes.length, greaterThan(maxSyncPayloadBytes));

        await SyncPayloadTransport.upload(cloud, entry, data);

        final root = _root(cloud, entry);
        final chunks = _chunks(root);
        expect(root['type'], 'chat');
        expect(root['id'], session.id);
        expect(root['jsonBytes'], jsonBytes.length);
        expect(root['payloadHash'], sha256.convert(jsonBytes).toString());
        expect(chunks.length, inInclusiveRange(2, 256));
        expect(cloud.uploadCalls, [
          for (final chunk in chunks) _partPath(entry, chunk),
          entry.path,
        ]);
        expect(cloud.downloadCalls, isEmpty);
        for (final file in cloud.files.values) {
          expect(
            utf8.encode(file).length,
            lessThanOrEqualTo(maxSyncPayloadBytes),
          );
        }
        for (final chunk in chunks) {
          expect(chunk['bytes'], inInclusiveRange(1, _chunkBytes));
        }
        final downloaded = await SyncPayloadTransport.download(cloud, entry);
        expect(jsonEncode(downloaded), json);
        final restored = ChatSession.fromJson(downloaded);
        expect(jsonEncode(restored.toJson()), json);
        expect(restored.messages, hasLength(session.messages.length));
        expect(restored.messages.first.isHidden, isTrue);
        expect(restored.messages.last.reasoning, reasoning);
        expect(restored.messages.last.swipes, [content, alternative]);
        expect(restored.messages.last.swipesMeta.first['reasoning'], reasoning);
        expect(restored.messages.last.agentSwipes.single.reasoning, reasoning);
        expect(restored.sessionVars, session.sessionVars);
      },
    );

    test('chat aggregate over 128 MiB rejects before cloud requests', () async {
      final cloud = _RecordingCloudAdapter();
      // UTF8, not Dart character count, governs the logical aggregate budget.
      final data = {'text': '界' * (_maxDecodedBytes ~/ 3)};

      await expectLater(
        SyncPayloadTransport.upload(cloud, mediumChatEntry, data),
        throwsA(anything),
      );

      expect(cloud.uploadCalls, isEmpty);
      expect(cloud.downloadCalls, isEmpty);
      expect(cloud.ensuredFolders, isEmpty);
    });

    test('legacy plain chat over 30 MiB still rejects on read', () async {
      final cloud = FakeCloudAdapter();
      final json = jsonEncode({'text': '界' * (maxSyncPayloadBytes ~/ 3)});
      expect(json.length, lessThan(maxSyncPayloadBytes));
      cloud.files[mediumChatEntry.path] = json;

      await expectLater(
        SyncPayloadTransport.download(cloud, mediumChatEntry),
        throwsA(anything),
      );
      expect(cloud.downloadCalls, [mediumChatEntry.path]);
    });

    test(
      'chat index identity and bounds reject before any part requests',
      () async {
        final mutations = <void Function(Map<String, dynamic>)>[
          (root) => root['__syncPayload'] = false,
          (root) => root['version'] = 2,
          (root) => root['encoding'] = 'base64',
          (root) => root['type'] = 'reconciliation_state',
          (root) => root['id'] = 'another-session',
          (root) => root['jsonBytes'] = _maxDecodedBytes + 1,
          (root) => root['jsonBytes'] = 0,
          (root) => root['jsonBytes'] = '1024',
          (root) =>
              root['compressedBytes'] = _maxDecodedBytes + _chunkBytes + 1,
          (root) => root['compressedBytes'] = 0,
          (root) =>
              root['compressedBytes'] = (root['compressedBytes'] as int) + 1,
          (root) => root['chunks'] = <dynamic>[],
          (root) => root['chunks'] = List.generate(
            257,
            (_) => Map<String, dynamic>.from(_chunks(root).first),
          ),
          (root) => _chunks(root).last['bytes'] = _chunkBytes + 1,
          (root) => _chunks(root).last['bytes'] = 0,
          (root) => _chunks(root).last['bytes'] = -1,
          (root) => _chunks(root).last['bytes'] = '768',
          (root) => _chunks(root).last['hash'] = '../outside',
          (root) => root['payloadHash'] = 'not a hash',
        ];
        for (var i = 0; i < mutations.length; i++) {
          final cloud = chatCloud();
          final root = _root(cloud, mediumChatEntry);
          mutations[i](root);

          await expectLater(
            SyncPayloadTransport.download(
              cloud,
              mediumChatEntry,
              rawPayload: jsonEncode(root),
            ),
            throwsA(anything),
            reason: 'Invalid chat index case $i',
          );
          expect(cloud.downloadCalls, isEmpty);
        }
      },
    );

    test(
      'other entity envelopes remain rejected before part requests',
      () async {
        for (final type in [
          'character',
          'persona',
          'rewrite_job_history',
          'local_storage',
        ]) {
          final cloud = chatCloud();
          final root = _root(cloud, mediumChatEntry)..['type'] = type;
          final entry = mediumChatEntry.copyWith(type: type);

          await expectLater(
            SyncPayloadTransport.download(
              cloud,
              entry,
              rawPayload: jsonEncode(root),
            ),
            throwsA(anything),
            reason: 'Unsupported envelope type: $type',
          );
          expect(cloud.downloadCalls, isEmpty);
        }
      },
    );

    test(
      'missing corrupt and invalid chat parts never return partial data',
      () async {
        for (final damage in [
          'missing',
          'corrupt',
          'base64',
          'reordered',
          'hash',
          'expansion',
        ]) {
          final cloud = chatCloud();
          final root = _root(cloud, mediumChatEntry);
          final path = _partPath(mediumChatEntry, _chunks(root).last);
          switch (damage) {
            case 'missing':
              cloud.files.remove(path);
            case 'corrupt':
              final bytes = base64Decode(cloud.files[path]!);
              bytes[bytes.length ~/ 2] ^= 1;
              cloud.files[path] = base64Encode(bytes);
            case 'base64':
              cloud.files[path] = '!' * cloud.files[path]!.length;
            case 'reordered':
              root['chunks'] = _chunks(root).reversed.toList();
            case 'hash':
              root['payloadHash'] = '0' * 64;
            case 'expansion':
              root['jsonBytes'] = _compressionThreshold;
          }
          cloud.files[mediumChatEntry.path] = jsonEncode(root);

          await expectLater(
            SyncPayloadTransport.download(cloud, mediumChatEntry),
            throwsA(anything),
            reason: 'Chat damage: $damage',
          );
        }
      },
    );

    test(
      'interrupted chat replacement preserves old root and full chat',
      () async {
        final cloud = _RecordingCloudAdapter()..files.addAll(chatFiles);
        final oldRoot = cloud.files[mediumChatEntry.path];
        final replacement = _chat(_noise(seed: 99)).toJson();
        cloud.failPartUploadNumber = 2;

        await expectLater(
          SyncPayloadTransport.upload(
            cloud,
            _entry(replacement, type: 'chat'),
            replacement,
          ),
          throwsA(anything),
        );

        expect(cloud.partUploadCount, 2);
        expect(cloud.uploadCalls, isNot(contains(mediumChatEntry.path)));
        expect(cloud.files[mediumChatEntry.path], oldRoot);
        for (final file in chatFiles.entries) {
          expect(cloud.files[file.key], file.value);
        }
        expect(
          jsonEncode(
            await SyncPayloadTransport.download(cloud, mediumChatEntry),
          ),
          jsonEncode(mediumChatPayload),
        );
      },
    );

    test(
      'ownership loss stops upload after compression folder or part await',
      () async {
        for (final checkpoint in ['compression', 'folder', 'part']) {
          final cloud = _RecordingCloudAdapter()..files.addAll(chatFiles);
          final oldRoot = cloud.files[mediumChatEntry.path];
          var active = true;
          var checks = 0;
          cloud.afterEnsureFolder = () {
            if (checkpoint == 'folder') active = false;
          };
          cloud.afterUpload = (path) {
            if (checkpoint == 'part' && path.contains('.parts/')) {
              active = false;
            }
          };

          await expectLater(
            SyncPayloadTransport.upload(
              cloud,
              mediumChatEntry,
              mediumChatPayload,
              checkActive: () {
                checks++;
                if (checkpoint == 'compression' && checks == 2) active = false;
                if (!active) throw StateError('Sync run superseded');
              },
            ),
            throwsA(isA<StateError>()),
            reason: 'Ownership lost at $checkpoint',
          );

          expect(cloud.files[mediumChatEntry.path], oldRoot);
          expect(cloud.uploadCalls, isNot(contains(mediumChatEntry.path)));
          expect(cloud.partUploadCount, checkpoint == 'part' ? 1 : 0);
          if (checkpoint == 'compression') {
            expect(cloud.ensuredFolders, isEmpty);
          }
        }
      },
    );
  });

  test('other entity types retain ordinary JSON above threshold', () async {
    final cloud = _RecordingCloudAdapter();
    final data = {'text': 'x' * (_compressionThreshold + 1)};
    final entry = _entry(data, type: 'character');

    await SyncPayloadTransport.upload(cloud, entry, data);

    expect(cloud.files, {entry.path: jsonEncode(data)});
    expect(cloud.uploadCalls, [entry.path]);
    expect(await SyncPayloadTransport.download(cloud, entry), data);
  });

  test(
    'compression threshold is inclusive and measured in UTF8 bytes',
    () async {
      for (final type in ['reconciliation_state', 'chat']) {
        for (final bytes in [
          _compressionThreshold - 1,
          _compressionThreshold,
        ]) {
          final cloud = FakeCloudAdapter();
          final data = _payloadWithUtf8Size(bytes);
          final entry = _entry(data, type: type);
          final json = jsonEncode(data);
          expect(utf8.encode(json), hasLength(bytes));
          expect(json.length, lessThan(_compressionThreshold));

          await SyncPayloadTransport.upload(cloud, entry, data);

          if (bytes < _compressionThreshold) {
            expect(cloud.files, {entry.path: json});
          } else {
            expect(_root(cloud, entry)['__syncPayload'], isTrue);
            expect(_root(cloud, entry)['jsonBytes'], bytes);
          }
          expect(await SyncPayloadTransport.download(cloud, entry), data);
        }
      }
    },
  );

  test(
    'ordinary JSON rejects more than 30 MiB UTF8 on upload and read',
    () async {
      final cloud = FakeCloudAdapter();
      final data = {'text': '界' * (maxSyncPayloadBytes ~/ 3)};
      final entry = _entry(data, type: 'character');
      final json = jsonEncode(data);
      expect(json.length, lessThan(maxSyncPayloadBytes));
      expect(utf8.encode(json).length, greaterThan(maxSyncPayloadBytes));

      await expectLater(
        SyncPayloadTransport.upload(cloud, entry, data),
        throwsA(anything),
      );
      expect(cloud.files, isEmpty);
      cloud.files[entry.path] = json;
      await expectLater(
        SyncPayloadTransport.download(cloud, entry),
        throwsA(anything),
      );
    },
  );

  test(
    'multipart payload over 30 MiB roundtrips and publishes root last',
    () async {
      final cloud = _RecordingCloudAdapter()
        ..requireEnsuredParentForUpload = true;
      await cloud.ensureFolder('$cloudBase/reconciliation_state');
      final data = _state('${'x' * (31 * 1024 * 1024)}$noise');
      final entry = _entry(data);
      final jsonBytes = utf8.encode(jsonEncode(data));
      expect(jsonBytes.length, greaterThan(maxSyncPayloadBytes));

      await SyncPayloadTransport.upload(cloud, entry, data);

      final root = _root(cloud, entry);
      final chunks = _chunks(root);
      expect(chunks.length, greaterThan(1));
      expect(
        root.keys,
        unorderedEquals([
          '__syncPayload',
          'version',
          'encoding',
          'type',
          'id',
          'jsonBytes',
          'compressedBytes',
          'payloadHash',
          'chunks',
        ]),
      );
      expect(root['__syncPayload'], isTrue);
      expect(root['version'], 1);
      expect(root['encoding'], 'gzip+base64-chunks');
      expect(root['type'], entry.type);
      expect(root['id'], entry.id);
      expect(root['jsonBytes'], jsonBytes.length);
      expect(root['payloadHash'], sha256.convert(jsonBytes).toString());
      expect(cloud.ensuredFolders, contains('${entry.path}.parts'));
      expect(cloud.uploadCalls, [
        for (final chunk in chunks) _partPath(entry, chunk),
        entry.path,
      ]);
      final compressed = BytesBuilder(copy: false);
      for (final chunk in chunks) {
        expect(chunk.keys, unorderedEquals(['hash', 'bytes']));
        final encoded = cloud.files[_partPath(entry, chunk)]!;
        expect(encoded.length, lessThanOrEqualTo(1024 * 1024));
        final bytes = base64Decode(encoded);
        expect(bytes.length, inInclusiveRange(1, _chunkBytes));
        expect(bytes.length, chunk['bytes']);
        expect(sha256.convert(bytes).toString(), chunk['hash']);
        compressed.add(bytes);
      }
      expect(compressed.length, root['compressedBytes']);
      expect(
        sha256.convert(gzip.decode(compressed.takeBytes())).toString(),
        root['payloadHash'],
      );
      expect(await SyncPayloadTransport.download(cloud, entry), data);
    },
  );

  test(
    'repeated upload uses identical content-addressed parts and root',
    () async {
      final cloud = _RecordingCloudAdapter()..files.addAll(chunkedFiles);
      final before = Map.of(cloud.files);

      await SyncPayloadTransport.upload(cloud, mediumEntry, mediumPayload);
      await SyncPayloadTransport.upload(cloud, mediumEntry, mediumPayload);

      expect(cloud.files, before);
      expect(
        await SyncPayloadTransport.download(cloud, mediumEntry),
        mediumPayload,
      );
    },
  );

  test(
    'engine pushes over 30 MiB and independent device pulls logical hash',
    () async {
      final sourceState = FakeReconciliationStateStore();
      final source = SyncWorld(reconciliationStateStore: sourceState);
      final data = _state('x' * (31 * 1024 * 1024));
      sourceState.data[_sessionId] = data;
      await source.chats.put(makeChat(_sessionId));
      final logicalHash = SyncSerialization.computeSyncHash(data);

      await source.engine.pushEntities(onProgress: (_) {});

      final manifestPath = cloudPath('manifest', 'manifest');
      final manifest = SyncManifest.fromJson(
        jsonDecode(source.cloud.files[manifestPath]!) as Map<String, dynamic>,
      );
      final entry =
          manifest.entries[entryKey('reconciliation_state', _sessionId)]!;
      final root = _root(source.cloud, entry);
      expect(root['jsonBytes'], greaterThan(maxSyncPayloadBytes));
      expect(root['payloadHash'], logicalHash);
      expect(entry.hash, logicalHash);
      expect(entry.hash, isNot(SyncSerialization.computeSyncHash(root)));
      final stateFiles = {
        for (final file in source.cloud.files.entries)
          if (file.key.startsWith(entry.path)) file.key: file.value,
      };
      final repeatedProgress = <SyncProgress>[];
      await source.engine.pushEntities(onProgress: repeatedProgress.add);
      expect(
        repeatedProgress.any(
          (item) => item.message == 'Pushing reconciliation_state:$_sessionId',
        ),
        isFalse,
      );
      expect({
        for (final file in source.cloud.files.entries)
          if (file.key.startsWith(entry.path)) file.key: file.value,
      }, stateFiles);

      // A new device has no accepted manifest, preferences, or local store rows.
      SharedPreferences.setMockInitialValues({});
      final targetState = FakeReconciliationStateStore();
      final target = SyncWorld(reconciliationStateStore: targetState);
      target.cloud.files.addAll(source.cloud.files);
      expect(targetState.data, isEmpty);
      expect(
        (await target.manifestProvider.readLocalManifest()).entries,
        isEmpty,
      );
      final conflicts = <Object>[];

      await target.engine.pullEntities(
        onProgress: (_) {},
        onConflict: conflicts.add,
      );

      expect(conflicts, isEmpty);
      expect(target.chats.data, contains(_sessionId));
      expect(targetState.data[_sessionId], data);
      expect(
        (await target.manifestProvider.readLocalManifest())
            .entries[entry.key]!
            .hash,
        logicalHash,
      );
      expect(
        target.cloud.downloadCalls,
        containsAll([
          entry.path,
          for (final chunk in _chunks(root)) _partPath(entry, chunk),
        ]),
      );
    },
  );

  test(
    'interrupted replacement parts preserve old root and readable data',
    () async {
      final cloud = _RecordingCloudAdapter()..files.addAll(chunkedFiles);
      final oldRoot = cloud.files[mediumEntry.path];
      final replacement = _state(_noise(seed: 99));
      cloud.failPartUploadNumber = 2;

      await expectLater(
        SyncPayloadTransport.upload(cloud, _entry(replacement), replacement),
        throwsA(anything),
      );

      expect(cloud.partUploadCount, 2);
      expect(
        cloud.files.keys.toSet().difference(chunkedFiles.keys.toSet()),
        isNotEmpty,
      );
      expect(cloud.uploadCalls, isNot(contains(mediumEntry.path)));
      expect(cloud.files[mediumEntry.path], oldRoot);
      expect(
        await SyncPayloadTransport.download(cloud, mediumEntry),
        mediumPayload,
      );
    },
  );

  test('corrupted part with original descriptor hash is rejected', () async {
    final cloud = chunkedCloud();
    final chunk = _chunks(_root(cloud, mediumEntry)).first;
    final path = _partPath(mediumEntry, chunk);
    final bytes = base64Decode(cloud.files[path]!);
    bytes[bytes.length ~/ 2] ^= 1;
    cloud.files[path] = base64Encode(bytes);

    await expectLater(
      SyncPayloadTransport.download(cloud, mediumEntry),
      throwsA(anything),
    );
  });

  test('missing referenced part is rejected', () async {
    final cloud = chunkedCloud();
    final chunk = _chunks(_root(cloud, mediumEntry)).last;
    cloud.files.remove(_partPath(mediumEntry, chunk));

    await expectLater(
      SyncPayloadTransport.download(cloud, mediumEntry),
      throwsA(anything),
    );
  });

  test('reordering individually valid parts is rejected', () async {
    final cloud = chunkedCloud();
    final root = _root(cloud, mediumEntry);
    root['chunks'] = _chunks(root).reversed.toList();
    cloud.files[mediumEntry.path] = jsonEncode(root);

    await expectLater(
      SyncPayloadTransport.download(cloud, mediumEntry),
      throwsA(anything),
    );
  });

  test(
    'root identity, version and encoding mismatches are rejected before parts',
    () async {
      for (final mutation in <Map<String, dynamic>>[
        {'type': 'chat'},
        {'id': 'another-session'},
        {'version': 2},
        {'version': '1'},
        {'encoding': 'base64'},
      ]) {
        final cloud = chunkedCloud();
        final root = _root(cloud, mediumEntry)..addAll(mutation);
        cloud.files[mediumEntry.path] = jsonEncode(root);

        await expectLater(
          SyncPayloadTransport.download(cloud, mediumEntry),
          throwsA(anything),
          reason: 'Invalid root: $mutation',
        );
        expect(cloud.downloadCalls, [mediumEntry.path]);
      }
    },
  );

  test(
    'payload hash and declared JSON, compressed and part sizes must match',
    () async {
      final original = _root(chunkedCloud(), mediumEntry);
      final mutations = <void Function(Map<String, dynamic>)>[
        (root) => root['payloadHash'] = '0' * 64,
        (root) => root['jsonBytes'] = (root['jsonBytes'] as int) + 1,
        (root) =>
            root['compressedBytes'] = (root['compressedBytes'] as int) + 1,
        (root) => _chunks(root).last['bytes'] =
            (_chunks(root).last['bytes'] as int) + 1,
      ];
      for (var i = 0; i < mutations.length; i++) {
        final cloud = chunkedCloud();
        final root = jsonDecode(jsonEncode(original)) as Map<String, dynamic>;
        mutations[i](root);
        cloud.files[mediumEntry.path] = jsonEncode(root);

        await expectLater(
          SyncPayloadTransport.download(cloud, mediumEntry),
          throwsA(anything),
          reason: 'Invalid hash or size case $i',
        );
      }
    },
  );

  test('unsafe descriptor hashes never cause escaped cloud requests', () async {
    for (final hash in [
      '../outside',
      '..\\outside',
      '/outside',
      '%2e%2e%2foutside',
      '${'a' * 64}/../../outside',
    ]) {
      final cloud = chunkedCloud();
      final root = _root(cloud, mediumEntry);
      _chunks(root).first['hash'] = hash;
      cloud.files[mediumEntry.path] = jsonEncode(root);

      await expectLater(
        SyncPayloadTransport.download(cloud, mediumEntry),
        throwsA(anything),
        reason: 'Unsafe hash: $hash',
      );
      expect(cloud.downloadCalls, [mediumEntry.path]);
    }
  });

  test(
    'descriptor count and byte bounds reject before downloading parts',
    () async {
      final mutations = <void Function(Map<String, dynamic>)>[
        (root) => root['chunks'] = <dynamic>[],
        (root) => root['chunks'] = List.generate(
          257,
          (_) => Map<String, dynamic>.from(_chunks(root).first),
        ),
        (root) => root['jsonBytes'] = _maxDecodedBytes + 1,
        (root) => root['jsonBytes'] = 0,
        (root) => root['compressedBytes'] = 256 * _chunkBytes + 1,
        (root) => root['compressedBytes'] = -1,
        (root) => _chunks(root).first['bytes'] = _chunkBytes + 1,
        (root) => _chunks(root).first['bytes'] = 0,
        (root) => _chunks(root).first['bytes'] = -1,
      ];
      for (var i = 0; i < mutations.length; i++) {
        final cloud = chunkedCloud();
        final root = _root(cloud, mediumEntry);
        mutations[i](root);
        cloud.files[mediumEntry.path] = jsonEncode(root);

        await expectLater(
          SyncPayloadTransport.download(cloud, mediumEntry),
          throwsA(anything),
          reason: 'Out-of-bounds descriptor case $i',
        );
        expect(cloud.downloadCalls, [mediumEntry.path]);
      }
    },
  );

  test('gzip expansion beyond declared JSON bytes is rejected', () async {
    final cloud = FakeCloudAdapter();
    final data = _state('x' * (1024 * 1024));
    final entry = _entry(data);
    await SyncPayloadTransport.upload(cloud, entry, data);
    final root = _root(cloud, entry);
    // Compressed bytes, each part hash and the final logical hash remain valid.
    // Only the allowed expansion is reduced below what this gzip stream emits.
    root['jsonBytes'] = _compressionThreshold;
    cloud.files[entry.path] = jsonEncode(root);

    await expectLater(
      SyncPayloadTransport.download(cloud, entry),
      throwsA(anything),
    );
    expect(cloud.downloadCalls.length, greaterThan(1));
  });

  test(
    'optional and required serialization readers unwrap and reject damage',
    () async {
      final cloud = chunkedCloud();
      expect(
        await SyncSerialization.readCloudEntity(cloud, mediumEntry),
        mediumPayload,
      );
      expect(
        await SyncSerialization.readRequiredCloudEntity(cloud, mediumEntry),
        mediumPayload,
      );
      final chunk = _chunks(_root(cloud, mediumEntry)).first;
      cloud.files.remove(_partPath(mediumEntry, chunk));

      expect(
        await SyncSerialization.readCloudEntity(cloud, mediumEntry),
        isNull,
      );
      await expectLater(
        SyncSerialization.readRequiredCloudEntity(cloud, mediumEntry),
        throwsA(anything),
      );
    },
  );

  test(
    'invalid base64 and non-gzip bytes reject even with matching descriptor',
    () async {
      final base64Cloud = chunkedCloud();
      final chunk = _chunks(_root(base64Cloud, mediumEntry)).first;
      base64Cloud.files[_partPath(mediumEntry, chunk)] = 'not base64!';
      await expectLater(
        SyncPayloadTransport.download(base64Cloud, mediumEntry),
        throwsA(anything),
      );

      final gzipCloud = chunkedCloud();
      final root = _root(gzipCloud, mediumEntry);
      final bytes = utf8.encode('This is not a gzip stream.');
      final descriptor = {
        'hash': sha256.convert(bytes).toString(),
        'bytes': bytes.length,
      };
      root['chunks'] = [descriptor];
      root['compressedBytes'] = bytes.length;
      gzipCloud.files[_partPath(mediumEntry, descriptor)] = base64Encode(bytes);
      gzipCloud.files[mediumEntry.path] = jsonEncode(root);
      await expectLater(
        SyncPayloadTransport.download(gzipCloud, mediumEntry),
        throwsA(anything),
      );
    },
  );
}
