part of '../support_repo.dart';

/// Opaque original DB/parent/raw-message observation. It is never serialized.
final class SupportUserEditingObservation {
  SupportUserEditingObservation._(
    this._db,
    this._parent,
    this._row,
    this._identities,
    this.message,
  );
  final AppDatabase _db;
  final SupportSessionRow _parent;
  final SupportMessageRow _row;
  final ({int parent, int user}) _identities;
  final SupportMessage message;
  @override
  String toString() => 'SupportUserEditingObservation';
}

extension _SupportUserEditingStore on _SupportGuardedReplyStore {
  bool _editableUser(SupportMessage user) =>
      messages.nativeInput.identifier(user.id) &&
      messages.nativeInput.identifier(user.sessionId) &&
      (user.runId == null || messages.nativeInput.identifier(user.runId)) &&
      user.role == 'user' &&
      const {
        'complete',
        'preparing',
        'pending',
        'stopped',
        'error',
        'limited',
      }.contains(user.status) &&
      !user.isLocked &&
      user.body.length <= 8192 &&
      messages.nativeInput.time(user.createdAt);

  Future<SupportSessionRow> _userParent(
    String id,
    bool Function() current,
  ) async {
    try {
      return await messages.nativeInput.parent(id, current);
    } on SupportCipherException {
      throw const _SupportReplyRefused();
    }
  }

  /// Dynamic SQLite metadata is validated BEFORE a payload row is mapped. The
  /// same-session, role and exact-status filters also precede body fetching.
  Future<SupportMessageRow> _editingRow(
    SupportMessage user,
    bool Function() current,
  ) async {
    _requireCurrent(current);
    _require(_editableUser(user));
    final invalid = await _checked(
      db
          .customSelect(
            'SELECT 1 AS invalid_user FROM support_messages WHERE id = ? AND ('
            "typeof(created_at) != 'integer' OR created_at < 0 OR created_at > ${_SupportNativeInputStore.maxTime} "
            "OR typeof(role) != 'text' OR typeof(status) != 'text' "
            "OR (run_id IS NOT NULL AND typeof(run_id) != 'text')) LIMIT 1",
            variables: [Variable<String>(user.id)],
            readsFrom: {db.supportMessages},
          )
          .get(),
      current,
    );
    _require(invalid.isEmpty);
    final row = await _checked(
      (db.select(db.supportMessages)..where(
            (t) =>
                t.id.equals(user.id) &
                t.sessionId.equals(user.sessionId) &
                t.role.equals('user') &
                t.status.equals(user.status) &
                t.createdAt.equals(user.createdAt) &
                (user.runId == null
                    ? t.runId.isNull()
                    : t.runId.equals(user.runId!)),
          ))
          .getSingleOrNull(),
      current,
    );
    _require(row != null);
    return row!;
  }

  Future<void> _sameUserObservation(
    SupportUserEditingObservation expected,
    bool Function() current, {
    SupportMessageRow? written,
  }) async {
    _requireCurrent(current);
    _require(identical(expected._db, db));
    _require(
      await _checked(sessions.row(expected.message.sessionId), current) ==
          expected._parent,
    );
    _require(
      await _editingRow(expected.message, current) ==
          (written ?? expected._row),
    );
    _require(
      await _userIdentities(expected.message, current) == expected._identities,
    );
    _requireCurrent(current);
  }

  Future<({int parent, int user})> _userIdentities(
    SupportMessage user,
    bool Function() current,
  ) async {
    _requireCurrent(current);
    final row = await _checked(
      db
          .customSelect(
            'SELECT s.rowid AS parent_identity, m.rowid AS user_identity '
            'FROM support_sessions s JOIN support_messages m ON m.session_id = s.id '
            'WHERE s.id = ? AND m.id = ? LIMIT 1',
            variables: [
              Variable<String>(user.sessionId),
              Variable<String>(user.id),
            ],
            readsFrom: {db.supportSessions, db.supportMessages},
          )
          .getSingleOrNull(),
      current,
    );
    _require(row != null);
    final identities = row!;
    return (
      parent: identities.read<int>('parent_identity'),
      user: identities.read<int>('user_identity'),
    );
  }

