part of '../database_restore_repo.dart';

/// Public SQLite/VFS witness bridge. This loads ONLY Astoria's bridge; every
/// SQLite address is borrowed from the exact already-loaded native asset.
/// Installation and native witness records remain process-owned, never unloaded.
final class _RestoreUnixIdentity {
  _RestoreUnixIdentity(this.files) : _library = _loadLibrary() {
    if (_abi() != 1) _refuse(DatabaseRestoreCode.unsupported);
    final Pointer<NativeFunction<_RestoreBackupInit>> backup = Native.addressOf(
      nsql.sqlite3_backup_init,
    );
    final Pointer<NativeFunction<_RestoreAutocommit>> autocommit =
        Native.addressOf(nsql.sqlite3_get_autocommit);
    final Pointer<NativeFunction<Int Function(Pointer<nsql.sqlite3_vfs>, Int)>>
    register = Native.addressOf(nsql.sqlite3_vfs_register);
    _addresses = [
      backup.cast<Void>(),
      autocommit.cast<Void>(),
      _resolve(backup.cast(), 'sqlite3_vfs_find'),
      register.cast<Void>(),
      _resolve(backup.cast(), 'sqlite3_file_control'),
      _resolve(backup.cast(), 'sqlite3_txn_state'),
    ];
    if (_addresses.any((value) => value == nullptr)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    checkInstallation();
    getAutocommit = autocommit
        .asFunction<int Function(Pointer<nsql.sqlite3>)>();
    transaction = _addresses[5]
        .cast<NativeFunction<_RestoreTxnNative>>()
        .asFunction<_RestoreTxn>();
  }

  final _RestoreFilePort files;
  final DynamicLibrary _library;

  static DynamicLibrary _loadLibrary() {
    try {
      final library = DynamicLibrary.open('libastoria_snapshot.so');
      // Resolve the complete public contract before installing hooks or arming
      // a witness. Missing cleanup entry points must not strand a live raw.
      for (final name in const [
        'astoria_restore_sqlite_identity_abi',
        'astoria_restore_sqlite_symbol',
        'astoria_restore_sqlite_install',
        'astoria_restore_sqlite_begin',
        'astoria_restore_sqlite_claim',
        'astoria_restore_sqlite_check',
        'astoria_restore_sqlite_retire',
      ]) {
        library.lookup<Void>(name);
      }
      return library;
    } catch (_) {
      _refuse(DatabaseRestoreCode.unsupported);
      rethrow;
    }
  }

  late final List<Pointer<Void>> _addresses;
  late final int Function(Pointer<nsql.sqlite3>) getAutocommit;
  late final _RestoreTxn transaction;
  late final _abi = _library.lookupFunction<Int Function(), int Function()>(
    'astoria_restore_sqlite_identity_abi',
  );
  late final _symbol = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>),
        Pointer<Void> Function(Pointer<Void>, Pointer<Char>)
      >('astoria_restore_sqlite_symbol');
  late final _install = _library
      .lookupFunction<
        Int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        ),
        int Function(
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
          Pointer<Void>,
        )
      >('astoria_restore_sqlite_install');
  late final _begin = _library
      .lookupFunction<
        Pointer<Void> Function(Pointer<Char>, Uint64, Uint64),
        Pointer<Void> Function(Pointer<Char>, int, int)
      >('astoria_restore_sqlite_begin');
  late final _claim = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Pointer<Void>),
        int Function(Pointer<Void>, Pointer<Void>)
      >('astoria_restore_sqlite_claim');
  late final _check = _library
      .lookupFunction<
        Int Function(Pointer<Void>, Pointer<Void>, Uint64, Uint64),
        int Function(Pointer<Void>, Pointer<Void>, int, int)
      >('astoria_restore_sqlite_check');
  late final _retire = _library
      .lookupFunction<Int Function(Pointer<Void>), int Function(Pointer<Void>)>(
        'astoria_restore_sqlite_retire',
      );

  T text<T>(String value, T Function(Pointer<Char>) action) {
    final bytes = utf8.encode(value);
    final memory = files.allocate(bytes.length + 1).cast<Uint8>();
    try {
      memory.asTypedList(bytes.length).setAll(0, bytes);
      memory[bytes.length] = 0;
      return action(memory.cast());
    } finally {
      files.free(memory.cast());
    }
  }

  Pointer<Void> _resolve(Pointer<Void> backup, String name) =>
      text(name, (value) => _symbol(backup, value));

  void checkInstallation() {
    if (_install(
          _addresses[0],
          _addresses[1],
          _addresses[2],
          _addresses[3],
          _addresses[4],
          _addresses[5],
        ) !=
        0) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
  }

  Pointer<Void> begin(_RestorePin pin) {
    pin.check();
    final (device, inode, _) = pin.identity;
    final witness = text(pin.path, (path) => _begin(path, device, inode));
    if (witness == nullptr) _refuse(DatabaseRestoreCode.unsupported);
    return witness;
  }

  void claim(Pointer<Void> witness, _RestoreRaw raw) {
    if (_claim(witness, raw.database.handle.cast()) != 0) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
  }

  void verify(Pointer<Void> witness, _RestoreRaw raw, _RestorePin pin) {
    pin.check();
    final (device, inode, _) = pin.identity;
    if (_check(witness, raw.database.handle.cast(), device, inode) != 0) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
  }

  void retire(Pointer<Void> witness) {
    // -1 revokes authority but does NOT grant raw-close permission. The exact
    // raw/pins stay in owner custody for an explicit later cleanup attempt.
    if (_retire(witness) != 0) _refuse(DatabaseRestoreCode.recoveryRequired);
  }
}

/// Registers file/witness custody BEFORE any fallible open or claim. A failed
/// cleanup remains retained by the native port, including a never-opened arm.
final class _RestoreUnixOpen {
  _RestoreUnixOpen(this.identity, this.pin);
  final _RestoreUnixIdentity identity;
  final _RestorePin pin;
  Pointer<Void>? witness;
  _RestoreRaw? raw;
  bool admitted = false;

  void retire() {
    final current = witness;
    if (current != null) identity.retire(current);
  }

  void close() {
    final current = raw;
    if (current != null) {
      current.close();
    } else {
      retire();
      pin.close();
    }
  }

  bool get closed => pin.closed && (raw == null || raw!.closed);
}
