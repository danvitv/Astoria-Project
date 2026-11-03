import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/sync_reconciliation_source.dart';
import 'package:glaze_flutter/features/cloud_sync/services/reconciliation_page_cache.dart';
import 'package:glaze_flutter/features/cloud_sync/services/reconciliation_page_transport.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_queue.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart' as fixtures;

const _session = 'persistent-page-cache-session';
const _rowBytes = ReconciliationPageTransport.pageBytes ~/ 2;

class _JournalSource implements ReconciliationStateSource {
  const _JournalSource(this.rows);

  final List<Map<String, dynamic>> rows;

  @override
  String get sessionId => _session;

  @override
  int get schemaVersion => 2;

  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    if (section != ReconciliationSection.manifests) return;
    for (final row in rows) {
      yield Map<String, dynamic>.from(row);
    }
  }
}

class _JournalStore extends fixtures.FakeReconciliationStateStore
    implements SyncPagedReconciliationStateStore {
  _JournalStore([this.source]);

  final ReconciliationStateSource? source;
  ReconciliationFingerprint? imported;
  int imports = 0;

  @override
  Future<List<String>> getAllSessionIds() async =>
      source != null || imported != null ? [_session] : [];

  @override
  Future<bool> hasBySessionId(String id) async =>
      id == _session && (source != null || imported != null);

  @override
  Future<Map<String, dynamic>?> getBySessionId(String id) =>
      throw StateError('Paged sync must not assemble the legacy map');

  @override
  Future<ReconciliationFingerprint?> fingerprintBySessionId(String id) async {
    if (id != _session) return null;
    return source == null
        ? imported
        : ReconciliationJsonCodec.fingerprint(source!);
  }

  @override
  Future<T?> withExportSnapshot<T>(
    String id,
    Future<T> Function(ReconciliationStateSource source) consume,
  ) async => id == _session && source != null ? consume(source!) : null;

  @override
  Future<void> mergeFromSource(
    String id,
    ReconciliationStateSource incoming,
  ) async {
    expect(id, _session);
    imported = await ReconciliationJsonCodec.fingerprint(incoming);
    imports++;
  }
}

class _RecordingCloud extends fixtures.FakeCloudAdapter {
  final writes = <String>[];
  Future<void> Function(String path)? beforeDownload;

  @override
  Future<String> download(String path) async {
    await beforeDownload?.call(path);
    return super.download(path);
  }

  @override
  Future<void> upload(String path, String data) async {
    await super.upload(path, data);
    writes.add(path);
  }
}

// Seven distinct half-page NDJSON rows are enough to exercise a changed tail:
// five rows occupy three pages; appending two preserves exactly two prefixes.
Map<String, dynamic> _manifestRow(int index) {
  final row = <String, dynamic>{
    'messageId': 'message-${index.toString().padLeft(3, '0')}',
    'manifestJson': '',
  };
  final textLength = _rowBytes - utf8.encode(jsonEncode(row)).length - 1;
  final random = Random(90210 + index);
  final noise = Uint8List.fromList(
    List.generate(((textLength + 3) ~/ 4) * 3, (_) => random.nextInt(256)),
  );
  row['manifestJson'] = base64Encode(noise).substring(0, textLength);
  expect(utf8.encode(jsonEncode(row)).length + 1, _rowBytes);
  return row;
}

Future<SyncManifestEntry> _entry(ReconciliationStateSource source) async =>
    SyncManifestEntry(
      type: 'reconciliation_state',
      id: source.sessionId,
      path: cloudPath('reconciliation_state', source.sessionId),
      updatedAt: 1000,
      hash: (await ReconciliationJsonCodec.fingerprint(source)).hash,
    );

Map<String, dynamic> _root(_RecordingCloud cloud, SyncManifestEntry entry) =>
    jsonDecode(cloud.files[entry.path]!) as Map<String, dynamic>;

List<Map<String, dynamic>> _pages(Map<String, dynamic> root) =>
    ((root['sections'] as List)[ReconciliationSection.manifests.index]['pages']
            as List)
        .cast<Map<String, dynamic>>();

String _pagePath(SyncManifestEntry entry, Map<String, dynamic> page) =>
    '${entry.path}.pages/${page['hash']}.b64';

List<String> _pagePaths(
  SyncManifestEntry entry,
  Iterable<Map<String, dynamic>> pages,
) => [for (final page in pages) _pagePath(entry, page)];

