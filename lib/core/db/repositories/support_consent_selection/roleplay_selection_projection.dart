part of '../support_consent_selection_repo.dart';

final class _RoleplaySelectionProjection {
  const _RoleplaySelectionProjection(this.db, this.currentRedactor);
  final AppDatabase db;
  final SecretRedactor Function() currentRedactor;

  // CASE is lazy in SQLite: length, validity and array shape are checked before
  // array length/enumeration. No private session names/vars/preview are read.
  static const _columns =
      '''
    CASE WHEN length(s.session_id) <= 256 THEN s.session_id END AS session_id,
    CASE WHEN length(s.character_id) <= 256 THEN s.character_id END AS character_id,
    s.session_index,
    CASE WHEN c.variant_group_id IS NULL OR length(c.variant_group_id) <= 256 THEN 1 ELSE 0 END AS identity_valid,
    CASE WHEN length(c.name) <= 256 THEN c.name END AS character_label,
    CASE WHEN length(c.variant_name) <= 256 THEN c.variant_name END AS variant_label,
    CASE WHEN length(c.variant_group_id) <= 256 THEN c.variant_group_id END AS variant_group_id,
    c.variant_order,
    CASE WHEN payload.payload_characters > ${SupportConsentSelectionRepo.maxRoleplaySourceChars} THEN 1
         WHEN payload.integrity_ok != 1 THEN 2
         WHEN payload.message_count > ${SupportConsentSelectionRepo.maxSourceMessages} THEN 1
         ELSE 0 END AS source_status,
    CASE WHEN payload.payload_characters > ${SupportConsentSelectionRepo.maxRoleplaySourceChars} THEN NULL
         WHEN payload.integrity_ok != 1 THEN NULL
         ELSE payload.message_count END AS message_count
  ''';
  static const _visible = '(c.char_id IS NULL OR c.hidden = 0)';

  SupportConsentSessionOption? _option(QueryRow row, SecretRedactor redactor) {
    final id = row.readNullable<String>('session_id');
    final characterId = row.readNullable<String>('character_id');
    final index = row.read<int>('session_index');
    final group = row.readNullable<String>('variant_group_id');
    final order = row.readNullable<int>('variant_order');
    if (row.read<int>('identity_valid') != 1 ||
        !_validIdentity(id, redactor) ||
        !_validIdentity(characterId, redactor) ||
        index < 0 ||
        index > 1000000 ||
        (group != null &&
            group.isNotEmpty &&
            !_validIdentity(group, redactor)) ||
        (order != null && (order < 0 || order > 1000000))) {
      return null;
    }
    return SupportConsentSessionOption(
      sessionId: id!,
      characterId: characterId!,
      sessionIndex: index,
      variantGroupId: group,
      variantOrder: order,
      characterLabel: _safeLabel(
        row.readNullable<String>('character_label'),
        'Character',
        redactor,
      ),
      variantLabel: _safeLabel(
        row.readNullable<String>('variant_label'),
        'Variant',
        redactor,
      ),
      messageCount: row.readNullable<int>('message_count'),
      status: switch (row.read<int>('source_status')) {
        0 => SupportConsentSelectionStatus.available,
        1 => SupportConsentSelectionStatus.limited,
        _ => SupportConsentSelectionStatus.unavailable,
      },
    );
  }

  Future<SupportConsentMessagePage> messages(
    String? sessionId,
    int offset,
    int limit,
  ) async {
    const source = SupportConsentSelectionSource.roleplay;
    if (!_validPage(
      offset,
      limit,
      SupportConsentSelectionRepo.maxMessagePageSize,
    )) {
      return _unavailableMessages(source);
    }
    try {
      if (!_validIdentity(sessionId, currentRedactor())) {
        return _unavailableMessages(source);
      }
      final id = sessionId!;
      return await db.transaction(() async {
        final header = await db
            .customSelect(
              '''
          WITH ${ChatMessageStorageSql.targetPayloadCte('?')}
          SELECT $_columns FROM chat_sessions s
          INNER JOIN chat_message_payloads payload ON payload.session_id=s.session_id
          LEFT JOIN characters c ON c.char_id = s.character_id
          WHERE $_visible LIMIT 1
        ''',
              variables: [Variable.withString(id)],
            )
            .getSingleOrNull();
        if (header == null) return _unavailableMessages(source);
        final option = _option(header, currentRedactor());
        if (option == null) return _unavailableMessages(source);
        if (option.status != SupportConsentSelectionStatus.available) {
          return _unavailableMessages(
            source,
            sessionId: id,
            status: option.status,
            sourceCount: option.messageCount,
            roleplaySession: option,
          );
        }
        final rows = await db
            .customSelect(_messageSql, variables: [Variable.withString(id)])
            .get();
        if (rows.length != option.messageCount) {
          return _unavailableMessages(source);
        }
        final redactor = currentRedactor();
        // Redact again after all asynchronous reads; never reuse stale labels.
        final currentOption = _option(header, redactor);
        if (currentOption == null) return _unavailableMessages(source);
        final duplicates = <String, int>{};
        for (final row in rows) {
          final messageId = row.readNullable<String>('message_id');
          if (messageId != null) {
            duplicates.update(messageId, (n) => n + 1, ifAbsent: () => 1);
          }
        }
        final eligible = <SupportConsentMessageOption>[];
        for (final row in rows) {
          final messageId = row.readNullable<String>('message_id');
          final role = _selectionRole(row.readNullable<String>('role'));
          if (!_validIdentity(messageId, redactor) ||
              duplicates[messageId] != 1 ||
              role == null ||
              row.read<int>('eligible') != 1) {
            continue;
          }
          eligible.add(
            SupportConsentMessageOption(
              sessionId: id,
              messageId: messageId!,
              role: role,
              nativeOrder: row.read<int>('native_order'),
              swipeId: role == SupportConsentSelectionRole.assistant
                  ? row.read<int>('swipe_id')
                  : null,
              agentSwipeId: role == SupportConsentSelectionRole.assistant
                  ? row.read<int>('agent_swipe_id')
                  : null,
              timestampMs: row.readNullable<int>('timestamp_ms'),
            ),
          );
        }
        return _messagePage(
          source: source,
          sessionId: id,
          eligible: eligible,
          sourceCount: option.messageCount!,
          offset: offset,
          limit: limit,
          roleplaySession: currentOption,
        );
      });
    } catch (_) {
      return _unavailableMessages(source);
    }
  }