  Future<SupportUserEditingObservation?> readUserForEditing(
    SupportMessage user,
    bool Function() current,
  ) => _transaction(current, () async {
    _require(_editableUser(user));
    final row = await _editingRow(user, current);
    final parent = await _userParent(user.sessionId, current);
    final identities = await _userIdentities(user, current);
    _requireCurrent(current);
    final durable = await _checked(mapper.message(row), current);
    // The UI's empty cards projection has two existing storage spellings.
    // Retain the actual raw row; this does not normalize or rewrite ciphertext.
    final emptyCards = const {'', '[]'};
    final same =
        durable == user ||
        (emptyCards.contains(durable.cardsJson) &&
            emptyCards.contains(user.cardsJson) &&
            durable == user.copyWith(cardsJson: durable.cardsJson));
    _require(!durable.isLocked && same);
    await _requireUnlinkedUser(durable, current);
    final observation = SupportUserEditingObservation._(
      db,
      parent,
      row,
      identities,
      durable,
    );
    await _sameUserObservation(observation, current);
    _requireCurrent(current);
    return observation;
  });

  Future<SupportMessage?> editUserMessage(
    SupportUserEditingObservation expected,
    String body,
    bool Function() current,
  ) => _transaction(current, () async {
    _require(body.trim().isNotEmpty && body.length <= 8192);
    _require(utf8.decode(utf8.encode(body)) == body);
    await _sameUserObservation(expected, current);
    _requireCurrent(current);
    final durable = await _checked(mapper.message(expected._row), current);
    _require(!durable.isLocked && durable == expected.message);
    await _userParent(durable.sessionId, current);
    await _requireUnlinkedUser(durable, current);
    _requireCurrent(current);
    final encrypted = await _checked(
      cipher.encrypt(
        plaintext: body,
        table: 'support_messages',
        rowId: durable.id,
        sessionId: durable.sessionId,
        field: 'body_ciphertext',
      ),
      current,
    );
    await _sameUserObservation(expected, current);
    _require(
      await _checked(
            (db.update(db.supportMessages)..where(
                  (t) =>
                      t.id.equals(durable.id) &
                      t.sessionId.equals(durable.sessionId) &
                      t.bodyCiphertext.equals(expected._row.bodyCiphertext),
                ))
                .write(
                  SupportMessagesCompanion(bodyCiphertext: Value(encrypted)),
                ),
            current,
          ) ==
          1,
    );
    final written = await _editingRow(durable, current);
    _require(written == expected._row.copyWith(bodyCiphertext: encrypted));
    final next = await _checked(mapper.message(written), current);
    _require(!next.isLocked && next == durable.copyWith(body: body));
    await _sameUserObservation(expected, current, written: written);
    await _requireUnlinkedUser(durable, current);
    _requireCurrent(current);
    // Existing model dependencies/checkpoints were refused before editing;
    // their old provenance is neither rewritten nor falsely rebound.
    return next;
  });

  Future<void> _requireUnlinkedUser(
    SupportMessage user,
    bool Function() current,
  ) async {
    final linked = await _checked(
      db
          .customSelect(
            "SELECT 1 AS linked FROM support_messages WHERE session_id = ? "
            "AND role = 'assistant' AND run_id IS NOT NULL AND created_at >= ? "
            'UNION ALL SELECT 1 FROM support_context_blocks c '
            'LEFT JOIN support_messages m ON m.id = c.end_message_id AND m.session_id = c.session_id '
            'WHERE c.session_id = ? AND '
            "((c.is_active = 1 AND (c.start_message_id != '' OR c.end_message_id != '')) "
            "OR c.id LIKE 'support.reply_provenance:%') "
            'AND (m.id IS NULL OR m.created_at >= ?) LIMIT 1',
            variables: [
              Variable<String>(user.sessionId),
              Variable<int>(user.createdAt),
              Variable<String>(user.sessionId),
              Variable<int>(user.createdAt),
            ],
            readsFrom: {db.supportMessages, db.supportContextBlocks},
          )
          .get(),
      current,
    );
    _require(linked.isEmpty);
  }
}
