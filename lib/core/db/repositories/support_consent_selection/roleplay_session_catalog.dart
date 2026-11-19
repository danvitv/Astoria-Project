part of '../support_consent_selection_repo.dart';

extension _RoleplaySessionCatalog on _RoleplaySelectionProjection {
  Future<SupportConsentSessionPage> sessions(int offset, int limit) async {
    SupportConsentSessionPage unavailable() => SupportConsentSessionPage(
      items: const [],
      status: SupportConsentSelectionStatus.unavailable,
    );
    if (!_validPage(
      offset,
      limit,
      SupportConsentSelectionRepo.maxSessionPageSize,
    )) {
      return unavailable();
    }
    try {
      final rows = await db
          .customSelect(
            '''
        $_activityMetadata
        SELECT ${_RoleplaySelectionProjection._columns}
        FROM chat_sessions s
        INNER JOIN chat_message_payloads payload ON payload.session_id=s.session_id
        LEFT JOIN characters c ON c.char_id = s.character_id
        JOIN session_activity a ON a.session_id = s.session_id
        WHERE ${_RoleplaySelectionProjection._visible}
        ORDER BY a.activity_ms DESC, s.updated_at DESC, s.rowid ASC
        LIMIT ? OFFSET ?
        ''',
            variables: [Variable.withInt(limit + 1), Variable.withInt(offset)],
          )
          .get();
      final redactor = currentRedactor();
      final source = rows.take(limit).toList();
      final options = source
          .map((row) => _option(row, redactor))
          .nonNulls
          .toList();
      return SupportConsentSessionPage(
        items: options,
        omittedCount: source.length - options.length,
        status: rows.length > limit
            ? SupportConsentSelectionStatus.limited
            : SupportConsentSelectionStatus.available,
        nextOffset:
            rows.length > limit &&
                offset + limit <= SupportConsentSelectionRepo.maxOffset
            ? offset + limit
            : null,
      );
    } catch (_) {
      return unavailable();
    }
  }

  // Match chat history/sessionPreviewAndTime BEFORE paging: newest message or
  // branch/creation event, not updated_at (which also changes on settings edits).
  // Only scalar timestamps leave SQLite; no message/vars/preview body is read.
  static final String _activityMetadata =
      '''
    WITH ${ChatMessageStorageSql.metadataCte}, session_times AS (
       SELECT s.session_id,
          CASE WHEN payload.integrity_ok = 1
            THEN COALESCE(payload.first_timestamp, 0) ELSE 0 END AS first_ms,
          CASE WHEN payload.integrity_ok = 1
            THEN COALESCE(payload.last_timestamp, 0) ELSE 0 END AS last_ms,
         CASE WHEN json_valid(s.session_vars_json) THEN
           CASE WHEN json_type(s.session_vars_json, '\$.branchedAt') = 'text'
             AND length(json_extract(s.session_vars_json, '\$.branchedAt')) <= 256
             THEN trim(json_extract(s.session_vars_json, '\$.branchedAt')) END
           END AS branch_text
       FROM chat_sessions s
       INNER JOIN chat_message_payloads payload ON payload.session_id=s.session_id
    ), session_activity AS (
      SELECT session_id, MAX(
        CASE WHEN typeof(last_ms) = 'integer' THEN last_ms ELSE 0 END,
        CASE WHEN branch_text != '' AND branch_text NOT GLOB '*[^0-9]*'
          AND CAST(branch_text AS INTEGER) > 0
          THEN CAST(branch_text AS INTEGER)
          ELSE CASE WHEN typeof(first_ms) = 'integer' THEN first_ms ELSE 0 END END
      ) AS activity_ms FROM session_times
    )
  ''';
}
