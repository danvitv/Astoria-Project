part of '../support_text_context_repo.dart';

final class _RoleplayTextReader {
  const _RoleplayTextReader(this.db);
  final AppDatabase db;
  // SQLite CASE is lazy. The byte bound precedes validity, shape, count and
  // json_each. No full source JSON ever crosses the SQL projection boundary.
  static const _boundedJson =
      '''CASE
    WHEN typeof(messages_json) != 'text' THEN '[]'
    WHEN length(CAST(messages_json AS BLOB)) > ${SupportTextContextRepo.maxRoleplaySourceBytes} THEN '[]'
    WHEN NOT json_valid(messages_json) THEN '[]'
    WHEN json_type(messages_json) != 'array' THEN '[]'
    WHEN json_array_length(messages_json) > ${SupportTextContextRepo.maxSourceMessages} THEN '[]'
    ELSE messages_json END''';
  static const _entries =
      '''
      WITH target AS (
        SELECT $_boundedJson AS j FROM chat_sessions WHERE session_id = ? LIMIT 1
      ), entries AS (
        SELECT e.key AS native_order,
          CASE WHEN e.type = 'object' THEN e.value ELSE '{}' END AS o
        FROM target, json_each(target.j) e
      ), identified AS (
        SELECT native_order, o,
          CASE WHEN json_type(o, '\$.id') = 'text' AND length(json_extract(o, '\$.id')) <= 256
            THEN json_extract(o, '\$.id') END AS message_id
        FROM entries
      )
  ''';

