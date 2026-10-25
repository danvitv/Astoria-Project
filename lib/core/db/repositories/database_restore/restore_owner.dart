part of '../database_restore_repo.dart';

/// Real kernel startup owner, live proposal, native files and admitted/accepted
/// connection lifetime. Acquisition NEVER creates the target parent/data root.
/// The parent must already be canonical and exist before normal migrations.
final class NativeDatabaseRestoreOwner {
  NativeDatabaseRestoreOwner._(
    this._windows,
    this._native,
    this._targetPath,
    this._candidatePath,
    this._cipher,
    this._testFault,
  );
  final _RestoreFilePort _windows;
  final _RestoreNativePort _native;
  final String _targetPath;
  final String _candidatePath;
  final SupportPayloadCipher _cipher;
  final void Function(DatabaseRestoreTestBoundary)? _testFault;
  final _work = _RestoreWork();
  final _directories = <_RestorePin>[];
  _RestorePin? _kernel;
  NativeDatabaseStartupOwner? _startup;
  _RestorePin? _targetPin;
  _RestoreCandidate? _candidate;
  _RestoreRaw? _target;
  _RestoreOriginals? _originals;
  _RestoreAcceptedWrapper? _wrapper;
  DatabaseRestoreProposal? _proposal;
  _RestoreState _state = _RestoreState.idle;
  Future<void>? _active;
  Future<void>? _closing;
  bool _retired = false;
  bool _cancelled = false;
  bool _effectStarted = false;
  bool _bootstrapStarted = false;
  bool _closeFailed = false;
  Stopwatch? _clock;

  static NativeDatabaseRestoreOwner acquire({
    required File target,
    required File candidate,
    required SupportPayloadCipher payloadCipher,
    @visibleForTesting void Function(DatabaseRestoreTestBoundary)? testFault,
  }) {
    if (!Platform.isWindows || sizeOf<UintPtr>() != 8)
      _refuse(DatabaseRestoreCode.unsupported);
    final windows = _RestoreWindows();
    windows.requirePath(target.path);
    windows.requirePath(candidate.path);
    if (p.windows.equals(target.path, candidate.path))
      _refuse(DatabaseRestoreCode.unsupported);
    final native = _RestoreSqlite(windows);
    final owner = NativeDatabaseRestoreOwner._(
      windows,
      native,
      target.path,
      candidate.path,
      payloadCipher,
      testFault,
    );
    try {
      owner._pinAncestors(p.windows.dirname(target.path));
      owner._pinAncestors(p.windows.dirname(candidate.path));
      // OPEN_ALWAYS + share=0: persistent, nonblocking OS ownership. No PID,
      // lease JSON, stale-file removal or callback/boolean writer proof.
      owner._kernel = windows.pin(
        p.windows.join(
          p.windows.dirname(target.path),
          '.astoria-restore-startup.lock',
        ),
        lock: true,
      );
      owner._targetPin = windows.pin(target.path);
      if (windows.exists(owner._markerPath))
        owner._state = _RestoreState.blocked;
      return owner;
    } catch (error, stack) {
      owner._work.remember(error, stack);
      // All acquired resources are synchronous and no raw DB is open yet.
      owner._targetPin?.close();
      owner._kernel?.close();
      for (final pin in owner._directories.reversed) {
        pin.close();
      }
      native.close();
      Error.throwWithStackTrace(
        DatabaseRestoreException(
          error is DatabaseRestoreException
              ? error.code
              : DatabaseRestoreCode.unsupported,
        ),
        stack,
      );
    }
  }

