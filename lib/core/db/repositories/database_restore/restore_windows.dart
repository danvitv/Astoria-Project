part of '../database_restore_repo.dart';

/// The only dynamically opened DLL is the Windows system DLL. SQLite controls
/// below borrow the already loaded module; no SQLite DLL/VFS is loaded here.
final class _RestoreWindows implements _RestoreFilePort {
  _RestoreWindows() : _dll = DynamicLibrary.open('kernel32.dll');
  @override
  p.Context get paths => p.windows;
  @override
  String? get androidDataRoot => null;
  @override
  void releaseOwnedProofs() {}
  @override
  List<_RestorePin> pinAncestors(String parent) {
    final chain = <String>[];
    var path = parent;
    while (true) {
      chain.add(path);
      final next = p.windows.dirname(path);
      if (next == path) break;
      path = next;
    }
    final pins = <_RestorePin>[];
    try {
      for (final path in chain.reversed) {
        requirePath(path);
        pins.add(pin(path, directory: true));
      }
      return pins;
    } catch (_) {
      for (final value in pins.reversed) {
        value.close();
      }
      rethrow;
    }
  }

  final DynamicLibrary _dll;
  late final _alloc = _dll
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  late final _free = _dll
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final _open = _dll
      .lookupFunction<
        Pointer<Void> Function(
          Pointer<Uint16>,
          Uint32,
          Uint32,
          Pointer<Void>,
          Uint32,
          Uint32,
          Pointer<Void>,
        ),
        Pointer<Void> Function(
          Pointer<Uint16>,
          int,
          int,
          Pointer<Void>,
          int,
          int,
          Pointer<Void>,
        )
      >('CreateFileW');
  late final _close = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  late final _info = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('GetFileInformationByHandle');
  late final _drive = _dll
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetDriveTypeW');
  late final _volume = _dll
      .lookupFunction<
        Int32 Function(
          Pointer<Uint16>,
          Pointer<Uint16>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint16>,
          Uint32,
        ),
        int Function(
          Pointer<Uint16>,
          Pointer<Uint16>,
          int,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint32>,
          Pointer<Uint16>,
          int,
        )
      >('GetVolumeInformationW');
  late final _attributes = _dll
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetFileAttributesW');
  late final _error = _dll.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
    isLeaf: true,
  );
  late final _finalName = _dll
      .lookupFunction<
        Uint32 Function(Pointer<Void>, Pointer<Uint16>, Uint32, Uint32),
        int Function(Pointer<Void>, Pointer<Uint16>, int, int)
      >('GetFinalPathNameByHandleW');
  late final _mkdir = _dll
      .lookupFunction<
        Int32 Function(Pointer<Uint16>, Pointer<Void>),
        int Function(Pointer<Uint16>, Pointer<Void>)
      >('CreateDirectoryW');
  late final _delete = _dll
      .lookupFunction<
        Int32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('DeleteFileW');
  late final _rmdir = _dll
      .lookupFunction<
        Int32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('RemoveDirectoryW');
  late final _read = _dll
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('ReadFile');
  late final _write = _dll
      .lookupFunction<
        Int32 Function(
          Pointer<Void>,
          Pointer<Void>,
          Uint32,
          Pointer<Uint32>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          int,
          Pointer<Uint32>,
          Pointer<Void>,
        )
      >('WriteFile');
  late final _seek = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int64, Pointer<Int64>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Int64>, int)
      >('SetFilePointerEx');
  late final _flush = _dll
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('FlushFileBuffers');
  late final _module = _dll
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Uint16>, Pointer<Pointer<Void>>),
        int Function(int, Pointer<Uint16>, Pointer<Pointer<Void>>)
      >('GetModuleHandleExW');
  late final _symbol = _dll
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>)
      >('GetProcAddress');

  Pointer<Void> allocate(int bytes) {
    final result = _alloc(0x40, bytes);
    if (result == nullptr) _refuse(DatabaseRestoreCode.unsupported);
    return result;
  }

  void free(Pointer<Void> pointer) => _free(pointer);
  T text<T>(String value, T Function(Pointer<Uint16>) action) {
    final memory = allocate((value.length + 1) * 2).cast<Uint16>();
    try {
      memory.asTypedList(value.length + 1).setAll(0, value.codeUnits);
      return action(memory);
    } finally {
      free(memory.cast());
    }
  }

  T ascii<T>(String value, T Function(Pointer<Uint8>) action) {
    final bytes = asciiCodec.encode(value);
    final memory = allocate(bytes.length + 1).cast<Uint8>();
    try {
      memory.asTypedList(bytes.length + 1).setAll(0, bytes);
      return action(memory);
    } finally {
      free(memory.cast());
    }
  }

  static const asciiCodec = AsciiCodec();

  void requirePath(String path) {
    final parts = p.windows.split(path);
    if (!RegExp(r'^[A-Za-z]:\\').hasMatch(path) ||
        path.length > 220 ||
        p.windows.normalize(path) != path ||
        path.substring(2).contains(':') ||
        path.contains('\u0000') ||
        path.contains('/') ||
        parts
            .skip(1)
            .any(
              (s) =>
                  s.isEmpty ||
                  s.endsWith('.') ||
                  s.endsWith(' ') ||
                  s.contains(RegExp(r'[<>"|?*]')) ||
                  RegExp(
                    r'^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(\.|$)',
                    caseSensitive: false,
                  ).hasMatch(s),
            )) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    text(p.windows.rootPrefix(path), (root) {
      if (_drive(root) != 3) _refuse(DatabaseRestoreCode.unsupported);
      final name = allocate(512).cast<Uint16>();
      try {
        if (_volume(root, nullptr, 0, nullptr, nullptr, nullptr, name, 256) ==
                0 ||
            String.fromCharCodes(
                  name.asTypedList(256).takeWhile((n) => n != 0),
                ) !=
                'NTFS') {
          _refuse(DatabaseRestoreCode.unsupported);
        }
      } finally {
        free(name.cast());
      }
    });
  }

  bool exists(String path) => text(path, (name) {
    final attributes = _attributes;
    final error = _error;
    error();
    final value = attributes(name);
    final code = error();
    if (value != 0xffffffff) return true;
    if (code == 2 || code == 3) return false;
    _refuse(DatabaseRestoreCode.unsupported);
    return false;
  });

  _RestorePin pin(
    String path, {
    bool directory = false,
    bool immutable = false,
    bool lock = false,
    bool create = false,
    bool write = false,
  }) => text(path, (name) {
    final handle = _open(
      name,
      0x80000000 | (write ? 0x40000000 : 0),
      lock
          ? 0
          : immutable
          ? 1
          : 3,
      nullptr,
      lock
          ? 4
          : create
          ? 1
          : 3,
      0x00200000 | (directory ? 0x02000000 : 0),
      nullptr,
    );
    if (!_valid(handle))
      _refuse(
        lock ? DatabaseRestoreCode.busy : DatabaseRestoreCode.unsupported,
      );
    try {
      final info = information(handle);
      if ((info[0] & 0x400) != 0 ||
          (((info[0] & 0x10) != 0) != directory) ||
          (!directory && info[10] != 1))
        _refuse(DatabaseRestoreCode.unsupported);
      final output = allocate(1024).cast<Uint16>();
      try {
        final length = _finalName(handle, output, 512, 0);
        if (length == 0 || length >= 512)
          _refuse(DatabaseRestoreCode.unsupported);
        final actual = String.fromCharCodes(output.asTypedList(length));
        if (!p.windows.equals(actual, '\\\\?\\$path'))
          _refuse(DatabaseRestoreCode.unsupported);
      } finally {
        free(output.cast());
      }
      return _RestoreWindowsPin(this, handle, path, (
        info[7],
        info[11],
        info[12],
      ), directory);
    } catch (_) {
      _close(handle);
      rethrow;
    }
  });
  bool _valid(Pointer<Void> handle) =>
      handle != nullptr &&
      handle.address != -1 &&
      handle.address != 0xffffffffffffffff;
  List<int> information(Pointer<Void> handle) {
    final memory = allocate(52).cast<Uint32>();
    try {
      if (_info(handle, memory.cast()) == 0)
        _refuse(DatabaseRestoreCode.unsupported);
      return List<int>.of(memory.asTypedList(13));
    } finally {
      free(memory.cast());
    }
  }

  void closeHandle(Pointer<Void> handle) {
    if (_close(handle) == 0) _refuse(DatabaseRestoreCode.recoveryRequired);
  }

  Pointer<Void> borrowModule(Pointer<Void> address) {
    final slot = allocate(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
    try {
      if (address == nullptr ||
          _module(4 | 2, address.cast(), slot) == 0 ||
          slot.value == nullptr) {
        _refuse(DatabaseRestoreCode.unsupported);
      }
      return slot
          .value; // FROM_ADDRESS | UNCHANGED_REFCOUNT; never FreeLibrary.
    } finally {
      free(slot.cast());
    }
  }

  Pointer<Void> symbol(Pointer<Void> module, String name) =>
      ascii(name, (text) => _symbol(module, text));

  String createStage(String parent) {
    final random = Random.secure();
    final nonce = List.generate(
      16,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final path = p.windows.join(parent, '.restore-$nonce');
    requirePath(path);
    if (text(path, (name) => _mkdir(name, nullptr)) == 0)
      _refuse(DatabaseRestoreCode.unsupported);
    return path;
  }

  void deleteOwnedFile(String path) {
    if (text(path, _delete) == 0) _refuse(DatabaseRestoreCode.recoveryRequired);
  }

  void deleteOwnedDirectory(String path) {
    if (text(path, _rmdir) == 0) _refuse(DatabaseRestoreCode.recoveryRequired);
  }

  /// All bytes come from THIS native pin, never a path-reopened Dart reader.
  Future<Digest> copyOrHash(
    _RestorePin input,
    void Function() check, {
    _RestorePin? output,
  }) async {
    input.check();
    final length = input.length;
    if (length > _RestoreLimits.maxBytes) _refuse(DatabaseRestoreCode.tooLarge);
    final memory = allocate(_RestoreLimits.chunk + 24);
    final bytes = memory.cast<Uint8>();
    final count = (bytes + _RestoreLimits.chunk).cast<Uint32>();
    final written = (bytes + _RestoreLimits.chunk + 4).cast<Uint32>();
    final position = (bytes + _RestoreLimits.chunk + 8).cast<Int64>();
    final digest = _RestoreDigestSink();
    final sink = sha256.startChunkedConversion(digest);
    try {
      if (_seek(input.handle, 0, position, 0) == 0 || position.value != 0)
        _refuse(DatabaseRestoreCode.unsupported);
      var offset = 0;
      while (offset < length) {
        check();
        final n = min(_RestoreLimits.chunk, length - offset);
        count.value = 0;
        if (_read(input.handle, memory, n, count, nullptr) == 0 ||
            count.value != n)
          _refuse(DatabaseRestoreCode.unsupported);
        sink.add(Uint8List.sublistView(bytes.asTypedList(n), 0, n));
        if (output != null) {
          written.value = 0;
          if (_write(output.handle, memory, n, written, nullptr) == 0 ||
              written.value != n)
            _refuse(DatabaseRestoreCode.unsupported);
        }
        offset += n;
        await Future<void>.delayed(Duration.zero);
        check();
      }
      count.value = 0;
      if (_read(input.handle, memory, 1, count, nullptr) == 0 ||
          count.value != 0 ||
          input.length != length) {
        _refuse(DatabaseRestoreCode.stale);
      }
      input.check();
      if (output != null && _flush(output.handle) == 0)
        _refuse(DatabaseRestoreCode.recoveryRequired);
    } finally {
      sink.close();
      free(memory);
    }
    return digest.value!;
  }

  void writeMarker(_RestorePin marker, String stageBasename) {
    // Bounded locator ONLY; no approval, command, source path or model data.
    final data = utf8.encode('restore-interrupted-v1\n$stageBasename\n');
    final countOffset = (data.length + 3) & ~3;
    final memory = allocate(countOffset + 4);
    try {
      memory.cast<Uint8>().asTypedList(data.length).setAll(0, data);
      final count = (memory.cast<Uint8>() + countOffset).cast<Uint32>();
      if (_write(marker.handle, memory, data.length, count, nullptr) == 0 ||
          count.value != data.length ||
          _flush(marker.handle) == 0) {
        _refuse(DatabaseRestoreCode.recoveryRequired);
      }
    } finally {
      free(memory);
    }
  }
}

final class _RestoreWindowsPin implements _RestorePin {
  _RestoreWindowsPin(
    this.api,
    this.handle,
    this.path,
    this.identity,
    this.directory,
  );
  final _RestoreWindows api;
  final Pointer<Void> handle;
  final String path;
  final (int, int, int) identity;
  final bool directory;
  bool closed = false;
  int get length {
    if (closed) _refuse(DatabaseRestoreCode.closed);
    final info = api.information(handle);
    return info[8] * 0x100000000 + info[9];
  }

  void check() {
    if (closed) _refuse(DatabaseRestoreCode.stale);
    final info = api.information(handle);
    if ((info[7], info[11], info[12]) != identity ||
        (info[0] & 0x400) != 0 ||
        (!directory && info[10] != 1)) {
      _refuse(DatabaseRestoreCode.stale);
    }
    // A no-delete-share retained handle protects this canonical namespace.
  }

  void close() {
    if (closed) return;
    api.closeHandle(handle);
    closed = true;
  }
}

final class _RestoreDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
