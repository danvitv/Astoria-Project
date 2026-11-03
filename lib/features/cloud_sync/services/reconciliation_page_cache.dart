import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Disposable compressed pages, never an accepted manifest. Callers must still
/// verify gzip sizes, section counts and the whole logical payload hash.
class ReconciliationPageCache {
  ReconciliationPageCache(
    this.root, {
    this.maxBytes = 256 * 1024 * 1024,
    this.maxEntries = 2048,
  }) {
    if (maxBytes < 0 || maxEntries < 0) {
      throw ArgumentError('Negative reconciliation cache budget');
    }
  }

  static const maxPageBytes = 512 * 1024 + 8192;
  static final _hashPattern = RegExp(r'^[a-f0-9]{64}$');
  static final _filePattern = RegExp(r'^([a-f0-9]{64})\.page$');
  final Directory root;
  final int maxBytes;
  final int maxEntries;
  final _entries = <String, _CachedPage>{};
  Future<void> _pending = Future<void>.value();
  var _initialized = false;
  var _unavailable = false;
  var _bytes = 0;
  var _tick = 0;

  Future<T> _serialized<T>(Future<T> Function() action) {
    final result = _pending.then((_) => action());
    _pending = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  /// Disk errors are a miss; admission failures must propagate, not retry cloud.
  Future<Uint8List?> read(
    String hash,
    int expectedBytes, {
    void Function()? checkActive,
  }) => _serialized(() async {
    checkActive?.call();
    if (!_valid(hash, expectedBytes) || maxEntries == 0 || maxBytes == 0) {
      return null;
    }
    try {
      await _initialize(checkActive);
      checkActive?.call();
      if (_unavailable) return null;
      return await _read(hash, expectedBytes, checkActive);
    } on FileSystemException {
      checkActive?.call();
      return null;
    }
  });

  /// Atomic publication. A disk failure loses only an optimization, not a sync.
  Future<void> write(
    String hash,
    Uint8List bytes, {
    void Function()? checkActive,
  }) => _serialized(() async {
    checkActive?.call();
    if (!_valid(hash, bytes.length) ||
        bytes.length > maxBytes ||
        maxEntries == 0) {
      return;
    }
    if (sha256.convert(bytes).toString() != hash) {
      throw const FormatException('Invalid reconciliation cache page');
    }
    Directory? pending;
    try {
      await _initialize(checkActive);
      checkActive?.call();
      if (_unavailable) return;
      await _requireSafeRoot(checkActive, allowMissing: true);
      if (await _read(hash, bytes.length, checkActive) != null) return;
      checkActive?.call();
      await _trim(bytes.length, 1, checkActive);
      checkActive?.call();
      await root.create(recursive: true);
      checkActive?.call();
      if (await FileSystemEntity.type(root.path, followLinks: false) !=
          FileSystemEntityType.directory) {
        return;
      }
      checkActive?.call();
      pending = await root.createTemp('.pending-');
      checkActive?.call();
      final file = File('${pending.path}/page');
      await file.writeAsBytes(bytes);
      checkActive?.call();
      await file.rename(_file(hash).path);
      // Bookkeeping for settled IO must survive retirement too. Otherwise an
      // aborted owner could leave published files outside its eviction budget.
      _entries[hash] = _CachedPage(bytes.length, ++_tick);
      _bytes += bytes.length;
      checkActive?.call();
    } on FileSystemException {
      checkActive?.call();
    } finally {
      // Only the private temporary directory issued to this operation is owned.
      if (pending != null) {
        try {
          await pending.delete(recursive: true);
        } on FileSystemException {
          // At most one bounded pending page per interrupted write.
        }
      }
    }
  });

  bool _valid(String hash, int bytes) =>
      _hashPattern.hasMatch(hash) && bytes > 0 && bytes <= maxPageBytes;

  File _file(String hash) => File('${root.path}/$hash.page');

  Future<void> _requireSafeRoot(
    void Function()? checkActive, {
    bool allowMissing = false,
  }) async {
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    checkActive?.call();
    if (type != FileSystemEntityType.directory &&
        !(allowMissing && type == FileSystemEntityType.notFound)) {
      throw const FileSystemException('Reconciliation cache root unavailable');
    }
  }

  Future<void> _initialize(void Function()? checkActive) async {
    if (_initialized) return;
    final type = await FileSystemEntity.type(root.path, followLinks: false);
    checkActive?.call();
    if (type == FileSystemEntityType.notFound) {
      _initialized = true;
      return;
    }
    if (type != FileSystemEntityType.directory) {
      _unavailable = true;
      _initialized = true;
      return;
    }
    // Bound metadata even if external damage adds unexpected files. Never
    // traverse recursively, follow links or load page contents here.
    var scanned = 0;
    final entries = <String, _CachedPage>{};
    var bytes = 0;
    await for (final entity in root.list(followLinks: false)) {
      checkActive?.call();
      if (++scanned > maxEntries * 2 + 16) {
        _unavailable = true;
        _initialized = true;
        return;
      }
      if (entity is! File) continue;
      final match = _filePattern.firstMatch(entity.uri.pathSegments.last);
      if (match == null) continue;
      final stat = await entity.stat();
      checkActive?.call();
      entries[match[1]!] = _CachedPage(
        stat.size,
        stat.modified.microsecondsSinceEpoch,
      );
      bytes += stat.size;
    }
    // Rebuild restart age from file timestamps, then use logical access order:
    // Windows clock granularity must not tie two successive hits/writes.
    final oldest = entries.keys.toList()
      ..sort((a, b) => entries[a]!.used.compareTo(entries[b]!.used));
    for (final hash in oldest) {
      _entries[hash] = _CachedPage(entries[hash]!.bytes, ++_tick);
    }
    _bytes = bytes;
    _initialized = true;
    await _trim(0, 0, checkActive);
  }

  Future<Uint8List?> _read(
    String hash,
    int expectedBytes,
    void Function()? checkActive,
  ) async {
    await _requireSafeRoot(checkActive, allowMissing: true);
    final file = _file(hash);
    final type = await FileSystemEntity.type(file.path, followLinks: false);
    checkActive?.call();
    if (type != FileSystemEntityType.file) {
      _forget(hash);
      return null;
    }
    await _requireSafeRoot(checkActive);
    final handle = await file.open();
    Uint8List? bytes;
    try {
      checkActive?.call();
      final length = await handle.length();
      checkActive?.call();
      if (length == expectedBytes) {
        // A concurrent growth cannot cause an unbounded allocation.
        bytes = await handle.read(expectedBytes + 1);
        checkActive?.call();
      }
    } finally {
      await handle.close();
    }
    checkActive?.call();
    if (bytes?.length != expectedBytes ||
        sha256.convert(bytes!).toString() != hash) {
      await _requireSafeRoot(checkActive);
      await file.delete();
      _forget(hash);
      checkActive?.call();
      return null;
    }
    if (!_entries.containsKey(hash)) _bytes += bytes.length;
    _entries[hash] = _CachedPage(bytes.length, ++_tick);
    return bytes;
  }

  void _forget(String hash) {
    final previous = _entries.remove(hash);
    if (previous != null) _bytes -= previous.bytes;
  }

  Future<void> _trim(
    int incomingBytes,
    int incomingEntries,
    void Function()? checkActive,
  ) async {
    final oldest = _entries.keys.toList()
      ..sort((a, b) => _entries[a]!.used.compareTo(_entries[b]!.used));
    for (final hash in oldest) {
      if (_bytes + incomingBytes <= maxBytes &&
          _entries.length + incomingEntries <= maxEntries) {
        break;
      }
      checkActive?.call();
      await _requireSafeRoot(checkActive, allowMissing: true);
      final file = _file(hash);
      final type = await FileSystemEntity.type(file.path, followLinks: false);
      checkActive?.call();
      if (type == FileSystemEntityType.file) {
        await _requireSafeRoot(checkActive);
        await file.delete();
      }
      _forget(hash);
      checkActive?.call();
    }
  }
}

class _CachedPage {
  const _CachedPage(this.bytes, this.used);
  final int bytes;
  final int used;
}
