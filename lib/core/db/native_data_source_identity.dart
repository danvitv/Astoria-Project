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
