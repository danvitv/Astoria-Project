import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/unstable/ffi_bindings.dart' as nsql;

enum SqliteNativeAbiStatus {
  supported,
  unsupportedPlatform,
  unsupportedTempRoot,
  unsupportedNativeApi,
  unsupportedAllocation,
  unsupportedModule,
  unsupportedKnownSymbolIdentity,
  unsupportedFileControlExport,
  unsupportedTxnStateExport,
  unsupportedOwnedDiskSetup,
  unsupportedVfs,
  unsupportedFileHandle,
  unsupportedFileIdentity,
  unsupportedIdleState,
  unsupportedCleanup,
}

/// Fixed diagnostics only: never include native paths or SQLite error bodies.
final class SqliteNativeAbiFailure implements Exception {
  const SqliteNativeAbiFailure(this.status);
  final SqliteNativeAbiStatus status;

  @override
  String toString() => 'SQLite restore ABI unsupported: ${status.name}';
}

/// One Windows shipped-module availability probe, not a restore/lease proof.
SqliteNativeAbiStatus probeSqliteNativeRestoreAbi({
  required Directory approvedTempRoot,
}) {
  if (!Platform.isWindows || sizeOf<UintPtr>() != 8) {
    throw const SqliteNativeAbiFailure(
      SqliteNativeAbiStatus.unsupportedPlatform,
    );
  }
  if (approvedTempRoot.path != r'C:\Users\Даниил\AppData\Local\Temp\opencode') {
    throw const SqliteNativeAbiFailure(
      SqliteNativeAbiStatus.unsupportedTempRoot,
    );
  }

  _WindowsAbiApi? api;
  Directory? ownedDirectory;
  String? ownedPath;
  Database? database;
  Pointer<Void> ownedNamePin = nullptr;
  var phase = SqliteNativeAbiStatus.unsupportedNativeApi;
  SqliteNativeAbiFailure? firstFailure;
  StackTrace? firstStack;

  void remember(Object error, StackTrace stack, SqliteNativeAbiStatus reason) {
    firstFailure ??= error is SqliteNativeAbiFailure
        ? error
        : SqliteNativeAbiFailure(reason);
    firstStack ??= stack;
  }

  void cleanup(void Function() action) {
    try {
      action();
    } catch (error, stack) {
      remember(error, stack, SqliteNativeAbiStatus.unsupportedCleanup);
    }
  }

  try {
    final windows = api = _WindowsAbiApi();
    phase = SqliteNativeAbiStatus.unsupportedModule;
    final controls = _SameModuleControls.resolve(windows);

    // No disk access occurs until the actual module/export gate has passed.
    phase = SqliteNativeAbiStatus.unsupportedOwnedDiskSetup;
    final directory = ownedDirectory = approvedTempRoot.createTempSync(
      'sqlite-restore-abi-',
    );
    final path = ownedPath = '${directory.path}\\abi.db';
    final db = database = sqlite3.open(path, mode: OpenMode.readWriteCreate);
    db.execute('CREATE TABLE abi_probe (value INTEGER NOT NULL)');
    db.execute('INSERT INTO abi_probe VALUES (1)');
    // Only one tiny synthetic table/row; do not use an application DB/schema.
    if (File(path).lengthSync() > 64 * 1024) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedOwnedDiskSetup,
      );
    }

    phase = SqliteNativeAbiStatus.unsupportedFileHandle;
    ownedNamePin = windows.openNamePin(path);
    phase = SqliteNativeAbiStatus.unsupportedVfs;
    controls.verifyConnection(windows, db, ownedNamePin);
  } catch (error, stack) {
    remember(error, stack, phase);
  } finally {
    // No SQLite function is invoked after this owned connection is closed.
    var databaseClosed = database == null;
    cleanup(() {
      database?.close();
      databaseClosed = true;
    });
    final windows = api;
    var pinClosed = ownedNamePin == nullptr;
    if (databaseClosed && windows != null && !pinClosed) {
      cleanup(() {
        windows.closeOwnedNamePin(ownedNamePin);
        pinClosed = true;
      });
    }
    if (windows != null) {
      for (final allocation in windows.allocations) {
        cleanup(() => windows.free(allocation));
      }
    }
    // On close failure, retain the pin/files rather than unlink an open DB.
    // No directory inventory or recursive deletion, even on a failing probe.
    final path = ownedPath;
    if (databaseClosed && pinClosed && path != null) {
      for (final exactPath in [path, '$path-journal']) {
        cleanup(() {
          final file = File(exactPath);
          if (file.existsSync()) file.deleteSync();
        });
      }
    }
    if (databaseClosed && pinClosed && ownedDirectory != null) {
      cleanup(() => ownedDirectory!.deleteSync());
    }
  }
  if (firstFailure != null) {
    Error.throwWithStackTrace(firstFailure!, firstStack!);
  }
  return SqliteNativeAbiStatus.supported;
}

