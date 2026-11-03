import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/sync_reconciliation_source.dart';
import 'package:glaze_flutter/features/cloud_sync/services/reconciliation_page_transport.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_engine.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_serialization.dart';
import 'package:glaze_flutter/features/cloud_sync/services/sync_queue.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'sync_lifecycle_test.dart' as fixtures;

const _session = 'paged-session';

class _Source implements ReconciliationStateSource {
  _Source(this.rows, this.text);
  final int rows;
  final String text;
  int maxActiveRows = 0;

  @override
  String get sessionId => _session;
  @override
  int get schemaVersion => 2;

  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    if (section != ReconciliationSection.manifests) return;
    for (var index = 0; index < rows; index++) {
      maxActiveRows = 1;
      yield {'messageId': 'message-$index', 'manifestJson': text};
    }
  }
}

class _Store extends fixtures.FakeReconciliationStateStore
    implements SyncPagedReconciliationStateStore {
  _Store([this.source]);
  ReconciliationStateSource? source;
  ReconciliationFingerprint? imported;
  int imports = 0;

  @override
  Future<List<String>> getAllSessionIds() async =>
      source != null || imported != null ? [_session] : [];
  @override
  Future<bool> hasBySessionId(String id) async =>
      source != null || imported != null;
  @override
  Future<Map<String, dynamic>?> getBySessionId(String id) =>
      throw StateError('Paged engine must never assemble the whole map');
  @override
  Future<ReconciliationFingerprint?> fingerprintBySessionId(String id) async =>
      source == null ? imported : ReconciliationJsonCodec.fingerprint(source!);
  @override
  Future<T?> withExportSnapshot<T>(
    String id,
    Future<T> Function(ReconciliationStateSource) consume,
  ) async => source == null ? null : consume(source!);
  @override
  Future<void> mergeFromSource(
    String id,
    ReconciliationStateSource incoming,
  ) async {
    imported = await ReconciliationJsonCodec.fingerprint(incoming);
    imports++;
  }
}

class _Cloud extends fixtures.FakeCloudAdapter {
  int uploadedPages = 0;
  int? failPage;
  final writes = <String>[];
  void Function(String)? afterUpload;
  Future<void> Function(String)? beforeDownload;

  @override
  Future<String> download(String path) async {
    await beforeDownload?.call(path);
    return super.download(path);
  }

  @override
  Future<void> upload(String path, String data) async {
    if (path.contains('.pages/') && ++uploadedPages == failPage) {
      throw StateError('Interrupted page upload');
    }
    writes.add(path);
    await super.upload(path, data);
    afterUpload?.call(path);
  }
}

String _noise() {
  final random = Random(41);
  return base64Encode(
    Uint8List.fromList(List.generate(1024 * 1024, (_) => random.nextInt(256))),
  );
}

Future<SyncManifestEntry> _entry(ReconciliationStateSource source) async =>
    SyncManifestEntry(
      type: 'reconciliation_state',
      id: _session,
      path: cloudPath('reconciliation_state', _session),
      updatedAt: 1000,
      hash: (await ReconciliationJsonCodec.fingerprint(source)).hash,
    );

Map<String, dynamic> _root(_Cloud cloud, SyncManifestEntry entry) =>
    jsonDecode(cloud.files[entry.path]!) as Map<String, dynamic>;

List<dynamic> _pages(Map<String, dynamic> root) =>
    (root['sections'] as List)[ReconciliationSection.manifests.index]['pages']
        as List;

