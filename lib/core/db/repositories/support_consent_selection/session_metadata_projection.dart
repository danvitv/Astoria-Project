part of '../support_consent_selection_repo.dart';

SupportConsentSessionMetadata _unavailableSession(
  SupportConsentSelectionSource source, {
  String? sessionId,
  SupportConsentSelectionStatus status =
      SupportConsentSelectionStatus.unavailable,
}) => SupportConsentSessionMetadata(
  source: source,
  sessionId: sessionId,
  status: status,
);

extension _RoleplaySessionMetadata on _RoleplaySelectionProjection {
  Future<SupportConsentSessionMetadata> sessionMetadata(String? id) async {
    const source = SupportConsentSelectionSource.roleplay;
    try {
      if (!_validIdentity(id, currentRedactor())) {
        return _unavailableSession(source);
      }
      final row = await db
          .customSelect(
            '''
        SELECT ${_RoleplaySelectionProjection._columns},
          s.rowid AS native_identity, c.rowid AS parent_native_identity,
          s.updated_at,
          CASE WHEN typeof(s.session_index) = 'integer' AND
            s.session_index BETWEEN 0 AND 1000000 AND
            typeof(c.variant_order) = 'integer' AND
            c.variant_order BETWEEN 0 AND 1000000 AND
            (c.variant_group_id IS NULL OR typeof(c.variant_group_id) = 'text')
            THEN 1 ELSE 0 END AS readable_identity,
          CASE WHEN typeof(s.messages_json) != 'text' THEN 2
            WHEN length(CAST(s.messages_json AS BLOB)) > 2097152 THEN 1
            WHEN NOT json_valid(s.messages_json) THEN 2
            WHEN json_type(s.messages_json) != 'array' THEN 2
            WHEN json_array_length(s.messages_json) > 2000 THEN 1
            ELSE 0 END AS readable_source
        FROM chat_sessions s INNER JOIN characters c ON c.char_id = s.character_id
        WHERE s.session_id = ? AND typeof(s.character_id) = 'text'
          AND typeof(c.hidden) = 'integer' AND c.hidden = 0 LIMIT 1
      ''',
            variables: [Variable.withString(id!)],
          )
          .getSingleOrNull();
      if (row == null || row.read<int>('readable_identity') != 1) {
        return _unavailableSession(source);
      }
      final option = _option(row, currentRedactor());
      final status = row.read<int>('readable_source');
      if (option == null || option.sessionId != id || status != 0) {
        return _unavailableSession(
          source,
          sessionId: id,
          status: status == 1
              ? SupportConsentSelectionStatus.limited
              : SupportConsentSelectionStatus.unavailable,
        );
      }
      return SupportConsentSessionMetadata(
        source: source,
        sessionId: id,
        status: SupportConsentSelectionStatus.available,
        roleplaySession: option,
        nativeIdentity: row.read<int>('native_identity'),
        parentNativeIdentity: row.read<int>('parent_native_identity'),
        updatedAt: row.read<int>('updated_at'),
        messageCount: option.messageCount,
      );
    } catch (_) {
      return _unavailableSession(source);
    }
  }
}

extension _SupportSessionMetadata on _SupportSelectionProjection {
  Future<SupportConsentSessionMetadata> sessionMetadata(String? id) async {
    const source = SupportConsentSelectionSource.support;
    try {
      if (!_validIdentity(id, currentRedactor())) {
        return _unavailableSession(source);
      }
      return await db.transaction(() async {
        // Existing exact parent-title AEAD check only; no body decrypt or
        // provider credential reader. Its private title/config never escapes.
        final parent = await supportRepo.getSessionById(id!);
        if (parent == null || parent.id != id) {
          return _unavailableSession(source);
        }
        if (parent.isLocked) {
          return _unavailableSession(
            source,
            sessionId: id,
            status: SupportConsentSelectionStatus.parentLocked,
          );
        }
        final row = await db
            .customSelect(
              '''
          SELECT rowid AS native_identity, created_at, updated_at,
            length(title_ciphertext) AS title_size,
            (SELECT COUNT(*) FROM support_messages WHERE session_id = ?) AS n
          FROM support_sessions WHERE id = ? LIMIT 1
        ''',
              variables: [Variable.withString(id), Variable.withString(id)],
            )
            .getSingleOrNull();
        if (row == null ||
            !_validIdentity(id, currentRedactor()) ||
            row.read<int>('title_size') >
                SupportConsentSelectionRepo.maxSessionParentEnvelopeChars ||
            row.read<int>('created_at') < 0 ||
            row.read<int>('created_at') > 8640000000000) {
          return _unavailableSession(source);
        }
        if (row.read<int>('n') > 2000) {
          return _unavailableSession(
            source,
            sessionId: id,
            status: SupportConsentSelectionStatus.limited,
          );
        }
        return SupportConsentSessionMetadata(
          source: source,
          sessionId: id,
          status: SupportConsentSelectionStatus.available,
          nativeIdentity: row.read<int>('native_identity'),
          createdAt: row.read<int>('created_at'),
          updatedAt: row.read<int>('updated_at'),
          messageCount: row.read<int>('n'),
        );
      });
    } catch (_) {
      return _unavailableSession(source);
    }
  }
}