typedef _BackupInitNative =
    Pointer<nsql.sqlite3_backup> Function(
      Pointer<nsql.sqlite3>,
      Pointer<nsql.sqlite3_char>,
      Pointer<nsql.sqlite3>,
      Pointer<nsql.sqlite3_char>,
    );
typedef _AutocommitNative = Int Function(Pointer<nsql.sqlite3>);
typedef _FileControlNative =
    Int Function(Pointer<nsql.sqlite3>, Pointer<Char>, Int, Pointer<Void>);
typedef _FileControlDart =
    int Function(Pointer<nsql.sqlite3>, Pointer<Char>, int, Pointer<Void>);
typedef _TxnStateNative = Int Function(Pointer<nsql.sqlite3>, Pointer<Char>);
typedef _TxnStateDart = int Function(Pointer<nsql.sqlite3>, Pointer<Char>);

/// Test-only reuse of the proved ABI bridge. Callers own and serialize every
/// supplied live database and pin; no SQLite work is allowed after raw close.
final class SqliteRestoreTestAbi {
  SqliteRestoreTestAbi() {
    if (!Platform.isWindows || sizeOf<UintPtr>() != 8) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedPlatform,
      );
    }
    try {
      _controls = _SameModuleControls.resolve(_windows);
      main = _windows.utf8Text('main').cast<nsql.sqlite3_char>();
    } catch (error, stack) {
      close();
      Error.throwWithStackTrace(error, stack);
    }
  }

  final _windows = _WindowsAbiApi();
  late final _SameModuleControls _controls;
  late final Pointer<nsql.sqlite3_char> main;
  bool _closed = false;

  void _requireLive() {
    if (_closed || _windows.allocations.length > 2048) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedAllocation,
      );
    }
  }

  Pointer<Void> openNamePin(String path) {
    _requireLive();
    return _windows.openNamePin(path);
  }

  void closeOwnedNamePin(Pointer<Void> pin) {
    _requireLive();
    _windows.closeOwnedNamePin(pin);
  }

  void verifyConnection(Database db, Pointer<Void> pin) {
    _requireLive();
    _controls.verifyConnection(_windows, db, pin);
  }

  int transactionState(Database db) {
    _requireLive();
    return _controls.txnState(db.handle.cast(), main.cast());
  }

  /// These settings preserve an actually created WAL for observation, not an
  /// unchanged-bootstrap guarantee. No journal mode switch occurs here.
  void preserveWalOnOwnedConnection(Database db) {
    _requireLive();
    final output = _windows.allocate(sizeOf<Int>()).cast<Int>();
    output.value = 1;
    if (_controls.fileControl(
          db.handle.cast(),
          main.cast(),
          10,
          output.cast(),
        ) !=
        0) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedFileControlExport,
      );
    }
    // SQLITE_DBCONFIG_NO_CKPT_ON_CLOSE: exact existing int/int* signature.
    if (nsql.sqlite3_db_config(db.handle.cast(), 1006, 1, output) != 0 ||
        output.value != 1) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedNativeApi,
      );
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    Object? first;
    StackTrace? firstStack;
    for (final pointer in _windows.allocations) {
      try {
        _windows.free(pointer);
      } catch (error, stack) {
        first ??= error;
        firstStack ??= stack;
      }
    }
    if (first != null) Error.throwWithStackTrace(first, firstStack!);
  }
}

final class _SameModuleControls {
  _SameModuleControls(this.fileControl, this.txnState);
  final _FileControlDart fileControl;
  final _TxnStateDart txnState;