void main() {
  late Directory temporaryRoot;
  late ReconciliationPageTransport transport;
  late _Cloud cloud;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final local = Platform.environment['LOCALAPPDATA'];
    final parent = local == null
        ? Directory.systemTemp
        : Directory('$local/Temp/opencode');
    temporaryRoot = await parent.createTemp('reconciliation-pages-test-');
    transport = ReconciliationPageTransport(temporaryRoot: temporaryRoot);
    cloud = _Cloud();
  });
  tearDown(() async {
    expect(await temporaryRoot.list().toList(), isEmpty);
    await temporaryRoot.delete();
  });

  test(
    'streamed fingerprint equals the unchanged virtual schema-2 JSON',
    () async {
      final data = {
        '__reconciliationState': true,
        'schemaVersion': 2,
        'sessionId': _session,
        for (final section in ReconciliationSection.values)
          section.name: <dynamic>[],
      };
      data['manifests'] = [
        {'messageId': 'm1', 'manifestJson': 'Ж 🐈'},
      ];
      final fingerprint = await ReconciliationJsonCodec.fingerprint(
        MapReconciliationStateSource(data),
      );
      expect(fingerprint.hash, SyncSerialization.computeSyncHash(data));
      expect(fingerprint.jsonBytes, utf8.encode(jsonEncode(data)).length);
    },
  );

  test(
    'a large record spans bounded pages and replays without hash drift',
    () async {
      final source = _Source(2, _noise());
      final entry = await _entry(source);
      await transport.upload(cloud, entry, _Store(source));
      final root = _root(cloud, entry);
      expect(root['version'], 2);
      expect(_pages(root).length, greaterThan(2));
      expect(cloud.writes.last, entry.path);
      for (final page in _pages(root)) {
        expect(
          page['bytes'],
          lessThanOrEqualTo(ReconciliationPageTransport.pageBytes),
        );
      }
      for (final raw in cloud.files.values) {
        expect(utf8.encode(raw).length, lessThanOrEqualTo(1024 * 1024));
      }
      await transport.withDownloadedSource(cloud, entry, (incoming) async {
        expect(
          (await ReconciliationJsonCodec.fingerprint(incoming)).hash,
          entry.hash,
        );
        final rows = await incoming
            .readSection(ReconciliationSection.manifests)
            .toList();
        expect(rows.length, 2);
        expect(rows.first['manifestJson'], source.text);
      });
    },
  );

  test(
    '10k message-manifest rows exceed 128MiB without a whole-map allocation',
    () async {
      final source = _Source(10000, 'retained evidence Ж ' * 1024);
      final entry = await _entry(source);
      await transport.upload(cloud, entry, _Store(source));
      final root = _root(cloud, entry);
      expect(root['jsonBytes'], greaterThan(128 * 1024 * 1024));
      expect(source.maxActiveRows, 1);
      await transport.withDownloadedSource(cloud, entry, (incoming) async {
        var count = 0;
        await for (final _ in incoming.readSection(
          ReconciliationSection.manifests,
        )) {
          count++;
        }
        expect(count, 10000);
      });
      expect(
        cloud.files.values.every((value) => value.length <= 1024 * 1024),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('existing immutable pages are not re-uploaded', () async {
    final progress = <String>[];
    transport = ReconciliationPageTransport(
      temporaryRoot: temporaryRoot,
      onProgress: progress.add,
    );
    final source = _Source(100, 'proof ' * 1024);
    final entry = await _entry(source);
    await transport.upload(cloud, entry, _Store(source));
    final uploaded = cloud.uploadedPages;
    expect(progress.first, 'Preparing ${entry.key}');
    expect(progress.last, 'Publishing ${entry.key} index');
    progress.clear();
    await transport.upload(cloud, entry, _Store(source));
    expect(cloud.uploadedPages, uploaded);
    expect(cloud.writes.last, entry.path);
    final pages = progress.where((message) => message.contains(': pages '));
    expect(pages, isNotEmpty);
    expect(pages.first, contains('pages 0/'));
    expect(
      pages.skip(1).every((message) => message.endsWith('(0 uploaded)')),
      isTrue,
    );
  });

  test('interrupted replacement keeps the previous index readable', () async {
    final previous = _Source(1, 'old proof');
    final oldEntry = await _entry(previous);
    await transport.upload(cloud, oldEntry, _Store(previous));
    final oldRoot = cloud.files[oldEntry.path];
    final replacement = _Source(2, _noise());
    final entry = await _entry(replacement);
    cloud.failPage = cloud.uploadedPages + 2;
    await expectLater(
      transport.upload(cloud, entry, _Store(replacement)),
      throwsStateError,
    );
    expect(cloud.files[entry.path], oldRoot);
    await transport.withDownloadedSource(cloud, oldEntry, (incoming) async {
      expect(
        (await ReconciliationJsonCodec.fingerprint(incoming)).hash,
        oldEntry.hash,
      );
    });
  });

  test(
    'pull pages count completed downloads before checked application',
    () async {
      final source = _Source(100, 'proof ' * 1024);
      final entry = await _entry(source);
      await transport.upload(cloud, entry, _Store(source));
      final pages = _pages(_root(cloud, entry));
      expect(pages.length, greaterThan(1));
      final blockedPath = '${entry.path}.pages/${pages[1]['hash']}.b64';
      final started = Completer<void>();
      final resume = Completer<void>();
      cloud.beforeDownload = (path) async {
        if (path != blockedPath) return;
        started.complete();
        await resume.future;
      };
      final progress = <String>[];
      transport = ReconciliationPageTransport(
        temporaryRoot: temporaryRoot,
        onProgress: progress.add,
      );
      var consumed = false;
      final pending = transport.withDownloadedSource(cloud, entry, (
        incoming,
      ) async {
        consumed = true;
        expect(
          (await ReconciliationJsonCodec.fingerprint(incoming)).hash,
          entry.hash,
        );
      });
      try {
        await started.future.timeout(const Duration(seconds: 10));
        expect(progress.first, 'Pulling ${entry.key} index');
        expect(progress.last, 'Pulling ${entry.key}: pages 1/${pages.length}');
        expect(consumed, isFalse);
        expect(progress, isNot(contains('Applying ${entry.key}')));
      } finally {
        resume.complete();
      }
      await pending;
      expect(consumed, isTrue);
      expect(
        progress,
        contains('Pulling ${entry.key}: pages ${pages.length}/${pages.length}'),
      );
      expect(progress[progress.length - 2], 'Verifying ${entry.key} payload');
      expect(progress.last, 'Applying ${entry.key}');
    },
  );

  test(
    'retirement during the applying phase cannot enter the consumer',
    () async {
      final source = _Source(100, 'proof ' * 1024);
      final entry = await _entry(source);
      await transport.upload(cloud, entry, _Store(source));
      final queue = SyncQueue();
      transport = ReconciliationPageTransport(
        temporaryRoot: temporaryRoot,
        checkActive: queue.captureActiveGuard(),
        onProgress: (message) {
          if (message == 'Applying ${entry.key}') {
            queue.abort();
            queue.reset();
          }
        },
      );
      var consumed = false;
      await expectLater(
        transport.withDownloadedSource(cloud, entry, (_) async {
          consumed = true;
        }),
        throwsStateError,
      );
      expect(consumed, isFalse);
    },
  );

  for (final paged in [false, true]) {
    test(
      'retirement during root publication preserves old root (paged=$paged)',
      () async {
        final previous = _Source(1, 'old proof');
        final oldEntry = await _entry(previous);
        await transport.upload(cloud, oldEntry, _Store(previous));
        final oldRoot = cloud.files[oldEntry.path];
        final replacement = paged
            ? _Source(100, 'replacement proof ' * 1024)
            : _Source(1, 'replacement proof');
        final entry = await _entry(replacement);
        final queue = SyncQueue();
        transport = ReconciliationPageTransport(
          temporaryRoot: temporaryRoot,
          checkActive: queue.captureActiveGuard(),
          onProgress: (message) {
            final publication = paged
                ? 'Publishing ${entry.key} index'
                : 'Pushing ${entry.key}';
            if (message == publication) {
              queue.abort();
              queue.reset();
            }
          },
        );
        await expectLater(
          transport.upload(cloud, entry, _Store(replacement)),
          throwsStateError,
        );
        expect(cloud.files[entry.path], oldRoot);
        expect(cloud.writes.where((path) => path == entry.path), hasLength(1));
        await ReconciliationPageTransport(
          temporaryRoot: temporaryRoot,
        ).withDownloadedSource(cloud, oldEntry, (incoming) async {
          expect(
            (await ReconciliationJsonCodec.fingerprint(incoming)).hash,
            oldEntry.hash,
          );
        });
      },
    );
  }

  test(
    'mutation between fingerprint and export cannot publish stale-hash bytes',
    () async {
      final entry = await _entry(_Source(1, 'old'));
      await expectLater(
        transport.upload(cloud, entry, _Store(_Source(1, 'new'))),
        throwsStateError,
      );
      expect(cloud.files, isEmpty);
      expect(cloud.writes, isEmpty);
    },
  );

  test('legacy plain JSON imports without a staged map re-encode', () async {
    final data = {
      '__reconciliationState': true,
      'schemaVersion': 2,
      'sessionId': _session,
      'runs': <dynamic>[],
    };
    final entry = SyncManifestEntry(
      type: 'reconciliation_state',
      id: _session,
      path: cloudPath('reconciliation_state', _session),
      updatedAt: 1,
      hash: SyncSerialization.computeSyncHash(data),
    );
    cloud.files[entry.path] = jsonEncode(data);
    await transport.withDownloadedSource(cloud, entry, (source) async {
      expect(source.sessionId, _session);
      expect(
        await source.readSection(ReconciliationSection.runs).toList(),
        isEmpty,
      );
    });
    expect(cloud.downloadCalls, [entry.path]);
  });

  test(
    'Abort followed by Reset cannot let an old upload publish its index',
    () async {
      final previous = _Source(1, 'old');
      final oldEntry = await _entry(previous);
      await transport.upload(cloud, oldEntry, _Store(previous));
      final oldRoot = cloud.files[oldEntry.path];
      final queue = SyncQueue();
      final guarded = ReconciliationPageTransport(
        temporaryRoot: temporaryRoot,
        checkActive: queue.captureActiveGuard(),
      );
      cloud.afterUpload = (path) {
        if (path.contains('.pages/')) {
          queue.abort();
          queue.reset();
        }
      };
      final replacement = _Source(1, _noise());
      await expectLater(
        guarded.upload(cloud, await _entry(replacement), _Store(replacement)),
        throwsStateError,
      );
      expect(cloud.files[oldEntry.path], oldRoot);
    },
  );

  test('a reconciliation tombstone removes only its own pages', () async {
    final source = _Source(1, _noise());
    final entry = await _entry(source);
    await transport.upload(cloud, entry, _Store(source));
    cloud.files['${entry.path}-other.pages/unrelated.b64'] = 'other evidence';
    await SyncSerialization.deleteCloudFileIfExists(cloud, entry);
    expect(cloud.files, {
      '${entry.path}-other.pages/unrelated.b64': 'other evidence',
    });
  });

  for (final mutation in [
    'path',
    'order',
    'missing',
    'corrupt',
    'count',
    'size',
    'hash',
    'version',
    'session',
  ]) {
    test(
      '$mutation damage rejects before the repository consumer runs',
      () async {
        final source = _Source(2, _noise());
        final entry = await _entry(source);
        await transport.upload(cloud, entry, _Store(source));
        final root = _root(cloud, entry);
        final pages = _pages(root);
        final path = '${entry.path}.pages/${pages.first['hash']}.b64';
        switch (mutation) {
          case 'path':
            pages.first['hash'] = '../other-session';
          case 'order':
            final first = pages.removeAt(0);
            pages.add(first);
          case 'missing':
            cloud.files.remove(path);
          case 'corrupt':
            final raw = cloud.files[path]!;
            cloud.files[path] =
                '${raw[0] == 'A' ? 'B' : 'A'}${raw.substring(1)}';
          case 'count':
            root['sections'][ReconciliationSection.manifests.index]['count'] =
                5;
          case 'size':
            pages.first['bytes'] = (pages.first['bytes'] as int) - 1;
          case 'hash':
            root['payloadHash'] = '0' * 64;
          case 'version':
            root['version'] = 3;
          case 'session':
            root['id'] = 'other-session';
        }
        cloud.files[entry.path] = jsonEncode(root);
        cloud.downloadCalls.clear();
        final progress = <String>[];
        transport = ReconciliationPageTransport(
          temporaryRoot: temporaryRoot,
          onProgress: progress.add,
        );
        var consumed = false;
        await expectLater(
          transport.withDownloadedSource(cloud, entry, (_) async {
            consumed = true;
          }),
          throwsA(isA<Exception>()),
        );
        expect(consumed, isFalse);
        expect(progress, isNot(contains('Applying ${entry.key}')));
        if (mutation == 'path') expect(cloud.downloadCalls, [entry.path]);
      },
    );
  }

  test(
    'engine uses paged fingerprint, export and import, never the legacy map',
    () async {
      final source = _Source(100, 'unchanged evidence ' * 1024);
      final senderStore = _Store(source);
      final sender = fixtures.SyncWorld(reconciliationStateStore: senderStore);
      await sender.chats.put(fixtures.makeChat(_session));
      final progress = <SyncProgress>[];
      await sender.engine.pushEntities(onProgress: progress.add);
      final pageProgress = progress.where(
        (event) => event.message?.contains(': pages ') ?? false,
      );
      expect(pageProgress, isNotEmpty);
      expect(
        pageProgress.every((event) => event.current < event.total),
        isTrue,
      );
      final publishing = progress.singleWhere(
        (event) =>
            event.message == 'Publishing reconciliation_state:$_session index',
      );
      expect(publishing.current, lessThan(publishing.total));
      final entry = (await sender.manifestProvider.readLocalManifest())
          .entries[entryKey('reconciliation_state', _session)]!;
      expect(
        (jsonDecode(sender.cloud.files[entry.path]!) as Map)['version'],
        2,
      );
      final receiverStore = _Store();
      final receiver = fixtures.SyncWorld(
        reconciliationStateStore: receiverStore,
      );
      receiver.cloud.files.addAll(sender.cloud.files);
      final pullProgress = <SyncProgress>[];
      await receiver.engine.pullEntities(
        onProgress: pullProgress.add,
        onConflict: (_) {},
      );
      final pullingPages = pullProgress.where(
        (event) => event.message?.contains(': pages ') ?? false,
      );
      expect(pullingPages, isNotEmpty);
      expect(
        pullingPages.every((event) => event.current < event.total),
        isTrue,
      );
      final applying = pullProgress.singleWhere(
        (event) => event.message == 'Applying reconciliation_state:$_session',
      );
      expect(applying.current, lessThan(applying.total));
      expect(
        pullProgress.indexOf(applying),
        lessThan(
          pullProgress.indexWhere(
            (event) => event.message == 'Pulled reconciliation_state:$_session',
          ),
        ),
      );
      expect(receiverStore.imports, greaterThan(0));
      expect(receiverStore.imported!.hash, entry.hash);
      expect(
        (await receiver.manifestProvider.readLocalManifest())
            .entries[entry.key]!
            .hash,
        entry.hash,
      );
    },
  );
}
