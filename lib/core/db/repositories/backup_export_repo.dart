import '../app_db.dart';

/// Read-only backup access. Full rows are fetched by byte budget, not merely
/// row count: one chat row can contain tens of megabytes of message history.
final class BackupExportRepo {
  BackupExportRepo(this._db);

  final AppDatabase _db;
  static const pageBytes = 2 * 1024 * 1024;
  static const _metadataPageSize = 500;

  Stream<List<Map<String, dynamic>>> pages(String tableName) async* {
    final table = _db.allTables.singleWhere(
      (table) => table.actualTableName == tableName,
    );
    final size = table.$columns
        .map((column) => 'coalesce(length(CAST("${column.$name}" AS BLOB)), 0)')
        .join(' + ');
    final orderBy = tableName == 'lorebook_use_acceptance_records'
        ? "CASE acceptance_kind WHEN 'variation' THEN 0 ELSE 1 END, accepted_at, acceptance_id, rowid"
        : 'rowid';
    var offset = 0;
    while (true) {
      // Only IDs and byte lengths cross the worker boundary in this query.
      final metadata = await _db
          .customSelect(
            'SELECT rowid AS export_rowid, $size AS export_bytes '
            'FROM "$tableName" ORDER BY $orderBy '
            'LIMIT $_metadataPageSize OFFSET $offset',
          )
          .get();
      if (metadata.isEmpty) break;
      var ids = <int>[];
      var bytes = 0;
      for (final row in metadata) {
        final rowBytes = row.read<int>('export_bytes');
        if (ids.isNotEmpty && bytes + rowBytes > pageBytes) {
          yield await _readRows(tableName, orderBy, ids);
          ids = [];
          bytes = 0;
        }
        ids.add(row.read<int>('export_rowid'));
        bytes += rowBytes;
      }
      if (ids.isNotEmpty) yield await _readRows(tableName, orderBy, ids);
      offset += metadata.length;
      if (metadata.length < _metadataPageSize) break;
    }
  }

  Future<List<Map<String, dynamic>>> _readRows(
    String tableName,
    String orderBy,
    List<int> ids,
  ) async {
    final rows = await _db
        .customSelect(
          'SELECT * FROM "$tableName" WHERE rowid IN (${ids.join(',')}) '
          'ORDER BY $orderBy',
        )
        .get();
    return [for (final row in rows) row.data];
  }

  Future<Set<String>> avatarIds(String tableName, String column) async => {
    for (final row
        in await _db.customSelect('SELECT $column FROM $tableName').get())
      if (row.data[column] case final String id when id.isNotEmpty) id,
  };
}