Uint8List _wireBytes(
  _RecordingCloud cloud,
  SyncManifestEntry entry,
  Map<String, dynamic> page,
) => base64Decode(cloud.files[_pagePath(entry, page)]!);

Future<void> _expectCachedPages(
  ReconciliationPageCache cache,
  _RecordingCloud cloud,
  SyncManifestEntry entry,
  Iterable<Map<String, dynamic>> pages,
) async {
  for (final page in pages) {
    expect(
      await cache.read(page['hash'] as String, page['compressedBytes'] as int),
      _wireBytes(cloud, entry, page),
    );
  }
}

Future<void> _expectReplay(
  ReconciliationPageTransport transport,
  _RecordingCloud cloud,
  SyncManifestEntry entry,
  ReconciliationStateSource expected,
) async {
  final fingerprint = await ReconciliationJsonCodec.fingerprint(expected);
  var consumers = 0;
  await transport.withDownloadedSource(cloud, entry, (incoming) async {
    consumers++;
    expect(incoming.sessionId, expected.sessionId);
    expect(incoming.schemaVersion, expected.schemaVersion);
    final actual = await ReconciliationJsonCodec.fingerprint(incoming);
    expect(actual.hash, entry.hash);
    expect(actual.hash, fingerprint.hash);
    expect(actual.jsonBytes, fingerprint.jsonBytes);
    for (final section in ReconciliationSection.values) {
      expect(
        await incoming.readSection(section).toList(),
        await expected.readSection(section).toList(),
        reason: '${section.name} must replay exactly, cached or downloaded',
      );
    }
  });
  expect(consumers, 1);
}

Future<void> _expectRejected(
  ReconciliationPageTransport transport,
  _RecordingCloud cloud,
  SyncManifestEntry entry,
) async {
  var consumed = false;
  await expectLater(
    transport.withDownloadedSource(cloud, entry, (_) async {
      consumed = true;
    }),
    throwsA(isA<Exception>()),
  );
  expect(
    consumed,
    isFalse,
    reason: 'No partial source may enter domain writes',
  );
}

// Locate the fixture's raw compressed blob by content, not private cache layout.
Future<File> _cachedFile(Directory root, String hash) async {
  await for (final entity in root.list(recursive: true, followLinks: false)) {
    if (entity is File &&
        sha256.convert(await entity.readAsBytes()).toString() == hash) {
      return entity;
    }
  }
  throw StateError('The verified fixture page was not persisted');
}

SyncEngine _engine(
  fixtures.SyncWorld world,
  _JournalStore store,
  ReconciliationPageCache cache,
) => SyncEngine(
  world.cloud,
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
  fixtures.FakeExtensionPresetStore(),
  fixtures.FakeExtensionsSettingsStore(),
  fixtures.FakeInfoBlockStore(),
  fixtures.FakeTrackerSnapshotStore(),
  fixtures.FakeTrackerValueStore(),
  world.studioConfigs,
  world.studioPresets,
  null,
  null,
  null,
  null,
  world.sessionDeletions,
  world.characterDeletions,
  (_) async {},
  store,
  null,
  null,
  0,
  Duration.zero,
  null,
  null,
  cache,
);

