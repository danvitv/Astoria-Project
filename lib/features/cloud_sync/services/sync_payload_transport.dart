import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../cloud_adapter.dart';
import '../sync_models.dart';

/// Wire encoding only: repositories and manifest hashes still see exact JSON.
/// Immutable, content-addressed parts are uploaded before the small root index.
/// A failed part upload therefore cannot damage the previously published root.
class SyncPayloadTransport {
  static const _compressionThreshold = 512 * 1024;
  static const _chunkBytes = 768 * 1024;
  static const _maxDecodedBytes = 128 * 1024 * 1024;
  static const _maxCompressedBytes = _maxDecodedBytes + _chunkBytes;
  static const _maxChunks = 256;
  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');

  static bool _allowsChunked(SyncManifestEntry entry) =>
      entry.type == 'reconciliation_state' ||
      entry.type == 'tracker_snapshot' ||
      entry.type == 'chat';

  static int _jsonLimit(SyncManifestEntry entry) =>
      _allowsChunked(entry) ? _maxDecodedBytes : maxSyncPayloadBytes;

  /// [checkActive] may throw when the caller no longer owns this sync run.
  static Future<void> upload(
    CloudAdapter adapter,
    SyncManifestEntry entry,
    Map<String, dynamic> data, {
    void Function()? checkActive,
  }) async {
    checkActive?.call();
    final json = jsonEncode(data);
    final bytes = utf8.encode(json);
    if (bytes.length > _jsonLimit(entry)) {
      throw Exception('Payload exceeds limit for ${entry.key}');
    }
    if (entry.type == 'reconciliation_state' &&
        sha256.convert(bytes).toString() != entry.hash) {
      throw StateError('Reconciliation changed during sync; retry the push');
    }
    if (!_allowsChunked(entry) || bytes.length < _compressionThreshold) {
      await adapter.upload(entry.path, json);
      checkActive?.call();
      return;
    }

    // Large gzip work must not block Flutter's UI isolate.
    final compressed = await compress(bytes);
    checkActive?.call();
    if (compressed.isEmpty ||
        compressed.length > _maxCompressedBytes ||
        (compressed.length + _chunkBytes - 1) ~/ _chunkBytes > _maxChunks) {
      throw StateError('Compressed payload exceeds limit for ${entry.key}');
    }
    final chunks = <Map<String, dynamic>>[];
    for (var offset = 0; offset < compressed.length; offset += _chunkBytes) {
      final part = Uint8List.sublistView(
        compressed,
        offset,
        min(offset + _chunkBytes, compressed.length),
      );
      final hash = sha256.convert(part).toString();
      chunks.add({'hash': hash, 'bytes': part.length});
    }
    final root = jsonEncode({
      '__syncPayload': true,
      'version': 1,
      'encoding': 'gzip+base64-chunks',
      'type': entry.type,
      'id': entry.id,
      'jsonBytes': bytes.length,
      'compressedBytes': compressed.length,
      'payloadHash': sha256.convert(bytes).toString(),
      'chunks': chunks,
    });
    if (utf8.encode(root).length > maxSyncPayloadBytes) {
      throw StateError('Payload index exceeds limit for ${entry.key}');
    }
    await adapter.ensureFolder('${entry.path}.parts');
    checkActive?.call();
    for (var index = 0; index < chunks.length; index++) {
      final offset = index * _chunkBytes;
      final part = Uint8List.sublistView(
        compressed,
        offset,
        min(offset + _chunkBytes, compressed.length),
      );
      await adapter.upload(
        _partPath(entry, chunks[index]['hash'] as String),
        base64Encode(part),
      );
      checkActive?.call();
    }
    // Do not delete old parts here: another device may still be reading an old
    // root, and concurrent writers may be preparing their own immutable parts.
    await adapter.upload(entry.path, root);
    checkActive?.call();
  }

  static Future<Map<String, dynamic>> download(
    CloudAdapter adapter,
    SyncManifestEntry entry, {
    String? rawPayload,
  }) async {
    final raw = rawPayload ?? await adapter.download(entry.path);
    if (raw.isEmpty) throw StateError('Empty cloud entity: ${entry.key}');
    // The aggregate budget does not relax the limit on any physical file,
    // including legacy uncompressed chat and reconciliation documents.
    if (raw.length > maxSyncPayloadBytes ||
        utf8.encode(raw).length > maxSyncPayloadBytes) {
      throw FormatException('Cloud payload exceeds limit for ${entry.key}');
    }
    final root = jsonDecode(raw);
    if (root is! Map<String, dynamic>) {
      throw const FormatException('Cloud entity must be a JSON object');
    }
    if (!root.containsKey('__syncPayload')) return root;
    return _downloadParts(adapter, entry, root);
  }

