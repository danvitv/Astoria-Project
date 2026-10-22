part of '../support_consent_selection_repo.dart';

final class _SupportSelectionProjection {
  const _SupportSelectionProjection(
    this.db,
    this.supportRepo,
    this.currentRedactor,
  );
  final AppDatabase db;
  final SupportRepo supportRepo;
  final SecretRedactor Function() currentRedactor;

  Future<SupportConsentMessagePage> messages(
    String? sessionId,
    int offset,
    int limit,
  ) async {
    const source = SupportConsentSelectionSource.support;
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
        // The existing parent owner checks only this exact encrypted title. No
        // title/config/model fields escape, and no message bodies are decrypted.
        final parent = await supportRepo.getSessionById(id);
        if (parent == null || parent.id != id) {
          return _unavailableMessages(source);
        }
        if (parent.isLocked) {
          return _unavailableMessages(
            source,
            sessionId: id,
            status: SupportConsentSelectionStatus.parentLocked,
          );
        }
        final countRow = await db
            .customSelect(
              'SELECT COUNT(*) AS n FROM support_messages WHERE session_id = ?',
              variables: [Variable.withString(id)],
            )
            .getSingle();
        final count = countRow.read<int>('n');
        if (count > SupportConsentSelectionRepo.maxSourceMessages) {
          return _unavailableMessages(
            source,
            sessionId: id,
            sourceCount: count,
            status: SupportConsentSelectionStatus.limited,
          );
        }
        final rows = await db
            .customSelect(
              '''
          SELECT CASE WHEN length(id) <= 256 THEN id END AS message_id,
                 CASE WHEN role IN ('user', 'assistant', 'system') THEN role END AS role,
                 CASE WHEN status = 'complete' THEN 1 ELSE 0 END AS eligible,
                 created_at
          FROM support_messages WHERE session_id = ?
          ORDER BY created_at ASC, id ASC
          LIMIT ${SupportConsentSelectionRepo.maxSourceMessages}
        ''',
              variables: [Variable.withString(id)],
            )
            .get();
        if (rows.length != count) return _unavailableMessages(source);
        final redactor = currentRedactor();
        if (!_validIdentity(id, redactor)) return _unavailableMessages(source);
        final eligible = <SupportConsentMessageOption>[];
        for (var i = 0; i < rows.length; i++) {
          final row = rows[i];
          final messageId = row.readNullable<String>('message_id');
          final role = _selectionRole(row.readNullable<String>('role'));
          final createdAt = row.read<int>('created_at');
          if (!_validIdentity(messageId, redactor) ||
              role == null ||
              row.read<int>('eligible') != 1 ||
              createdAt < 0 ||
              createdAt > 8640000000000) {
            continue;
          }
          eligible.add(
            SupportConsentMessageOption(
              sessionId: id,
              messageId: messageId!,
              role: role,
              nativeOrder: i,
              createdAtSeconds: createdAt,
            ),
          );
        }
        return _messagePage(
          source: source,
          sessionId: id,
          eligible: eligible,
          sourceCount: count,
          offset: offset,
          limit: limit,
        );
      });
    } catch (_) {
      return _unavailableMessages(source);
    }
  }
}