  static _SameModuleControls resolve(_WindowsAbiApi windows) {
    // These exact types match the public generated @Native declarations.
    final Pointer<NativeFunction<_BackupInitNative>> backupAddress =
        Native.addressOf(nsql.sqlite3_backup_init);
    final Pointer<NativeFunction<_AutocommitNative>> autocommitAddress =
        Native.addressOf(nsql.sqlite3_get_autocommit);
    final module = windows.borrowModuleFromAddress(backupAddress.cast());
    if (autocommitAddress == nullptr ||
        windows.symbol(module, 'sqlite3_backup_init').address !=
            backupAddress.address ||
        windows.symbol(module, 'sqlite3_get_autocommit').address !=
            autocommitAddress.address) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedKnownSymbolIdentity,
      );
    }
    final control = windows.symbol(module, 'sqlite3_file_control');
    if (control == nullptr) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedFileControlExport,
      );
    }
    final txn = windows.symbol(module, 'sqlite3_txn_state');
    if (txn == nullptr) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedTxnStateExport,
      );
    }
    // Public C ABI only; never read any sqlite3_file/VFS struct offsets.
    return _SameModuleControls(
      control
          .cast<NativeFunction<_FileControlNative>>()
          .asFunction<_FileControlDart>(),
      txn.cast<NativeFunction<_TxnStateNative>>().asFunction<_TxnStateDart>(),
    );
  }

  void verifyConnection(
    _WindowsAbiApi windows,
    Database database,
    Pointer<Void> ownedNamePin,
  ) {
    final db = database.handle.cast<nsql.sqlite3>();
    final main = windows.utf8Text('main').cast<Char>();
    final vfsName = windows
        .allocate(sizeOf<Pointer<Char>>())
        .cast<Pointer<Char>>();
    SqliteNativeAbiFailure? firstVfsFailure;
    StackTrace? firstVfsStack;
    try {
      // SQLITE_FCNTL_VFSNAME returns SQLite-allocated text via char**.
      final code = fileControl(db, main, 12, vfsName.cast());
      if (code != 0 || vfsName.value == nullptr) {
        throw const SqliteNativeAbiFailure(
          SqliteNativeAbiStatus.unsupportedVfs,
        );
      }
      // Exact, bounded stock locking VFS name; no win32-none or wrapper.
      final bytes = vfsName.value.cast<Uint8>();
      const expected = [0x77, 0x69, 0x6e, 0x33, 0x32, 0]; // win32\0
      for (var i = 0; i < expected.length; i++) {
        if (bytes[i] != expected[i]) {
          throw const SqliteNativeAbiFailure(
            SqliteNativeAbiStatus.unsupportedVfs,
          );
        }
      }
    } catch (error, stack) {
      firstVfsFailure = error is SqliteNativeAbiFailure
          ? error
          : const SqliteNativeAbiFailure(SqliteNativeAbiStatus.unsupportedVfs);
      firstVfsStack = stack;
    } finally {
      // This string, and ONLY this string, was allocated by SQLite.
      try {
        if (vfsName.value != nullptr) nsql.sqlite3_free(vfsName.value.cast());
      } catch (error, stack) {
        firstVfsFailure ??= error is SqliteNativeAbiFailure
            ? error
            : const SqliteNativeAbiFailure(
                SqliteNativeAbiStatus.unsupportedCleanup,
              );
        firstVfsStack ??= stack;
      }
    }
    if (firstVfsFailure != null) {
      Error.throwWithStackTrace(firstVfsFailure!, firstVfsStack!);
    }

    final handleSlot = windows
        .allocate(sizeOf<Pointer<Void>>())
        .cast<Pointer<Void>>();
    final code = fileControl(db, main, 29, handleSlot.cast());
    final borrowedSqliteHandle = handleSlot.value;
    if (code != 0 || !windows.validHandle(borrowedSqliteHandle)) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedFileHandle,
      );
    }
    // SQLITE_FCNTL_WIN32_GET_HANDLE: borrowed handle, never closed/mutated.
    if (windows.identity(borrowedSqliteHandle) !=
        windows.identity(ownedNamePin)) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedFileIdentity,
      );
    }
    if (txnState(db, main) != 0 || nsql.sqlite3_get_autocommit(db) != 1) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedIdleState,
      );
    }
  }
}

/// Windows SDK types; x64/ARM64 use the platform's unified calling convention.
/// The probe rejects 32-bit Windows instead of assuming a stdcall bridge.
final class _WindowsAbiApi {
  _WindowsAbiApi() : library = DynamicLibrary.open('kernel32.dll');
  final DynamicLibrary library;
  final allocations = <Pointer<Void>>[];

