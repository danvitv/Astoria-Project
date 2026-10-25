part of '../database_snapshot_service.dart';

/// Windows local NTFS only. Dart FileStat doesn't expose stable file IDs and
/// File.rename may replace a target, so neither is an identity/publication port.
final class _WindowsApi {
  _WindowsApi() : library = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary library;
  late final _allocate = library
      .lookupFunction<
        Pointer<Void> Function(Uint32, IntPtr),
        Pointer<Void> Function(int, int)
      >('LocalAlloc');
  late final _free = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>),
        Pointer<Void> Function(Pointer<Void>)
      >('LocalFree');
  late final _open = library
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
  late final _close = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  late final _info = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('GetFileInformationByHandle');
  late final _readFile = library
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
  late final _setFilePointer = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int64, Pointer<Int64>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Int64>, int)
      >('SetFilePointerEx');
  late final _setInfo = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32),
        int Function(Pointer<Void>, int, Pointer<Void>, int)
      >('SetFileInformationByHandle');
  late final _attributes = library
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetFileAttributesW');
  // Pure thread-local DWORD getter: no filesystem work, blocking or callbacks.
  // Only this error consumer is leaf; the filesystem producer remains non-leaf.
  late final _error = library.lookupFunction<Uint32 Function(), int Function()>(
    'GetLastError',
    isLeaf: true,
  );
  late final _drive = library
      .lookupFunction<
        Uint32 Function(Pointer<Uint16>),
        int Function(Pointer<Uint16>)
      >('GetDriveTypeW');
  late final _volume = library
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

  Pointer<Void> allocate(int bytes) {
    final pointer = _allocate(0x40, bytes); // LPTR: zero initialized.
    if (pointer == nullptr) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
    }
    return pointer;
  }

  void free(Pointer<Void> pointer) {
    _free(pointer);
  }

  T _withText<T>(String text, T Function(Pointer<Uint16>) body) {
    final pointer = allocate((text.length + 1) * 2).cast<Uint16>();
    try {
      pointer.asTypedList(text.length + 1).setAll(0, text.codeUnits);
      return body(pointer);
    } finally {
      free(pointer.cast());
    }
  }

  _SnapshotFailure _identityFailure(
    DatabaseSnapshotIdentityRole role,
    DatabaseSnapshotIdentityBoundary boundary,
  ) => _SnapshotFailure(
    DatabaseSnapshotStatus.unsupportedIdentity,
    identityFailure: DatabaseSnapshotIdentityFailure._(role, boundary),
  );

  void requireLocalPath(String path, DatabaseSnapshotIdentityRole role) {
    final parts = p.windows.split(path);
    if (!RegExp(r'^[a-zA-Z]:\\').hasMatch(path) ||
        path.length > 200 ||
        p.windows.normalize(path) != path ||
        path.substring(2).contains(':') ||
        path.contains('\u0000') ||
        path.contains('/') ||
        parts
            .skip(1)
            .any(
              (part) =>
                  part.isEmpty ||
                  part.endsWith('.') ||
                  part.endsWith(' ') ||
                  part.contains(RegExp(r'[<>"|?*]')),
            )) {
      throw _identityFailure(
        role,
        DatabaseSnapshotIdentityBoundary.canonicalPath,
      );
    }
    final root = p.windows.rootPrefix(path);
    _withText(root, (pointer) {
      if (_drive(pointer) != 3) {
        // DRIVE_FIXED, never network or removable.
        throw _identityFailure(
          role,
          DatabaseSnapshotIdentityBoundary.localFixedDrive,
        );
      }
      final name = allocate(512).cast<Uint16>();
      try {
        if (_volume(
              pointer,
              nullptr,
              0,
              nullptr,
              nullptr,
              nullptr,
              name,
              256,
            ) ==
            0) {
          throw _identityFailure(
            role,
            DatabaseSnapshotIdentityBoundary.volumeInformation,
          );
        }
        final chars = name.asTypedList(256).takeWhile((c) => c != 0).toList();
        if (String.fromCharCodes(chars) != 'NTFS') {
          throw _identityFailure(role, DatabaseSnapshotIdentityBoundary.ntfs);
        }
      } finally {
        free(name.cast());
      }
    });
  }

  bool exists(
    String path, {
    DatabaseSnapshotIdentityRole role = DatabaseSnapshotIdentityRole.ownedStage,
  }) => _withText(path, (pointer) {
    // Symbol resolution is not the first FFI invocation. Resolve both bindings
    // and invoke the pure error getter BEFORE producing the error to capture,
    // so its cold call setup is outside the capture interval as well.
    final getAttributes = _attributes;
    final getLastError = _error;
    getLastError();
    final attributes = getAttributes(pointer);
    final error = getLastError(); // Before Dart branching can enter the VM.
    if (attributes != 0xffffffff) return true;
    if (error == 2 || error == 3) return false;
    throw _identityFailure(
      role,
      DatabaseSnapshotIdentityBoundary.entryAttributes,
    );
  });

  _WindowsPin open(
    String path, {
    bool directory = false,
    bool create = false,
    bool immutable = false,
    bool renameAccess = false,
    bool probeImmutable = false,
    DatabaseSnapshotIdentityRole role = DatabaseSnapshotIdentityRole.ownedStage,
  }) => _withText(path, (pointer) {
    // No FILE_SHARE_DELETE: source and ancestors cannot be swapped, unlinked
    // or redirected. The sealed snapshot also denies write-sharing.
    final handle = _open(
      pointer,
      0x80000000 | (renameAccess ? 0x10000 : 0),
      probeImmutable ? 7 : (immutable ? 1 : 3),
      nullptr,
      create ? 1 : 3,
      0x00200000 | (directory ? 0x02000000 : 0),
      nullptr,
    );
    if (handle == nullptr ||
        handle.address == -1 ||
        handle.address ==
            (sizeOf<IntPtr>() == 8 ? 0xffffffffffffffff : 0xffffffff)) {
      throw _identityFailure(role, DatabaseSnapshotIdentityBoundary.handleOpen);
    }
    try {
      final info = information(handle, role: role);
      final attributes = info[0];
      if ((attributes & 0x400) != 0) {
        throw _identityFailure(
          role,
          DatabaseSnapshotIdentityBoundary.reparsePoint,
        );
      }
      if (((attributes & 0x10) != 0) != directory) {
        throw _identityFailure(
          role,
          DatabaseSnapshotIdentityBoundary.entityKind,
        );
      }
      if (!directory && info[10] != 1) {
        throw _identityFailure(
          role,
          DatabaseSnapshotIdentityBoundary.linkCount,
        );
      }
      return _WindowsPin(this, handle, path, directory, immutable, (
        info[7],
        info[11],
        info[12],
      ), role);
    } catch (_) {
      _close(handle);
      rethrow;
    }
  });

  List<int> information(
    Pointer<Void> handle, {
    DatabaseSnapshotIdentityRole role = DatabaseSnapshotIdentityRole.ownedStage,
  }) {
    final memory = allocate(52).cast<Uint32>();
    try {
      if (_info(handle, memory.cast()) == 0) {
        throw _identityFailure(
          role,
          DatabaseSnapshotIdentityBoundary.handleInformation,
        );
      }
      return List<int>.of(memory.asTypedList(13));
    } finally {
      free(memory.cast());
    }
  }

  void renameNoReplace(_WindowsPin pin, String destination) {
    // Rename using the OWNED file handle: false ReplaceIfExists is an atomic
    // no-overwrite operation even if another file appears at the destination.
    final pointerSize = sizeOf<IntPtr>();
    final lengthOffset = pointerSize == 8 ? 16 : 8;
    final nameOffset = lengthOffset + 4;
    final bytes = nameOffset + destination.length * 2;
    final memory = allocate(bytes);
    try {
      memory
          .cast<Uint8>()
          .asTypedList(bytes)
          .buffer
          .asByteData()
          .setUint32(lengthOffset, destination.length * 2, Endian.host);
      (memory.cast<Uint8>() + nameOffset)
          .cast<Uint16>()
          .asTypedList(destination.length)
          .setAll(0, destination.codeUnits);
      if (_setInfo(pin.handle, 3, memory, bytes) == 0) {
        throw _SnapshotFailure(
          exists(destination)
              ? DatabaseSnapshotStatus.destinationExists
              : DatabaseSnapshotStatus.unsupportedIdentity,
        );
      }
      pin.path = destination;
    } finally {
      free(memory);
    }
  }

  void deleteOwned(_WindowsPin pin) {
    final memory = allocate(1).cast<Uint8>();
    try {
      memory.value = 1;
      if (_setInfo(pin.handle, 4, memory.cast(), 1) == 0) {
        throw const _SnapshotFailure(
          DatabaseSnapshotStatus.unsupportedIdentity,
        );
      }
    } finally {
      free(memory.cast());
    }
  }
}

