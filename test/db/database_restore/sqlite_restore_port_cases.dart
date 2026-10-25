part of 'sqlite_restore_port_fixture.dart';

final class _Acceptance {
  _Acceptance(this.wrapper, this.accepted);
  final _WrapperOwner wrapper;
  final bool accepted;
}

extension _RestoreCases on _RestoreFixture {
  Future<_Acceptance> accept(_RawOwner owner) async {
    final wrapper = wrap(owner);
    // Await the ORIGINAL executor/repository futures in order. There is no
    // raced timeout, abandoned query, constructor-only or markOpened verdict.
    final chat = await ChatRepo(wrapper.db).getById('synthetic-chat');
    expect(
      chat != null && chat.characterId == _RestoreFixture.characterId,
      true,
      reason: 'Actual owning ChatRepo query accepts restored table',
    );
    final version = await wrapper.db.customSelect('PRAGMA user_version').get();
    expect(version.single.data.values.single, 137);
    final schema = await wrapper.db
        .customSelect("SELECT name FROM sqlite_schema WHERE type='table'")
        .get();
    final names = schema.map((r) => r.data.values.single as String).toSet();
    expect(
      registered.every(names.contains),
      true,
      reason: 'Actual same executor sees every registered table',
    );
    expect(
      wrapper.db.nativeDataSourceIdentity?.belongsTo(wrapper.db),
      true,
      reason: 'The actual openedNative wrapper owns this executor lifetime',
    );
    final support = await SupportRepo(
      wrapper.db,
      cipher,
    ).getSessionById(_RestoreFixture.supportId);
    expect(support != null, true, reason: 'Real encrypted Support row queried');
    // A malformed envelope is genuinely locked by the production row mapper.
    // This explicit compatibility gate refuses it; it is not an injected error.
    return _Acceptance(wrapper, !support!.isLocked);
  }

  void preserveActualRawOriginal(_BundleObservation observation) {
    const labels = ['main', 'wal', 'shm', 'journal'];
    for (var i = 0; i < labels.length; i++) {
      final bytes = observation._bytes[i];
      if (bytes == null) continue;
      final archive = File(path('original-${labels[i]}.bin'));
      archive.writeAsBytesSync(bytes, flush: true);
      expect(
        _BundleObservation._sameBytes(archive.readAsBytesSync(), bytes),
        true,
        reason: 'Independent flushed owned raw artifact verified',
      );
    }
  }

  _RawOwner newDurableCopy(String filename) {
    final copyPath = path(filename);
    final copy = open(copyPath, OpenMode.readWriteCreate);
    copy.db.execute('PRAGMA journal_mode = DELETE');
    copy.db.execute('PRAGMA synchronous = FULL');
    final copyPin = pin(copyPath);
    abi.verifyConnection(copy.db, copyPin.handle);
    return copy;
  }

