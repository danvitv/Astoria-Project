import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart';
import 'package:sqlite3/unstable/ffi_bindings.dart' as nsql;

part 'database_snapshot/snapshot_models.dart';
part 'database_snapshot/snapshot_native.dart';
part 'database_snapshot/snapshot_sqlite.dart';
part 'database_snapshot/snapshot_windows.dart';

/// A native-only prerequisite for recovery, not an app backup or restore API.
/// Construction belongs to the source connection owner, never a model/tool.
final class DatabaseSnapshotService {
  DatabaseSnapshotService({required this._native});

  final NativeDatabaseSnapshotOwner _native;
  final Map<VerifiedDatabaseSnapshot, _SnapshotRecord> _records = {};
  bool _running = false;
  bool _disposed = false;

  Future<DatabaseSnapshotResult> create({
    required DatabaseSnapshotControl control,
  }) async {
    if (_running || _disposed) {
      return const DatabaseSnapshotResult(DatabaseSnapshotStatus.unavailable);
    }
    _running = true;
    _native._identityFailure = null;
    final guard = _SnapshotGuard(
      control,
      () => !_disposed && _native._isSourceCurrent(),
    );
    _SnapshotFiles? files;
    Database? source;
    Database? copy;
    try {
      guard.check();
      files = _SnapshotFiles.acquire(_native);
      guard.check();
      source = sqlite3.open(files.sourcePath, mode: OpenMode.readOnly);
      _SnapshotSqlite.configure(source, guard);
      files.checkSourceConnection(source);
      files.check();
      guard.check();
      // An explicit read transaction pins the same committed WAL state for
      // metadata, counts and online backup. Never checkpoint the live source.
      source.execute('BEGIN');
      final expected = _SnapshotSqlite.inspect(
        source,
        _native._registeredTables,
        guard,
      );
      files.checkSourceConnection(source);
      guard.check();
      files.createStage();
      copy = sqlite3.open(files.stagePath, mode: OpenMode.readWrite);
      _SnapshotSqlite.configure(copy, guard, readOnly: false);
      await _SnapshotSqlite.backup(source, copy, files, guard);
      guard.check();
      files.check();
      // Only the isolated destination is made self-contained. Its backup may
      // inherit WAL mode; it must have no required sidecars before publication.
      copy.execute('PRAGMA journal_mode = DELETE');
      _SnapshotSqlite.verify(copy, expected, _native._registeredTables, guard);
      copy.close();
      copy = null;
      source.execute('ROLLBACK');
      source.close();
      source = null;
      files.sealStage();
      final digest = await files.hashStage(guard);
      guard.check();
      await guard.boundary(DatabaseSnapshotBoundary.beforePublish);
      guard.check();
      files.check();
      guard.check();
      // No await or user callback between this guard, native no-replace rename
      // and publication. The immutable file pin is retained in the record.
      final pin = files.publish();
      final handle = VerifiedDatabaseSnapshot._();
      _records[handle] = _SnapshotRecord(
        pin: pin,
        digest: digest,
        verifiedAt: DateTime.now().toUtc(),
        schema: expected,
      );
      return DatabaseSnapshotResult(
        DatabaseSnapshotStatus.verified,
        handle: handle,
        tableCount: expected.counts.length,
        byteCount: pin.length,
      );
    } on _SnapshotFailure catch (error) {
      _native._identityFailure = error.identityFailure;
      return DatabaseSnapshotResult(error.status);
    } catch (_) {
      // SQLite, OS, hooks and paths are never reflected into public errors.
      final status = guard.failure ?? DatabaseSnapshotStatus.invalid;
      return DatabaseSnapshotResult(status);
    } finally {
      try {
        copy?.close();
      } catch (_) {}
      try {
        source?.close();
      } catch (_) {}
      try {
        files?.close();
      } catch (_) {}
      _running = false;
      if (_disposed) _releaseRecords();
    }
  }

  /// Rechecks custody and the complete byte hash without exposing the file.
  Future<DatabaseSnapshotResult> verifyHandle(
    VerifiedDatabaseSnapshot handle, {
    required DatabaseSnapshotControl control,
  }) async {
    final record = _records[handle];
    if (_disposed || record == null || _running) {
      return const DatabaseSnapshotResult(DatabaseSnapshotStatus.unavailable);
    }
    _running = true;
    final guard = _SnapshotGuard(control, () => !_disposed);
    try {
      guard.check();
      final digest = await record.pin.hash(guard);
      guard.check();
      if (digest != record.digest) {
        return const DatabaseSnapshotResult(DatabaseSnapshotStatus.invalid);
      }
      return DatabaseSnapshotResult(
        DatabaseSnapshotStatus.verified,
        handle: handle,
        tableCount: record.schema.counts.length,
        byteCount: record.pin.length,
      );
    } on _SnapshotFailure catch (error) {
      return DatabaseSnapshotResult(error.status);
    } catch (_) {
      return DatabaseSnapshotResult(
        guard.failure ?? DatabaseSnapshotStatus.invalid,
      );
    } finally {
      _running = false;
      if (_disposed) _releaseRecords();
    }
  }

  /// No live DB replacement exists without an awaited writer/lifecycle owner.
  DatabaseSnapshotStatus get runtimeRestoreStatus =>
      DatabaseSnapshotStatus.unsupportedRestore;

  /// Releases immutable native pins; never deletes a published snapshot.
  void dispose() {
    _disposed = true;
    if (!_running) _releaseRecords();
  }

  void _releaseRecords() {
    for (final record in _records.values) {
      record.pin.close();
    }
    _records.clear();
  }
}
