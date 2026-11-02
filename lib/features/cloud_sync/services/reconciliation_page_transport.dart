import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../../../core/application/sync_reconciliation_source.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';
import 'reconciliation_staging.dart';
import 'sync_payload_transport.dart';

/// Pages are independent gzip streams of section NDJSON. A record may span
/// pages, so the per-file/page budgets do not cap the size of the entire journal.
class ReconciliationPageTransport {
  const ReconciliationPageTransport({
    this.temporaryRoot,
    this.checkActive,
    this.onProgress,
  });

  static const pageBytes = 512 * 1024;
  static const _maxCompressedBytes = pageBytes + 8192;
  static const _maxIndexBytes = 8 * 1024 * 1024;
  static const _maxPages = 32768;
  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');
  final Directory? temporaryRoot;
  final void Function()? checkActive;
  final void Function(String)? onProgress;

  Future<void> upload(
    CloudAdapter adapter,
    SyncManifestEntry entry,
    SyncPagedReconciliationStateStore store,
  ) async {
    checkActive?.call();
    onProgress?.call('Preparing ${entry.key}');
    final staging = await store.withExportSnapshot(
      entry.id,
      (source) => ReconciliationStaging.capture(
        _GuardedSource(source, checkActive),
        temporaryRoot: temporaryRoot,
      ),
    );
    if (staging == null) return;
    try {
      checkActive?.call();
      if (staging.fingerprint.hash != entry.hash) {
        throw StateError('Reconciliation changed during sync; retry the push');
      }
      if (staging.fingerprint.jsonBytes < 512 * 1024) {
        // Small journals retain the legacy wire format and bounded allocation.
        final bytes = BytesBuilder(copy: false);
        await for (final chunk in ReconciliationJsonCodec.encode(
          _GuardedSource(staging, checkActive),
        )) {
          bytes.add(chunk);
        }
        checkActive?.call();
        onProgress?.call('Pushing ${entry.key}');
        await adapter.upload(entry.path, utf8.decode(bytes.takeBytes()));
        return;
      }
      await adapter.ensureFolder('${entry.path}.pages');
      checkActive?.call();
      final existing = await _publishedPageNames(adapter, entry);
      checkActive?.call();
      var totalPages = 0;
      for (final section in ReconciliationSection.values) {
        final length = await staging.file(section).length();
        checkActive?.call();
        totalPages += (length + pageBytes - 1) ~/ pageBytes;
      }
      onProgress?.call('Pushing ${entry.key}: pages 0/$totalPages');
      final sections = <Map<String, dynamic>>[];
      var pageCount = 0;
      var uploadedPages = 0;
      for (final section in ReconciliationSection.values) {
        final pages = <Map<String, dynamic>>[];
        await for (final page in _pages(staging.file(section))) {
          checkActive?.call();
          if (++pageCount > _maxPages) {
            throw const FormatException(
              'Reconciliation page count exceeds budget',
            );
          }
          final compressed = await SyncPayloadTransport.compress(page);
          checkActive?.call();
          if (compressed.length > _maxCompressedBytes) {
            throw const FormatException(
              'Compressed reconciliation page too large',
            );
          }
          final hash = sha256.convert(compressed).toString();
          final name = '$hash.b64';
          if (existing.add(name)) {
            await adapter.upload(
              _pagePath(entry, hash),
              base64Encode(compressed),
            );
            checkActive?.call();
            uploadedPages++;
          }
          pages.add({
            'hash': hash,
            'bytes': page.length,
            'compressedBytes': compressed.length,
          });
          onProgress?.call(
            'Pushing ${entry.key}: pages $pageCount/$totalPages '
            '($uploadedPages uploaded)',
          );
        }
        sections.add({
          'name': section.name,
          'count': staging.counts[section],
          'pages': pages,
        });
      }
      final root = jsonEncode({
        '__syncPayload': true,
        'version': 2,
        'encoding': 'gzip+base64-pages',
        'type': entry.type,
        'id': entry.id,
        'schemaVersion': staging.schemaVersion,
        'payloadHash': staging.fingerprint.hash,
        'jsonBytes': staging.fingerprint.jsonBytes,
        'sections': sections,
      });
      if (utf8.encode(root).length > _maxIndexBytes) {
        throw const FormatException('Reconciliation page index exceeds budget');
      }
      // All immutable pages exist first; never remove pages an old reader needs.
      checkActive?.call();
      onProgress?.call('Publishing ${entry.key} index');
      await adapter.upload(entry.path, root);
    } finally {
      await staging.dispose();
    }
  }

