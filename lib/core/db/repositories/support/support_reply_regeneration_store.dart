part of '../support_repo.dart';

/// Original database observation, not reconstructible from restored DTOs. Raw
/// encrypted expectations catch target/provenance ABA between read and claim.
final class SupportReplyRegenerationObservation {
  SupportReplyRegenerationObservation._(
    this._db,
    this._parent,
    this._row,
    this._context,
    this.message,
    this.provenance,
  );
  final AppDatabase _db;
  final SupportSessionRow _parent;
  final SupportMessageRow _row;
  final SupportContextBlockRow _context;
  final SupportMessage message;
  final SupportContextBlock provenance;
  @override
  String toString() => 'SupportReplyRegenerationObservation';
}

/// Explicit in-place LAST terminal reply replacement. All observations and
/// writes are exact-row guarded; the user and ordering metadata never change.
extension _SupportReplyRegenerationStore on _SupportGuardedReplyStore {
  bool _regenerationBlock(SupportContextBlock block, SupportMessage reply) =>
      block.id == _provenanceId(reply.id) &&
      block.sessionId == reply.sessionId &&
      block.startMessageId == reply.id &&
      block.endMessageId == reply.id &&
      block.createdAt == reply.createdAt &&
      !block.isActive &&
      !block.isLocked &&
      block.summary.isEmpty &&
      _text(block.protectedFactsJson) &&
      block.protectedFactsJson.trim().isNotEmpty;

  Future<void> _lastReply(SupportMessage reply, bool Function() current) async {
    _require(
      _reply(reply) &&
          _SupportGuardedReplyStore._terminal.contains(reply.status),
    );
    await _replyTail(reply, current);
  }

  Future<void> _replyTail(SupportMessage reply, bool Function() current) async {
    // Metadata only: ties are deliberately refused, not guessed into an order.
    final other = await _checked(
      db
          .customSelect(
            'SELECT 1 AS later FROM support_messages WHERE session_id = ? AND id != ? '
            'AND (typeof(created_at) != \'integer\' OR created_at >= ?) LIMIT 1',
            variables: [
              Variable<String>(reply.sessionId),
              Variable<String>(reply.id),
              Variable<int>(reply.createdAt),
            ],
            readsFrom: {db.supportMessages},
          )
          .get(),
      current,
    );
    _require(other.isEmpty);
  }

  Future<SupportReplyRegenerationObservation?> readForRegeneration(
    SupportMessage reply,
    bool Function() current,
  ) => _transaction(current, () async {
    await _lastReply(reply, current);
    final parent = await _parent(reply.sessionId, current);
    final row = await _checked(messages.row(reply.id), current);
    final context = await _checked(
      _contextRow(_provenanceId(reply.id)),
      current,
    );
    _require(
      row != null && context != null && row.sessionId == reply.sessionId,
    );
    _require(await _message(row!, current) == reply);
    final block = await _provenance(context!, current);
    _require(_regenerationBlock(block, reply));
    await _unchanged(parent, reply.id, block.id, row, context, current);
    return SupportReplyRegenerationObservation._(
      db,
      parent,
      row,
      context,
      reply,
      block,
    );
  });

  Future<bool> validateRegenerationPosition(
    SupportMessage reply,
    bool Function() current,
  ) async =>
      await _transaction(current, () async {
        _require(_reply(reply));
        await _replyTail(reply, current);
        final row = await _checked(messages.row(reply.id), current);
        _require(
          row != null &&
              row.sessionId == reply.sessionId &&
              row.createdAt == reply.createdAt &&
              row.runId == reply.runId &&
              row.role == reply.role &&
              row.status == reply.status,
        );
        return true;
      }) ??
      false;

