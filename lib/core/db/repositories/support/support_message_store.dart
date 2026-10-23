part of '../support_repo.dart';

final class _SupportMessageStore {
  _SupportMessageStore(this.db, this.cipher, this.mapper, this.sessions);
  final AppDatabase db;
  final SupportPayloadCipher cipher;
  final _SupportRowMapper mapper;
  final _SupportSessionStore sessions;
  late final nativeInput = _SupportNativeInputStore(db, mapper, sessions, this);
  late final replies = _SupportGuardedReplyStore(
    db,
    cipher,
    mapper,
    sessions,
    this,
  );
  Future<SupportMessageRow?> row(String id) => (db.select(
    db.supportMessages,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<SupportMessage> put(
    SupportMessage message, {
    bool append = false,
    int? sessionUpdatedAt,
  }) => db.transaction(() async {
    _requireUnlocked(message.isLocked);
    final parent = await sessions.requireParent(message.sessionId);
    final existing = await row(message.id);
    if (existing != null) {
      _requireSameSession(existing.sessionId, message.sessionId);
      _requireUnlocked((await mapper.message(existing)).isLocked);
    }
    await db
        .into(db.supportMessages)
        .insertOnConflictUpdate(await _encrypt(message));
    if (append) {
      await (db.update(
        db.supportSessions,
      )..where((t) => t.id.equals(message.sessionId))).write(
        SupportSessionsCompanion(
          updatedAt: Value(
            sessionUpdatedAt ?? math.max(parent.updatedAt, message.createdAt),
          ),
        ),
      );
    }
    return mapper.message((await row(message.id))!);
  });
  Future<SupportMessage?> mutate(
    String id,
    SupportMessage Function(SupportMessage) mutate,
  ) => db.transaction(() async {
    final existing = await row(id);
    if (existing == null) return null;
    await sessions.requireParent(existing.sessionId);
    final latest = await mapper.message(existing);
    _requireUnlocked(latest.isLocked);
    final candidate = mutate(latest);
    _requireSameSession(existing.sessionId, candidate.sessionId);
    _requireUnlocked(candidate.isLocked);
    final next = candidate.copyWith(
      id: existing.id,
      sessionId: existing.sessionId,
    );
    await (db.update(
      db.supportMessages,
    )..where((t) => t.id.equals(id))).write(await _encrypt(next));
    return mapper.message((await row(id))!);
  });
  Future<SupportMessage?> updateStatus(String id, String status) =>
      db.transaction(() async {
        final existing = await row(id);
        if (existing == null) return null;
        await sessions.requireParent(existing.sessionId, unlocked: false);
        await (db.update(db.supportMessages)..where((t) => t.id.equals(id)))
            .write(SupportMessagesCompanion(status: Value(status)));
        return mapper.message((await row(id))!);
      });
  Future<SupportMessage?> get(String id) async {
    final found = await row(id);
    return found == null ? null : mapper.message(found);
  }

  SimpleSelectStatement<$SupportMessagesTable, SupportMessageRow> _query(
    String sessionId,
  ) => db.select(db.supportMessages)
    ..where((t) => t.sessionId.equals(sessionId))
    ..orderBy([
      (t) => OrderingTerm.asc(t.createdAt),
      (t) => OrderingTerm.asc(t.id),
    ]);
  Future<List<SupportMessage>> _map(List<SupportMessageRow> rows) async {
    final result = <SupportMessage>[];
    for (final row in rows) {
      result.add(await mapper.message(row));
    }
    return result;
  }

  Future<List<SupportMessage>> all(String sessionId) async =>
      _map(await _query(sessionId).get());
  Stream<List<SupportMessage>> watch(String sessionId) =>
      _query(sessionId).watch().asyncMap(_map);
  Future<void> delete(String id) async {
    await (db.delete(db.supportMessages)..where((t) => t.id.equals(id))).go();
  }

  Future<SupportMessagesCompanion> _encrypt(SupportMessage message) async {
    final body = await cipher.encrypt(
      plaintext: message.body,
      table: 'support_messages',
      rowId: message.id,
      sessionId: message.sessionId,
      field: 'body_ciphertext',
    );
    final cards = message.cardsJson.isEmpty
        ? ''
        : await cipher.encrypt(
            plaintext: message.cardsJson,
            table: 'support_messages',
            rowId: message.id,
            sessionId: message.sessionId,
            field: 'cards_ciphertext',
          );
    return SupportMessagesCompanion(
      id: Value(message.id),
      sessionId: Value(message.sessionId),
      role: Value(message.role),
      bodyCiphertext: Value(body),
      cardsCiphertext: Value(cards),
      runId: Value(message.runId),
      status: Value(message.status),
      createdAt: Value(message.createdAt),
    );
  }
}
