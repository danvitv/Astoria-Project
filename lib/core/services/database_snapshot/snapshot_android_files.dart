part of '../database_snapshot_service.dart';

final class _AndroidSnapshotPointer extends Opaque {}

/// App-owned namespace + retained descriptors. This does not claim to stop a
/// privileged actor (or arbitrary code with our UID) from replacing directories.
final class _AndroidSnapshotFiles {
  _AndroidSnapshotFiles(this.source, this.token);
  final NativeBackgroundDatabaseSnapshotSource source;
  final String token;
  final List<_AndroidDirectoryPin> _directories = [];
  late final _AndroidSnapshotApi _api;
  _AndroidSnapshotPin? _stage;
  _AndroidDirectoryPin? _slot;
  bool _transferred = false;

  _AndroidSnapshotPin get stage => _stage!;

  void acquire(_SnapshotGuard guard) {
    guard.check();
    _api = _AndroidSnapshotApi();
    var directory = _keep(_api.root(source.namespace.dataRoot));
    final root = directory;
    final relative = p.posix.relative(
      source.sourcePath,
      from: source.namespace.dataRoot,
    );
    if (relative.startsWith('../') ||
        p.posix.isAbsolute(relative) ||
        p.posix.basename(relative) != 'astoria.db') {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unavailable);
    }
    for (final name in p.posix.split(p.posix.dirname(relative))) {
      if (name != '.') directory = _keep(_api.directory(directory, name));
    }
    // Pin the named source as well as its ancestors. The actual SQLite handle
    // remains in the original background worker, never reopened here.
    _keep(_api.file(directory, 'astoria.db'));
    directory = _keep(_api.directory(root, 'no_backup', create: 1));
    directory = _keep(
      _api.directory(directory, 'astoria_snapshots', create: 1),
    );
    directory = _slot = _keep(_api.directory(directory, token, create: 2));
    _stage = _AndroidSnapshotPin(_api, _api.stage(directory, 'snapshot.db'));
    if (stage.length != 0) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
    }
    guard.check();
  }

  _AndroidDirectoryPin _keep(_AndroidDirectoryPin pin) {
    _directories.add(pin);
    return pin;
  }

  void check() {
    for (final pin in _directories) {
      _api.info(pin.pointer);
    }
  }

  void transfer() {
    _transferred = true;
  }

  void close() {
    // Unknown original SQLite destination state must never reach this cleanup.
    if (!_transferred && _stage != null) {
      _api.discard(stage.pointer);
      stage.close();
      _stage = null;
    }
    if (!_transferred && _slot != null) {
      _api.discardDirectory(_slot!.pointer);
      _slot = null;
    }
    for (final pin in _directories.reversed) {
      pin.close();
    }
    _directories.clear();
  }
}

final class _AndroidDirectoryPin {
  _AndroidDirectoryPin(this.api, this.pointer);
  final _AndroidSnapshotApi api;
  Pointer<_AndroidSnapshotPointer> pointer;
  void close() {
    if (pointer == nullptr) return;
    api.close(pointer);
    pointer = nullptr;
  }
}

final class _AndroidSnapshotPin implements _SnapshotImmutablePin {
  _AndroidSnapshotPin(this.api, this.pointer);
  final _AndroidSnapshotApi api;
  Pointer<_AndroidSnapshotPointer> pointer;
  bool published = false;
  @override
  int get length => api.info(pointer)[5];

  void seal() => api.seal(pointer);

  void publish() {
    api.publish(pointer, 'astoria-backup.db');
    published =
        true; // Native linkat succeeded, even if its stage unlink failed.
  }

  @override
  Future<Digest> hash(_SnapshotGuard guard) async {
    final size = length;
    if (size < 1 || size > _SnapshotLimits.maxBytes) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
    }
    final sink = _SnapshotDigestSink();
    final digest = sha256.startChunkedConversion(sink);
    final memory = api.allocate(_SnapshotLimits.hashChunk);
    try {
      for (var offset = 0; offset < size;) {
        guard.check();
        final count = api.read(
          pointer,
          memory,
          min(_SnapshotLimits.hashChunk, size - offset),
          offset,
        );
        if (count <= 0) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
        }
        digest.add(memory.asTypedList(count));
        offset += count;
        await Future<void>.delayed(Duration.zero);
        guard.check();
      }
      if (length != size) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
      digest.close();
      return sink.value!;
    } finally {
      api.free(memory);
    }
  }

  @override
  void close() {
    if (pointer == nullptr) return;
    api.close(pointer);
    pointer = nullptr;
  }
}

