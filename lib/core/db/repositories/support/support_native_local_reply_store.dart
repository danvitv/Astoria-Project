part of '../support_repo.dart';

/// Additive composition only: no changes to the existing model reply guards.
extension _SupportNativeLocalReplyAppend on _SupportMessageStore {
  Future<SupportMessage?> appendNativeLocalReply(
    SupportMessage message,
    SupportMessage originatingUser,
    String provenanceJson,
    bool Function() current,
  ) => replies._transaction(current, () async {
    replies._require(
      message.status == 'complete' &&
          !message.isLocked &&
          message.cardsJson.length <= 65536,
    );
    final reserved = await replies._checked(
      replies.reserve(
        message.copyWith(body: '', cardsJson: '', status: 'preparing'),
        provenanceJson,
        current,
        originatingUser: originatingUser,
      ),
      current,
    );
    replies._require(reserved != null);
    final owned = reserved!;
    final settled = await replies._checked(
      replies.settle(owned, 'complete', message.body, current),
      current,
    );
    replies._require(settled != null);
    final complete = settled!;
    final parent = await replies._checked(
      replies._parent(message.sessionId, current),
      current,
    );
    final row = await replies._checked(this.row(message.id), current);
    final context = await replies._checked(
      replies._contextRow(owned.provenance.id),
      current,
    );
    replies._require(row != null && context != null);
    final storedRow = row!;
    final storedContext = context!;
    replies._require(
      await replies._checked(replies._message(storedRow, current), current) ==
          complete,
    );
    replies._require(
      await replies._checked(
            replies._provenance(storedContext, current),
            current,
          ) ==
          owned.provenance,
    );
    final cards = message.cardsJson.isEmpty
        ? ''
        : await replies._checked(
            cipher.encrypt(
              plaintext: message.cardsJson,
              table: 'support_messages',
              rowId: message.id,
              sessionId: message.sessionId,
              field: 'cards_ciphertext',
            ),
            current,
          );
    await replies._checked(
      replies._unchanged(
        parent,
        message.id,
        owned.provenance.id,
        storedRow,
        storedContext,
        current,
      ),
      current,
    );
    await nativeInput.matchUser(originatingUser, current);
    replies._requireCurrent(current);
    final count = await replies._checked(
      (db.update(db.supportMessages)..where(
            (t) =>
                t.id.equals(message.id) &
                t.sessionId.equals(message.sessionId) &
                t.runId.equals(message.runId!) &
                t.status.equals('complete') &
                t.cardsCiphertext.equals(''),
          ))
          .write(SupportMessagesCompanion(cardsCiphertext: Value(cards))),
      current,
    );
    replies._require(count == 1);
    final written = await replies._checked(this.row(message.id), current);
    replies._require(written != null);
    final nextRow = written!;
    final durable = await replies._checked(mapper.message(nextRow), current);
    replies._require(
      durable == complete.copyWith(cardsJson: message.cardsJson),
    );
    await replies._checked(
      replies._unchanged(
        parent,
        message.id,
        owned.provenance.id,
        nextRow,
        storedContext,
        current,
      ),
      current,
    );
    await nativeInput.matchUser(originatingUser, current);
    replies._requireCurrent(current);
    final updatedAt = math.max(parent.updatedAt, durable.createdAt);
    final parentCount = await replies._checked(
      (db.update(db.supportSessions)
            ..where((t) => t.id.equals(message.sessionId)))
          .write(SupportSessionsCompanion(updatedAt: Value(updatedAt))),
      current,
    );
    replies._require(parentCount == 1);
    await replies._checked(
      replies._unchanged(
        parent.copyWith(updatedAt: updatedAt),
        message.id,
        owned.provenance.id,
        nextRow,
        storedContext,
        current,
      ),
      current,
    );
    await nativeInput.matchUser(originatingUser, current);
    replies._requireCurrent(current);
    return durable;
  });
}