  Future<void> complete() async {
    contenders.add(open(targetPath, OpenMode.readWrite)); // Before lease.
    final owner = acquire();
    contenders.add(open(targetPath, OpenMode.readWrite)); // After lease.
    excluded('before original-source backup');
    final original = _LogicalImage.capture(owner.db);
    original.requireRegistration(registered);
    final rawOriginal = _BundleObservation.capture(targetPath);
    preserveActualRawOriginal(rawOriginal);
    final originalCopy = newDurableCopy('original-copy.db');
    fullCopy(owner, originalCopy);
    original.requireEqual(
      _LogicalImage.capture(originalCopy.db),
      'complete independent original backup',
    );
    excluded('after original-source backup and verification');

    final good = _LogicalImage.capture(candidate!.db);
    good.requireRegistration(registered);
    final badCandidate = newDurableCopy('locked-candidate.db');
    fullCopy(candidate!, badCandidate);
    // All 61 tables, current version and valid native pages remain intact.
    // Only this own synthetic encrypted envelope is physically made malformed.
    badCandidate.db.execute(
      'UPDATE support_sessions SET title_ciphertext=? '
      'WHERE id=?',
      ['synthetic-malformed-envelope', _RestoreFixture.supportId],
    );
    final bad = _LogicalImage.capture(badCandidate.db);
    bad.requireRegistration(registered);
    fullCopy(badCandidate, owner);
    excluded('candidate DONE and finish before acceptance');
    bad.requireEqual(
      _LogicalImage.capture(owner.db),
      'full bad-candidate copy',
    );
    excluded('complete bad-candidate native validation');
    final rejected = await accept(owner);
    expect(rejected.accepted, false, reason: 'Actual app ciphertext refusal');
    excluded('failed actual app acceptance with settled executor');
    await rejected.wrapper.close();
    expect(owner.closed, false, reason: 'Wrapper false-close retains SAME raw');
    excluded('failed wrapper closed before reverse backup');
    fullCopy(originalCopy, owner);
    original.requireEqual(
      _LogicalImage.capture(owner.db),
      'reverse original full committed logical image',
    );
    original.requireEqual(
      _LogicalImage.capture(originalCopy.db),
      'original source remains intact after reverse copy',
    );
    excluded('reverse-original DONE finish and full verification');

    fullCopy(candidate!, owner);
    excluded('final candidate DONE and finish');
    final installed = _LogicalImage.capture(owner.db);
    good.requireEqual(
      installed,
      'every schema column typed row blob ciphertext',
    );
    excluded('final complete native validation');
    final accepted = await accept(owner);
    expect(accepted.accepted, true, reason: 'Actual same raw app acceptance');
    excluded('accepted actual same raw wrapper with settled executor');
    await accepted.wrapper.close();
    expect(
      owner.closed,
      false,
      reason: 'Awaited wrapper close keeps raw lease',
    );
    good.requireEqual(_LogicalImage.capture(owner.db), 'after wrapper close');
    excluded('accepted wrapper closed before final raw close');
    // Fixed boolean observations only; no header/rootpage exception is invented.
    _recordFacts('complete', mode, {
      'schemaCookieChanged': installed.schemaCookie != good.schemaCookie,
      ..._BundleObservation.capture(targetPath).flagsAgainst(rawOriginal),
    });
    await owner.close();
    afterRelease();
  }

  Future<void> contention() async {
    final candidateBefore = _LogicalImage.capture(candidate!.db);
    for (final writer in [false, true]) {
      final holder = open(targetPath, OpenMode.readWrite);
      final original = _LogicalImage.capture(holder.db);
      holder.db.execute(writer ? 'BEGIN IMMEDIATE' : 'BEGIN');
      if (writer) {
        holder.db.execute(
          'UPDATE extra_restore_entity '
          "SET nullable_value='synthetic-uncommitted-writer' WHERE id=1",
        );
      } else {
        holder.db.select(
          'SELECT blob_value FROM extra_restore_entity WHERE id=1',
        );
      }
      expect(
        abi.transactionState(holder.db),
        writer ? 2 : 1,
        reason: 'Real original contender active transaction',
      );
      expect(nsql.sqlite3_get_autocommit(holder.db.handle.cast()), 0);
      final refused = target = open(targetPath, OpenMode.readWrite);
      targetPin = pin(targetPath);
      refused.db.execute('PRAGMA main.locking_mode = EXCLUSIVE');
      expectBusy(
        () => refused.db.execute('BEGIN EXCLUSIVE'),
        writer
            ? 'original active writer acquisition'
            : 'original active reader acquisition',
      );
      idle(refused);
      expect(
        _liveBackup == null,
        true,
        reason: 'Finite refusal starts no candidate destination backup',
      );
      await refused.close();
      holder.db.execute('ROLLBACK');
      idle(holder);
      original.requireEqual(
        _LogicalImage.capture(holder.db),
        'refused acquisition retains committed original',
      );
      candidateBefore.requireEqual(
        _LogicalImage.capture(candidate!.db),
        'refused acquisition does not touch candidate',
      );
      await holder.close();
    }

    final owner = acquire();
    final original = _LogicalImage.capture(owner.db);
    contenders.add(open(targetPath, OpenMode.readWrite));
    for (final writer in [false, true]) {
      owner.db.execute(writer ? 'BEGIN IMMEDIATE' : 'BEGIN');
      if (writer) {
        owner.db.execute(
          'UPDATE extra_restore_entity '
          "SET nullable_value='synthetic-uncommitted-destination' WHERE id=1",
        );
      } else {
        owner.db.select(
          'SELECT blob_value FROM extra_restore_entity WHERE id=1',
        );
      }
      expect(abi.transactionState(owner.db), writer ? 2 : 1);
      expect(nsql.sqlite3_get_autocommit(owner.db.handle.cast()), 0);
      final rejected = startBackup(candidate!, owner);
      expect(
        rejected.initialized,
        false,
        reason: 'Native backup_init refuses actual destination transaction',
      );
      expect(rejected.initCode, 1, reason: 'SQLite ERROR, not forged success');
      rejected.finish();
      expect(
        rejected.finishCalls,
        0,
        reason: 'Null init has nothing to finish',
      );
      owner.db.execute('ROLLBACK');
      idle(owner);
      original.requireEqual(
        _LogicalImage.capture(owner.db),
        'actual destination transaction rejection and rollback',
      );
      excluded('after active destination transaction refusal');
    }
    await owner.close();
    afterRelease();
  }

