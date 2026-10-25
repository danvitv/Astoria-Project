part of 'sqlite_restore_port_fixture.dart';

final class _RawOwner {
  _RawOwner(this._db);
  final Database _db;
  bool closed = false;
  Future<void>? _closing;
  Database get db {
    if (closed) throw StateError('Owned SQLite connection already closed');
    return _db;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    _db.close();
    closed = true;
  }
}

final class _WrapperOwner {
  _WrapperOwner(this._db);
  final AppDatabase _db;
  bool closed = false;
  Future<void>? _closing;
  AppDatabase get db {
    if (closed) throw StateError('Owned Drift wrapper already closed');
    return _db;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    await _db.close();
    closed = true;
  }
}

final class _PinOwner {
  _PinOwner(this.abi, this.handle);
  final SqliteRestoreTestAbi abi;
  final Pointer<Void> handle;
  bool closed = false;
  void close() {
    if (closed) return;
    abi.closeOwnedNamePin(handle);
    closed = true;
  }
}

/// From successful init through finish the destination is inaccessible to all
/// fixture code. Only this backup family is used, with exactly one finish.
final class _NativeBackup {
  _NativeBackup(Database source, Database destination, SqliteRestoreTestAbi abi)
    : _pointer = nsql.sqlite3_backup_init(
        destination.handle.cast(),
        abi.main,
        source.handle.cast(),
        abi.main,
      ) {
    initialized = _pointer != nullptr;
    initCode = initialized
        ? 0
        : nsql.sqlite3_extended_errcode(destination.handle.cast()) & 255;
  }
  Pointer<nsql.sqlite3_backup> _pointer;
  late final bool initialized;
  late final int initCode;
  int finishCalls = 0;
  int? finishCode;
  int? lastStep;
  bool get finished => _pointer == nullptr;

  int step(int pages) {
    if (_pointer == nullptr) throw StateError('Backup not live');
    return lastStep = nsql.sqlite3_backup_step(_pointer, pages);
  }

  int get remaining => nsql.sqlite3_backup_remaining(_pointer);
  int get pageCount => nsql.sqlite3_backup_pagecount(_pointer);
  void finish() {
    if (_pointer == nullptr) return;
    final pointer = _pointer;
    _pointer = nullptr;
    finishCalls++;
    finishCode = nsql.sqlite3_backup_finish(pointer);
  }
}

extension _RestoreNative on _RestoreFixture {
  void idle(_RawOwner owner) {
    expect(
      nsql.sqlite3_get_autocommit(owner.db.handle.cast()),
      1,
      reason: 'Real autocommit at a settled safe boundary',
    );
    expect(
      abi.transactionState(owner.db),
      0,
      reason: 'Real main transaction state NONE',
    );
  }

  _RawOwner acquire() {
    final owner = target = open(targetPath, OpenMode.readWrite);
    targetPin = pin(targetPath);
    // busy_timeout and locking_mode don't read database pages. EXCLUSIVE is
    // chosen BEFORE BEGIN, metadata, WAL access or openedNative construction.
    owner.db.execute('PRAGMA main.locking_mode = EXCLUSIVE');
    if (mode == 'WAL') {
      abi.preserveWalOnOwnedConnection(owner.db);
      owner.db.execute('PRAGMA wal_autocheckpoint = 0');
    }
    owner.db.execute('BEGIN EXCLUSIVE');
    owner.db.execute('COMMIT');
    idle(owner);
    owner.db.execute('PRAGMA synchronous = FULL');
    expect(
      owner.db.select('PRAGMA main.journal_mode').single.values.single ==
          mode.toLowerCase(),
      true,
      reason: 'Real durable target journal mode',
    );
    abi.verifyConnection(owner.db, targetPin!.handle);
    return owner;
  }

  _NativeBackup startBackup(_RawOwner source, _RawOwner destination) {
    expect(_liveBackup == null || _liveBackup!.finished, true);
    return _liveBackup = _NativeBackup(source.db, destination.db, abi);
  }

  void fullCopy(_RawOwner source, _RawOwner destination) {
    idle(destination);
    final backup = startBackup(source, destination);
    Object? first;
    StackTrace? firstStack;
    try {
      expect(backup.initialized, true, reason: 'Genuine backup_init succeeds');
      for (var i = 0; i < 128; i++) {
        final code = backup.step(32);
        expect(
          backup.pageCount <= 2048,
          true,
          reason: 'Finite synthetic page budget',
        );
        if (code == 101) break;
        expect(code, 0, reason: 'Bounded native full-copy step');
      }
      expect(
        backup.lastStep,
        101,
        reason: 'DONE is required, not just finish OK',
      );
    } catch (error, stack) {
      first = error;
      firstStack = stack;
    } finally {
      try {
        backup.finish();
        expect(backup.finishCalls, 1, reason: 'Exactly one backup_finish');
        expect(
          backup.finishCode,
          0,
          reason: 'Finish OK is separately required',
        );
      } catch (error, stack) {
        first ??= error;
        firstStack ??= stack;
      }
    }
    if (first != null) Error.throwWithStackTrace(first, firstStack!);
    idle(destination);
  }

  void expectBusy(void Function() operation, String boundary) {
    int? code;
    try {
      operation();
    } on SqliteException catch (error) {
      code = error.resultCode;
    }
    expect(
      code == 5 || code == 6,
      true,
      reason: 'Actual contender BUSY/LOCKED: $boundary',
    );
  }

  void excluded(String boundary) {
    final owner = target!;
    idle(owner);
    abi.verifyConnection(owner.db, targetPin!.handle);
    for (final contender in contenders) {
      expectBusy(() => contender.db.execute('BEGIN IMMEDIATE'), boundary);
      idle(contender);
      expectBusy(
        () => contender.db.execute(
          'UPDATE extra_restore_entity '
          "SET nullable_value='synthetic-contender-write' WHERE id=1",
        ),
        boundary,
      );
      idle(contender);
      if (mode == 'WAL') {
        // This pragma may throw BUSY or report busy in its first numeric column.
        var checkpointBusy = false;
        try {
          final rows = contender.db.select('PRAGMA wal_checkpoint(PASSIVE)');
          checkpointBusy = rows.length == 1 && rows.single.values.first == 1;
        } on SqliteException catch (error) {
          checkpointBusy = error.resultCode == 5 || error.resultCode == 6;
        }
        expect(checkpointBusy, true, reason: 'Real competing WAL checkpoint');
        idle(contender);
      }
    }
    idle(owner);
  }

  void afterRelease() {
    expect(
      target!.closed,
      true,
      reason: 'Final actual raw close releases lease',
    );
    for (final contender in contenders) {
      contender.db.execute('BEGIN IMMEDIATE');
      contender.db.execute(
        'UPDATE extra_restore_entity '
        "SET nullable_value='synthetic-after-release' WHERE id=1",
      );
      contender.db.execute('COMMIT');
      idle(contender);
      expect(
        contender.db
                .select(
                  'SELECT nullable_value '
                  'FROM extra_restore_entity WHERE id=1',
                )
                .single
                .values
                .single ==
            'synthetic-after-release',
        true,
        reason: 'Actual committed write after final raw close',
      );
    }
  }
}
