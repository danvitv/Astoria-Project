part of '../support_source_text_repo.dart';

extension _SourceGameReader on SupportSourceTextRepo {
  // Same guarded SQLite metadata discovery as the strict text-context reader.
  // Neither CASE nor json_each projects any body before exact native authority.
  static const _bounded = '''CASE WHEN typeof(messages_json) != 'text' THEN '[]'
    WHEN length(CAST(messages_json AS BLOB)) > 2097152 THEN '[]'
    WHEN NOT json_valid(messages_json) THEN '[]'
    WHEN json_type(messages_json) != 'array' THEN '[]'
    WHEN json_array_length(messages_json) > 2000 THEN '[]'
    ELSE messages_json END''';
  static const _entries =
      '''WITH target AS (
    SELECT $_bounded AS j FROM chat_sessions WHERE session_id = ? LIMIT 1
  ), entries AS (
    SELECT e.key AS native_order, CASE WHEN e.type = 'object' THEN e.value ELSE '{}' END AS o
    FROM target, json_each(target.j) e
  ), identified AS (
    SELECT native_order, o,
      CASE WHEN json_type(o, '\$.id') = 'text' AND length(json_extract(o, '\$.id')) <= 128
        THEN json_extract(o, '\$.id') END AS message_id FROM entries
  )''';

  Future<List<Map<String, Object?>>> _discoverGame(
    String id,
    void Function() guard,
  ) async {
    guard();
    final shape = await _db
        .customSelect(
          '''SELECT CASE
      WHEN typeof(messages_json) != 'text' THEN 0
      WHEN length(CAST(messages_json AS BLOB)) > 2097152 THEN 0
      WHEN NOT json_valid(messages_json) THEN 0
      WHEN json_type(messages_json) != 'array' THEN 0
      WHEN json_array_length(messages_json) > 2000 THEN 0 ELSE 1 END AS valid
      FROM chat_sessions WHERE session_id = ? LIMIT 1''',
          variables: [Variable.withString(id)],
        )
        .getSingleOrNull();
    guard();
    if (shape == null || shape.read<int>('valid') != 1) _deny();
    final rows = await _db
        .customSelect(
          '''$_entries
      SELECT native_order, message_id,
      CASE WHEN json_type(o, '\$.content') = 'text' THEN length(json_extract(o, '\$.content')) END AS chars,
      CASE WHEN json_type(o, '\$.content') = 'text' THEN length(CAST(json_extract(o, '\$.content') AS BLOB)) END AS bytes,
      CASE WHEN message_id IS NOT NULL AND length(message_id) > 0 AND
        json_type(o, '\$.role') = 'text' AND json_extract(o, '\$.role') IN ('user','assistant','system') AND
        json_type(o, '\$.content') = 'text' AND
        COALESCE(json_type(o, '\$.isHidden'), 'null') IN ('true','false','null') AND
        COALESCE(json_type(o, '\$.isError'), 'null') IN ('true','false','null') AND
        COALESCE(json_type(o, '\$.isTyping'), 'null') IN ('true','false','null') AND
        COALESCE(json_type(o, '\$.isEditing'), 'null') IN ('true','false','null') AND
        COALESCE(json_type(o, '\$.isLocked'), 'null') IN ('true','false','null') AND
        COALESCE(json_type(o, '\$.isAllReasoning'), 'null') IN ('true','false','null') AND
        COALESCE(json_type(o, '\$.status'), 'null') IN ('text','null') AND
        (COALESCE(json_type(o, '\$.swipeId'), 'null') = 'null' OR
          (json_type(o, '\$.swipeId') = 'integer' AND json_extract(o, '\$.swipeId') BETWEEN 0 AND 1000000)) AND
        (COALESCE(json_type(o, '\$.agentSwipeId'), 'null') = 'null' OR
          (json_type(o, '\$.agentSwipeId') = 'integer' AND json_extract(o, '\$.agentSwipeId') BETWEEN 0 AND 1000000)) AND
        (COALESCE(json_type(o, '\$.timestamp'), 'null') = 'null' OR
          (json_type(o, '\$.timestamp') = 'integer' AND json_extract(o, '\$.timestamp') BETWEEN 0 AND 8640000000000000)) AND
        COALESCE(json_type(o, '\$.swipes'), 'null') IN ('array','null') AND
        COALESCE(json_type(o, '\$.agentSwipes'), 'null') IN ('array','null') AND
        (SELECT COUNT(*) = COUNT(DISTINCT key) FROM json_each(o)
          WHERE key IN ('id','role','content','isHidden','isError','isTyping','isEditing','isLocked',
            'isAllReasoning','status','swipeId','agentSwipeId','timestamp','swipes','agentSwipes'))
        THEN 1 ELSE 0 END AS shape_valid,
      CASE WHEN COALESCE(json_type(o, '\$.isHidden'), 'null') IN ('false','null') AND
        COALESCE(json_type(o, '\$.isError'), 'null') IN ('false','null') AND
        COALESCE(json_type(o, '\$.isTyping'), 'null') IN ('false','null') AND
        COALESCE(json_type(o, '\$.isEditing'), 'null') IN ('false','null') AND
        COALESCE(json_type(o, '\$.isLocked'), 'null') IN ('false','null') AND
        COALESCE(json_type(o, '\$.isAllReasoning'), 'null') IN ('false','null') AND
        (COALESCE(json_type(o, '\$.status'), 'null') = 'null' OR
          (json_type(o, '\$.status') = 'text' AND json_extract(o, '\$.status') = 'complete'))
        THEN 1 ELSE 0 END AS visible
      FROM identified ORDER BY native_order ASC LIMIT 2001''',
          variables: [Variable.withString(id)],
        )
        .get();
    guard();
    if (rows.length > 2000) _deny();
    final seen = <String>{};
    final result = <Map<String, Object?>>[];
    for (final row in rows) {
      final map = row.data;
      if (map['shape_valid'] != 1 ||
          !_identity(map['message_id']) ||
          !seen.add(map['message_id'] as String) ||
          map['chars'] is! int ||
          map['bytes'] is! int)
        _deny();
      result.add(Map.unmodifiable(map));
    }
    return List.unmodifiable(result);
  }