final class _AndroidSnapshotApi {
  _AndroidSnapshotApi() {
    if (!Platform.isAndroid) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unavailable);
    }
    _library = DynamicLibrary.open('libastoria_snapshot.so');
    if (_library.lookupFunction<Int32 Function(), int Function()>(
          'astoria_snapshot_abi',
        )() !=
        1) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unavailable);
    }
  }
  late final DynamicLibrary _library;
  static const _failure = _SnapshotFailure(
    DatabaseSnapshotStatus.unsupportedIdentity,
  );
  Pointer<Uint8> allocate(int size) {
    final value = _library
        .lookupFunction<
          Pointer<Uint8> Function(Uint64),
          Pointer<Uint8> Function(int)
        >('astoria_snapshot_allocate')(size);
    if (value == nullptr) throw _failure;
    return value;
  }

  void free(Pointer<Uint8> memory) =>
      _library.lookupFunction<
        Void Function(Pointer<Void>),
        void Function(Pointer<Void>)
      >('astoria_snapshot_free')(memory.cast());
  T _name<T>(String text, T Function(Pointer<Char>) work) {
    final bytes = utf8.encode(text);
    final memory = allocate(bytes.length + 1);
    try {
      memory.asTypedList(bytes.length).setAll(0, bytes);
      return work(memory.cast());
    } finally {
      free(memory);
    }
  }

  _AndroidDirectoryPin _pin(Pointer<_AndroidSnapshotPointer> value) {
    if (value == nullptr) throw _failure;
    return _AndroidDirectoryPin(this, value);
  }

  _AndroidDirectoryPin root(String path) => _pin(
    _name(
      path,
      (name) =>
          _library.lookupFunction<
            Pointer<_AndroidSnapshotPointer> Function(Pointer<Char>),
            Pointer<_AndroidSnapshotPointer> Function(Pointer<Char>)
          >('astoria_snapshot_root')(name),
    ),
  );
  _AndroidDirectoryPin directory(
    _AndroidDirectoryPin parent,
    String name, {
    int create = 0,
  }) => _pin(
    _name(
      name,
      (value) =>
          _library.lookupFunction<
            Pointer<_AndroidSnapshotPointer> Function(
              Pointer<_AndroidSnapshotPointer>,
              Pointer<Char>,
              Int32,
            ),
            Pointer<_AndroidSnapshotPointer> Function(
              Pointer<_AndroidSnapshotPointer>,
              Pointer<Char>,
              int,
            )
          >('astoria_snapshot_directory')(parent.pointer, value, create),
    ),
  );
  _AndroidDirectoryPin file(_AndroidDirectoryPin parent, String name) => _pin(
    _name(
      name,
      (value) =>
          _library.lookupFunction<
            Pointer<_AndroidSnapshotPointer> Function(
              Pointer<_AndroidSnapshotPointer>,
              Pointer<Char>,
            ),
            Pointer<_AndroidSnapshotPointer> Function(
              Pointer<_AndroidSnapshotPointer>,
              Pointer<Char>,
            )
          >('astoria_snapshot_file')(parent.pointer, value),
    ),
  );
  Pointer<_AndroidSnapshotPointer> stage(
    _AndroidDirectoryPin parent,
    String name,
  ) => _pin(
    _name(
      name,
      (value) =>
          _library.lookupFunction<
            Pointer<_AndroidSnapshotPointer> Function(
              Pointer<_AndroidSnapshotPointer>,
              Pointer<Char>,
            ),
            Pointer<_AndroidSnapshotPointer> Function(
              Pointer<_AndroidSnapshotPointer>,
              Pointer<Char>,
            )
          >('astoria_snapshot_stage')(parent.pointer, value),
    ),
  ).pointer;
  List<int> info(Pointer<_AndroidSnapshotPointer> pin) {
    final memory = allocate(48);
    try {
      final output = memory.cast<Uint64>();
      if (_library.lookupFunction<
            Int32 Function(Pointer<_AndroidSnapshotPointer>, Pointer<Uint64>),
            int Function(Pointer<_AndroidSnapshotPointer>, Pointer<Uint64>)
          >('astoria_snapshot_info')(pin, output) !=
          0) {
        throw _failure;
      }
      return output.asTypedList(6).toList();
    } finally {
      free(memory);
    }
  }

  void _call(String name, Pointer<_AndroidSnapshotPointer> pin) {
    if (_library.lookupFunction<
          Int32 Function(Pointer<_AndroidSnapshotPointer>),
          int Function(Pointer<_AndroidSnapshotPointer>)
        >(name)(pin) !=
        0) {
      throw _failure;
    }
  }

  void seal(Pointer<_AndroidSnapshotPointer> pin) =>
      _call('astoria_snapshot_seal', pin);
  void discard(Pointer<_AndroidSnapshotPointer> pin) =>
      _call('astoria_snapshot_discard', pin);
  void discardDirectory(Pointer<_AndroidSnapshotPointer> pin) =>
      _call('astoria_snapshot_discard_directory', pin);
  void close(Pointer<_AndroidSnapshotPointer> pin) =>
      _call('astoria_snapshot_close', pin);
  int read(
    Pointer<_AndroidSnapshotPointer> pin,
    Pointer<Uint8> bytes,
    int size,
    int offset,
  ) =>
      _library.lookupFunction<
        Int64 Function(
          Pointer<_AndroidSnapshotPointer>,
          Pointer<Uint8>,
          Uint64,
          Uint64,
        ),
        int Function(Pointer<_AndroidSnapshotPointer>, Pointer<Uint8>, int, int)
      >('astoria_snapshot_read')(pin, bytes, size, offset);
  void publish(Pointer<_AndroidSnapshotPointer> pin, String name) =>
      _name(name, (value) {
        final result = _library
            .lookupFunction<
              Int32 Function(Pointer<_AndroidSnapshotPointer>, Pointer<Char>),
              int Function(Pointer<_AndroidSnapshotPointer>, Pointer<Char>)
            >('astoria_snapshot_publish')(pin, value);
        if (result < 0) throw _failure;
      });
}