  /// Existing-installation recovery borrows the SAME pre-migration process
  /// guard. Closing/cancelling this owner cannot release/reacquire that guard.
  static NativeDatabaseRestoreOwner fromStartup({
    required NativeDatabaseStartupOwner startup,
    required File candidate,
    required SupportPayloadCipher payloadCipher,
    @visibleForTesting void Function(DatabaseRestoreTestBoundary)? testFault,
  }) {
    startup._requireRestoreAdmission();
    final windows = startup._windows;
    final paths = windows.paths;
    final targetPath = startup._targetPath;
    if (!windows.exists(targetPath)) _refuse(DatabaseRestoreCode.unavailable);
    if (windows is _RestoreWindows) windows.requirePath(candidate.path);
    _requireAndroidCandidate(windows, candidate.path);
    if (paths.equals(targetPath, candidate.path)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final _RestoreNativePort native = windows is _RestoreWindows
        ? _RestoreSqlite(windows)
        : _RestoreAndroidSqlite(windows);
    final owner = NativeDatabaseRestoreOwner._(
      windows,
      native,
      targetPath,
      candidate.path,
      payloadCipher,
      testFault,
    ).._startup = startup;
    try {
      owner._pinAncestors(paths.dirname(targetPath));
      owner._pinAncestors(paths.dirname(candidate.path));
      owner._targetPin = windows.pin(targetPath);
      startup._requireRestoreAdmission();
      startup._restore = owner;
      return owner;
    } catch (error, stack) {
      owner._targetPin?.close();
      for (final pin in owner._directories.reversed) {
        pin.close();
      }
      native.close();
      Error.throwWithStackTrace(
        DatabaseRestoreException(
          error is DatabaseRestoreException
              ? error.code
              : DatabaseRestoreCode.unsupported,
        ),
        stack,
      );
    }
  }

  bool get normalOpeningBlocked =>
      _state == _RestoreState.blocked ||
      _state == _RestoreState.admitted ||
      _state == _RestoreState.accepted ||
      _closeFailed;
  bool get hasRetainedOriginals =>
      _originals != null &&
      _originals!._verified &&
      !_originals!._retentionEnded;
  bool get targetReadWriteOpened => _bootstrapStarted;
  String get _markerPath => _windows.paths.join(
    _windows.paths.dirname(_targetPath),
    '.astoria-restore-interrupted',
  );

  void _pinAncestors(String parent) {
    final files = _windows;
    if (files is _RestoreWindows) {
      // Keep the established Windows acquisition order and duplicate handling.
      final chain = <String>[];
      var path = parent;
      while (true) {
        chain.add(path);
        final next = p.windows.dirname(path);
        if (next == path) break;
        path = next;
      }
      for (final path in chain.reversed) {
        if (_directories.any((pin) => p.windows.equals(pin.path, path)))
          continue;
        files.requirePath(path);
        _directories.add(files.pin(path, directory: true));
      }
      return;
    }
    for (final pin in _windows.pinAncestors(parent)) {
      if (_directories.any(
        (existing) => _windows.paths.equals(existing.path, pin.path),
      )) {
        pin.close();
      } else {
        _directories.add(pin);
      }
    }
  }

  static void _requireAndroidCandidate(_RestoreFilePort files, String path) {
    final root = files.androidDataRoot;
    if (root == null) return;
    final paths = files.paths;
    final pickerRoot = paths.join(root, 'cache', 'file_picker');
    // FilePicker 11's app-private COPY, not a content URI or the external
    // original. Physical no-symlink/single-link proof belongs to native pins.
    if (!paths.isAbsolute(path) ||
        paths.normalize(path) != path ||
        path.contains('\u0000') ||
        !paths.isWithin(pickerRoot, path)) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final relative = paths.split(paths.relative(path, from: pickerRoot));
    if (relative.length != 2 ||
        !RegExp(r'^[0-9]+$').hasMatch(relative.first) ||
        relative.last.isEmpty) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
  }

  void _check({bool settling = false}) {
    if (_startup != null) {
      _startup!._check();
      if (!identical(_startup!._restore, this)) {
        _refuse(DatabaseRestoreCode.stale);
      }
    } else if (_kernel == null || _kernel!.closed) {
      _refuse(DatabaseRestoreCode.stale);
    }
    if (_targetPin == null || _targetPin!.closed)
      _refuse(DatabaseRestoreCode.stale);
    _kernel?.check();
    _targetPin!.check();
    for (final pin in _directories) {
      pin.check();
    }
    if (!settling && (_retired || _cancelled))
      _refuse(DatabaseRestoreCode.cancelled);
    if (!settling &&
        (_clock?.elapsed ?? Duration.zero) > const Duration(seconds: 15))
      _refuse(DatabaseRestoreCode.tooLarge);
  }

  Future<T> _track<T>(Future<T> operation) {
    // Attach the original failure handler NOW, not after cleanup/another await.
    _active = operation.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {
        _work.remember(error, stack);
      },
    );
    return operation;
  }

