abstract final class ChatMessageStorageSql {
  const ChatMessageStorageSql._();

  /// Metadata for every session without constructing row-backed JSON arrays.
  /// Consumers may page/sort on these scalar projections before reading bodies.
  static final String metadataCte =
      '''
    chat_message_payloads AS (
      ${_metadataSelect()}
    )
  ''';

  /// A compatibility payload for exactly one trusted internal target
  /// expression (`?`, `args.target`, and similar fixed SQL). Row invariants are
  /// checked before an array is exposed, so corruption fails closed.
  static String targetPayloadCte(String targetExpression) =>
      '''
    chat_message_metadata AS (
      ${_metadataSelect(where: 'session.session_id = $targetExpression')}
    ),
    chat_message_payloads AS (
      SELECT metadata.*,
        CASE WHEN metadata.is_row_backed = 0 THEN metadata.legacy_json
          WHEN metadata.integrity_ok != 1 THEN NULL
          ELSE COALESCE((
            SELECT json_group_array(json(ordered.message_json))
            FROM (
              SELECT message.message_json
              FROM chat_message_rows AS message
              WHERE message.session_id = metadata.session_id
                AND message.storage_generation = metadata.active_generation
              ORDER BY message.position_key
            ) AS ordered
          ), '[]') END AS messages_json
      FROM chat_message_metadata AS metadata
    )
  ''';

  static const _rowIntegrity = '''
    storage.active_generation > 0 AND storage.revision > 0
    AND storage.message_count >= 0
    AND storage.message_count = (
      SELECT count(*) FROM chat_message_rows AS counted
      WHERE counted.session_id = session.session_id
        AND counted.storage_generation = storage.active_generation
    )
    AND storage.message_count = (
      SELECT count(DISTINCT positioned.position_key)
      FROM chat_message_rows AS positioned
      WHERE positioned.session_id = session.session_id
        AND positioned.storage_generation = storage.active_generation
    )
    AND NOT EXISTS (
      SELECT 1 FROM chat_message_rows AS checked
      WHERE checked.session_id = session.session_id
        AND checked.storage_generation = storage.active_generation
        AND (
          checked.position_key <= 0
          OR checked.role = ''
          OR
          NOT json_valid(checked.message_json)
          OR json_type(checked.message_json) != 'object'
          OR json_type(checked.message_json, '\$.id') != 'text'
          OR json_extract(checked.message_json, '\$.id') IS NOT checked.message_id COLLATE BINARY
          OR json_type(checked.message_json, '\$.role') != 'text'
          OR json_extract(checked.message_json, '\$.role') IS NOT checked.role COLLATE BINARY
          OR NOT (
            (json_type(checked.message_json, '\$.timestamp') = 'integer'
              AND json_extract(checked.message_json, '\$.timestamp') IS checked.message_timestamp)
            OR (COALESCE(json_type(checked.message_json, '\$.timestamp'), 'null') = 'null'
              AND checked.message_timestamp IS NULL)
          )
        )
    )
  ''';

  static const _legacyIntegrity = '''
    typeof(session.messages_json) = 'text'
    AND json_valid(session.messages_json)
    AND json_type(session.messages_json) = 'array'
  ''';

  static String _metadataSelect({String? where}) =>
      '''
    SELECT session.session_id,
      CASE WHEN storage.session_id IS NULL THEN 0 ELSE 1 END AS is_row_backed,
      storage.active_generation,
      CASE WHEN storage.session_id IS NULL THEN session.messages_json END AS legacy_json,
      CASE WHEN storage.session_id IS NULL
        THEN CASE WHEN $_legacyIntegrity THEN 1 ELSE 0 END
        ELSE CASE WHEN $_rowIntegrity THEN 1 ELSE 0 END END AS integrity_ok,
      CASE WHEN storage.session_id IS NULL THEN length(session.messages_json)
        ELSE 2 + COALESCE((
          SELECT sum(length(sized.message_json)) +
            CASE WHEN count(*) > 0 THEN count(*) - 1 ELSE 0 END
          FROM chat_message_rows AS sized
          WHERE sized.session_id = session.session_id
            AND sized.storage_generation = storage.active_generation
        ), 0) END AS payload_characters,
      CASE WHEN storage.session_id IS NULL
        THEN CASE WHEN $_legacyIntegrity THEN json_array_length(session.messages_json) END
        ELSE storage.message_count END AS message_count,
      CASE WHEN storage.session_id IS NULL
        THEN CASE WHEN $_legacyIntegrity
          THEN json_extract(session.messages_json, '\$[0].timestamp') END
        ELSE (SELECT first.message_timestamp FROM chat_message_rows AS first
          WHERE first.session_id = session.session_id
            AND first.storage_generation = storage.active_generation
          ORDER BY first.position_key LIMIT 1) END AS first_timestamp,
      CASE WHEN storage.session_id IS NULL
        THEN CASE WHEN $_legacyIntegrity
          THEN json_extract(session.messages_json, '\$[#-1].timestamp') END
        ELSE (SELECT last.message_timestamp FROM chat_message_rows AS last
          WHERE last.session_id = session.session_id
            AND last.storage_generation = storage.active_generation
          ORDER BY last.position_key DESC LIMIT 1) END AS last_timestamp
    FROM chat_sessions AS session
    LEFT JOIN chat_message_storage_rows AS storage
      ON storage.session_id = session.session_id
    ${where == null ? '' : 'WHERE $where'}
  ''';
}
