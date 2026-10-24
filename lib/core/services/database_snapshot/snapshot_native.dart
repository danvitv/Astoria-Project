part of '../database_snapshot_service.dart';

/// Trusted native construction only. The connection owner supplies its exact
/// current DB path and registration, and must invalidate isSourceCurrent when
/// its DB/path/epoch changes. Nothing resolves app paths or opens a default DB.
/// Source basename/sidecars and destination directory namespace custody must
/// be exclusive to that native owner (SQLite writers may still commit rows).
final class NativeDatabaseSnapshotOwner {
  NativeDatabaseSnapshotOwner({
    required this._sourcePath,
    required this._destinationPath,
    required Iterable<String> registeredTableNames,
    required this._isSourceCurrent,
  }) : _registeredTables = Set.unmodifiable(registeredTableNames);

  final String _sourcePath;
  final String _destinationPath;
  final Set<String> _registeredTables;
  final bool Function() _isSourceCurrent;
  DatabaseSnapshotIdentityFailure? _identityFailure;

  /// A failed native proof gate only. Never exposes path/error/file metadata,
  /// never changes the public result and never substitutes for identity proof.
  DatabaseSnapshotIdentityFailure? get identityFailure => _identityFailure;
}

final class _SnapshotFiles {
  _SnapshotFiles(this.api, this.sourcePath, this.destinationPath);
  final _WindowsApi api;
  final String sourcePath;
  final String destinationPath;
  late final String stagePath;
  final List<_WindowsPin> directories = [];
  final Map<String, _WindowsPin> sourceSidecars = {};
  late final _WindowsPin source;
  _WindowsPin? stage;
  (int, int, int)? stageIdentity;
  bool stageOwned = false;
  bool sidecarsOwned = false;
  bool published = false;