  Future<DatabaseRestoreProposal> _prepare() {
    if (_state == _RestoreState.blocked)
      _refuse(DatabaseRestoreCode.interruptedRequiresFreshConfirmation);
    if (_state != _RestoreState.idle || _retired)
      _refuse(DatabaseRestoreCode.stale);
    _check();
    if (_windows.exists(_markerPath)) {
      _state = _RestoreState.blocked;
      _refuse(DatabaseRestoreCode.interruptedRequiresFreshConfirmation);
    }
    _state = _RestoreState.preparing;
    _clock = Stopwatch()..start();
    return _track(_prepareCandidate());
  }

  Future<DatabaseRestoreProposal> _prepareCandidate() async {
    try {
      _check();
      if (_startup != null) {
        await _work.run(_cipher.requireExistingInstallationKey());
        _check();
      }
      final pin = _windows.pin(_candidatePath, immutable: true);
      // Register custody before fallible native length/information checks, so
      // preparation cleanup also owns a pin whose metadata call refuses.
      final candidate = _candidate = _RestoreCandidate(pin);
      if (pin.identity == _targetPin!.identity ||
          pin.length <= 0 ||
          pin.length > _RestoreLimits.maxBytes) {
        pin.close();
        _refuse(DatabaseRestoreCode.unsupported);
      }
      // Immutable local main-only selected backup. No sidecar recovery or
      // silent omission of WAL/journal as part of a selected backup.
      // On Android these are ONLY the FilePicker copy's neighbors; the external
      // original is neither inspected nor asserted to have had no WAL.
      for (final suffix in ['-wal', '-shm', '-journal']) {
        if (_windows.exists('$_candidatePath$suffix'))
          _refuse(DatabaseRestoreCode.unsupported);
      }
      candidate.raw = _native.open(
        _candidatePath,
        OpenMode.readOnly,
        immutable: true,
      );
      _native.verify(candidate.raw!, pin);
      candidate.raw!.database.execute('PRAGMA trusted_schema = OFF');
      candidate.raw!.database.execute('PRAGMA query_only = ON');
      candidate.schema = await _RestoreSchema.compiled(_work);
      _check();
      candidate.schema!.validate(candidate.raw!.database);
      candidate.digest = await _RestoreLogicalDigest.capture(
        candidate.raw!.database,
        _check,
        validateStoredTypes: true,
      );
      _check();
      candidate.wrapper = _RestoreAcceptedWrapper(
        AppDatabase.openedNative(
          candidate.raw!.database,
          closeUnderlyingOnClose: false,
        ),
      );
      await _RestoreAcceptance.accept(
        candidate.wrapper!.database,
        candidate.raw!.database,
        candidate.schema!,
        _cipher,
        _work,
        _check,
      );
      _check();
      await candidate.wrapper!.close(_work, null);
      _check();
      candidate.fileHash = await _windows.copyOrHash(pin, _check);
      _check();
      _state = _RestoreState.prepared;
      _clock?.stop();
      return _proposal = DatabaseRestoreProposal._(this, candidate);
    } catch (error, stack) {
      _work.remember(error, stack);
      _state =
          _work.pending != 0 ||
              (_windows.androidDataRoot != null &&
                  error is DatabaseRestoreException &&
                  error.code == DatabaseRestoreCode.recoveryRequired)
          ? _RestoreState.blocked
          : _RestoreState.settled;
      if (_work.pending == 0) {
        try {
          await _candidate?.wrapper?.close(_work, null);
          if (_work.pending != 0) _refuse(DatabaseRestoreCode.recoveryRequired);
          _candidate?.close();
        } catch (secondary, trace) {
          _work.remember(secondary, trace);
          _state = _RestoreState.blocked;
          Error.throwWithStackTrace(
            const DatabaseRestoreException(
              DatabaseRestoreCode.recoveryRequired,
            ),
            stack,
          );
        }
      }
      Error.throwWithStackTrace(
        DatabaseRestoreException(
          error is DatabaseRestoreException
              ? error.code
              : DatabaseRestoreCode.invalidCandidate,
        ),
        stack,
      );
    }
  }