  Future<void> incomplete() async {
    contenders.add(open(targetPath, OpenMode.readWrite));
    final owner = acquire();
    contenders.add(open(targetPath, OpenMode.readWrite));
    excluded('before one-page candidate backup');
    final original = _LogicalImage.capture(owner.db);
    final originalCopy = newDurableCopy('original-copy.db');
    fullCopy(owner, originalCopy);
    original.requireEqual(
      _LogicalImage.capture(originalCopy.db),
      'full original saved before incomplete candidate',
    );
    excluded('after original-source backup before incomplete candidate');
    final backup = startBackup(candidate!, owner);
    Object? first;
    StackTrace? firstStack;
    try {
      expect(backup.initialized, true);
      expect(backup.step(1), 0, reason: 'One genuine page step, NOT DONE');
      expect(
        backup.pageCount > 1 && backup.remaining > 0,
        true,
        reason: 'Actual incomplete copy remains',
      );
      // Explicit abort at this exact bounded boundary. No destination API,
      // validation, identity query or callback is allowed before finish.
    } catch (error, stack) {
      first = error;
      firstStack = stack;
    } finally {
      try {
        backup.finish();
        expect(backup.finishCalls, 1);
        expect(
          backup.finishCode,
          0,
          reason: 'Abandoned finish OK is NOT success',
        );
      } catch (error, stack) {
        first ??= error;
        firstStack ??= stack;
      }
    }
    if (first != null) Error.throwWithStackTrace(first, firstStack!);
    expect(
      backup.lastStep == 101,
      false,
      reason: 'No DONE, no restore success',
    );
    idle(owner);
    original.requireEqual(
      _LogicalImage.capture(owner.db),
      'finish before DONE rolls back the entire destination',
    );
    excluded('incomplete finish and full original verification');
    await owner.close();
    afterRelease();
  }

