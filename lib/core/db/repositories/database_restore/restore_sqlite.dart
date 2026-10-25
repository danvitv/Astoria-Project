part of '../database_restore_repo.dart';

typedef _RestoreBackupInit =
    Pointer<nsql.sqlite3_backup> Function(
      Pointer<nsql.sqlite3>,
      Pointer<nsql.sqlite3_char>,
      Pointer<nsql.sqlite3>,
      Pointer<nsql.sqlite3_char>,
    );
typedef _RestoreAutocommit = Int Function(Pointer<nsql.sqlite3>);
typedef _RestoreFileControlNative =
    Int Function(Pointer<nsql.sqlite3>, Pointer<Char>, Int, Pointer<Void>);
typedef _RestoreFileControl =
    int Function(Pointer<nsql.sqlite3>, Pointer<Char>, int, Pointer<Void>);
typedef _RestoreTxnNative = Int Function(Pointer<nsql.sqlite3>, Pointer<Char>);
typedef _RestoreTxn = int Function(Pointer<nsql.sqlite3>, Pointer<Char>);

final class _RestoreSqlite {
  _RestoreSqlite(this.windows) {
    final Pointer<NativeFunction<_RestoreBackupInit>> backup = Native.addressOf(
      nsql.sqlite3_backup_init,
    );
    final Pointer<NativeFunction<_RestoreAutocommit>> autocommit =
        Native.addressOf(nsql.sqlite3_get_autocommit);
    final module = windows.borrowModule(backup.cast());
    if (autocommit == nullptr ||
        windows.symbol(module, 'sqlite3_backup_init').address !=
            backup.address ||
        windows.symbol(module, 'sqlite3_get_autocommit').address !=
            autocommit.address)
      _refuse(DatabaseRestoreCode.unsupported);
    final control = windows.symbol(module, 'sqlite3_file_control');
    final transaction = windows.symbol(module, 'sqlite3_txn_state');
    if (control == nullptr || transaction == nullptr)
      _refuse(DatabaseRestoreCode.unsupported);
    _control = control
        .cast<NativeFunction<_RestoreFileControlNative>>()
        .asFunction<_RestoreFileControl>();
    _txn = transaction
        .cast<NativeFunction<_RestoreTxnNative>>()
        .asFunction<_RestoreTxn>();
    main = windows.allocate(5).cast<nsql.sqlite3_char>();
    main.cast<Uint8>().asTypedList(5).setAll(0, [109, 97, 105, 110, 0]);
  }
  final _RestoreWindows windows;
  late final _RestoreFileControl _control;
  late final _RestoreTxn _txn;
  late final Pointer<nsql.sqlite3_char> main;
  bool closed = false;
  void check() {
    if (closed) _refuse(DatabaseRestoreCode.closed);
  }

  _RestoreRaw open(String path, OpenMode mode, {bool immutable = false}) {
    check();
    windows.requirePath(path);
    final uri =
        '${Uri.file(path, windows: true)}?cache=private${immutable ? '&immutable=1' : ''}';
    return _RestoreRaw(sqlite3.open(uri, uri: true, mode: mode));
  }

  void idle(_RestoreRaw raw) {
    check();
    final handle = raw.database.handle.cast<nsql.sqlite3>();
    if (nsql.sqlite3_get_autocommit(handle) != 1 ||
        _txn(handle, main.cast()) != 0)
      _refuse(DatabaseRestoreCode.unsupported);
  }

  /// Main DB physical handle identity, NOT sqlite3_db_filename equivalence.
  /// GET_HANDLE and module are borrowed; they never acquire CloseHandle rights.
  void verify(_RestoreRaw raw, _RestorePin pin) {
    idle(raw);
    pin.check();
    final vfs = windows.allocate(sizeOf<Pointer<Char>>()).cast<Pointer<Char>>();
    final slot = windows
        .allocate(sizeOf<Pointer<Void>>())
        .cast<Pointer<Void>>();
    try {
      final handle = raw.database.handle.cast<nsql.sqlite3>();
      if (_control(handle, main.cast(), 12, vfs.cast()) != 0 ||
          vfs.value == nullptr)
        _refuse(DatabaseRestoreCode.unsupported);
      const expected = [119, 105, 110, 51, 50, 0];
      for (var i = 0; i < expected.length; i++) {
        if (vfs.value.cast<Uint8>()[i] != expected[i])
          _refuse(DatabaseRestoreCode.unsupported);
      }
      if (_control(handle, main.cast(), 29, slot.cast()) != 0 ||
          !windows._valid(slot.value))
        _refuse(DatabaseRestoreCode.unsupported);
      final info = windows.information(slot.value);
      if ((info[7], info[11], info[12]) != pin.identity ||
          info[10] != 1 ||
          (info[0] & 0x410) != 0)
        _refuse(DatabaseRestoreCode.unsupported);
    } finally {
      if (vfs.value != nullptr) nsql.sqlite3_free(vfs.value.cast());
      windows.free(vfs.cast());
      windows.free(slot.cast());
    }
  }

