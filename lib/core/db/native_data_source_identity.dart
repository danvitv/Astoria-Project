part of 'app_db.dart';

/// Original AppDatabase instance/lifetime and the file used by its executor.
/// This is native-only custody: no serialization, path getter or data reader.
final class NativeDataSourceIdentity {
  NativeDataSourceIdentity._(this._database, this._native);
  final AppDatabase _database;
  final _AppDatabaseNativeFile _native;

  bool get isCurrent => _native.current;
  bool belongsTo(AppDatabase database) =>
      identical(_database, database) && isCurrent;

  /// Joins work to this already-open original native lifetime. It does not open,
  /// reconnect, reveal a file/handle, establish a transaction or grant data access.
  /// Native ROOT repositories must still establish their own audited admission.
  Future<T> withBorrowedLifetime<T>(Future<T> Function() work) async {
    if (!isCurrent) throw StateError('Native source retired');
    late T result;
    await _native.borrow(() async {
      if (!isCurrent) throw StateError('Native source retired');
      result = await work();
    });
    return result;
  }

  /// A proposal only: no directory/file, key, body, SQL or OS dialog is touched.
  /// The opaque destination is private native UI metadata, never tool JSON.
  String? proposeAppPrivateSnapshotDestination() {
    final namespace = _native.androidSnapshotNamespace;
    if (!isCurrent ||
        namespace == null ||
        _native._unsettledSnapshots.isNotEmpty) {
      return null;
    }
    final random = Random.secure();
    final token = List.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    _native._privateSnapshotIssuer = Object();
    return _native._pendingSnapshotDestination = p.posix.join(
      namespace.workerStageRoot,
      token,
      'astoria-backup.db',
    );
  }

  /// Trusted native owner composition only. Acceptance can bind its retained
  /// proof without replacing/reopening the already-accepted Drift wrapper.
  /// Exact raw identity and once-only binding exclude candidate/path substitution.
  void retainSnapshotSource({
    required sqlite.Database source,
    required void Function() checkSource,
  }) {
    if (!isCurrent ||
        !identical(source, _native.raw) ||
        _native.checkSnapshotSource != null) {
      throw StateError('Native snapshot source unavailable');
    }
    _native.checkSnapshotSource = checkSource;
  }

  NativeDatabaseSnapshotOwner? ownerForApprovedLocalFile({
    required String destinationPath,
    required bool Function() isOriginalOwnerCurrent,
  }) {
    if (!isCurrent || !isOriginalOwnerCurrent() || !isCurrent) return null;
    final namespace = _native.androidSnapshotNamespace;
    if (namespace != null) {
      if (destinationPath != _native._pendingSnapshotDestination ||
          _native._unsettledSnapshots.isNotEmpty) {
        return null;
      }
      _native._pendingSnapshotDestination = null; // one-use, before native work
      final issuer = _native._privateSnapshotIssuer;
      bool current() =>
          isCurrent &&
          isOriginalOwnerCurrent() &&
          identical(issuer, _native._privateSnapshotIssuer) &&
          _native._unsettledSnapshots.isEmpty &&
          isCurrent;
      final repo = DatabaseBackgroundSnapshotSourceRepo(
        database: _database,
        namespace: namespace,
        sourcePath: _native.file!.path,
        registeredTables: _database.allTables
            .map((t) => t.actualTableName)
            .toSet(),
        isCurrent: current,
        joinLifetime: _native.borrow,
        retainUnsettled: (resource) =>
            _native._unsettledSnapshots.add(resource),
      );
      return NativeDatabaseSnapshotOwner.androidPrivate(
        source: repo.source,
        destinationPath: destinationPath,
      );
    }
    final source = _native.raw;
    final checkSource = _native.checkSnapshotSource;
    if (source != null && checkSource != null) {
      return NativeDatabaseSnapshotOwner.borrowed(
        source: source,
        sourcePath: _native.file!.path,
        destinationPath: destinationPath,
        registeredTableNames: _database.allTables.map((t) => t.actualTableName),
        isSourceCurrent: () =>
            isCurrent && isOriginalOwnerCurrent() && isCurrent,
        checkSource: checkSource,
        inReadTransaction: (work) => _native.borrow(
          () => _database.transaction(() async {
            if (!isCurrent || !isOriginalOwnerCurrent()) {
              throw StateError('Native snapshot source retired');
            }
            await work();
          }),
        ),
      );
    }
    return NativeDatabaseSnapshotOwner(
      sourcePath: _native.file!.path,
      destinationPath: destinationPath,
      registeredTableNames: _database.allTables.map((t) => t.actualTableName),
      isSourceCurrent: () => isCurrent && isOriginalOwnerCurrent() && isCurrent,
    );
  }

  @override
  String toString() => 'NativeDataSourceIdentity';
}

final class _AppDatabaseNativeFile {
  _AppDatabaseNativeFile();
  File? file;
  sqlite.Database? raw;
  void Function()? checkSnapshotSource;
  AndroidSnapshotNamespace? androidSnapshotNamespace;
  Object? _privateSnapshotIssuer;
  String? _pendingSnapshotDestination;
  final _unsettledSnapshots = <Object>[];
  final _borrowed = <Future<void>>{};
  bool opened = false, retired = false;
  bool get current => opened && !retired && file != null;
  void markOpened() {
    if (!retired) opened = true;
  }

  void retire() => retired = true;

  Future<void> borrow(Future<void> Function() work) {
    if (!current) return Future.error(StateError('Native source retired'));
    final operation = Future<void>.sync(work);
    late final Future<void> observed;
    observed = operation.then<void>(
      (_) {
        _borrowed.remove(observed);
      },
      onError: (Object _, StackTrace _) {
        _borrowed.remove(observed);
      },
    );
    _borrowed.add(observed);
    return operation;
  }

  Future<void> drain() async {
    while (_borrowed.isNotEmpty) {
      await Future.wait(List<Future<void>>.of(_borrowed));
    }
  }

  static _AppDatabaseNativeFile fromOpened(sqlite.Database connection) {
    final result = _AppDatabaseNativeFile();
    try {
      // Metadata of the exact native handle supplied to NativeDatabase.opened.
      // No private row, schema body, environment or default path is consulted.
      final attached = connection.select('PRAGMA database_list');
      if (attached.length == 1 && attached.single['name'] == 'main') {
        final path = attached.single['file'];
        if (path is String && path.isNotEmpty && p.isAbsolute(path)) {
          result.file = File(path);
          result.raw = connection;
        }
      }
    } catch (_) {
      /* Missing native source identity never fabricates a path. */
    }
    return result;
  }
}