  Future<T> withDownloadedSource<T>(
    CloudAdapter adapter,
    SyncManifestEntry entry,
    Future<T> Function(ReconciliationStateSource source) consume,
  ) async {
    checkActive?.call();
    final raw = await adapter.download(entry.path);
    checkActive?.call();
    if (raw.length > maxSyncPayloadBytes ||
        utf8.encode(raw).length > maxSyncPayloadBytes) {
      throw const FormatException('Cloud reconciliation file exceeds limit');
    }
    final decoded = jsonDecode(raw);
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('Invalid reconciliation root');
    }
    if (decoded['__syncPayload'] != true || decoded['version'] == 1) {
      final data = decoded['__syncPayload'] == true
          ? await SyncPayloadTransport.download(adapter, entry, rawPayload: raw)
          : decoded;
      if (data['__reconciliationState'] != true ||
          data['sessionId'] != entry.id ||
          (data['schemaVersion'] != 1 && data['schemaVersion'] != 2)) {
        throw const FormatException('Invalid legacy reconciliation payload');
      }
      checkActive?.call();
      return consume(
        _GuardedSource(MapReconciliationStateSource(data), checkActive),
      );
    }
    if (utf8.encode(raw).length > _maxIndexBytes) {
      throw const FormatException('Reconciliation page index exceeds budget');
    }
    final sections = _validateIndex(entry, decoded);
    final staging = await ReconciliationStaging.create(
      entry.id,
      decoded['schemaVersion'] as int,
      temporaryRoot: temporaryRoot,
    );
    try {
      var totalRows = 0;
      for (var index = 0; index < sections.length; index++) {
        final section = ReconciliationSection.values[index];
        final descriptor = sections[index];
        final output = await staging.file(section).open(mode: FileMode.write);
        try {
          for (final page in descriptor['pages'] as List) {
            checkActive?.call();
            final encoded = await adapter.download(
              _pagePath(entry, page['hash'] as String),
            );
            checkActive?.call();
            final compressedBytes = page['compressedBytes'] as int;
            if (encoded.length != ((compressedBytes + 2) ~/ 3) * 4) {
              throw const FormatException('Reconciliation page size mismatch');
            }
            final compressed = base64Decode(encoded);
            if (compressed.length != compressedBytes ||
                sha256.convert(compressed).toString() != page['hash']) {
              throw const FormatException('Reconciliation page hash mismatch');
            }
            final bytes = SyncPayloadTransport.decompress(
              compressed,
              page['bytes'] as int,
            );
            await output.writeFrom(bytes);
          }
        } finally {
          await output.close();
        }
        var count = 0;
        await for (final _ in _GuardedSource(
          staging,
          checkActive,
        ).readSection(section)) {
          count++;
          if (++totalRows > ReconciliationStaging.maxRows ||
              (section == ReconciliationSection.runs &&
                  count > ReconciliationJsonCodec.maxRunRows)) {
            throw const FormatException('Too many reconciliation records');
          }
        }
        if (count != descriptor['count']) {
          throw const FormatException('Reconciliation section count mismatch');
        }
        staging.counts[section] = count;
      }
      await staging.verifyFingerprint(
        decoded['payloadHash'] as String,
        decoded['jsonBytes'] as int,
      );
      // Domain writes only start after every page and the whole logical hash
      // have been checked. Network failure never leaves a half-imported lane.
      checkActive?.call();
      return await consume(_GuardedSource(staging, checkActive));
    } finally {
      await staging.dispose();
    }
  }

  static List<Map<String, dynamic>> _validateIndex(
    SyncManifestEntry entry,
    Map<String, dynamic> root,
  ) {
    final hash = root['payloadHash'];
    final size = root['jsonBytes'];
    final sections = root['sections'];
    if (entry.type != 'reconciliation_state' ||
        root['version'] != 2 ||
        root['encoding'] != 'gzip+base64-pages' ||
        root['type'] != entry.type ||
        root['id'] != entry.id ||
        root['schemaVersion'] != 2 ||
        hash is! String ||
        !_hashPattern.hasMatch(hash) ||
        size is! int ||
        size <= 0 ||
        size > ReconciliationStaging.maxStagingBytes ||
        sections is! List ||
        sections.length != ReconciliationSection.values.length) {
      throw const FormatException('Invalid reconciliation page index');
    }
    final result = <Map<String, dynamic>>[];
    var bytes = 0;
    var count = 0;
    var rows = 0;
    for (var index = 0; index < sections.length; index++) {
      final section = sections[index];
      if (section is! Map<String, dynamic> ||
          section['name'] != ReconciliationSection.values[index].name ||
          section['count'] is! int ||
          (section['count'] as int) < 0 ||
          section['pages'] is! List) {
        throw const FormatException('Invalid reconciliation section index');
      }
      rows += section['count'] as int;
      if (rows > ReconciliationStaging.maxRows ||
          (index == 0 &&
              (section['count'] as int) > ReconciliationJsonCodec.maxRunRows)) {
        throw const FormatException('Too many reconciliation records');
      }
      final pages = section['pages'] as List;
      if ((section['count'] == 0) != pages.isEmpty) {
        throw const FormatException('Invalid empty reconciliation section');
      }
      for (final page in pages) {
        if (++count > _maxPages ||
            page is! Map ||
            page['hash'] is! String ||
            !_hashPattern.hasMatch(page['hash'] as String) ||
            page['bytes'] is! int ||
            (page['bytes'] as int) <= 0 ||
            (page['bytes'] as int) > pageBytes ||
            page['compressedBytes'] is! int ||
            (page['compressedBytes'] as int) <= 0 ||
            (page['compressedBytes'] as int) > _maxCompressedBytes) {
          throw const FormatException('Invalid reconciliation page descriptor');
        }
        bytes += page['bytes'] as int;
        if (bytes > ReconciliationStaging.maxStagingBytes) {
          throw const FormatException('Reconciliation staging exceeds budget');
        }
      }
      result.add(section);
    }
    return result;
  }

  static String _pagePath(SyncManifestEntry entry, String hash) =>
      '${entry.path}.pages/$hash.b64';

  Future<Set<String>> _publishedPageNames(
    CloudAdapter adapter,
    SyncManifestEntry entry,
  ) async {
    // Never list all historical versions: that namespace grows without bound.
    // Only a bounded, successfully published index can supply reusable parts.
    String raw;
    try {
      raw = await adapter.download(entry.path);
    } on CloudFileNotFoundException {
      return {};
    }
    checkActive?.call();
    if (raw.length > _maxIndexBytes ||
        utf8.encode(raw).length > _maxIndexBytes) {
      return {};
    }
    try {
      final root = jsonDecode(raw);
      if (root is! Map<String, dynamic> ||
          root['__syncPayload'] != true ||
          root['version'] != 2) {
        return {};
      }
      return {
        for (final section in _validateIndex(entry, root))
          for (final page in section['pages'] as List) '${page['hash']}.b64',
      };
    } on FormatException {
      // A broken index supplies no reuse evidence. Republish all local pages.
      return {};
    }
  }

  static Stream<Uint8List> _pages(File file) async* {
    var page = BytesBuilder(copy: false);
    await for (final chunk in file.openRead()) {
      var offset = 0;
      while (offset < chunk.length) {
        final available = pageBytes - page.length;
        final end = (offset + available).clamp(0, chunk.length);
        page.add(chunk.sublist(offset, end));
        offset = end;
        if (page.length == pageBytes) {
          yield page.takeBytes();
        }
      }
    }
    if (page.isNotEmpty) yield page.takeBytes();
  }
}

class _GuardedSource
    implements ReconciliationStateSource, ReconciliationSourceGuard {
  const _GuardedSource(this.source, this.checkActive);
  final ReconciliationStateSource source;
  final void Function()? checkActive;
  @override
  void checkCurrent() => checkActive?.call();
  @override
  String get sessionId => source.sessionId;
  @override
  int get schemaVersion => source.schemaVersion;
  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    checkActive?.call();
    await for (final row in source.readSection(section)) {
      checkActive?.call();
      yield row;
    }
    checkActive?.call();
  }
}
