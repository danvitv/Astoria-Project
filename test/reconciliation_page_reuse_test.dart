import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/application/sync_reconciliation_source.dart';
import 'package:glaze_flutter/features/cloud_sync/services/reconciliation_page_transport.dart';
import 'package:glaze_flutter/features/cloud_sync/sync_models.dart';

import 'sync_lifecycle_test.dart' as fixtures;

const _session = 'cross-platform-page-reuse';
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
  _JournalStore(this.source);

  final ReconciliationStateSource source;

  @override
  Future<List<String>> getAllSessionIds() async => [source.sessionId];

  @override
  Future<bool> hasBySessionId(String sessionId) async =>
      sessionId == source.sessionId;

  @override
  Future<Map<String, dynamic>?> getBySessionId(String sessionId) =>
      throw StateError('Paged export must not assemble the legacy map');

  @override
  Future<ReconciliationFingerprint?> fingerprintBySessionId(
    String sessionId,
  ) async => sessionId == source.sessionId
      ? ReconciliationJsonCodec.fingerprint(source)
      : null;

  @override
  Future<T?> withExportSnapshot<T>(
    String sessionId,
    Future<T> Function(ReconciliationStateSource source) consume,
  ) async => sessionId == source.sessionId ? consume(source) : null;

  @override
  Future<void> mergeFromSource(
    String sessionId,
    ReconciliationStateSource source,
  ) => throw StateError('These transport fixtures only export snapshots');
}

class _RecordingCloud extends fixtures.FakeCloudAdapter {
  final attempts = <String>[];
  final writes = <String>[];
  int pageAttempts = 0;
  int? failPageAttempt;

  void clearWrites() {
    attempts.clear();
    writes.clear();
    pageAttempts = 0;
    failPageAttempt = null;
  }

  @override
  Future<void> upload(String path, String data) async {
    attempts.add(path);
    if (path.contains('.pages/') && ++pageAttempts == failPageAttempt) {
      throw StateError('Interrupted replacement page upload');
    }
    await super.upload(path, data);
    writes.add(path);
  }

  @override
  Future<void> uploadBinary(String path, Uint8List data) async {
    attempts.add(path);
    await super.uploadBinary(path, data);
    writes.add(path);
  }
}