  /// The caller derives this ID from validated dedicated provenance. A moved
  /// origin is refused by SQL BEFORE fetching or decrypting its foreign body.
  Future<SupportMessage?> readOrigin(
    String sessionId,
    String id,
    bool Function() current,
  ) => _transaction(current, () async {
    _require(
      messages.nativeInput.identifier(id) &&
          messages.nativeInput.identifier(sessionId),
    );
    await _parent(sessionId, current);
    final row = await _checked(
      (db.select(db.supportMessages)..where(
            (t) =>
                t.id.equals(id) &
                t.sessionId.equals(sessionId) &
                t.role.equals('user') &
                t.status.equals('complete') &
                t.runId.isNotNull() &
                t.cardsCiphertext.equals(''),
          ))
          .getSingleOrNull(),
      current,
    );
    _require(row != null);
    final user = await _message(row!, current);
    _require(messages.nativeInput.user(user));
    return user;
  });

  Future<SupportReplyReservation?> regenerate(
    SupportReplyRegenerationObservation expected,
    SupportMessage user,
    String attempt,
    String facts,
    bool Function() current,
  ) => _transaction(current, () async {
    final reply = expected.message, block = expected.provenance;
    _require(identical(expected._db, db));
    _require(
      _regenerationBlock(block, reply) &&
          _identifier(attempt) &&
          attempt != reply.runId &&
          attempt != user.runId &&
          _text(facts) &&
          facts.trim().isNotEmpty,
    );
    await _lastReply(reply, current);
    _require(
      user.sessionId == reply.sessionId && user.createdAt < reply.createdAt,
    );
    final parent = await _parent(reply.sessionId, current);
    final origin = await messages.nativeInput.matchUser(user, current);
    final row = await _checked(messages.row(reply.id), current);
    final context = await _checked(_contextRow(block.id), current);
    _require(
      row != null && context != null && row.sessionId == reply.sessionId,
    );
    _require(
      parent == expected._parent &&
          row == expected._row &&
          context == expected._context,
    );
    _require(await _message(row!, current) == reply);
    _require(await _provenance(context!, current) == block);
    final next = reply.copyWith(body: '', runId: attempt, status: 'preparing');
    final nextBlock = block.copyWith(protectedFactsJson: facts);
    final body = await _checked(
      cipher.encrypt(
        plaintext: '',
        table: 'support_messages',
        rowId: reply.id,
        sessionId: reply.sessionId,
        field: 'body_ciphertext',
      ),
      current,
    );
    final encryptedFacts = await _checked(
      cipher.encrypt(
        plaintext: facts,
        table: 'support_context_blocks',
        rowId: block.id,
        sessionId: block.sessionId,
        field: 'protected_facts_ciphertext',
      ),
      current,
    );
    await _unchanged(parent, reply.id, block.id, row, context, current);
    _require(
      await _checked(messages.nativeInput.userRow(user), current) == origin,
    );
    await _lastReply(reply, current);
    _require(
      await _checked(
            (db.update(db.supportMessages)..where(
                  (t) =>
                      t.id.equals(reply.id) &
                      t.sessionId.equals(reply.sessionId) &
                      t.runId.equals(reply.runId!) &
                      t.status.equals(reply.status),
                ))
                .write(
                  SupportMessagesCompanion(
                    bodyCiphertext: Value(body),
                    runId: Value(attempt),
                    status: const Value('preparing'),
                  ),
                ),
            current,
          ) ==
          1,
    );
    _require(
      await _checked(
            (db.update(db.supportContextBlocks)..where(
                  (t) =>
                      t.id.equals(block.id) &
                      t.sessionId.equals(block.sessionId),
                ))
                .write(
                  SupportContextBlocksCompanion(
                    protectedFactsCiphertext: Value(encryptedFacts),
                  ),
                ),
            current,
          ) ==
          1,
    );
    final written = await _checked(messages.row(reply.id), current);
    final writtenBlock = await _checked(_contextRow(block.id), current);
    _require(written != null && writtenBlock != null);
    final durable = await _message(written!, current);
    final provenance = await _provenance(writtenBlock!, current);
    _require(durable == next && provenance == nextBlock);
    _require(
      await _checked(messages.nativeInput.userRow(user), current) == origin,
    );
    await _unchanged(
      parent,
      reply.id,
      block.id,
      written,
      writtenBlock,
      current,
    );
    return (message: durable, provenance: provenance);
  });
}