void main() {
  late List<Map<String, dynamic>> rows;
  late Directory fixtureRoot;
  late Directory stagingRoot;
  late Directory cacheRoot;
  late _RecordingCloud cloud;

  ReconciliationPageTransport transport({
    bool cached = true,
    void Function()? checkActive,
    void Function(String)? onProgress,
  }) => ReconciliationPageTransport(
    temporaryRoot: stagingRoot,
    pageCache: cached ? ReconciliationPageCache(cacheRoot) : null,
    checkActive: checkActive,
    onProgress: onProgress,
  );

  Future<SyncManifestEntry> publish(_JournalSource source) async {
    final entry = await _entry(source);
    // The synthetic remote writer has no access to this device's cache.
    await transport(cached: false).upload(cloud, entry, _JournalStore(source));
    cloud.downloadCalls.clear();
    cloud.writes.clear();
    return entry;
  }

  setUpAll(() {
    rows = List.generate(7, _manifestRow);
  });

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final local = Platform.environment['LOCALAPPDATA'];
    final parent = local == null
        ? Directory('${Directory.systemTemp.path}/opencode')
        : Directory('$local/Temp/opencode');
    await parent.create(recursive: true);
    fixtureRoot = await parent.createTemp(
      'reconciliation-page-cache-transport-',
    );
    stagingRoot = await Directory('${fixtureRoot.path}/staging').create();
    cacheRoot = await Directory('${fixtureRoot.path}/cache').create();
    cloud = _RecordingCloud();
  });

  tearDown(() async {
    try {
      expect(await stagingRoot.list().toList(), isEmpty);
    } finally {
      await fixtureRoot.delete(recursive: true);
    }
  });

  test('cold pull persists pages; restart still fetches root', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await publish(source);
    final pages = _pages(_root(cloud, entry));
    expect(pages, hasLength(3));
    final progress = <String>[];

    await _expectReplay(
      transport(onProgress: progress.add),
      cloud,
      entry,
      source,
    );

    expect(cloud.downloadCalls, [entry.path, ..._pagePaths(entry, pages)]);
    expect(
      progress,
      contains('Pulling ${entry.key}: pages 3/3 (0 cached, 3 downloaded)'),
    );
    final restartedCache = ReconciliationPageCache(cacheRoot);
    await _expectCachedPages(restartedCache, cloud, entry, pages);
    cloud.downloadCalls.clear();
    progress.clear();

    await _expectReplay(
      transport(onProgress: progress.add),
      cloud,
      entry,
      source,
    );

    expect(cloud.downloadCalls, [entry.path]);
    expect(
      progress,
      contains('Pulling ${entry.key}: pages 3/3 (3 cached, 0 downloaded)'),
    );
    expect(progress.last, 'Applying ${entry.key}');
  });

  test(
    'append downloads only changed tail and new page after restart',
    () async {
      final previous = _JournalSource(rows.take(5).toList());
      final oldEntry = await publish(previous);
      final oldPages = _pages(_root(cloud, oldEntry));
      await _expectReplay(transport(), cloud, oldEntry, previous);
      final replacement = _JournalSource(rows);
      final entry = await publish(replacement);
      final pages = _pages(_root(cloud, entry));
      expect(oldPages, hasLength(3));
      expect(pages, hasLength(4));
      expect(pages.take(2), oldPages.take(2));
      final progress = <String>[];

      await _expectReplay(
        transport(onProgress: progress.add),
        cloud,
        entry,
        replacement,
      );

      expect(cloud.downloadCalls, [
        entry.path,
        ..._pagePaths(entry, pages.skip(2)),
      ]);
      expect(
        progress,
        contains('Pulling ${entry.key}: pages 4/4 (2 cached, 2 downloaded)'),
      );
    },
  );

  test('successful initial upload primes exact compressed bytes', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await _entry(source);
    await transport().upload(cloud, entry, _JournalStore(source));
    final pages = _pages(_root(cloud, entry));
    expect(cloud.writes, [..._pagePaths(entry, pages), entry.path]);
    final cache = ReconciliationPageCache(cacheRoot);
    await _expectCachedPages(cache, cloud, entry, pages);
    cloud.downloadCalls.clear();

    await _expectReplay(transport(), cloud, entry, source);

    expect(cloud.downloadCalls, [entry.path]);
  });

  for (final os in [3, 255]) {
    test('append upload primes reused OS $os hashes and new pages', () async {
      final previous = _JournalSource(rows.take(5).toList());
      final oldEntry = await publish(previous);
      final root = _root(cloud, oldEntry);
      // Reproduce a published foreign gzip header without platform dependence.
      for (final page in _pages(root)) {
        final originalPath = _pagePath(oldEntry, page);
        final bytes = _wireBytes(cloud, oldEntry, page);
        bytes[9] = os;
        page['hash'] = sha256.convert(bytes).toString();
        cloud.files.remove(originalPath);
        cloud.files[_pagePath(oldEntry, page)] = base64Encode(bytes);
      }
      cloud.files[oldEntry.path] = jsonEncode(root);
      final oldPages = _pages(root);
      final replacement = _JournalSource(rows);
      final entry = await _entry(replacement);

      await transport().upload(cloud, entry, _JournalStore(replacement));

      final pages = _pages(_root(cloud, entry));
      expect(pages, hasLength(4));
      expect(pages.take(2), oldPages.take(2));
      expect(cloud.writes, [..._pagePaths(entry, pages.skip(2)), entry.path]);
      final cache = ReconciliationPageCache(cacheRoot);
      await _expectCachedPages(cache, cloud, entry, pages);
      cloud.downloadCalls.clear();

      await _expectReplay(transport(), cloud, entry, replacement);

      expect(cloud.downloadCalls, [entry.path]);
    });
  }

  test('cache cannot authorize skipping upload after cloud wipe', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await _entry(source);
    await transport().upload(cloud, entry, _JournalStore(source));
    final pages = _pages(_root(cloud, entry));
    cloud.files.clear();
    cloud.writes.clear();
    cloud.downloadCalls.clear();

    await transport().upload(cloud, entry, _JournalStore(source));

    expect(cloud.downloadCalls, [entry.path]);
    expect(cloud.writes, [..._pagePaths(entry, pages), entry.path]);
    await _expectReplay(transport(cached: false), cloud, entry, source);
  });

  test('failed page upload never primes that unuploaded page', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await publish(source);
    final pages = _pages(_root(cloud, entry));
    cloud.files.clear();
    cloud.uploadFailures.add(_pagePath(entry, pages[1]));

    await expectLater(
      transport().upload(cloud, entry, _JournalStore(source)),
      throwsA(isA<Exception>()),
    );

    expect(cloud.writes, [_pagePath(entry, pages.first)]);
    expect(cloud.files.containsKey(entry.path), isFalse);
    final cache = ReconciliationPageCache(cacheRoot);
    await _expectCachedPages(cache, cloud, entry, pages.take(1));
    for (final page in pages.skip(1)) {
      expect(
        await cache.read(
          page['hash'] as String,
          page['compressedBytes'] as int,
        ),
        isNull,
      );
    }
  });

  for (final damage in ['corrupt', 'missing', 'truncated']) {
    test('$damage cache page safely refetches just that page', () async {
      final source = _JournalSource(rows.take(5).toList());
      final entry = await publish(source);
      final pages = _pages(_root(cloud, entry));
      await _expectReplay(transport(), cloud, entry, source);
      final page = pages.first;
      final file = await _cachedFile(cacheRoot, page['hash'] as String);
      if (damage == 'missing') {
        await file.delete();
      } else {
        final bytes = await file.readAsBytes();
        if (damage == 'corrupt') bytes[bytes.length ~/ 2] ^= 1;
        await file.writeAsBytes(
          damage == 'truncated' ? bytes.sublist(0, bytes.length - 1) : bytes,
        );
      }
      cloud.downloadCalls.clear();

      await _expectReplay(transport(), cloud, entry, source);

      expect(cloud.downloadCalls, [entry.path, _pagePath(entry, page)]);
      await _expectCachedPages(
        ReconciliationPageCache(cacheRoot),
        cloud,
        entry,
        [page],
      );
    });
  }

  for (final damage in ['corrupt', 'missing']) {
    test('$damage cloud page rejects when cache cannot supply it', () async {
      final source = _JournalSource(rows.take(5).toList());
      final entry = await publish(source);
      final pages = _pages(_root(cloud, entry));
      await _expectReplay(transport(), cloud, entry, source);
      final page = pages.first;
      await (await _cachedFile(cacheRoot, page['hash'] as String)).delete();
      final path = _pagePath(entry, page);
      if (damage == 'missing') {
        cloud.files.remove(path);
      } else {
        final bytes = _wireBytes(cloud, entry, page);
        bytes[bytes.length ~/ 2] ^= 1;
        cloud.files[path] = base64Encode(bytes);
      }
      cloud.downloadCalls.clear();

      await _expectRejected(transport(), cloud, entry);

      expect(cloud.downloadCalls, [entry.path, path]);
      expect(
        await ReconciliationPageCache(
          cacheRoot,
        ).read(page['hash'] as String, page['compressedBytes'] as int),
        isNull,
      );
    });
  }

  test(
    'missing later page preserves verified earlier pages for retry',
    () async {
      final source = _JournalSource(rows.take(5).toList());
      final entry = await publish(source);
      final pages = _pages(_root(cloud, entry));
      final missingPath = _pagePath(entry, pages.last);
      final missingBytes = cloud.files.remove(missingPath)!;
      final progress = <String>[];

      await _expectRejected(transport(onProgress: progress.add), cloud, entry);

      expect(cloud.downloadCalls, [entry.path, ..._pagePaths(entry, pages)]);
      expect(
        progress,
        contains('Pulling ${entry.key}: pages 2/3 (0 cached, 2 downloaded)'),
      );
      expect(progress, isNot(contains('Applying ${entry.key}')));
      final cache = ReconciliationPageCache(cacheRoot);
      await _expectCachedPages(cache, cloud, entry, pages.take(2));
      expect(
        await cache.read(
          pages.last['hash'] as String,
          pages.last['compressedBytes'] as int,
        ),
        isNull,
      );
      cloud.files[missingPath] = missingBytes;
      cloud.downloadCalls.clear();
      progress.clear();

      await _expectReplay(
        transport(onProgress: progress.add),
        cloud,
        entry,
        source,
      );

      expect(cloud.downloadCalls, [entry.path, missingPath]);
      expect(
        progress,
        contains('Pulling ${entry.key}: pages 3/3 (2 cached, 1 downloaded)'),
      );
    },
  );

  test('progress counts staged pages, not the in-flight download', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await publish(source);
    final pages = _pages(_root(cloud, entry));
    final started = Completer<void>();
    final resume = Completer<void>();
    cloud.beforeDownload = (path) async {
      if (path != _pagePath(entry, pages[1])) return;
      started.complete();
      await resume.future;
    };
    final progress = <String>[];
    var consumed = false;
    final pending = transport(onProgress: progress.add).withDownloadedSource(
      cloud,
      entry,
      (_) async {
        consumed = true;
      },
    );
    try {
      await started.future.timeout(const Duration(seconds: 10));
      expect(
        progress.last,
        'Pulling ${entry.key}: pages 1/3 (0 cached, 1 downloaded)',
      );
      expect(consumed, isFalse);
      await _expectCachedPages(
        ReconciliationPageCache(cacheRoot),
        cloud,
        entry,
        pages.take(1),
      );
    } finally {
      resume.complete();
      await pending;
    }
    expect(consumed, isTrue);
  });

  for (final section in ReconciliationSection.values) {
    test('cached ${section.name} count tampering rejects', () async {
      final source = _JournalSource(rows.take(5).toList());
      final entry = await publish(source);
      await _expectReplay(transport(), cloud, entry, source);
      final root = _root(cloud, entry);
      final descriptor =
          (root['sections'] as List)[section.index] as Map<String, dynamic>;
      descriptor['count'] = (descriptor['count'] as int) + 1;
      cloud.files[entry.path] = jsonEncode(root);
      cloud.downloadCalls.clear();

      await _expectRejected(transport(), cloud, entry);

      expect(cloud.downloadCalls, [entry.path]);
    });
  }

  for (final damage in [
    'payloadHash',
    'jsonBytes',
    'page-order',
    'section-order',
    'section-missing',
    'uncompressedBytes',
    'compressedBytes',
    'schema',
    'session',
  ]) {
    test('all-cached $damage tampering rejects before consumer', () async {
      final source = _JournalSource(rows.take(5).toList());
      var entry = await publish(source);
      await _expectReplay(transport(), cloud, entry, source);
      final root = _root(cloud, entry);
      final pages = _pages(root);
      final sections = root['sections'] as List;
      switch (damage) {
        case 'payloadHash':
          root['payloadHash'] = '0' * 64;
          // Matching manifest/root lies must still fail the full staged hash.
          entry = entry.copyWith(hash: root['payloadHash'] as String);
        case 'jsonBytes':
          root['jsonBytes'] = (root['jsonBytes'] as int) + 1;
        case 'page-order':
          final original = List<Map<String, dynamic>>.from(pages);
          pages[0] = original[1];
          pages[1] = original[0];
        case 'section-order':
          final first = sections[0];
          sections[0] = sections[1];
          sections[1] = first;
        case 'section-missing':
          sections.removeLast();
        case 'uncompressedBytes':
          pages.first['bytes'] = (pages.first['bytes'] as int) - 1;
        case 'compressedBytes':
          pages.first['compressedBytes'] =
              (pages.first['compressedBytes'] as int) + 1;
        case 'schema':
          root['schemaVersion'] = 1;
        case 'session':
          root['id'] = 'not-the-owning-session';
      }
      cloud.files[entry.path] = jsonEncode(root);
      cloud.downloadCalls.clear();

      await _expectRejected(transport(), cloud, entry);

      expect(
        cloud.downloadCalls,
        damage == 'compressedBytes'
            ? [entry.path, _pagePath(entry, pages.first)]
            : [entry.path],
      );
    });
  }

  test('hash-valid cached non-gzip page fails decompression', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await publish(source);
    await _expectReplay(transport(), cloud, entry, source);
    final root = _root(cloud, entry);
    final page = _pages(root).first;
    final bytes = Uint8List(page['compressedBytes'] as int);
    final hash = sha256.convert(bytes).toString();
    await ReconciliationPageCache(cacheRoot).write(hash, bytes);
    page['hash'] = hash;
    cloud.files[entry.path] = jsonEncode(root);
    cloud.downloadCalls.clear();

    await _expectRejected(transport(), cloud, entry);

    expect(cloud.downloadCalls, [entry.path]);
  });

  for (final phase in ['first-cached-page', 'applying']) {
    test(
      'retired cache-only pull stops at $phase before application',
      () async {
        final source = _JournalSource(rows.take(5).toList());
        final entry = await publish(source);
        await _expectReplay(transport(), cloud, entry, source);
        cloud.downloadCalls.clear();
        final queue = SyncQueue();
        final progress = <String>[];
        final guarded = transport(
          checkActive: queue.captureActiveGuard(),
          onProgress: (message) {
            progress.add(message);
            final stop = phase == 'applying'
                ? 'Applying ${entry.key}'
                : 'Pulling ${entry.key}: pages 1/3 (1 cached, 0 downloaded)';
            if (message == stop) {
              queue.abort();
              queue.reset();
            }
          },
        );
        var consumed = false;
        await expectLater(
          guarded.withDownloadedSource(cloud, entry, (_) async {
            consumed = true;
          }),
          throwsStateError,
        );
        expect(consumed, isFalse);
        expect(cloud.downloadCalls, [entry.path]);
        final requests = List<String>.from(cloud.downloadCalls);
        await expectLater(
          guarded.withDownloadedSource(cloud, entry, (_) async {
            consumed = true;
          }),
          throwsStateError,
        );
        expect(
          cloud.downloadCalls,
          requests,
          reason: 'A retired guard must not fetch the next root',
        );
        expect(consumed, isFalse);
        if (phase == 'first-cached-page') {
          expect(progress, isNot(contains('Applying ${entry.key}')));
        }
      },
    );
  }

  test('engine restart reports cache pages with unchanged entity totals', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await publish(source);
    final manifestPath = cloudPath('manifest', 'manifest');
    cloud.files[manifestPath] = jsonEncode(
      SyncManifest(
        deviceId: 'synthetic-remote',
        createdAt: 1,
        entries: {entry.key: entry},
      ).toJson(),
    );
    for (final warm in [false, true]) {
      final store = _JournalStore();
      final world = fixtures.SyncWorld(
        cloudAdapter: cloud,
        reconciliationStateStore: store,
      );
      await world.chats.put(fixtures.makeChat(_session));
      cloud.downloadCalls.clear();
      final progress = <SyncProgress>[];
      final cache = ReconciliationPageCache(cacheRoot);
      // Use the existing native engine fixture, not IOOverrides, which changes
      // filesystem type/path handling as well as temp IO on Windows. The engine
      // owns/disposes default staging, as in its other integration tests.
      await _engine(world, store, cache).pullEntities(
        onProgress: progress.add,
        onConflict: (_) => fail('Unexpected conflict'),
      );
      await _expectCachedPages(cache, cloud, entry, _pages(_root(cloud, entry)));
      expect(store.imports, 1);
      expect(store.imported!.hash, entry.hash);
      final phases = progress
          .where((p) => p.message?.contains(': pages ') ?? false)
          .toList();
      expect(phases, isNotEmpty);
      expect(phases.every((p) => p.current == 0 && p.total == 1), isTrue);
      expect(
        phases.last.message,
        'Pulling ${entry.key}: pages 3/3 '
        '(${warm ? 3 : 0} cached, ${warm ? 0 : 3} downloaded)',
      );
      final completed = progress.singleWhere(
        (p) => p.message == 'Pulled ${entry.key}',
      );
      expect(completed.current, 1);
      expect(completed.total, 1);
      expect(cloud.downloadCalls.where((p) => p == entry.path), [entry.path]);
      expect(
        cloud.downloadCalls.where((p) => p.contains('.pages/')),
        warm ? isEmpty : hasLength(3),
      );
    }
  });
}