  DatabaseRestoreConfirmation _confirm(DatabaseRestoreProposal proposal) {
    _check();
    if (_state != _RestoreState.prepared ||
        !identical(proposal, _proposal) ||
        !identical(proposal._owner, this) ||
        !identical(proposal._candidate, _candidate) ||
        proposal._retired ||
        proposal._confirmed)
      _refuse(DatabaseRestoreCode.stale);
    proposal._confirmed = true;
    return DatabaseRestoreConfirmation._(proposal);
  }

  Future<void> cancel() async {
    _cancelled = true;
    _proposal?._retired = true;
    final active = _active;
    if (active != null) await active;
    // After admission, the real run settles/reverses independently of cancelled
    // proposal admission. Resources stay retained until that original run ends.
    if (_state == _RestoreState.prepared) _state = _RestoreState.settled;
  }

  Future<void> close() => _closing ??= _close();
  Future<void> _close() async {
    final wasBlocked = _state == _RestoreState.blocked;
    _retired = true;
    await cancel();
    try {
      if (_work.pending != 0) _refuse(DatabaseRestoreCode.recoveryRequired);
      for (final resource in _work._schemaMemory) {
        await _work.run(resource.close());
      }
      _work._schemaMemory.clear();
      await _wrapper?.close(_work, _testFault);
      await _candidate?.wrapper?.close(_work, null);
      _testFault?.call(DatabaseRestoreTestBoundary.rawClose);
      _target?.close();
      _candidate?.close();
      _originals?.closeConnections();
      _targetPin?.close();
      for (final pin in _directories.reversed) {
        pin.close();
      }
      _kernel?.close();
      _native.close();
      // Only after all exact wrappers/raws/pins have successfully closed. The
      // startup process guard is borrowed and remains process-held separately.
      _windows.releaseOwnedProofs();
      _state = _closeFailed || wasBlocked
          ? _RestoreState.blocked
          : _RestoreState.closed;
      _startup?._detach(this);
    } catch (error, stack) {
      _work.remember(error, stack);
      _closeFailed = true;
      _state = _RestoreState.blocked;
      try {
        _originals?.recordInterruption();
      } catch (secondary, trace) {
        _work.remember(secondary, trace);
      }
      _closing = null; // Explicit retry may close; it cannot revive admission.
      Error.throwWithStackTrace(
        const DatabaseRestoreException(DatabaseRestoreCode.recoveryRequired),
        stack,
      );
    }
  }

  /// Retained native proof for the SAME raw during the real Drift read fence.
  /// Strict idle verify remains unchanged: inside a transaction this instead
  /// requires NONE/READ and the same physical platform connection witness.
  void _checkSnapshotSource() {
    _check(settling: true);
    if (_retired || _state != _RestoreState.accepted || _target == null) {
      _refuse(DatabaseRestoreCode.stale);
    }
    _native.verifyReadFence(_target!, _targetPin!);
  }
}

final class _RestoreCandidate {
  _RestoreCandidate(this.pin);
  final _RestorePin pin;
  _RestoreRaw? raw;
  _RestoreSchema? schema;
  _RestoreAcceptedWrapper? wrapper;
  _RestoreLogicalDigest? digest;
  Digest? fileHash;
  void close() {
    if (wrapper != null && !wrapper!.closed)
      _refuse(DatabaseRestoreCode.recoveryRequired);
    raw?.close();
    pin.close();
  }
}
