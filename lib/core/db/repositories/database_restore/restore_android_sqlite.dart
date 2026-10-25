part of '../database_restore_repo.dart';

/// Android uses the same guarded restore engine and backup-family asset calls.
/// O_PATH pins anchor namespace metadata; only the VFS witness identifies the
/// actual borrowed SQLite FD. No private unixFile fields, FD dup or FD close.
final class _RestoreAndroidSqlite implements _RestoreNativePort {
  _RestoreAndroidSqlite(this.files) {
    if (!Platform.isAndroid || files.androidDataRoot == null) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    identity = _RestoreUnixIdentity(files);
    main = files.allocate(5).cast<nsql.sqlite3_char>();
    main.cast<Uint8>().asTypedList(5).setAll(0, [109, 97, 105, 110, 0]);
  }

  final _RestoreFilePort files;
  late final _RestoreUnixIdentity identity;
  late final Pointer<nsql.sqlite3_char> main;
  final _opens = <_RestoreUnixOpen>[];
  bool _cleanupUncertain = false;
  bool closed = false;

  void check() {
    if (closed) _refuse(DatabaseRestoreCode.closed);
    if (_cleanupUncertain) _refuse(DatabaseRestoreCode.recoveryRequired);
    identity.checkInstallation();
  }

  _RestoreRaw open(String path, OpenMode mode, {bool immutable = false}) {
    check();
    // FilePort's default data-file pin MUST be O_PATH, never an ordinary RO
    // metadata FD whose close could silently drop the live target's POSIX locks.
    final opened = _RestoreUnixOpen(identity, files.pin(path));
    _opens.add(opened);
    try {
      opened.witness = identity.begin(opened.pin);
      // The bridge must admit URI/immutable candidates and RW target/original
      // witnesses concurrently. Older single-RO-witness bridges refuse here;
      // never retry using the default VFS, another SQLite, or pathname identity.
      final uri =
          '${Uri.file(path, windows: false)}'
          '?cache=private${immutable ? '&immutable=1' : ''}';
      opened.raw = _RestoreRaw(
        sqlite3.open(uri, uri: true, mode: mode, vfs: 'astoria_restore_unix'),
        beforeClose: opened.retire,
        afterClose: opened.pin.close,
      );
      identity.claim(opened.witness!, opened.raw!);
      verify(opened.raw!, opened.pin);
      opened.admitted = true;
      return opened.raw!;
    } catch (error, stack) {
      try {
        opened.close();
      } catch (_) {
        _cleanupUncertain = true;
        Error.throwWithStackTrace(
          const DatabaseRestoreException(DatabaseRestoreCode.recoveryRequired),
          stack,
        );
      }
      Error.throwWithStackTrace(error, stack);
    }
  }

  _RestoreUnixOpen _opening(_RestoreRaw raw) {
    check();
    for (final opened in _opens) {
      if (identical(opened.raw, raw) && !opened.closed) return opened;
    }
    _refuse(DatabaseRestoreCode.stale);
    throw StateError('Unreachable');
  }

  void idle(_RestoreRaw raw) {
    check();
    final handle = raw.database.handle.cast<nsql.sqlite3>();
    if (identity.getAutocommit(handle) != 1 ||
        identity.transaction(handle, main.cast()) != 0) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
  }

  void _physical(_RestoreRaw raw, _RestorePin pin) {
    final opened = _opening(raw);
    opened.pin.check();
    if (opened.pin.identity != pin.identity ||
        !files.paths.equals(opened.pin.path, pin.path)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    // Native check invokes anchored FILE_POINTER/VFS_POINTER and compares
    // raw's public sqlite3_file to the actual xOpen-captured still-borrowed FD.
    identity.verify(opened.witness!, raw, pin);
  }

  void verify(_RestoreRaw raw, _RestorePin pin) {
    idle(raw);
    _physical(raw, pin);
  }

  void verifyReadFence(_RestoreRaw raw, _RestorePin pin) {
    check();
    final db = raw.database;
    final handle = db.handle.cast<nsql.sqlite3>();
    final transaction = identity.transaction(handle, main.cast());
    if (transaction != 0 && transaction != 1) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    if (db.select('PRAGMA main.locking_mode').single.values.single !=
        'exclusive') {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    if (identity.getAutocommit(handle) == 1) {
      verify(raw, pin);
      return;
    }
    _physical(raw, pin);
  }

  void acquireExclusive(_RestoreRaw raw, _RestorePin pin) {
    final db = raw.database;
    db.execute('PRAGMA main.locking_mode = EXCLUSIVE');
    db.execute('PRAGMA busy_timeout = 0');
    if (db.select('PRAGMA main.locking_mode').single.values.single !=
        'exclusive') {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    verify(raw, pin);
    db.execute('BEGIN EXCLUSIVE');
    db.execute('COMMIT');
    idle(raw);
    db.execute('PRAGMA synchronous = FULL');
    db.execute('PRAGMA trusted_schema = OFF');
    final mode = db.select('PRAGMA main.journal_mode').single.values.single;
    if (mode != 'delete' && mode != 'wal') {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final locking = db.select('PRAGMA main.locking_mode').single.values.single;
    if (locking != 'exclusive') _refuse(DatabaseRestoreCode.unsupported);
    verify(raw, pin);
  }

  void durableOriginal(_RestoreRaw raw) {
    raw.database.execute('PRAGMA main.locking_mode = EXCLUSIVE');
    raw.database.execute('PRAGMA busy_timeout = 0');
    raw.database.execute('PRAGMA journal_mode = DELETE');
    raw.database.execute('PRAGMA synchronous = FULL');
    raw.database.execute('BEGIN EXCLUSIVE');
    raw.database.execute('COMMIT');
    idle(raw);
  }

  Future<void> copy(_RestoreRaw source, _RestoreRaw destination) =>
      _RestoreNativeBackup.copy(main, source, destination, idle);

  void close() {
    if (closed) return;
    for (final opened in _opens.reversed) {
      // Successful opens belong to the engine's wrapper-first close order.
      // Only failed-open orphan resources may be disposed by the native port.
      if (opened.admitted && opened.raw?.closed != true) {
        _refuse(DatabaseRestoreCode.recoveryRequired);
      }
      opened.close();
    }
    files.free(main.cast());
    closed = true;
  }
}