  Future<_TextRead> read(
    String sessionId,
    List<String> ids, {
    void Function()? checkpoint,
  }) async {
    checkpoint?.call();
    final header = await db
        .customSelect(
          '''
      SELECT s.rowid AS native_identity,
        CASE WHEN typeof(s.session_index) = 'integer' AND s.session_index BETWEEN 0 AND 1000000
          THEN s.session_index END AS session_index,
        CASE WHEN typeof(c.char_id) = 'text' AND length(c.char_id) <= 256
          AND length(CAST(c.char_id AS BLOB)) <= 1024 THEN c.char_id END AS character_id,
        c.rowid AS character_native_identity,
        CASE WHEN typeof(c.variant_group_id) = 'text' AND length(c.variant_group_id) <= 256
          AND length(CAST(c.variant_group_id AS BLOB)) <= 1024 THEN c.variant_group_id END AS variant_group_id,
        CASE WHEN c.variant_group_id IS NULL OR (typeof(c.variant_group_id) = 'text'
          AND length(c.variant_group_id) <= 256 AND length(CAST(c.variant_group_id AS BLOB)) <= 1024)
          THEN 1 ELSE 0 END AS group_valid,
        CASE WHEN typeof(c.variant_order) = 'integer' AND c.variant_order BETWEEN 0 AND 1000000
          THEN c.variant_order END AS variant_order,
        CASE WHEN typeof(s.messages_json) != 'text' THEN 2
          WHEN length(CAST(s.messages_json AS BLOB)) > ${SupportTextContextRepo.maxRoleplaySourceBytes} THEN 1
          WHEN NOT json_valid(s.messages_json) THEN 2
          WHEN json_type(s.messages_json) != 'array' THEN 2
          WHEN json_array_length(s.messages_json) > ${SupportTextContextRepo.maxSourceMessages} THEN 1
          ELSE 0 END AS source_status
      FROM chat_sessions s INNER JOIN characters c ON c.char_id = s.character_id
      WHERE s.session_id = ? AND typeof(s.character_id) = 'text'
        AND typeof(c.hidden) = 'integer' AND c.hidden = 0 LIMIT 1
    ''',
          variables: [Variable.withString(sessionId)],
        )
        .getSingleOrNull();
    checkpoint?.call();
    if (header == null) _fail(SupportTextContextFailure.unavailable);
    final status = header.read<int>('source_status');
    if (status != 0) {
      _fail(
        status == 1
            ? SupportTextContextFailure.limited
            : SupportTextContextFailure.unavailable,
      );
    }
    if (header.readNullable<String>('character_id') == null ||
        header.readNullable<int>('character_native_identity') == null ||
        header.read<int>('group_valid') != 1 ||
        header.readNullable<int>('variant_order') == null ||
        header.readNullable<int>('session_index') == null) {
      _fail(SupportTextContextFailure.unavailable);
    }
    // Private empty projection is used only after whole-source confirmation.
    // The public exact-selection APIs still reject empty IDs before this reader.
    if (ids.isEmpty) return _TextRead(header, const [], const []);
    final slots = List.filled(ids.length, '?').join(',');
    final variables = [
      Variable.withString(sessionId),
      ...ids.map(Variable.withString),
    ];
    final budget = await db.customSelect('''
      $_entries
      SELECT COUNT(*) AS n,
        COALESCE(SUM(CASE WHEN json_type(o, '\$.content') = 'text' THEN
          length(json_extract(o, '\$.content')) ELSE 0 END), 0) AS chars,
        COALESCE(SUM(CASE WHEN json_type(o, '\$.content') = 'text' THEN
          length(CAST(json_extract(o, '\$.content') AS BLOB)) ELSE 0 END), 0) AS bytes
      FROM identified WHERE message_id IN ($slots)
    ''', variables: variables).getSingle();
    checkpoint?.call();
    if (budget.read<int>('n') != ids.length) {
      _fail(SupportTextContextFailure.unavailable);
    }
    if (budget.read<int>('chars') > SupportTextContextRepo.maxTextChars ||
        budget.read<int>('bytes') > SupportTextContextRepo.maxTextBytes) {
      _fail(SupportTextContextFailure.limited);
    }
    final rows = await db.customSelect('''
      $_entries
      SELECT native_order, message_id,
        CASE WHEN json_type(o, '\$.role') = 'text' AND json_extract(o, '\$.role') IN ('user', 'assistant', 'system')
          THEN json_extract(o, '\$.role') END AS role,
        json_type(o, '\$.content') AS body_type,
        CASE WHEN json_type(o, '\$.content') = 'text'
          AND length(json_extract(o, '\$.content')) <= ${SupportTextContextRepo.maxTextChars}
          AND length(CAST(json_extract(o, '\$.content') AS BLOB)) <= ${SupportTextContextRepo.maxTextBytes}
          THEN json_extract(o, '\$.content') END AS body,
        CASE WHEN json_type(o, '\$.swipeId') = 'integer' THEN json_extract(o, '\$.swipeId') END AS swipe_id,
        json_type(o, '\$.swipeId') AS swipe_type,
        CASE WHEN json_type(o, '\$.agentSwipeId') = 'integer' THEN json_extract(o, '\$.agentSwipeId') END AS agent_swipe_id,
        json_type(o, '\$.agentSwipeId') AS agent_swipe_type,
        CASE WHEN json_type(o, '\$.timestamp') = 'integer' THEN json_extract(o, '\$.timestamp') END AS timestamp,
        json_type(o, '\$.timestamp') AS timestamp_type,
        json_type(o, '\$.isHidden') AS hidden_type,
        json_type(o, '\$.isError') AS error_type,
        json_type(o, '\$.isTyping') AS typing_type,
        json_type(o, '\$.isEditing') AS editing_type,
        json_type(o, '\$.isLocked') AS locked_type,
        json_type(o, '\$.isAllReasoning') AS all_reasoning_type,
        json_type(o, '\$.status') AS status_type,
        CASE WHEN json_type(o, '\$.swipes') = 'array' THEN json_array_length(o, '\$.swipes') END AS swipe_count,
        CASE WHEN json_type(o, '\$.agentSwipes') = 'array' THEN json_array_length(o, '\$.agentSwipes') END AS agent_swipe_count,
        CASE WHEN json_extract(o, '\$.role') != 'assistant' THEN 1
          WHEN COALESCE(json_type(o, '\$.swipeId'), 'null') NOT IN ('null', 'integer') OR
               COALESCE(json_type(o, '\$.agentSwipeId'), 'null') NOT IN ('null', 'integer') THEN 0
          WHEN COALESCE(json_type(o, '\$.swipes'), 'null') NOT IN ('null', 'array') OR
               COALESCE(json_type(o, '\$.agentSwipes'), 'null') NOT IN ('null', 'array') THEN 0
          WHEN COALESCE(json_array_length(o, '\$.swipes'), 0) > ${SupportTextContextRepo.maxSourceMessages} OR
               COALESCE(json_array_length(o, '\$.agentSwipes'), 0) > ${SupportTextContextRepo.maxSourceMessages} THEN 0
          WHEN COALESCE(json_array_length(o, '\$.swipes'), 0) = 0 AND COALESCE(json_extract(o, '\$.swipeId'), 0) != 0 THEN 0
          WHEN COALESCE(json_array_length(o, '\$.swipes'), 0) > 0 AND
            (COALESCE(json_extract(o, '\$.swipeId'), 0) < 0 OR
             COALESCE(json_extract(o, '\$.swipeId'), 0) >= json_array_length(o, '\$.swipes')) THEN 0
          WHEN COALESCE(json_array_length(o, '\$.swipes'), 0) > 0 AND
            json_type(o, '\$.swipes[' || COALESCE(json_extract(o, '\$.swipeId'), 0) || ']') != 'text' THEN 0
          WHEN COALESCE(json_array_length(o, '\$.agentSwipes'), 0) = 0 AND
            COALESCE(json_extract(o, '\$.agentSwipeId'), 0) != 0 THEN 0
          WHEN COALESCE(json_array_length(o, '\$.agentSwipes'), 0) > 0 AND
            (COALESCE(json_extract(o, '\$.agentSwipeId'), 0) < 0 OR
             COALESCE(json_extract(o, '\$.agentSwipeId'), 0) >= json_array_length(o, '\$.agentSwipes')) THEN 0
          WHEN COALESCE(json_array_length(o, '\$.agentSwipes'), 0) > 0 THEN
            CASE WHEN json_type(o, '\$.agentSwipes[' || COALESCE(json_extract(o, '\$.agentSwipeId'), 0) || '].content') = 'text'
              AND json_extract(o, '\$.agentSwipes[' || COALESCE(json_extract(o, '\$.agentSwipeId'), 0) || '].content') = json_extract(o, '\$.content')
              THEN 1 ELSE 0 END
          WHEN COALESCE(json_array_length(o, '\$.swipes'), 0) > 0 THEN
            CASE WHEN json_extract(o, '\$.swipes[' || COALESCE(json_extract(o, '\$.swipeId'), 0) || ']') = json_extract(o, '\$.content')
              THEN 1 ELSE 0 END
          ELSE 1 END AS variation_valid,
        CASE WHEN
          COALESCE(json_type(o, '\$.isHidden'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isError'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isTyping'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isEditing'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isLocked'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isAllReasoning'), 'null') IN ('false', 'null') AND
          (COALESCE(json_type(o, '\$.status'), 'null') = 'null' OR
            (json_type(o, '\$.status') = 'text' AND json_extract(o, '\$.status') = 'complete')) AND
          (COALESCE(json_type(o, '\$.swipeId'), 'null') = 'null' OR
            (json_type(o, '\$.swipeId') = 'integer' AND json_extract(o, '\$.swipeId') BETWEEN 0 AND 1000000)) AND
          (COALESCE(json_type(o, '\$.agentSwipeId'), 'null') = 'null' OR
            (json_type(o, '\$.agentSwipeId') = 'integer' AND json_extract(o, '\$.agentSwipeId') BETWEEN 0 AND 1000000)) AND
          (COALESCE(json_type(o, '\$.timestamp'), 'null') = 'null' OR
            (json_type(o, '\$.timestamp') = 'integer' AND json_extract(o, '\$.timestamp') BETWEEN 0 AND 8640000000000000)) AND
          (SELECT COUNT(*) = COUNT(DISTINCT key) FROM json_each(o)
            WHERE key IN ('id', 'role', 'content', 'isHidden', 'isError', 'isTyping', 'isEditing',
              'isLocked', 'isAllReasoning', 'status', 'swipeId', 'agentSwipeId', 'timestamp', 'swipes', 'agentSwipes'))
          THEN 1 ELSE 0 END AS eligible
      FROM identified WHERE message_id IN ($slots)
      ORDER BY native_order ASC LIMIT ${SupportTextContextRepo.maxSelections + 1}
    ''', variables: variables).get();
    checkpoint?.call();
    if (rows.length != ids.length) _fail(SupportTextContextFailure.unavailable);
    final bodies = <_RawTextBody>[];
    var chars = 0;
    var bytes = 0;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final role = row.readNullable<String>('role');
      if (row.read<String>('message_id') != ids[i] ||
          !const ['user', 'assistant', 'system'].contains(role) ||
          row.read<int>('eligible') != 1 ||
          row.read<int>('variation_valid') != 1 ||
          row.readNullable<String>('body_type') != 'text') {
        _fail(SupportTextContextFailure.unavailable);
      }
      final body = row.readNullable<String>('body');
      if (body == null) _fail(SupportTextContextFailure.limited);
      chars += body.length;
      bytes += _textBytes(body);
      if (chars > SupportTextContextRepo.maxTextChars ||
          bytes > SupportTextContextRepo.maxTextBytes) {
        _fail(SupportTextContextFailure.limited);
      }
      bodies.add(_RawTextBody(role!, body));
    }
    return _TextRead(header, rows, bodies);
  }
}