  void acquireExclusive(_RestoreRaw raw, _RestorePin pin) {
    // These settings precede FIRST access to pages or WAL. A failed BEGIN may
    // already have performed ordinary bootstrap/recovery: no untouched claim.
    final db = raw.database;
    db.execute('PRAGMA main.locking_mode = EXCLUSIVE');
    db.execute('PRAGMA busy_timeout = 0');
    if (db.select('PRAGMA main.locking_mode').single.values.single !=
        'exclusive')
      _refuse(DatabaseRestoreCode.unsupported);
    // Public controls inspect this opened main HANDLE without reading DB pages.
    // Physical identity and actual locking mode precede the first BEGIN/access.
    verify(raw, pin);
    db.execute('BEGIN EXCLUSIVE');
    db.execute('COMMIT');
    idle(raw);
    db.execute('PRAGMA synchronous = FULL');
    db.execute('PRAGMA trusted_schema = OFF');
    final mode = db.select('PRAGMA main.journal_mode').single.values.single;
    if (mode != 'delete' && mode != 'wal')
      _refuse(DatabaseRestoreCode.unsupported);
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

  /// Destination is private/inactive. From init until the exactly-once finish,
  /// ONLY backup-family calls occur: no SQL, identity, file_control, callbacks
  /// or externally supplied awaits can re-enter this destination.
  Future<void> copy(_RestoreRaw source, _RestoreRaw destination) async {
    idle(destination);
    final pointer = nsql.sqlite3_backup_init(
      destination.database.handle.cast(),
      main,
      source.database.handle.cast(),
      main,
    );
    if (pointer == nullptr) _refuse(DatabaseRestoreCode.bootstrapUnknown);
    Object? first;
    StackTrace? stack;
    var done = false;
    try {
      for (
        var step = 0;
        step < (_RestoreLimits.maxPages ~/ _RestoreLimits.stepPages) + 2;
        step++
      ) {
        final code = nsql.sqlite3_backup_step(
          pointer,
          _RestoreLimits.stepPages,
        );
        if (nsql.sqlite3_backup_pagecount(pointer) > _RestoreLimits.maxPages)
          _refuse(DatabaseRestoreCode.tooLarge);
        if (code == 101) {
          done = true;
          break;
        }
        if (code != 0)
          _refuse(
            code == 5 || code == 6
                ? DatabaseRestoreCode.busy
                : DatabaseRestoreCode.bootstrapUnknown,
          );
        await Future<void>.delayed(Duration.zero);
      }
      if (!done) _refuse(DatabaseRestoreCode.tooLarge);
    } catch (error, trace) {
      first = error;
      stack = trace;
    } finally {
      try {
        final finished = nsql.sqlite3_backup_finish(pointer);
        if (finished != 0 && first == null) {
          first = const DatabaseRestoreException(
            DatabaseRestoreCode.bootstrapUnknown,
          );
          stack = StackTrace.current;
        }
      } catch (error, trace) {
        first ??= error;
        stack ??= trace;
      }
    }
    if (first != null) Error.throwWithStackTrace(first, stack!);
    idle(destination);
  }

  void close() {
    if (closed) return;
    windows.free(main.cast());
    closed = true;
  }
}

final class _RestoreRaw {
  _RestoreRaw(this._database);
  final Database _database;
  bool closed = false;
  Database get database {
    if (closed) _refuse(DatabaseRestoreCode.closed);
    return _database;
  }

  void close() {
    if (closed) return;
    _database.close();
    closed = true;
  }
}
