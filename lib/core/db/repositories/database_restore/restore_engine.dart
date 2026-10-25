part of '../database_restore_repo.dart';

extension _RestoreEngine on NativeDatabaseRestoreOwner {
  Future<DatabaseRestoreResult> _restore(
    DatabaseRestoreConfirmation confirmation,
  ) {
    final proposal = confirmation._proposal;
    if (_state != _RestoreState.prepared ||
        _retired ||
        _cancelled ||
        confirmation._used ||
        !identical(proposal, _proposal) ||
        !identical(proposal._owner, this) ||
        proposal._retired ||
        !proposal._confirmed) {
      return Future.value(
        const DatabaseRestoreResult._(DatabaseRestoreCode.stale),
      );
    }
    confirmation._used = true;
    proposal._retired = true;
    _state = _RestoreState.admitted;
    _clock = Stopwatch()..start();
    return _track(_apply());
  }

  Future<DatabaseRestoreResult> _apply() async {
    try {
      _check();
      final candidate = _candidate!;
      candidate.pin.check();
      final currentHash = await _windows.copyOrHash(candidate.pin, _check);
      _check();
      if (currentHash != candidate.fileHash) _refuse(DatabaseRestoreCode.stale);
      _testFault?.call(DatabaseRestoreTestBoundary.beforeBootstrap);
      _check();
      // First target RW access is AFTER the new same-owner one-use admission.
      // Its ordinary SQLite bootstrap is explicitly inside confirmation scope.
      _bootstrapStarted = true;
      _target = _native.open(_targetPath, OpenMode.readWrite);
      _native.acquireExclusive(_target!, _targetPin!);
      _check();
      _originals = _RestoreOriginals.create(this);
      await _originals!.preserve();
      _check();
      _testFault?.call(DatabaseRestoreTestBoundary.originalVerified);
      _check();
      _native.verify(_target!, _targetPin!);
      _testFault?.call(DatabaseRestoreTestBoundary.candidateCopy);
      _check();
      _effectStarted = true;
      await _native.copy(candidate.raw!, _target!);
      _check();
      _native.verify(_target!, _targetPin!);
      final copied = await _RestoreLogicalDigest.capture(
        _target!.database,
        _check,
        validateStoredTypes: true,
      );
      _check();
      if (!copied.same(candidate.digest!))
        _refuse(DatabaseRestoreCode.invalidCandidate);
      candidate.schema!.validate(_target!.database);
      _wrapper = _RestoreAcceptedWrapper(
        AppDatabase.openedNative(
          _target!.database,
          closeUnderlyingOnClose: false,
          androidSnapshotNamespace: _startup?.androidSnapshotNamespace,
        ),
      );
      await _RestoreAcceptance.accept(
        _wrapper!.database,
        _target!.database,
        candidate.schema!,
        _cipher,
        _work,
        _check,
      );
      _check();
      _testFault?.call(DatabaseRestoreTestBoundary.acceptance);
      _check();
      // Opening an already-current DB must not mutate copied durable content.
      final acceptedImage = await _RestoreLogicalDigest.capture(
        _target!.database,
        _check,
      );
      _check();
      if (!acceptedImage.same(candidate.digest!))
        _refuse(DatabaseRestoreCode.invalidCandidate);
      _native.verify(_target!, _targetPin!);
      _originals!.clearSettledMarker();
      _state = _RestoreState.accepted;
      _clock?.stop();
      return DatabaseRestoreResult._(
        DatabaseRestoreCode.accepted,
        accepted: AcceptedDatabaseRestore._(this, _wrapper!.database),
      );
    } catch (error, stack) {
      _work.remember(error, stack);
      if (_effectStarted) return _reverse();
      if (_work.pending != 0 ||
          (_windows.androidDataRoot != null &&
              error is DatabaseRestoreException &&
              error.code == DatabaseRestoreCode.recoveryRequired)) {
        _state = _RestoreState.blocked;
        return const DatabaseRestoreResult._(
          DatabaseRestoreCode.recoveryRequired,
        );
      }
      _state = _RestoreState.settled;
      final code = !_bootstrapStarted
          ? error is DatabaseRestoreException
                ? error.code
                : DatabaseRestoreCode.unsupported
          : error is SqliteException &&
                (error.resultCode == 5 || error.resultCode == 6)
          ? DatabaseRestoreCode.busy
          : DatabaseRestoreCode.bootstrapUnknown;
      return DatabaseRestoreResult._(code);
    }
  }

  Future<DatabaseRestoreResult> _reverse() async {
    try {
      // Cancellation/retirement removes admission, NOT original settlement
      // custody. No new destructive gesture or approval is reconstructed here.
      _check(settling: true);
      if (_work.pending != 0) _refuse(DatabaseRestoreCode.recoveryRequired);
      await _wrapper?.close(_work, _testFault);
      _check(settling: true);
      _native.verify(_target!, _targetPin!);
      _testFault?.call(DatabaseRestoreTestBoundary.reverseCopy);
      await _native.copy(_originals!.raw!, _target!);
      _check(settling: true);
      _native.verify(_target!, _targetPin!);
      final restored = await _RestoreLogicalDigest.capture(
        _target!.database,
        () => _check(settling: true),
      );
      _check(settling: true);
      if (!restored.same(_originals!.digest!))
        _refuse(DatabaseRestoreCode.recoveryRequired);
      _originals!.clearSettledMarker();
      _state = _RestoreState.settled;
      return const DatabaseRestoreResult._(
        DatabaseRestoreCode.originalRestored,
      );
    } catch (error, stack) {
      _work.remember(error, stack); // Preserve FIRST original failure/stack.
      _state = _RestoreState.blocked;
      return const DatabaseRestoreResult._(
        DatabaseRestoreCode.recoveryRequired,
      );
    }
  }
}