  static final String _messageSql =
      '''
    WITH ${ChatMessageStorageSql.targetPayloadCte('?')}, target AS (
      SELECT CASE WHEN payload_characters > ${SupportConsentSelectionRepo.maxRoleplaySourceChars} THEN '[]'
                  WHEN integrity_ok != 1 THEN '[]'
                  WHEN NOT json_valid(messages_json) THEN '[]'
                  WHEN json_type(messages_json) != 'array' THEN '[]'
                  WHEN json_array_length(messages_json) > ${SupportConsentSelectionRepo.maxSourceMessages} THEN '[]'
                  ELSE messages_json END AS bounded_json
       FROM chat_message_payloads LIMIT 1
    ), entries AS (
      SELECT e.key AS native_order, e.type AS entry_type,
             CASE WHEN e.type = 'object' THEN e.value ELSE '{}' END AS o
      FROM target, json_each(target.bounded_json) e
    )
    SELECT native_order,
      CASE WHEN json_type(o, '\$.id') = 'text' AND length(json_extract(o, '\$.id')) <= 256
           THEN json_extract(o, '\$.id') END AS message_id,
      CASE WHEN json_extract(o, '\$.role') IN ('user', 'assistant', 'system')
           THEN json_extract(o, '\$.role') END AS role,
      CASE WHEN json_type(o, '\$.timestamp') = 'integer'
           THEN json_extract(o, '\$.timestamp') END AS timestamp_ms,
      CASE WHEN json_type(o, '\$.swipeId') = 'integer' AND json_extract(o, '\$.swipeId') BETWEEN 0 AND 1000000
           THEN json_extract(o, '\$.swipeId') ELSE 0 END AS swipe_id,
      CASE WHEN json_type(o, '\$.agentSwipeId') = 'integer' AND json_extract(o, '\$.agentSwipeId') BETWEEN 0 AND 1000000
           THEN json_extract(o, '\$.agentSwipeId') ELSE 0 END AS agent_swipe_id,
      CASE WHEN entry_type = 'object'
        AND COALESCE(json_type(o, '\$.isHidden'), 'null') IN ('false', 'null')
        AND COALESCE(json_type(o, '\$.isError'), 'null') IN ('false', 'null')
        AND COALESCE(json_type(o, '\$.isTyping'), 'null') IN ('false', 'null')
        AND (COALESCE(json_type(o, '\$.swipeId'), 'null') = 'null' OR
             (json_type(o, '\$.swipeId') = 'integer' AND json_extract(o, '\$.swipeId') BETWEEN 0 AND 1000000))
        AND (COALESCE(json_type(o, '\$.agentSwipeId'), 'null') = 'null' OR
             (json_type(o, '\$.agentSwipeId') = 'integer' AND json_extract(o, '\$.agentSwipeId') BETWEEN 0 AND 1000000))
        AND (COALESCE(json_type(o, '\$.timestamp'), 'null') = 'null' OR
             (json_type(o, '\$.timestamp') = 'integer' AND json_extract(o, '\$.timestamp') BETWEEN 0 AND 8640000000000000))
        AND (SELECT COUNT(*) = COUNT(DISTINCT key) FROM json_each(o)
             WHERE key IN ('id', 'role', 'isHidden', 'isError', 'isTyping', 'swipeId', 'agentSwipeId', 'timestamp'))
        THEN 1 ELSE 0 END AS eligible
    FROM entries ORDER BY native_order ASC
    LIMIT ${SupportConsentSelectionRepo.maxSourceMessages}
  ''';
}