  static _SnapshotFiles acquire(NativeDatabaseSnapshotOwner owner) {
    if (!Platform.isWindows) {
      throw const _SnapshotFailure(
        DatabaseSnapshotStatus.unsupportedIdentity,
        identityFailure: DatabaseSnapshotIdentityFailure._(
          DatabaseSnapshotIdentityRole.sourcePath,
          DatabaseSnapshotIdentityBoundary.platform,
        ),
      );
    }
    final api = _WindowsApi();
    api.requireLocalPath(
      owner._sourcePath,
      DatabaseSnapshotIdentityRole.sourcePath,
    );
    api.requireLocalPath(
      owner._destinationPath,
      DatabaseSnapshotIdentityRole.destinationPath,
    );
    if (p.windows.equals(owner._sourcePath, owner._destinationPath)) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unsupportedIdentity);
    }
    final files = _SnapshotFiles(
      api,
      owner._sourcePath,
      owner._destinationPath,
    );
    try {
      for (final folder in {
        p.windows.dirname(files.sourcePath),
        p.windows.dirname(files.destinationPath),
      }) {
        files._pinAncestors(folder);
      }
      files.source = api.open(
        files.sourcePath,
        role: DatabaseSnapshotIdentityRole.source,
      );
      for (final suffix in ['-wal', '-shm', '-journal']) {
        final path = '${files.sourcePath}$suffix';
        if (api.exists(
          path,
          role: DatabaseSnapshotIdentityRole.sourceSidecar,
        )) {
          files.sourceSidecars[path] = api.open(
            path,
            role: DatabaseSnapshotIdentityRole.sourceSidecar,
          );
        }
      }
      if (files.sourceSidecars.containsKey('${files.sourcePath}-journal') ||
          (files.sourceSidecars.containsKey('${files.sourcePath}-wal') &&
              !files.sourceSidecars.containsKey('${files.sourcePath}-shm'))) {
        // Never recover a hot journal or create live WAL shared-memory files.
        throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
      }
      files._checkDestination();
      final random = Random.secure();
      final suffix = List.generate(
        24,
        (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
      ).join();
      files.stagePath = '${files.destinationPath}.snapshot-$suffix.partial';
      return files;
    } catch (_) {
      for (final dir in files.directories) {
        dir.close();
      }
      for (final pin in files.sourceSidecars.values) {
        pin.close();
      }
      // source may not have been initialized yet.
      try {
        files.source.close();
      } catch (_) {}
      rethrow;
    }
  }

  void _pinAncestors(String path) {
    final ancestors = <String>[];
    var current = path;
    while (true) {
      ancestors.add(current);
      final parent = p.windows.dirname(current);
      if (parent == current) break;
      current = parent;
    }
    if (ancestors.length > 64) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.unsupportedIdentity);
    }
    for (final path in ancestors.reversed) {
      directories.add(
        api.open(
          path,
          directory: true,
          role: DatabaseSnapshotIdentityRole.ancestor,
        ),
      );
    }
  }

  void _checkDestination() {
    if (api.exists(
      destinationPath,
      role: DatabaseSnapshotIdentityRole.destinationPath,
    )) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.destinationExists);
    }
  }

  void checkSourceConnection(Database db) {
    final entries = db.select('PRAGMA database_list');
    final main = entries.where((row) => row['name'] == 'main').toList();
    if (main.length != 1 ||
        main.single['file'] is! String ||
        !p.windows.equals(main.single['file'] as String, sourcePath) ||
        entries.any((row) => row['name'] != 'main' && row['name'] != 'temp')) {
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    // Windows no-delete source pin proves this exact filename cannot switch
    // between source.open and SQLite's native main connection identity check.
    source.checkPath();
    _checkSourceSidecars();
  }

  void _checkSourceSidecars() {
    for (final suffix in ['-wal', '-shm', '-journal']) {
      final path = '$sourcePath$suffix';
      final pin = sourceSidecars[path];
      if (api.exists(path, role: DatabaseSnapshotIdentityRole.sourceSidecar) !=
          (pin != null)) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
      }
      pin?.checkPath();
    }
  }

  void createStage() {
    check();
    stage = api.open(stagePath, create: true);
    stageIdentity = stage!.identity;
    stageOwned = true;
    for (final suffix in ['-journal', '-wal', '-shm']) {
      if (api.exists('$stagePath$suffix')) {
        throw const _SnapshotFailure(
          DatabaseSnapshotStatus.unsupportedIdentity,
        );
      }
    }
    sidecarsOwned = true;
  }

  void check() {
    source.checkPath();
    _checkSourceSidecars();
    for (final directory in directories) {
      directory.checkPath();
    }
    stage?.checkPath();
    _checkDestination();
  }

  void sealStage() {
    check();
    final identity = stage!.identity;
    stage!.close();
    stage = null;
    final sealed = api.open(stagePath, immutable: true, renameAccess: true);
    if (sealed.identity != identity) {
      sealed.close();
      // Never remove a replacement that this operation doesn't own.
      stageOwned = false;
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    stage = sealed;
    for (final suffix in ['-journal', '-wal', '-shm']) {
      if (api.exists('$stagePath$suffix')) {
        throw const _SnapshotFailure(DatabaseSnapshotStatus.unknown);
      }
    }
  }

  Future<Digest> hashStage(_SnapshotGuard guard) => stage!.hash(guard);

  _WindowsPin publish() {
    check();
    final pin = stage!;
    api.renameNoReplace(pin, destinationPath);
    published = true;
    stageOwned = false;
    stage = null;
    final identity = pin.identity;
    pin.close();
    // SQLite on Windows doesn't share DELETE access. Retain a read-only pin
    // after rename so a later native restore owner can open SQLite read-only.
    final retained = api.open(
      destinationPath,
      immutable: true,
      role: DatabaseSnapshotIdentityRole.retainedSnapshot,
    );
    if (retained.identity != identity) {
      retained.close();
      throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
    }
    return retained;
  }

  void close() {
    if (stageOwned && !published) {
      // Only this cryptographically unique operation-owned stage is cleaned.
      // Directory pins and trusted native exclusive custody prevent escapes.
      try {
        stage?.checkPath();
        stage?.close();
        stage = null;
        for (final suffix in [
          '',
          if (sidecarsOwned) ...['-journal', '-wal', '-shm'],
        ]) {
          if (api.exists('$stagePath$suffix')) {
            final pin = api.open(
              '$stagePath$suffix',
              immutable: true,
              renameAccess: true,
            );
            try {
              if (suffix.isEmpty && pin.identity != stageIdentity) {
                throw const _SnapshotFailure(DatabaseSnapshotStatus.stale);
              }
              api.deleteOwned(pin);
            } finally {
              pin.close();
            }
          }
        }
      } catch (_) {
        // Preserve unknown/replaced entities instead of guessing ownership.
      }
    }
    stage?.close();
    source.close();
    for (final pin in sourceSidecars.values) {
      pin.close();
    }
    for (final directory in directories) {
      directory.close();
    }
  }
}
