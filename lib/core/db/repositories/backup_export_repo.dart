import 'package:drift/drift.dart';

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
    final size = tableName == 'chat_sessions'
        ? _chatSessionExportSize(table)
        : table.$columns
              .map(
                (column) =>
                    'coalesce(length(CAST("${column.$name}" AS BLOB)), 0)',
              )
              .join(' + ');
    final orderBy = tableName == 'lorebook_use_acceptance_records'
        ? "CASE acceptance_kind WHEN 'variation' THEN 0 ELSE 1 END, accepted_at, acceptance_id, rowid"
        : tableName == 'chat_sessions'
        ? 's.rowid'
        : 'rowid';
    final exportRowid = tableName == 'chat_sessions' ? 's.rowid' : 'rowid';
    var offset = 0;
    while (true) {
      // Only IDs and byte lengths cross the worker boundary in this query.
      final metadata = await _db
          .customSelect(
            'SELECT $exportRowid AS export_rowid, $size AS export_bytes '
            'FROM "$tableName" '
            '${tableName == 'chat_sessions' ? 'AS s LEFT JOIN chat_message_storage_rows AS storage ON storage.session_id=s.session_id ' : ''}'
            'ORDER BY $orderBy '
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
    if (tableName == 'chat_sessions') {
      final rows = await _db.customSelect('''SELECT s.*,
              CASE WHEN storage.session_id IS NULL THEN s.messages_json
              ELSE COALESCE((
                SELECT json_group_array(json(ordered.message_json))
                FROM (
                  SELECT message.message_json
                  FROM chat_message_rows AS message
                  WHERE message.session_id=s.session_id
                    AND message.storage_generation=storage.active_generation
                  ORDER BY message.position_key
                ) AS ordered
              ), '[]') END AS export_messages_json
            FROM chat_sessions AS s
            LEFT JOIN chat_message_storage_rows AS storage
              ON storage.session_id=s.session_id
            WHERE s.rowid IN (${ids.join(',')})
            ORDER BY s.rowid''').get();
      return [
        for (final row in rows)
          Map<String, dynamic>.from(row.data)
            ..['messages_json'] = row.data['export_messages_json']
            ..remove('export_messages_json'),
      ];
    }
    final rows = await _db
        .customSelect(
          'SELECT * FROM "$tableName" WHERE rowid IN (${ids.join(',')}) '
          'ORDER BY $orderBy',
        )
        .get();
    return [for (final row in rows) row.data];
  }

  String _chatSessionExportSize(TableInfo<Table, Object?> table) {
    final fixed = table.$columns
        .where((column) => column.$name != 'messages_json')
        .map(
          (column) => 'coalesce(length(CAST(s."${column.$name}" AS BLOB)), 0)',
        )
        .join(' + ');
    return '''$fixed + CASE WHEN storage.session_id IS NULL
      THEN coalesce(length(CAST(s.messages_json AS BLOB)), 0)
      ELSE coalesce((
        SELECT sum(length(CAST(message.message_json AS BLOB))) + count(*) + 2
        FROM chat_message_rows AS message
        WHERE message.session_id=s.session_id
          AND message.storage_generation=storage.active_generation
      ), 2) END''';
  }

  Future<Set<String>> avatarIds(String tableName, String column) async => {
    for (final row
        in await _db.customSelect('SELECT $column FROM $tableName').get())
      if (row.data[column] case final String id when id.isNotEmpty) id,
  };
}
