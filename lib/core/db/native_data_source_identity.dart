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

  NativeDatabaseSnapshotOwner? ownerForApprovedLocalFile({
    required String destinationPath,
    required bool Function() isOriginalOwnerCurrent,
  }) {
    if (!isCurrent || !isOriginalOwnerCurrent() || !isCurrent) return null;
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
  bool opened = false, retired = false;
  bool get current => opened && !retired && file != null;
  void markOpened() {
    if (!retired) opened = true;
  }

  void retire() => retired = true;

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
        }
      }
    } catch (_) {
      /* Missing native source identity never fabricates a path. */
    }
    return result;
  }
}
