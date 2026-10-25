part of '../database_restore_repo.dart';

/// Candidate-free, keyless pre-migration custody. Production supplies the ONE
/// pure APPDATA resolver's anchor/target; no file-picker/model path belongs here.
/// Retain this owner until process termination, not main/runApp/widget return.
final class NativeDatabaseStartupOwner {
  NativeDatabaseStartupOwner._(this._windows, this._targetPath);
  final _RestoreWindows _windows;
  final String _targetPath;
  final _directories = <_RestorePin>[];
  _RestorePin? _kernel;
  NativeDatabaseRestoreOwner? _restore;
  bool _blocked = false;
  bool _normalClaimed = false;
  bool _accepted = false;
  bool _closed = false;

  static NativeDatabaseStartupOwner acquire({
    required Directory existingStartupDirectory,
    required File target,
  }) {
    if (!Platform.isWindows || sizeOf<UintPtr>() != 8) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final windows = _RestoreWindows();
    windows.requirePath(existingStartupDirectory.path);
    windows.requirePath(target.path);
    // Exactly one channel-root level under the existing anchor. Never pin/open
    // an absent data root, target, SQLite module or candidate to acquire custody.
    if (!p.windows.equals(
          p.windows.dirname(p.windows.dirname(target.path)),
          existingStartupDirectory.path,
        ) ||
        p.windows.basename(target.path) != 'astoria.db') {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    final owner = NativeDatabaseStartupOwner._(windows, target.path);
    try {
      final ancestors = <String>[];
      var path = existingStartupDirectory.path;
      while (true) {
        ancestors.add(path);
        final parent = p.windows.dirname(path);
        if (parent == path) break;
        path = parent;
      }
      for (final path in ancestors.reversed) {
        windows.requirePath(path);
        owner._directories.add(windows.pin(path, directory: true));
      }
      owner._kernel = owner._pinKernel(
        p.windows.join(
          existingStartupDirectory.path,
          '.astoria-restore-startup.lock',
        ),
      );
      owner._checkMarker();
      return owner;
    } catch (error, stack) {
      owner._kernel?.close();
      for (final pin in owner._directories.reversed) {
        pin.close();
      }
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
      _closed || _blocked || _accepted || _normalClaimed || _restore != null;

  _RestorePin _pinKernel(String path) {
    _windows.requirePath(path);
    return _windows.text(path, (name) {
      // Resolve both lazy FFI bindings BEFORE CreateFileW: a first GetLastError
      // symbol lookup after failure can overwrite the actual sharing error.
      final open = _windows._open;
      final lastError = _windows._error;
      lastError();
      // Reuse Core's binding/pin, with immediate OS error classification: only
      // real sharing/lock conflict is busy; ACL/other open failures unsupported.
      final handle = open(name, 0x80000000, 0, nullptr, 4, 0x00200000, nullptr);
      // Capture before even Dart handle validation (which may enter the VM).
      final error = lastError();
      if (!_windows._valid(handle)) {
        _refuse(
          error == 32 || error == 33
              ? DatabaseRestoreCode.busy
              : DatabaseRestoreCode.unsupported,
        );
      }
      try {
        final info = _windows.information(handle);
        if ((info[0] & 0x410) != 0 || info[10] != 1) {
          _refuse(DatabaseRestoreCode.unsupported);
        }
        final output = _windows.allocate(1024).cast<Uint16>();
        try {
          final length = _windows._finalName(handle, output, 512, 0);
          if (length == 0 ||
              length >= 512 ||
              !p.windows.equals(
                String.fromCharCodes(output.asTypedList(length)),
                '\\\\?\\$path',
              )) {
            _refuse(DatabaseRestoreCode.unsupported);
          }
        } finally {
          _windows.free(output.cast());
        }
        return _RestorePin(_windows, handle, path, (
          info[7],
          info[11],
          info[12],
        ), false);
      } catch (_) {
        _windows.closeHandle(handle);
        rethrow;
      }
    });
  }

  void _check() {
    if (_closed || _kernel == null || _kernel!.closed) {
      _refuse(DatabaseRestoreCode.stale);
    }
    _kernel!.check();
    for (final pin in _directories) {
      pin.check();
    }
  }

  void _checkMarker() {
    _check();
    try {
      // A missing parent means absent marker; access/reparse/other failures are
      // NOT absence. Pin an existing parent for the complete observation.
      final parent = p.windows.dirname(_targetPath);
      if (_windows.exists(parent)) {
        final pin = _windows.pin(parent, directory: true);
        try {
          if (_windows.exists(
            p.windows.join(parent, '.astoria-restore-interrupted'),
          )) {
            _blocked = true;
          }
          pin.check();
        } finally {
          pin.close();
        }
      }
    } catch (_) {
      _blocked = true;
    }
  }

  /// One-way normal admission only AFTER a safe restore close/detachment. This
  /// is never accepted handoff permission and never releases the kernel guard.
  void claimNormalOpening() {
    _checkMarker();
    if (_blocked) {
      _refuse(DatabaseRestoreCode.interruptedRequiresFreshConfirmation);
    }
    if (_accepted || _normalClaimed || _restore != null) {
      _refuse(DatabaseRestoreCode.stale);
    }
    _normalClaimed = true;
  }

  void _requireRestoreAdmission() {
    _checkMarker();
    if (_blocked) {
      _refuse(DatabaseRestoreCode.interruptedRequiresFreshConfirmation);
    }
    if (_accepted || _normalClaimed || _restore != null) {
      _refuse(DatabaseRestoreCode.stale);
    }
  }

  void _detach(NativeDatabaseRestoreOwner owner) {
    if (!identical(_restore, owner)) _refuse(DatabaseRestoreCode.stale);
    if (owner.normalOpeningBlocked || owner._state != _RestoreState.closed) {
      _blocked = true;
      return;
    }
    // Accepted handoff never turns into normal lazy-opening permission. An
    // uncertain RW bootstrap without a verified reverse is not safe fallback.
    _blocked |= _accepted || (owner._bootstrapStarted && !owner._effectStarted);
    _restore = null;
  }

  /// Explicit fixture-only release AFTER its exact resources/work have joined.
  /// Production intentionally has no Dart guard-release API.
  @visibleForTesting
  void closeForTesting() {
    if (_closed) return;
    final restore = _restore;
    if (restore != null) {
      // A blocked close may have safely completed on an explicit retry, while
      // remaining blocked forever for production admission. This exact late
      // native-control closure occurs only after wrapper/raw/pin disposal.
      if (!restore._native.closed ||
          restore._work.pending != 0 ||
          restore._targetPin?.closed != true) {
        _refuse(DatabaseRestoreCode.recoveryRequired);
      }
      _restore = null;
    }
    _check();
    _kernel!.close();
    for (final pin in _directories.reversed) {
      pin.close();
    }
    _closed = true;
  }

  @override
  String toString() => 'NativeDatabaseStartupOwner(opaque)';
}
