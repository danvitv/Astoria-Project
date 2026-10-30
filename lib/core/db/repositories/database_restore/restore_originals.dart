part of '../database_restore_repo.dart';

/// Independent FULL-synchronous native committed original plus separately
/// verified raw observations taken UNDER the acquired lease. No atomic pre-open
/// four-file image is promised; bootstrap may already have recovered WAL.
final class _RestoreOriginals {
  _RestoreOriginals(this.owner, this.stage, this.stagePin);
  final NativeDatabaseRestoreOwner owner;
  final String stage;
  final _RestorePin stagePin;
  _RestoreRaw? raw;
  _RestorePin? nativePin;
  _RestoreLogicalDigest? digest;
  final _ownedFiles = <String>[];
  final _rawPins = <_RestorePin>[];
  final _observationPins = <_RestorePin>[];
  final _observations = <String, (bool, int, Digest?)>{};
  _RestorePin? marker;
  bool _released = false;
  bool _retentionEnded = false;
  bool _verified = false;

  static _RestoreOriginals create(NativeDatabaseRestoreOwner owner) {
    final stage = owner._windows.createStage(
      owner._windows.paths.dirname(owner._targetPath),
    );
    return _RestoreOriginals(
      owner,
      stage,
      owner._windows.pin(stage, directory: true),
    );
  }

  Future<void> preserve() async {
    final windows = owner._windows;
    final native = owner._native;
    final target = owner._target!;
    owner._check();
    native.verify(target, owner._targetPin!);
    final before = await _RestoreLogicalDigest.capture(
      target.database,
      owner._check,
    );
    owner._check();
    final path = windows.paths.join(stage, 'original.db');
    final file = nativePin = windows.pin(path, create: true, write: true);
    _ownedFiles.add(path);
    raw = native.open(path, OpenMode.readWrite);
    native.durableOriginal(raw!);
    native.verify(raw!, file);
    await native.copy(target, raw!);
    owner._check();
    native.verify(target, owner._targetPin!);
    digest = await _RestoreLogicalDigest.capture(raw!.database, owner._check);
    owner._check();
    if (!before.same(digest!)) _refuse(DatabaseRestoreCode.recoveryRequired);
    _verified = true;
    // Original logical damage does NOT demand current candidate registration,
    // FK/payload semantics or a different application version to be readable.
    // Closing any ordinary descriptor for the live target inode would release
    // process-owned POSIX locks. Android retains ONLY the verified logical
    // SQLite backup; Windows's four raw observations remain unchanged.
    if (windows is _RestoreWindows) {
      for (final suffix in ['', '-wal', '-shm', '-journal']) {
        owner._check();
        final sourcePath = '${owner._targetPath}$suffix';
        if (!windows.exists(sourcePath)) {
          _observations[suffix] = (false, 0, null);
          continue;
        }
        final input = windows.pin(sourcePath);
        _observationPins.add(input);
        _RestorePin? output;
        final copyPath = p.windows.join(
          stage,
          suffix.isEmpty ? 'main.raw' : '${suffix.substring(1)}.raw',
        );
        try {
          output = windows.pin(copyPath, create: true, write: true);
          _observationPins.add(output);
          _ownedFiles.add(copyPath);
          final size = input.length;
          final hash = await windows.copyOrHash(
            input,
            owner._check,
            output: output,
          );
          owner._check();
          output.close();
          output = null;
          final retained = windows.pin(copyPath, immutable: true);
          _rawPins.add(retained);
          if (retained.length != size ||
              await windows.copyOrHash(retained, owner._check) != hash) {
            _refuse(DatabaseRestoreCode.recoveryRequired);
          }
          owner._check();
          _observations[suffix] = (true, size, hash);
        } catch (error, stack) {
          owner._work.remember(error, stack);
          rethrow;
        } finally {
          output?.close();
          input.close();
        }
      }
    }
    owner._check();
    marker = windows.pin(owner._markerPath, create: true, write: true);
    windows.writeMarker(marker!, windows.paths.basename(stage));
    owner._check();
  }

  void clearSettledMarker() {
    final current = marker;
    if (current == null) return;
    current.close();
    owner._windows.deleteOwnedFile(owner._markerPath);
    marker = null;
  }

  void recordInterruption() {
    if (owner._windows.exists(owner._markerPath)) return;
    marker = owner._windows.pin(owner._markerPath, create: true, write: true);
    owner._windows.writeMarker(marker!, owner._windows.paths.basename(stage));
  }

  void closeConnections() {
    raw?.close();
    nativePin?.close();
    for (final pin in _observationPins.reversed) {
      pin.close();
    }
    for (final pin in _rawPins.reversed) {
      pin.close();
    }
    marker?.close();
    stagePin.close();
  }

  Future<void> releaseAfterAcceptance() async {
    if (_released) return;
    owner._check();
    // SQLite-created sidecars lack exclusive owned-file proof on Android.
    // Keep the original by default rather than deleting by guessed paths.
    if (owner._windows.androidDataRoot != null) {
      _refuse(DatabaseRestoreCode.unsupported);
    }
    // Release only this stage's original connection; accepted target stays live.
    closeConnections();
    // End recoverable-original custody BEFORE the first destructive deletion.
    // A later cleanup failure cannot restore it; _released separately records
    // complete cleanup so failed deletions/removal remain eligible for retry.
    _retentionEnded = true;
    for (final path in _ownedFiles) {
      for (final suffix in ['', '-journal', '-wal', '-shm']) {
        final owned = '$path$suffix';
        if (owner._windows.exists(owned)) owner._windows.deleteOwnedFile(owned);
      }
    }
    owner._windows.deleteOwnedDirectory(stage);
    _released = true;
  }
}

extension _RestoreRetention on NativeDatabaseRestoreOwner {
  Future<void> _releaseOriginals() async {
    if (_state != _RestoreState.accepted ||
        _retired ||
        _cancelled ||
        _active == null) {
      _refuse(DatabaseRestoreCode.stale);
    }
    // No delete may race owner close/cancel; retain the actual original future.
    await _track(_originals!.releaseAfterAcceptance());
    _check();
  }
}