// Each NDJSON row is exactly half a page. Five rows leave two full prefix
// pages and a half-page tail; appending two rows changes only that tail and
// adds one page. Distinct deterministic noise prevents accidental duplicates.
Map<String, dynamic> _manifestRow(int index) {
  final row = <String, dynamic>{
    'messageId': 'message-${index.toString().padLeft(3, '0')}',
    'manifestJson': '',
  };
  final overhead = utf8.encode(jsonEncode(row)).length + 1;
  final textLength = _rowBytes - overhead;
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

String _pagePath(SyncManifestEntry entry, String hash) =>
    '${entry.path}.pages/$hash.b64';

Map<String, dynamic> _root(_RecordingCloud cloud, SyncManifestEntry entry) =>
    jsonDecode(cloud.files[entry.path]!) as Map<String, dynamic>;

List<Map<String, dynamic>> _manifestPages(Map<String, dynamic> root) {
  final sections = (root['sections'] as List).cast<Map<String, dynamic>>();
  final section = sections[ReconciliationSection.manifests.index];
  expect(section['name'], 'manifests');
  return (section['pages'] as List).cast<Map<String, dynamic>>();
}

List<String> _pagePaths(
  SyncManifestEntry entry,
  Iterable<Map<String, dynamic>> pages,
) => [for (final page in pages) _pagePath(entry, page['hash'] as String)];

// Independent, bounded oracle for NDJSON slicing and canonical gzip hashes.
// It does not call transport-private helpers or its compression implementation.
Future<List<Map<String, dynamic>>> _canonicalPages(
  ReconciliationStateSource source,
) async {
  final ndjson = BytesBuilder(copy: false);
  await for (final row in source.readSection(ReconciliationSection.manifests)) {
    ndjson.add(ReconciliationJsonCodec.encodeRow(row));
    ndjson.addByte(10);
  }
  final bytes = ndjson.takeBytes();
  final pages = <Map<String, dynamic>>[];
  for (
    var offset = 0;
    offset < bytes.length;
    offset += ReconciliationPageTransport.pageBytes
  ) {
    final page = Uint8List.sublistView(
      bytes,
      offset,
      min(offset + ReconciliationPageTransport.pageBytes, bytes.length),
    );
    final compressed = Uint8List.fromList(gzip.encode(page));
    compressed[9] = 255;
    pages.add({
      'hash': sha256.convert(compressed).toString(),
      'bytes': page.length,
      'compressedBytes': compressed.length,
    });
  }
  return pages;
}

// Emulate an already-published Android/Linux (3), Windows (10), Apple (19),
// or canonical (255) snapshot on any host. Only the gzip OS byte and the
// content-addressed names change; the compressed body and logical root hash do
// not. Remove the original fixture names so reuse cannot find native aliases.
void _rewritePublishedOs(
  _RecordingCloud cloud,
  SyncManifestEntry entry,
  int os,
) {
  final root = _root(cloud, entry);
  expect(root['version'], 2);
  expect(root['encoding'], 'gzip+base64-pages');
  expect(root['payloadHash'], entry.hash);
  final pages = _manifestPages(root);
  final originalPaths = _pagePaths(entry, pages);
  final replacements = <String, String>{};
  for (final page in pages) {
    final compressed = base64Decode(
      cloud.files[_pagePath(entry, page['hash'] as String)]!,
    );
    expect(compressed.take(3).toList(), [31, 139, 8]);
    final original = Uint8List.fromList(compressed);
    compressed[9] = os;
    expect(compressed.sublist(0, 9), original.sublist(0, 9));
    expect(compressed.sublist(10), original.sublist(10));
    final hash = sha256.convert(compressed).toString();
    page['hash'] = hash;
    replacements[_pagePath(entry, hash)] = base64Encode(compressed);
  }
  for (final path in originalPaths) {
    cloud.files.remove(path);
  }
  cloud.files.addAll(replacements);
  cloud.files[entry.path] = jsonEncode(root);
}

void _expectCanonicalWrites(_RecordingCloud cloud, SyncManifestEntry entry) {
  for (final path in cloud.writes.where((path) => path != entry.path)) {
    final compressed = base64Decode(cloud.files[path]!);
    expect(compressed[9], 255, reason: 'New page gzip OS must be canonical');
    expect(
      path,
      _pagePath(entry, sha256.convert(compressed).toString()),
      reason: 'The filename must hash the actual canonical compressed bytes',
    );
  }
}

void _expectImmutableFilesPreserved(
  _RecordingCloud cloud,
  SyncManifestEntry entry,
  Map<String, String> previous,
  Iterable<String> newPaths,
) {
  for (final file in previous.entries.where((file) => file.key != entry.path)) {
    expect(cloud.files[file.key], file.value);
  }
  expect(
    cloud.files.keys.toSet(),
    {...previous.keys, ...newPaths},
    reason: 'Reuse must not rename, delete, or upload aliases of old pages',
  );
}

Future<void> _expectReplay(
  ReconciliationPageTransport transport,
  _RecordingCloud cloud,
  SyncManifestEntry entry,
  ReconciliationStateSource expected,
) async {
  final expectedFingerprint = await ReconciliationJsonCodec.fingerprint(
    expected,
  );
  await transport.withDownloadedSource(cloud, entry, (incoming) async {
    expect(incoming.sessionId, expected.sessionId);
    expect(incoming.schemaVersion, expected.schemaVersion);
    final actual = await ReconciliationJsonCodec.fingerprint(incoming);
    expect(actual.hash, entry.hash);
    expect(actual.hash, expectedFingerprint.hash);
    expect(actual.jsonBytes, expectedFingerprint.jsonBytes);
    for (final section in ReconciliationSection.values) {
      expect(
        await incoming.readSection(section).toList(),
        await expected.readSection(section).toList(),
        reason: '${section.name} must replay exactly across page boundaries',
      );
    }
  });
}

void main() {
  late List<Map<String, dynamic>> rows;
  late Directory temporaryRoot;
  late ReconciliationPageTransport transport;
  late _RecordingCloud cloud;

  setUpAll(() {
    rows = List.generate(7, _manifestRow);
  });

  setUp(() async {
    final local = Platform.environment['LOCALAPPDATA'];
    final parent = local == null
        ? Directory('${Directory.systemTemp.path}/opencode')
        : Directory('$local/Temp/opencode');
    await parent.create(recursive: true);
    temporaryRoot = await parent.createTemp('reconciliation-page-reuse-');
    transport = ReconciliationPageTransport(temporaryRoot: temporaryRoot);
    cloud = _RecordingCloud();
  });

  tearDown(() async {
    try {
      expect(await temporaryRoot.list().toList(), isEmpty);
    } finally {
      await temporaryRoot.delete(recursive: true);
    }
  });

  test('new v2 pages hash the canonical gzip OS header', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await _entry(source);
    final expectedPages = await _canonicalPages(source);

    await transport.upload(cloud, entry, _JournalStore(source));

    final root = _root(cloud, entry);
    expect(root['version'], 2);
    expect(root['encoding'], 'gzip+base64-pages');
    expect(root['payloadHash'], entry.hash);
    expect(_manifestPages(root), expectedPages);
    expect(cloud.writes, [..._pagePaths(entry, expectedPages), entry.path]);
    expect(cloud.attempts, cloud.writes);
    _expectCanonicalWrites(cloud, entry);
    expect(cloud.listFolderCalls, isEmpty);
    await _expectReplay(transport, cloud, entry, source);
  });

  for (final os in [3, 10, 19, 255]) {
    final label = os == 255 ? 'canonical' : 'legacy OS $os';
    test('$label prefix pages survive append without reupload', () async {
      final previous = _JournalSource(rows.take(5).toList());
      final oldEntry = await _entry(previous);
      await transport.upload(cloud, oldEntry, _JournalStore(previous));
      _rewritePublishedOs(cloud, oldEntry, os);
      await _expectReplay(transport, cloud, oldEntry, previous);
      final oldPages = _manifestPages(_root(cloud, oldEntry));
      expect(oldPages, hasLength(3));
      final oldFiles = Map<String, String>.from(cloud.files);
      cloud.clearWrites();

      final replacement = _JournalSource(rows);
      final entry = await _entry(replacement);
      expect(entry.hash, isNot(oldEntry.hash));
      final canonical = await _canonicalPages(replacement);
      expect(canonical, hasLength(4));
      final expectedPages = [...oldPages.take(2), ...canonical.skip(2)];
      final newPaths = _pagePaths(entry, canonical.skip(2));

      await transport.upload(cloud, entry, _JournalStore(replacement));

      final root = _root(cloud, entry);
      expect(root['payloadHash'], entry.hash);
      expect(_manifestPages(root), expectedPages);
      expect(
        (root['sections']
            as List)[ReconciliationSection.manifests.index]['count'],
        7,
      );
      expect(cloud.writes, [...newPaths, entry.path]);
      expect(cloud.attempts, cloud.writes);
      final oldHashes = oldPages.map((page) => page['hash']).toSet();
      final newHashes = _manifestPages(
        root,
      ).map((page) => page['hash']).toSet().difference(oldHashes);
      expect(newHashes, canonical.skip(2).map((page) => page['hash']).toSet());
      _expectCanonicalWrites(cloud, entry);
      _expectImmutableFilesPreserved(cloud, entry, oldFiles, newPaths);
      expect(cloud.listFolderCalls, isEmpty);
      await _expectReplay(transport, cloud, entry, replacement);
    });
  }

  for (final os in [3, 10, 19]) {
    test('same source under legacy OS $os reuses every page', () async {
      final source = _JournalSource(rows.take(5).toList());
      final entry = await _entry(source);
      await transport.upload(cloud, entry, _JournalStore(source));
      _rewritePublishedOs(cloud, entry, os);
      final previous = Map<String, String>.from(cloud.files);
      cloud.clearWrites();

      await transport.upload(cloud, entry, _JournalStore(source));

      // The engine skips unchanged entity tasks. A direct transport call still
      // republishes its small root; only immutable page uploads must be skipped.
      expect(cloud.attempts, [entry.path]);
      expect(cloud.writes, [entry.path]);
      expect(cloud.files, previous);
      expect(cloud.listFolderCalls, isEmpty);
      await _expectReplay(transport, cloud, entry, source);
    });
  }

  test('interrupted foreign-root replacement keeps the old journal', () async {
    final previous = _JournalSource(rows.take(5).toList());
    final oldEntry = await _entry(previous);
    await transport.upload(cloud, oldEntry, _JournalStore(previous));
    _rewritePublishedOs(cloud, oldEntry, 3);
    final oldFiles = Map<String, String>.from(cloud.files);
    cloud.clearWrites();
    cloud.failPageAttempt = 2;

    final replacement = _JournalSource(rows);
    final entry = await _entry(replacement);
    final canonical = await _canonicalPages(replacement);
    final newPaths = _pagePaths(entry, canonical.skip(2));

    await expectLater(
      transport.upload(cloud, entry, _JournalStore(replacement)),
      throwsStateError,
    );

    expect(cloud.attempts, newPaths);
    expect(cloud.writes, [newPaths.first]);
    expect(cloud.files[entry.path], oldFiles[entry.path]);
    expect(cloud.files.containsKey(newPaths.last), isFalse);
    _expectCanonicalWrites(cloud, entry);
    _expectImmutableFilesPreserved(cloud, entry, oldFiles, [newPaths.first]);
    await _expectReplay(transport, cloud, oldEntry, previous);
  });

  test('different page content is not mistaken for an OS variant', () async {
    final previous = _JournalSource(rows.take(5).toList());
    final oldEntry = await _entry(previous);
    await transport.upload(cloud, oldEntry, _JournalStore(previous));
    _rewritePublishedOs(cloud, oldEntry, 19);
    final oldPages = _manifestPages(_root(cloud, oldEntry));
    final oldFiles = Map<String, String>.from(cloud.files);
    cloud.clearWrites();

    final changedRows = rows.take(5).toList();
    final text = changedRows.first['manifestJson'] as String;
    changedRows[0] = {
      ...changedRows.first,
      'manifestJson': '${text[0] == 'A' ? 'B' : 'A'}${text.substring(1)}',
    };
    final replacement = _JournalSource(changedRows);
    final oldFingerprint = await ReconciliationJsonCodec.fingerprint(previous);
    final newFingerprint = await ReconciliationJsonCodec.fingerprint(
      replacement,
    );
    expect(newFingerprint.jsonBytes, oldFingerprint.jsonBytes);
    expect(newFingerprint.hash, isNot(oldFingerprint.hash));
    final entry = await _entry(replacement);
    final canonical = await _canonicalPages(replacement);
    final expectedPages = [canonical.first, ...oldPages.skip(1)];
    final newPaths = _pagePaths(entry, canonical.take(1));

    await transport.upload(cloud, entry, _JournalStore(replacement));

    expect(_manifestPages(_root(cloud, entry)), expectedPages);
    expect(cloud.writes, [...newPaths, entry.path]);
    expect(cloud.attempts, cloud.writes);
    expect(
      canonical.first['hash'],
      isNot(isIn(oldPages.map((page) => page['hash']))),
    );
    _expectCanonicalWrites(cloud, entry);
    _expectImmutableFilesPreserved(cloud, entry, oldFiles, newPaths);
    await _expectReplay(transport, cloud, entry, replacement);
  });

  test('invalid published index cannot supply reuse evidence', () async {
    final source = _JournalSource(rows.take(5).toList());
    final entry = await _entry(source);
    await transport.upload(cloud, entry, _JournalStore(source));
    _rewritePublishedOs(cloud, entry, 10);
    final root = _root(cloud, entry);
    _manifestPages(root).first['bytes'] =
        ReconciliationPageTransport.pageBytes + 1;
    cloud.files[entry.path] = jsonEncode(root);
    final previous = Map<String, String>.from(cloud.files);
    cloud.clearWrites();
    final canonical = await _canonicalPages(source);
    final newPaths = _pagePaths(entry, canonical);

    await transport.upload(cloud, entry, _JournalStore(source));

    expect(_manifestPages(_root(cloud, entry)), canonical);
    expect(cloud.writes, [...newPaths, entry.path]);
    expect(cloud.attempts, cloud.writes);
    _expectCanonicalWrites(cloud, entry);
    _expectImmutableFilesPreserved(cloud, entry, previous, newPaths);
    expect(cloud.listFolderCalls, isEmpty);
    await _expectReplay(transport, cloud, entry, source);
  });
}