  Future<SupportSourceSnapshot> _game(
    SupportSourceObservation observation,
    void Function() guard,
  ) async {
    final discovery = await _discoverGame(observation.sourceId, guard);
    guard();
    if (!_equal(discovery, observation._discovery)) _deny();
    // Reuse the existing strict variation/eligibility reader. No tolerant
    // ChatMessage JSON codec, hidden variants, raw prompts or attachments.
    final strict = await _text.loadRoleplayForNativeSource(
      sessionId: observation.sourceId,
      messageIds: observation.orderedSourceIds,
      checkpoint: guard,
    );
    guard();
    final slots = List.filled(
      observation.orderedSourceIds.length,
      '?',
    ).join(',');
    // Raw ACTIVE body primitives only, after strict admission. Needed for a
    // PRIVATE exact material hash (redaction must not hide a source mutation).
    final raw = await _db
        .customSelect(
          '''$_entries SELECT native_order, message_id,
        json_extract(o, '\$.role') AS role,
        CASE WHEN json_type(o, '\$.content') = 'text' AND length(json_extract(o, '\$.content')) <= 65536 AND
          length(CAST(json_extract(o, '\$.content') AS BLOB)) <= 65536 THEN json_extract(o, '\$.content') END AS body,
        json_extract(o, '\$.timestamp') AS timestamp,
        json_extract(o, '\$.swipeId') AS swipe_id, json_extract(o, '\$.agentSwipeId') AS agent_swipe_id
      FROM identified WHERE message_id IN ($slots) ORDER BY native_order ASC''',
          variables: [
            Variable.withString(observation.sourceId),
            ...observation.orderedSourceIds.map(Variable.withString),
          ],
        )
        .get();
    guard();
    if (raw.length != strict.messages.length) _deny();
    var chars = 0, bytes = 0;
    for (var i = 0; i < raw.length; i++) {
      final body = raw[i].readNullable<String>('body');
      if (body == null ||
          raw[i].read<String>('message_id') !=
              observation.orderedSourceIds[i] ||
          raw[i].read<String>('role') != strict.messages[i].role ||
          _currentRedactor()
                  .withKnownSecrets(
                    const [],
                    maxInputLength: 65536,
                    maxOutputLength: 65536,
                  )
                  .redactText(body) !=
              strict.messages[i].text)
        _deny();
      // Strict scalar validation also refuses lone-surrogate active text.
      SupportSourceJson.decode(jsonEncode(body));
      chars += body.runes.length;
      bytes += utf8.encode(body).length;
    }
    if (chars != observation.textCharacters || bytes != observation.textBytes)
      _deny();
    return _snapshot(
      observation,
      [
        observation._header,
        discovery,
        [for (final row in raw) row.data],
      ],
      {
        'domain': 'game',
        'sourceId': observation.sourceId,
        'extent': {
          'orderedSourceIds': observation.orderedSourceIds,
          'activeMessageOffset': observation.activeMessageOffset,
          'totalActiveMessages': observation.totalActiveMessages,
        },
        'messages': [
          for (var i = 0; i < strict.messages.length; i++)
            {
              'id': observation.orderedSourceIds[i],
              'role': strict.messages[i].role,
              'text': strict.messages[i].text,
            },
        ],
      },
    );
  }
}