/// Native file ID and an immutable no-write/no-delete-share retained handle.
final class _WindowsPin {
  _WindowsPin(
    this.api,
    this.handle,
    this.path,
    this.directory,
    this.immutable,
    this.identity,
    this.role,
  );
  final _WindowsApi api;
  final Pointer<Void> handle;
  String path;
  final bool directory;
  final bool immutable;
  final (int, int, int) identity;
  final DatabaseSnapshotIdentityRole role;
  bool closed = false;
  bool _hashing = false;
  bool _closeRequested = false;

  int get length {
    if (closed || _closeRequested) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    final info = api.information(handle, role: role);
    return info[8] * 0x100000000 + info[9];
  }

  void checkPath() {
    if (closed || _closeRequested) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    final other = api.open(
      path,
      directory: directory,
      probeImmutable: immutable,
      role: role,
    );
    try {
      if (identity != other.identity) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
      }
    } finally {
      other.close();
    }
  }

  Future<Digest> hash(_SnapshotGuard guard) async {
    if (_hashing) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unavailable);
    }
    if (closed || _closeRequested) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    guard.check();
    if (closed || _closeRequested) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    if (!immutable || directory) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
    }
    _hashing = true;
    Pointer<Void> memory = nullptr;
    try {
      _checkHash(guard);
      checkPath();
      _checkHash(guard);
      // One bounded allocation: bytes, DWORD read count, aligned LARGE_INTEGER
      // position and the existing 52-byte BY_HANDLE_FILE_INFORMATION layout.
      memory = api.allocate(_SnapshotLimits.hashChunk + 72);
      _checkHash(guard);
      final bytes = memory.cast<Uint8>();
      final buffer = bytes.asTypedList(_SnapshotLimits.hashChunk);
      final count = (bytes + _SnapshotLimits.hashChunk).cast<Uint32>();
      final position = (bytes + (_SnapshotLimits.hashChunk + 8)).cast<Int64>();
      final info = (bytes + (_SnapshotLimits.hashChunk + 16)).cast<Uint32>();
      final size = _hashLength(guard, info);
      if (size <= 0 || size > _SnapshotLimits.maxBytes) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.tooLarge);
      }
      final seek = api._setFilePointer;
      final readFile = api._readFile;
      _checkHash(guard);
      final moved = seek(handle, 0, position, 0); // FILE_BEGIN.
      _checkHash(guard);
      if (moved == 0) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
      if (position.value != 0) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
      }
      final output = _SnapshotDigestSink();
      final input = sha256.startChunkedConversion(output);
      final chunks =
          (size + _SnapshotLimits.hashChunk - 1) ~/ _SnapshotLimits.hashChunk;
      var read = 0;
      for (var chunk = 0; chunk < chunks; chunk++) {
        final requested = min(_SnapshotLimits.hashChunk, size - read);
        count.value = 0;
        _checkHash(guard);
        final ok = readFile(
          handle,
          memory,
          requested,
          count,
          nullptr, // This original handle is synchronous, not OVERLAPPED.
        );
        _checkHash(guard);
        if (ok == 0 || count.value != requested) {
          throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
        }
        input.add(Uint8List.sublistView(buffer, 0, requested));
        read += requested;
        _checkHash(guard);
        await Future<void>.delayed(Duration.zero);
        _checkHash(guard);
      }
      // Exact EOF on the SAME handle; never reopen a byte reader by path.
      count.value = 0;
      _checkHash(guard);
      final eof = readFile(handle, memory, 1, count, nullptr);
      _checkHash(guard);
      if (eof == 0 || count.value != 0 || read != size) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.invalid);
      }
      if (_hashLength(guard, info) != size) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
      }
      _checkHash(guard);
      checkPath();
      _checkHash(guard);
      input.close();
      _checkHash(guard);
      return output.value!;
    } finally {
      // Cleanup must run even when cancelled/stale. The original pin cannot be
      // closed/reused across a yield until this runner has stopped native reads.
      try {
        if (memory != nullptr) api.free(memory);
      } finally {
        _hashing = false;
        if (_closeRequested) close();
      }
    }
  }

  void _checkHash(_SnapshotGuard guard) {
    if (!_hashing || closed || _closeRequested) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    guard.check();
    // Native current predicates may synchronously request disposal themselves.
    if (closed || _closeRequested) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
  }

  int _hashLength(_SnapshotGuard guard, Pointer<Uint32> memory) {
    _checkHash(guard);
    final ok = api._info(handle, memory.cast());
    _checkHash(guard);
    if (ok == 0) {
      throw api._identityFailure(
        role,
        DatabaseSnapshotIdentityBoundary.handleInformation,
      );
    }
    final info = memory.asTypedList(13);
    if ((info[7], info[11], info[12]) != identity) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    return info[8] * 0x100000000 + info[9];
  }

  void close() {
    if (!closed) {
      if (_hashing) {
        _closeRequested = true;
        return;
      }
      if (api._close(handle) == 0) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
      }
      closed = true;
    }
  }
}

final class _SnapshotDigestSink implements Sink<Digest> {
  Digest? value;
  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}
