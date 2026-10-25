part of '../database_restore_repo.dart';

/// Descriptor-relative custody in the application's Context-canonical root.
/// This is NOT a SQLite writer fence. The native connection's borrowed VFS
/// descriptor and actual SQLite locks supply that separate proof.
final class _RestoreAndroidFiles implements _RestoreFilePort {
  _RestoreAndroidFiles(String canonicalDataRoot)
    : androidDataRoot = canonicalDataRoot {
    // String admission only: no Context, path provider, preferences, key lookup,
    // root open or directory creation occurs in this constructor.
    requirePath(canonicalDataRoot);
  }

  @override
  p.Context get paths => p.posix;
  @override
  final String androidDataRoot;
  final _owned = <String, _RestoreAndroidOwned>{};
  final _retiredProofs = <_RestoreAndroidOwned>[];
  final _uncertain = <_RestoreAndroidPin>[];
  static final _stageName = RegExp(r'^\.restore-[0-9a-f]{32}$');
  static bool _isStageName(String value) =>
      value.length == 41 && _stageName.hasMatch(value);
  static const _lockName = '.astoria-restore-startup.lock';
  static const _markerName = '.astoria-restore-interrupted';

  late final DynamicLibrary _library = _loadLibrary();
  DynamicLibrary _loadLibrary() {
    if (!Platform.isAndroid) _refuse(DatabaseRestoreCode.unsupported);
    try {
      final library = DynamicLibrary.open('libastoria_snapshot.so');
      if (library.lookupFunction<Int32 Function(), int Function()>(
            'astoria_snapshot_abi',
          )() !=
          1) {
        _refuse(DatabaseRestoreCode.unsupported);
      }
      // Resolve every symbol BEFORE any creation or lock acquisition. A missing
      // bridge cannot strand an artifact by failing at the next lazy lookup.
      for (final name in const [
        'astoria_snapshot_allocate',
        'astoria_snapshot_free',
        'astoria_restore_root',
        'astoria_snapshot_directory',
        'astoria_snapshot_file',
        'astoria_snapshot_info',
        'astoria_snapshot_close',
        'astoria_restore_uid',
        'astoria_restore_permissions',
        'astoria_restore_entry_kind',
        'astoria_restore_candidate_file',
        'astoria_restore_startup_lock',
        'astoria_restore_create_directory',
        'astoria_restore_create_file',
        'astoria_restore_pread',
        'astoria_restore_pwrite',
        'astoria_restore_sync_file',
        'astoria_restore_sync_parent',
        'astoria_restore_sync_directory',
        'astoria_restore_delete_owned',
      ]) {
        library.lookup<Void>(name);
      }
      return library;
    } catch (_) {
      _refuse(DatabaseRestoreCode.unsupported);
      rethrow;
    }
  }