  Future<void> bootstrap() async {
    // Close all original owners first. Observe the ACTUAL bundle left by the
    // native mode, then damage only our own main header (no hot-journal stunt).
    final validBundle = _BundleObservation.capture(targetPath);
    if (mode == 'WAL') {
      final wal = validBundle._bytes[1];
      expect(
        wal != null && wal.length > 32,
        true,
        reason: 'Actual original persisted WAL contains more than its header',
      );
    }
    final file = File(targetPath);
    final bytes = file.readAsBytesSync();
    expect(bytes.length >= 4096, true);
    bytes.fillRange(0, 16, 0x41);
    file.writeAsBytesSync(bytes, flush: true);
    final beforeOpen = _BundleObservation.capture(targetPath);
    expect(beforeOpen.mainExists, true);
    if (mode == 'WAL') {
      expect(
        beforeOpen._bytes.first!.take(16).every((byte) => byte == 0x41),
        true,
        reason: 'Actual own main header was invalidated before native access',
      );
      final retainedWal = beforeOpen._bytes[1];
      expect(retainedWal != null, true, reason: 'Original WAL still exists');
      expect(
        _BundleObservation._sameBytes(validBundle._bytes[1]!, retainedWal!),
        true,
        reason: 'Main-header invalidation preserved the actual original WAL',
      );
    }
    final owner = target = open(targetPath, OpenMode.readWrite);
    targetPin = pin(targetPath);
    owner.db.execute('PRAGMA main.locking_mode = EXCLUSIVE');
    abi.verifyConnection(owner.db, targetPin!.handle);
    final afterOpen = _BundleObservation.capture(targetPath);
    int? code;
    try {
      owner.db.execute('BEGIN EXCLUSIVE');
    } on SqliteException catch (error) {
      code = error.resultCode;
    }
    var bootstrapReadable = false;
    var originalLogicalSame = false;
    if (mode == 'WAL') {
      // Parent observed genuine BEGIN success with this valid retained WAL.
      // Require that behavior, settle the real transaction and prove which
      // complete database SQLite reads; no permissive error/fallback verdict.
      expect(
        code,
        isNull,
        reason: 'Actual retained-WAL bootstrap BEGIN succeeds',
      );
      expect(nsql.sqlite3_get_autocommit(owner.db.handle.cast()), 0);
      expect(
        abi.transactionState(owner.db),
        2,
        reason: 'Successful WAL BEGIN holds a real write transaction',
      );
      owner.db.execute('COMMIT');
      idle(owner);
      abi.verifyConnection(owner.db, targetPin!.handle);
      final readableOriginal = _LogicalImage.capture(owner.db);
      readableOriginal.requireRegistration(registered);
      originalSeedImage.requireEqual(
        readableOriginal,
        'retained WAL bootstrap reads the complete original seed image',
      );
      bootstrapReadable = code == null;
      originalLogicalSame = originalSeedImage.equals(readableOriginal);
    } else {
      // DELETE retains its genuine invalid-header refusal requirement.
      expect(
        code,
        26,
        reason: 'Actual SQLite NOTADB from owned invalid header',
      );
    }
    final afterBootstrap = _BundleObservation.capture(targetPath);
    idle(owner);
    expect(
      _liveBackup == null,
      true,
      reason: 'No candidate backup on invalid DB',
    );
    await owner.close();
    final afterClose = _BundleObservation.capture(targetPath);
    _recordFacts(
      'beforeInvalidation',
      mode,
      validBundle.flagsAgainst(validBundle),
    );
    _recordFacts('beforeOpen', mode, beforeOpen.flagsAgainst(validBundle));
    _recordFacts('open', mode, afterOpen.flagsAgainst(beforeOpen));
    if (mode == 'WAL') {
      _recordFacts('authorizedWalBootstrap', mode, {
        'bootstrapReadable': bootstrapReadable,
        'originalLogicalSame': originalLogicalSame,
        ...afterBootstrap.flagsAgainst(beforeOpen),
      });
    } else {
      _recordFacts('refusal', mode, afterBootstrap.flagsAgainst(beforeOpen));
    }
    _recordFacts('cancelClose', mode, afterClose.flagsAgainst(beforeOpen));
    // These are observed booleans, not a blanket unchanged-bootstrap assertion.
  }
}

void _recordFacts(String boundary, String mode, Map<String, bool> flags) {
  // Scalar, fixed-label observations only; no paths, hashes or payload leave.
  // ignore: avoid_print
  print('SQLite restore port $mode $boundary ${jsonEncode(flags)}');
}