  static Future<Map<String, dynamic>> _downloadParts(
    CloudAdapter adapter,
    SyncManifestEntry entry,
    Map<String, dynamic> root,
  ) async {
    final jsonBytes = root['jsonBytes'];
    final compressedBytes = root['compressedBytes'];
    final payloadHash = root['payloadHash'];
    final descriptors = root['chunks'];
    if (!_allowsChunked(entry) ||
        root['__syncPayload'] != true ||
        root['version'] != 1 ||
        root['encoding'] != 'gzip+base64-chunks' ||
        root['type'] != entry.type ||
        root['id'] != entry.id ||
        jsonBytes is! int ||
        jsonBytes <= 0 ||
        jsonBytes > _maxDecodedBytes ||
        compressedBytes is! int ||
        compressedBytes <= 0 ||
        compressedBytes > _maxCompressedBytes ||
        payloadHash is! String ||
        !_hashPattern.hasMatch(payloadHash) ||
        descriptors is! List ||
        descriptors.isEmpty ||
        descriptors.length > _maxChunks) {
      throw const FormatException('Invalid chunked sync payload index');
    }
    // Validate every descriptor before issuing any cloud request. The index
    // cannot choose arbitrary paths or allocate an unbounded decoded buffer.
    var expectedCompressedBytes = 0;
    for (final descriptor in descriptors) {
      if (descriptor is! Map ||
          descriptor['hash'] is! String ||
          !_hashPattern.hasMatch(descriptor['hash'] as String) ||
          descriptor['bytes'] is! int ||
          (descriptor['bytes'] as int) <= 0 ||
          (descriptor['bytes'] as int) > _chunkBytes) {
        throw const FormatException('Invalid sync payload part descriptor');
      }
      expectedCompressedBytes += descriptor['bytes'] as int;
    }
    if (expectedCompressedBytes != compressedBytes) {
      throw const FormatException('Sync payload compressed size mismatch');
    }

    final output = _BoundedPayloadSink(jsonBytes);
    final decoder = gzip.decoder.startChunkedConversion(output);
    try {
      for (final descriptor in descriptors) {
        final hash = descriptor['hash'] as String;
        final size = descriptor['bytes'] as int;
        final encoded = await adapter.download(_partPath(entry, hash));
        if (encoded.length != ((size + 2) ~/ 3) * 4) {
          throw const FormatException(
            'Sync payload part encoded size mismatch',
          );
        }
        final part = base64Decode(encoded);
        if (part.length != size || sha256.convert(part).toString() != hash) {
          throw const FormatException('Sync payload part fingerprint mismatch');
        }
        decoder.add(part);
      }
      decoder.close();
    } catch (_) {
      // Release the zlib stream even after a missing or corrupt part. A close
      // on truncated input may fail too; preserve the original failure.
      try {
        decoder.close();
      } catch (_) {}
      rethrow;
    }
    final bytes = output.takeBytes();
    if (bytes.length != jsonBytes ||
        sha256.convert(bytes).toString() != payloadHash) {
      throw const FormatException('Decoded sync payload fingerprint mismatch');
    }
    final data = jsonDecode(utf8.decode(bytes));
    if (data is! Map<String, dynamic> || data.containsKey('__syncPayload')) {
      throw const FormatException('Invalid decoded sync entity');
    }
    return data;
  }

  static String _partPath(SyncManifestEntry entry, String hash) =>
      '${entry.path}.parts/$hash.b64';

  static Future<Uint8List> compress(List<int> bytes) =>
      Isolate.run(() => Uint8List.fromList(gzip.encode(bytes)));

  static Uint8List decompress(List<int> bytes, int expectedBytes) {
    final output = _BoundedPayloadSink(expectedBytes);
    final decoder = gzip.decoder.startChunkedConversion(output);
    try {
      decoder.add(bytes);
      decoder.close();
    } catch (_) {
      try {
        decoder.close();
      } catch (_) {}
      rethrow;
    }
    final decoded = output.takeBytes();
    if (decoded.length != expectedBytes) {
      throw const FormatException('Decoded sync page size mismatch');
    }
    return decoded;
  }
}

/// Checks the size as gzip emits bytes, not after allocating the whole output.
class _BoundedPayloadSink extends ByteConversionSinkBase {
  _BoundedPayloadSink(this.limit);

  final int limit;
  final _bytes = BytesBuilder(copy: false);
  int _length = 0;

  @override
  void add(List<int> chunk) {
    if (chunk.length > limit - _length) {
      throw const FormatException('Decoded sync payload exceeds declared size');
    }
    _length += chunk.length;
    _bytes.add(chunk);
  }

  @override
  void close() {}

  Uint8List takeBytes() => _bytes.takeBytes();
}