  late final _allocate = _library
      .lookupFunction<
        Pointer<Void> Function(Uint64),
        Pointer<Void> Function(int)
      >('astoria_snapshot_allocate');
  late final _free = _library
      .lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('astoria_snapshot_free');
  late final _root = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Char>),
        Pointer<Void> Function(Pointer<Char>)
      >('astoria_restore_root');
  late final _directory = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>, Int32),
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>, int)
      >('astoria_snapshot_directory');
  late final _metadata = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>)
      >('astoria_snapshot_file');
  late final _info = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Uint64>),
        int Function(Pointer<Void>, Pointer<Uint64>)
      >('astoria_snapshot_info');
  late final _close = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('astoria_snapshot_close');
  late final _uid = _library.lookupFunction<Uint64 Function(), int Function()>(
    'astoria_restore_uid',
  )();
  late final _permissions = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('astoria_restore_permissions');
  late final _entryKind = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Char>),
        int Function(Pointer<Void>, Pointer<Char>)
      >('astoria_restore_entry_kind');
  late final _candidate = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>, Pointer<Int32>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>, Pointer<Int32>)
      >('astoria_restore_candidate_file');
  late final _lock = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Int32>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Int32>)
      >('astoria_restore_startup_lock');
  late final _createDirectory = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>, Pointer<Int32>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>, Pointer<Int32>)
      >('astoria_restore_create_directory');
  late final _createFile = _library
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Char>,
          Pointer<Pointer<Void>>,
          Pointer<Int32>,
        ),
        Pointer<Void> Function(
          Pointer<Void>,
          Pointer<Char>,
          Pointer<Pointer<Void>>,
          Pointer<Int32>,
        )
      >('astoria_restore_create_file');
  late final _read = _library
      .lookupFunction<
        Int64 Function(Pointer<Void>, Pointer<Uint8>, Uint64, Uint64),
        int Function(Pointer<Void>, Pointer<Uint8>, int, int)
      >('astoria_restore_pread');
  late final _write = _library
      .lookupFunction<
        Int64 Function(Pointer<Void>, Pointer<Uint8>, Uint64, Uint64),
        int Function(Pointer<Void>, Pointer<Uint8>, int, int)
      >('astoria_restore_pwrite');
  late final _syncFile = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('astoria_restore_sync_file');
  late final _syncParent = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('astoria_restore_sync_parent');
  late final _syncDirectory = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('astoria_restore_sync_directory');
  late final _delete = _library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32),
        int Function(Pointer<Void>, int)
      >('astoria_restore_delete_owned');

  @override
  Pointer<Void> allocate(int bytes) {
    if (bytes <= 0 || bytes > _RestoreLimits.chunk) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final memory = _allocate(bytes);
    if (memory == nullptr) _refuse(DatabaseRestoreCode.unsupported);
    return memory;
  }

  @override
  void free(Pointer<Void> memory) => _free(memory);

  T _text<T>(String value, T Function(Pointer<Char>) action) {
    final bytes = utf8.encode(value);
    final memory = allocate(bytes.length + 1);
    try {
      memory.cast<Uint8>().asTypedList(bytes.length).setAll(0, bytes);
      return action(memory.cast());
    } finally {
      free(memory);
    }
  }

  void requirePath(String path) {
    final encoded = utf8.encode(path);
    if (!paths.isAbsolute(path) ||
        path == '/' ||
        paths.normalize(path) != path ||
        path.contains('\u0000') ||
        encoded.length > 4096 ||
        utf8.decode(encoded) != path ||
        (path != androidDataRoot && !paths.isWithin(androidDataRoot, path))) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final components = path.substring(1).split('/');
    if (components.length > 64 ||
        components.any(
          (name) =>
              name.isEmpty ||
              name == '.' ||
              name == '..' ||
              utf8.encode(name).length > 128,
        )) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
  }

  List<int> information(Pointer<Void> handle) {
    // Separate fixed metadata allocation: never allocate 65536 + stat bytes.
    final memory = allocate(48).cast<Uint64>();
    try {
      if (_info(handle, memory) != 0) _refuse(DatabaseRestoreCode.stale);
      return List<int>.of(memory.asTypedList(6));
    } finally {
      free(memory.cast());
    }
  }

  _RestoreAndroidPin _adopt(
    Pointer<Void> handle,
    String path, {
    bool directory = false,
    bool readable = false,
  }) {
    if (handle == nullptr) _refuse(DatabaseRestoreCode.unsupported);
    final pin = _RestoreAndroidPin(
      this,
      handle,
      path,
      directory,
      readable: readable,
    );
    try {
      pin.check();
      return pin;
    } catch (_) {
      pin.close();
      rethrow;
    }
  }

  void _closeAll(Iterable<_RestoreAndroidPin> pins) {
    var failed = false;
    for (final pin in pins) {
      try {
        pin.close();
      } catch (_) {
        failed = true;
      }
    }
    if (failed) _refuse(DatabaseRestoreCode.recoveryRequired);
  }

  @override
  List<_RestorePin> pinAncestors(String parent) {
    requirePath(parent);
    final pins = <_RestoreAndroidPin>[];
    try {
      // The native root retains / and canonical ancestors internally, without
      // applying the app-root uid/mode policy to / or /data.
      pins.add(
        _adopt(_text(androidDataRoot, _root), androidDataRoot, directory: true),
      );
      var path = androidDataRoot;
      if (parent != path) {
        for (final name in paths.relative(parent, from: path).split('/')) {
          path = paths.join(path, name);
          final handle = _text(
            name,
            (name) => _directory(pins.last.handle, name, 0),
          );
          pins.add(_adopt(handle, path, directory: true));
        }
      }
      return pins;
    } catch (_) {
      _closeAll(pins.reversed);
      rethrow;
    }
  }

  T _withParent<T>(String path, T Function(_RestoreAndroidPin) action) {
    final pins = pinAncestors(paths.dirname(path)).cast<_RestoreAndroidPin>();
    try {
      return action(pins.last);
    } finally {
      _closeAll(pins.reversed);
    }
  }

  @override
  bool exists(String path) {
    requirePath(path);
    final pins = <_RestoreAndroidPin>[];
    try {
      pins.add(
        _adopt(_text(androidDataRoot, _root), androidDataRoot, directory: true),
      );
      if (path == androidDataRoot) return true;
      final names = paths.relative(path, from: androidDataRoot).split('/');
      var currentPath = androidDataRoot;
      for (var i = 0; i < names.length; i++) {
        final kind = _text(
          names[i],
          (name) => _entryKind(pins.last.handle, name),
        );
        if (kind == 0) return false;
        if (kind != 1 && kind != 2) _refuse(DatabaseRestoreCode.unsupported);
        if (i == names.length - 1) return true;
        if (kind != 1) _refuse(DatabaseRestoreCode.unsupported);
        currentPath = paths.join(currentPath, names[i]);
        pins.add(
          _adopt(
            _text(names[i], (name) => _directory(pins.last.handle, name, 0)),
            currentPath,
            directory: true,
          ),
        );
      }
      _refuse(DatabaseRestoreCode.unsupported);
      return false;
    } finally {
      _closeAll(pins.reversed);
    }
  }

  @override
  _RestorePin pin(
    String path, {
    bool directory = false,
    bool immutable = false,
    bool lock = false,
    bool create = false,
    bool write = false,
  }) {
    requirePath(path);
    if (directory) {
      if (immutable || lock || create || write) {
        _refuse(DatabaseRestoreCode.unsupported);
      }
      if (path == androidDataRoot) {
        return _adopt(_text(path, _root), path, directory: true);
      }
      return _withParent(
        path,
        (parent) => _adopt(
          _text(
            paths.basename(path),
            (name) => _directory(parent.handle, name, 0),
          ),
          path,
          directory: true,
        ),
      );
    }
    if (path == androidDataRoot ||
        (immutable && (lock || create || write)) ||
        (lock && (create || write)) ||
        (create != write)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    if (lock && path != paths.join(androidDataRoot, _lockName)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    if (immutable && _owned.containsKey(path)) {
      // Immutable opens are for the selected candidate, not an extra regular fd
      // on a still-live original SQLite connection. Owned-stage reads retain the
      // original create/write fd instead; they are never reopened for bytes.
      _refuse(DatabaseRestoreCode.unsupported);
    }
    return _withParent(path, (parent) {
      if (create) return _newFile(parent, path);
      if (!lock && !immutable) {
        return _adopt(
          _text(paths.basename(path), (name) => _metadata(parent.handle, name)),
          path,
        );
      }
      final status = allocate(4).cast<Int32>();
      try {
        status.value = -1;
        final handle = lock
            ? _lock(parent.handle, status)
            : _text(
                paths.basename(path),
                (name) => _candidate(parent.handle, name, status),
              );
        if (status.value != 0 || handle == nullptr) {
          if (handle != nullptr) {
            _uncertain.add(_RestoreAndroidPin(this, handle, path, false));
            _refuse(DatabaseRestoreCode.recoveryRequired);
          }
          _refuse(
            lock && status.value == 1
                ? DatabaseRestoreCode.busy
                : DatabaseRestoreCode.unsupported,
          );
        }
        return _adopt(handle, path, readable: immutable);
      } finally {
        free(status.cast());
      }
    });
  }

  void _register(String path, _RestoreAndroidOwned record) {
    final previous = _owned[path];
    if (previous != null) _retiredProofs.add(previous);
    _owned[path] = record;
  }

  _RestoreAndroidOwned _ownedStage(String path) {
    final record = _owned[path];
    if (record == null ||
        !record.proof.directory ||
        record.uncertain ||
        record.deleted ||
        !_isStageName(paths.basename(path))) {
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    final owned = record!;
    owned.proof.check();
    return owned;
  }

  _RestoreAndroidPin _newFile(_RestoreAndroidPin parent, String path) {
    if (paths.basename(path) != _markerName) {
      _ownedStage(paths.dirname(path));
    }
    final previous = _owned[path];
    if (previous != null && (!previous.deleted || previous.uncertain)) {
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    final slots = allocate(16);
    final status = slots.cast<Int32>();
    final proof = (slots.cast<Uint8>() + 8).cast<Pointer<Void>>();
    try {
      status.value = -1;
      proof.value = nullptr;
      final handle = _text(
        paths.basename(path),
        (name) => _createFile(parent.handle, name, proof, status),
      );
      if (handle == nullptr) _refuse(DatabaseRestoreCode.unsupported);
      final writer = _RestoreAndroidPin(
        this,
        handle,
        path,
        false,
        readable: true,
        writable: true,
      );
      // Native transfers both exact original caps even when post-create
      // metadata fails. Register BEFORE any Dart metadata/length observation.
      final metadata = _RestoreAndroidPin(this, proof.value, path, false);
      final record = _RestoreAndroidOwned(metadata, writer: writer);
      _register(path, record);
      try {
        if (status.value != 0 || proof.value == nullptr) {
          _refuse(DatabaseRestoreCode.recoveryRequired);
        }
        writer.check();
        metadata.check();
        if (writer.identity != metadata.identity) {
          _refuse(DatabaseRestoreCode.recoveryRequired);
        }
        return writer;
      } catch (_) {
        record.uncertain = true;
        rethrow;
      }
    } finally {
      free(slots);
    }
  }

  @override
  String createStage(String parent) {
    requirePath(parent);
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = paths.join(parent, '.restore-$nonce');
    requirePath(path);
    return _withParent(path, (parent) {
      final status = allocate(4).cast<Int32>();
      try {
        status.value = -1;
        final handle = _text(
          paths.basename(path),
          (name) => _createDirectory(parent.handle, name, status),
        );
        if (handle == nullptr) _refuse(DatabaseRestoreCode.unsupported);
        final proof = _RestoreAndroidPin(this, handle, path, true);
        final record = _RestoreAndroidOwned(proof);
        _register(path, record);
        try {
          if (status.value != 0) _refuse(DatabaseRestoreCode.recoveryRequired);
          proof.check();
          if ((information(handle)[2] & 0x1ff) != 0x1c0) {
            _refuse(DatabaseRestoreCode.recoveryRequired);
          }
          return path;
        } catch (_) {
          record.uncertain = true;
          rethrow;
        }
      } finally {
        free(status.cast());
      }
    });
  }

  void _deleteOwned(String path, bool directory) {
    requirePath(path);
    final record = _owned[path];
    if (record == null ||
        record.uncertain ||
        record.proof.directory != directory ||
        record.proof.closed ||
        (record.writer != null && !record.writer!.closed)) {
      // No adoption by arbitrary path, including SQLite-created sidecars. This
      // port cannot prove their actual original connection has been closed.
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    final owned = record!;
    if (_delete(owned.proof.handle, directory ? 1 : 0) != 0) {
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    owned.deleted = true;
  }

  @override
  void deleteOwnedFile(String path) => _deleteOwned(path, false);
  @override
  void deleteOwnedDirectory(String path) => _deleteOwned(path, true);

  @override
  void releaseOwnedProofs() {
    // Parent invokes ONLY after the actual raw connections and ordinary pins
    // have closed/joined. The startup flock never belongs to this record map.
    final records = [..._retiredProofs, ..._owned.values];
    if (_uncertain.isNotEmpty ||
        records.any(
          (record) =>
              record.uncertain ||
              (record.writer != null && !record.writer!.closed),
        )) {
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    for (final record in records.reversed) {
      record.proof.close();
    }
    _retiredProofs.clear();
    _owned.clear();
  }

  _RestoreAndroidPin _bytePin(_RestorePin pin, {bool output = false}) {
    if (pin is! _RestoreAndroidPin ||
        !identical(pin.api, this) ||
        pin.directory ||
        !pin.readable ||
        (output && !pin.writable)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final value = pin as _RestoreAndroidPin;
    value.check();
    if (value.writable) {
      final record = _owned[value.path];
      if (record == null ||
          record.uncertain ||
          record.deleted ||
          !identical(record.writer, value)) {
        _refuse(DatabaseRestoreCode.recoveryRequired);
      }
      final owned = record!;
      owned.proof.check();
      if (owned.proof.identity != value.identity) {
        _refuse(DatabaseRestoreCode.recoveryRequired);
      }
      if (!output) _ownedStage(paths.dirname(value.path));
    }
    return value;
  }

  void _durableFile(_RestoreAndroidPin pin) {
    pin.check();
    if (_syncFile(pin.handle) != 0 || _syncParent(pin.handle) != 0) {
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    pin.check();
    final record = _owned[pin.path];
    if (record != null && identical(record.writer, pin)) record.durable = true;
  }

  @override
  Future<Digest> copyOrHash(
    _RestorePin input,
    void Function() check, {
    _RestorePin? output,
  }) async {
    check();
    final source = _bytePin(input);
    final destination = output == null ? null : _bytePin(output, output: true);
    if (destination != null) _ownedStage(paths.dirname(destination.path));
    final length = source.length;
    if (length > _RestoreLimits.maxBytes) _refuse(DatabaseRestoreCode.tooLarge);
    if (destination != null &&
        (destination.identity == source.identity || destination.length != 0)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final memory = allocate(_RestoreLimits.chunk).cast<Uint8>();
    final digest = _RestoreDigestSink();
    final sink = sha256.startChunkedConversion(digest);
    try {
      var offset = 0;
      while (offset < length) {
        check();
        _bytePin(source);
        if (destination != null) _bytePin(destination, output: true);
        final n = min(_RestoreLimits.chunk, length - offset);
        if (_read(source.handle, memory, n, offset) != n) {
          _refuse(DatabaseRestoreCode.stale);
        }
        sink.add(memory.asTypedList(n));
        if (destination != null &&
            _write(destination.handle, memory, n, offset) != n) {
          _refuse(DatabaseRestoreCode.recoveryRequired);
        }
        offset += n;
        await Future<void>.delayed(Duration.zero);
        check();
        source.check();
        destination?.check();
      }
      check();
      if (_read(source.handle, memory, 1, length) != 0 ||
          source.length != length) {
        _refuse(DatabaseRestoreCode.stale);
      }
      source.check();
      if (destination != null) {
        if (destination.length != length) {
          _refuse(DatabaseRestoreCode.recoveryRequired);
        }
        _durableFile(destination);
      }
      check();
    } finally {
      sink.close();
      free(memory.cast());
    }
    return digest.value!;
  }

  @override
  void writeMarker(_RestorePin marker, String stageBasename) {
    if (!_isStageName(stageBasename) ||
        paths.basename(marker.path) != _markerName) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final writer = _bytePin(marker, output: true);
    if (writer.length != 0) _refuse(DatabaseRestoreCode.recoveryRequired);
    final stage = paths.join(paths.dirname(marker.path), stageBasename);
    final slot = _ownedStage(stage);
    // SQLite backup uses FULL synchronous on its original connection. Sync the
    // independently owned original fd and its stage before publishing a marker;
    // never open/close the live source main just to request durability.
    for (final entry in _owned.entries) {
      if (paths.dirname(entry.key) == stage && !entry.value.deleted) {
        final file = entry.value.writer;
        if (entry.value.uncertain ||
            file == null ||
            (file.closed && !entry.value.durable)) {
          _refuse(DatabaseRestoreCode.recoveryRequired);
        }
        final ownedFile = file!;
        if (!ownedFile.closed) _durableFile(_bytePin(ownedFile, output: true));
      }
    }
    if (_syncDirectory(slot.proof.handle) != 0) {
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    // Bounded locator only; no source path, body, approval or installation key.
    final data = utf8.encode('restore-interrupted-v1\n$stageBasename\n');
    final memory = allocate(data.length).cast<Uint8>();
    try {
      memory.asTypedList(data.length).setAll(0, data);
      if (_write(writer.handle, memory, data.length, 0) != data.length ||
          writer.length != data.length) {
        _refuse(DatabaseRestoreCode.recoveryRequired);
      }
      _durableFile(writer);
    } finally {
      free(memory.cast());
    }
  }
}

final class _RestoreAndroidOwned {
  _RestoreAndroidOwned(this.proof, {this.writer});
  final _RestoreAndroidPin proof;
  final _RestoreAndroidPin? writer;
  bool uncertain = false;
  bool deleted = false;
  bool durable = false;
}

final class _RestoreAndroidPin implements _RestorePin {
  _RestoreAndroidPin(
    this.api,
    this.handle,
    this.path,
    this.directory, {
    this.readable = false,
    this.writable = false,
  });
  final _RestoreAndroidFiles api;
  @override
  final Pointer<Void> handle;
  @override
  final String path;
  @override
  final bool directory;
  final bool readable;
  final bool writable;
  (int, int, int)? _identity;
  bool _closeAttempted = false;
  @override
  bool closed = false;

  List<int> _information() {
    if (closed || _closeAttempted) _refuse(DatabaseRestoreCode.stale);
    final value = api.information(handle);
    final type = value[2] & 0xf000;
    final actual = (value[0], value[1], 0);
    if (value[3] != api._uid ||
        api._permissions(handle) != 0 ||
        type != (directory ? 0x4000 : 0x8000) ||
        (!directory && value[4] != 1) ||
        (_identity != null && _identity != actual)) {
      _refuse(DatabaseRestoreCode.stale);
    }
    _identity ??= actual; // Android identity is (full uint64 dev, ino, zero).
    return value;
  }

  @override
  (int, int, int) get identity {
    _information();
    return _identity!;
  }

  @override
  int get length => _information()[5];
  @override
  void check() => _information();

  @override
  void close() {
    if (closed) return;
    if (_closeAttempted) _refuse(DatabaseRestoreCode.recoveryRequired);
    // Consume Dart ownership BEFORE native close. A failed close retains this
    // exact pointer, whose native capsule also retains an uncertain parent.
    _closeAttempted = true;
    if (api._close(handle) != 0) {
      api._uncertain.add(this);
      _refuse(DatabaseRestoreCode.recoveryRequired);
    }
    closed = true;
  }
}