final class _RestoreAcceptedWrapper {
  _RestoreAcceptedWrapper(this.database);
  final AppDatabase database;
  Future<void>? _closing;
  bool closed = false;
  Future<void> close(
    _RestoreWork work,
    void Function(DatabaseRestoreTestBoundary)? fault,
  ) async {
    if (closed) return;
    fault?.call(DatabaseRestoreTestBoundary.wrapperClose);
    // Keep the exact original executor-close future, including a failed close.
    _closing ??= work.run(database.close());
    await _closing;
    if (work.pending != 0) _refuse(DatabaseRestoreCode.recoveryRequired);
    closed = true;
  }
}

/// Actual registered schema + awaited owning repositories and AEAD checks, not
/// a caller-supplied permissive accept predicate or constructor markOpened.
abstract final class _RestoreAcceptance {
  static Future<void> accept(
    AppDatabase app,
    Database raw,
    _RestoreSchema schema,
    SupportPayloadCipher cipher,
    _RestoreWork work,
    void Function() check,
  ) async {
    await work.run(ChatRepo(app).countByCharacterId(''));
    check();
    if (app.nativeDataSourceIdentity == null ||
        app.schemaVersion != schema.version ||
        app.allTables
            .map((t) => t.actualTableName)
            .toSet()
            .difference(schema.tables)
            .isNotEmpty)
      _refuse(DatabaseRestoreCode.invalidCandidate);
    for (final table in schema.tables) {
      // Real SAME executor reads, bounded one-row metadata, all registration.
      await work.run(
        app.customSelect('SELECT * FROM ${_quote(table)} LIMIT 1').get(),
      );
      check();
    }
    final chat = ChatRepo(app);
    await _each(raw, 'chat_sessions', 'session_id', (id) async {
      if (await work.run(chat.getById(id)) == null)
        _refuse(DatabaseRestoreCode.invalidCandidate);
    }, check);
    final support = SupportRepo(app, cipher);
    await _each(raw, 'support_sessions', 'id', (id) async {
      final model = await work.run(support.getSessionById(id));
      if (model == null || model.isLocked)
        _refuse(DatabaseRestoreCode.invalidCandidate);
    }, check);
    await _each(raw, 'support_messages', 'id', (id) async {
      final model = await work.run(support.getMessageById(id));
      if (model == null || model.isLocked)
        _refuse(DatabaseRestoreCode.invalidCandidate);
    }, check);
    await _each(raw, 'support_context_blocks', 'id', (id) async {
      final model = await work.run(support.getContextBlockById(id));
      if (model == null || model.isLocked)
        _refuse(DatabaseRestoreCode.invalidCandidate);
    }, check);
    await _each(raw, 'support_mutation_journal', 'id', (id) async {
      final model = await work.run(support.getMutationById(id));
      if (model == null || model.isLocked)
        _refuse(DatabaseRestoreCode.invalidCandidate);
    }, check);
    await checkPayloads(raw, cipher, work, check);
    check();
  }

  static Future<void> _each(
    Database raw,
    String table,
    String idColumn,
    Future<void> Function(String) action,
    void Function() check,
  ) async {
    final statement = raw.prepare(
      'SELECT ${_quote(idColumn)} FROM ${_quote(table)}',
    );
    try {
      final cursor = statement.iterateWith(const StatementParameters.empty());
      var count = 0;
      while (cursor.moveNext()) {
        check();
        if (++count > _RestoreLimits.maxRows)
          _refuse(DatabaseRestoreCode.tooLarge);
        await action(cursor.current.values.single as String);
        check();
      }
    } finally {
      statement.close();
    }
  }

  static Future<void> checkPayloads(
    Database raw,
    SupportPayloadCipher cipher,
    _RestoreWork work,
    void Function() check,
  ) async {
    const fields = <String, List<String>>{
      'support_sessions': ['title_ciphertext'],
      'support_messages': ['body_ciphertext', 'cards_ciphertext'],
      'support_context_blocks': [
        'summary_ciphertext',
        'protected_facts_ciphertext',
      ],
      'support_mutation_journal': ['before_ciphertext', 'after_ciphertext'],
    };
    var total = 0;
    for (final entry in fields.entries) {
      final table = entry.key;
      final session = table == 'support_sessions' ? 'id' : 'session_id';
      final statement = raw.prepare(
        'SELECT id,${_quote(session)},${entry.value.map(_quote).join(',')} FROM ${_quote(table)}',
      );
      try {
        final cursor = statement.iterateWith(const StatementParameters.empty());
        while (cursor.moveNext()) {
          check();
          if (++total > _RestoreLimits.maxRows)
            _refuse(DatabaseRestoreCode.tooLarge);
          final values = cursor.current.values.toList();
          for (var i = 0; i < entry.value.length; i++) {
            final field = entry.value[i];
            final envelope = values[i + 2] as String;
            if (envelope.isEmpty &&
                (field == 'cards_ciphertext' ||
                    field == 'protected_facts_ciphertext'))
              continue;
            // Plaintext stays local to the original pure AEAD future and is
            // discarded. Missing installation keys are a refusal, not recovery.
            await work.run(
              cipher.decrypt(
                envelopeText: envelope,
                table: table,
                rowId: values[0] as String,
                sessionId: values[1] as String,
                field: field,
              ),
            );
            check();
          }
        }
      } finally {
        statement.close();
      }
    }
  }
}