  late final _getHeap = library
      .lookupFunction<Pointer<Void> Function(), Pointer<Void> Function()>(
        'GetProcessHeap',
      );
  late final _heap = _getHeap(); // Borrowed process heap, never destroyed.
  late final _heapAlloc = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Uint32, UintPtr),
        Pointer<Void> Function(Pointer<Void>, int, int)
      >('HeapAlloc');
  late final _heapFree = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Uint32, Pointer<Void>),
        int Function(Pointer<Void>, int, Pointer<Void>)
      >('HeapFree');
  late final _moduleFromAddress = library
      .lookupFunction<
        Int32 Function(Uint32, Pointer<Uint16>, Pointer<Pointer<Void>>),
        int Function(int, Pointer<Uint16>, Pointer<Pointer<Void>>)
      >('GetModuleHandleExW');
  late final _procAddress = library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Uint8>)
      >('GetProcAddress');
  late final _createFile = library
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
  late final _closeHandle = library
      .lookupFunction<
        Int32 Function(Pointer<Void>),
        int Function(Pointer<Void>)
      >('CloseHandle');
  late final _fileInformation = library
      .lookupFunction<
        Int32 Function(Pointer<Void>, Pointer<_FileInformation>),
        int Function(Pointer<Void>, Pointer<_FileInformation>)
      >('GetFileInformationByHandle');

  Pointer<Void> allocate(int bytes) {
    if (_heap == nullptr) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedAllocation,
      );
    }
    final pointer = _heapAlloc(_heap, 8, bytes); // HEAP_ZERO_MEMORY.
    if (pointer == nullptr) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedAllocation,
      );
    }
    allocations.add(pointer);
    return pointer;
  }

  void free(Pointer<Void> pointer) {
    if (_heapFree(_heap, 0, pointer) == 0) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedCleanup,
      );
    }
  }

  Pointer<Uint8> utf8Text(String text) {
    final bytes = utf8.encode(text);
    final pointer = allocate(bytes.length + 1).cast<Uint8>();
    pointer.asTypedList(bytes.length + 1).setAll(0, bytes);
    return pointer;
  }

  Pointer<Void> borrowModuleFromAddress(Pointer<Void> address) {
    final slot = allocate(sizeOf<Pointer<Void>>()).cast<Pointer<Void>>();
    // FROM_ADDRESS (4) | UNCHANGED_REFCOUNT (2). Never FreeLibrary.
    if (address == nullptr ||
        _moduleFromAddress(4 | 2, address.cast<Uint16>(), slot) == 0 ||
        slot.value == nullptr) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedModule,
      );
    }
    return slot.value;
  }

  Pointer<Void> symbol(Pointer<Void> module, String name) =>
      _procAddress(module, utf8Text(name));

  bool validHandle(Pointer<Void> handle) =>
      handle != nullptr &&
      handle.address != -1 &&
      handle.address != 0xffffffffffffffff;

  Pointer<Void> openNamePin(String path) {
    final text = allocate((path.length + 1) * 2).cast<Uint16>();
    text.asTypedList(path.length + 1).setAll(0, path.codeUnits);
    final handle = _createFile(
      text,
      0x80000000, // GENERIC_READ; no DELETE access.
      1 | 2, // FILE_SHARE_READ | FILE_SHARE_WRITE; no delete-sharing.
      nullptr,
      3, // OPEN_EXISTING.
      0x00200000, // FILE_FLAG_OPEN_REPARSE_POINT.
      nullptr,
    );
    if (!validHandle(handle)) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedFileHandle,
      );
    }
    return handle;
  }

  void closeOwnedNamePin(Pointer<Void> ownedHandle) {
    if (_closeHandle(ownedHandle) == 0) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedCleanup,
      );
    }
  }

  (int, int, int) identity(Pointer<Void> handle) {
    if (sizeOf<_FileInformation>() != 52) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedNativeApi,
      );
    }
    final slot = allocate(sizeOf<_FileInformation>()).cast<_FileInformation>();
    if (_fileInformation(handle, slot) == 0) {
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedFileIdentity,
      );
    }
    final info = slot.ref;
    if ((info.attributes & (0x400 | 0x10)) != 0) {
      // Reject reparse points and directories, not a weaker pathname match.
      throw const SqliteNativeAbiFailure(
        SqliteNativeAbiStatus.unsupportedFileIdentity,
      );
    }
    return (info.volumeSerialNumber, info.fileIndexHigh, info.fileIndexLow);
  }
}

final class _FileTime extends Struct {
  @Uint32()
  external int low;
  @Uint32()
  external int high;
}

/// Public BY_HANDLE_FILE_INFORMATION, 13 DWORDs / 52 bytes, no private offsets.
final class _FileInformation extends Struct {
  @Uint32()
  external int attributes;
  external _FileTime creationTime;
  external _FileTime lastAccessTime;
  external _FileTime lastWriteTime;
  @Uint32()
  external int volumeSerialNumber;
  @Uint32()
  external int fileSizeHigh;
  @Uint32()
  external int fileSizeLow;
  @Uint32()
  external int numberOfLinks;
  @Uint32()
  external int fileIndexHigh;
  @Uint32()
  external int fileIndexLow;
}
