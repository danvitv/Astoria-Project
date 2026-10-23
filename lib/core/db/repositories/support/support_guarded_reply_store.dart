part of '../support_repo.dart';

/// Owns only create-only reservations and exact-run body/status settlement.
final class _SupportGuardedReplyStore {
  _SupportGuardedReplyStore(
    this.db,
    this.cipher,
    this.mapper,
    this.sessions,
    this.messages,
  );
  final AppDatabase db;
  final SupportPayloadCipher cipher;
  final _SupportRowMapper mapper;
  final _SupportSessionStore sessions;
  final _SupportMessageStore messages;

  static const _terminal = {'complete', 'stopped', 'error', 'limited'};
  static const _maxTextChars = 65536;

  String _provenanceId(String messageId) =>
      'support.reply_provenance:$messageId';

  Future<T> _checked<T>(Future<T> work, bool Function() current) async {
    final result = await work;
    _requireCurrent(current);
    return result;
  }

  void _requireCurrent(bool Function() current) {
    if (!current()) throw const _SupportReplyRefused();
  }

  void _require(bool condition) {
    if (!condition) throw const _SupportReplyRefused();
  }

  bool _identifier(String? value) =>
      value != null &&
      value.isNotEmpty &&
      value.length <= cipher.maxIdentifierBytes &&
      value == value.trim() &&
      !value.contains('|') &&
      value.runes.fold<int>(
            0,
            (n, r) =>
                n +
                (r < 128
                    ? 1
                    : r < 2048
                    ? 2
                    : r < 65536
                    ? 3
                    : 4),
          ) <=
          cipher.maxIdentifierBytes;

  bool _text(String value) => value.length <= _maxTextChars;

  bool _reply(SupportMessage message) =>
      _identifier(message.id) &&
      _identifier(message.sessionId) &&
      _identifier(message.runId) &&
      _identifier(_provenanceId(message.id)) &&
      message.role == 'assistant' &&
      message.cardsJson.isEmpty &&
      !message.isLocked &&
      message.createdAt >= 0 &&
      _text(message.body);

  Future<SupportContextBlockRow?> _contextRow(String id) => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<SupportSessionRow> _parent(String id, bool Function() current) async {
    final parent = await _checked(sessions.row(id), current);
    _require(parent != null);
    final readable = await _checked(mapper.session(parent!), current);
    _requireUnlocked(readable.isLocked);
    return parent;
  }

  Future<SupportMessage> _message(
    SupportMessageRow row,
    bool Function() current,
  ) async {
    _require(row.cardsCiphertext.isEmpty);
    final body = await _checked(
      cipher.decrypt(
        envelopeText: row.bodyCiphertext,
        table: 'support_messages',
        rowId: row.id,
        sessionId: row.sessionId,
        field: 'body_ciphertext',
      ),
      current,
    );
    return SupportMessage(
      id: row.id,
      sessionId: row.sessionId,
      role: row.role,
      body: body,
      runId: row.runId,
      status: row.status,
      createdAt: row.createdAt,
    );
  }

  Future<SupportContextBlock> _provenance(
    SupportContextBlockRow row,
    bool Function() current,
  ) async {
    Future<String> decrypt(String text, String field) => _checked(
      cipher.decrypt(
        envelopeText: text,
        table: 'support_context_blocks',
        rowId: row.id,
        sessionId: row.sessionId,
        field: field,
      ),
      current,
    );
    final summary = await decrypt(row.summaryCiphertext, 'summary_ciphertext');
    _requireCurrent(current);
    final facts = await decrypt(
      row.protectedFactsCiphertext,
      'protected_facts_ciphertext',
    );
    _requireCurrent(current);
    return SupportContextBlock(
      id: row.id,
      sessionId: row.sessionId,
      startMessageId: row.startMessageId,
      endMessageId: row.endMessageId,
      summary: summary,
      protectedFactsJson: facts,
      isActive: row.isActive,
      createdAt: row.createdAt,
    );
  }

  Future<void> _unchanged(
    SupportSessionRow parent,
    String messageId,
    String contextId,
    SupportMessageRow? message,
    SupportContextBlockRow? context,
    bool Function() current, {
    bool messageAbsentMetadataOnly = false,
  }) async {
    if (messageAbsentMetadataOnly) {
      _require(message == null);
      _require(
        await _checked(
          messages.nativeInput.absent(messageId, current),
          current,
        ),
      );
    } else {
      _require(await _checked(messages.row(messageId), current) == message);
    }
    _require(await _checked(_contextRow(contextId), current) == context);
    _require(await _checked(sessions.row(parent.id), current) == parent);
  }

  Future<T?> _transaction<T>(
    bool Function() current,
    Future<T> Function() work,
  ) async {
    try {
      _requireCurrent(current);
      return await db.transaction(() {
        _requireCurrent(current);
        return work();
      });
    } on _SupportReplyRefused {
      return null;
    }
  }

  Future<SupportReplyReservation?> reserve(
    SupportMessage message,
    String provenanceJson,
    bool Function() current, {
    SupportMessage? originatingUser,
  }) => _transaction(current, () async {
    _require(
      _reply(message) && message.status == 'preparing' && message.body.isEmpty,
    );
    _require(_text(provenanceJson) && provenanceJson.trim().isNotEmpty);
    final native = messages.nativeInput;
    SupportMessageRow? originRow;
    final floor = message.createdAt;
    final parent = originatingUser == null
        ? await _checked(_parent(message.sessionId, current), current)
        : await _checked(native.parent(message.sessionId, current), current);
    if (originatingUser != null) {
      _require(
        native.user(originatingUser) &&
            native.identifier(message.id) &&
            native.identifier(message.sessionId) &&
            native.identifier(message.runId) &&
            native.time(floor) &&
            native.time(parent.createdAt) &&
            native.time(parent.updatedAt) &&
            originatingUser.id != message.id &&
            originatingUser.sessionId == message.sessionId &&
            originatingUser.runId == message.runId,
      );
      originRow = await native.matchUser(originatingUser, current);
      _requireCurrent(current);
      message = message.copyWith(
        createdAt: await native.allocate(message.sessionId, floor, current),
      );
      _requireCurrent(current);
    }
    final block = SupportContextBlock(
      id: _provenanceId(message.id),
      sessionId: message.sessionId,
      startMessageId: message.id,
      endMessageId: message.id,
      summary: '',
      protectedFactsJson: provenanceJson,
      isActive: false,
      createdAt: message.createdAt,
    );
    await _checked(
      _unchanged(
        parent,
        message.id,
        block.id,
        null,
        null,
        current,
        messageAbsentMetadataOnly: originatingUser != null,
      ),
      current,
    );
    final encrypted = await _checked(messages._encrypt(message), current);
    final summary = await _checked(
      cipher.encrypt(
        plaintext: '',
        table: 'support_context_blocks',
        rowId: block.id,
        sessionId: block.sessionId,
        field: 'summary_ciphertext',
      ),
      current,
    );
    final facts = await _checked(
      cipher.encrypt(
        plaintext: provenanceJson,
        table: 'support_context_blocks',
        rowId: block.id,
        sessionId: block.sessionId,
        field: 'protected_facts_ciphertext',
      ),
      current,
    );
    await _checked(
      _unchanged(
        parent,
        message.id,
        block.id,
        null,
        null,
        current,
        messageAbsentMetadataOnly: originatingUser != null,
      ),
      current,
    );
    if (originRow != null) {
      native.require(
        await native.checked(current, () => native.userRow(originatingUser!)) ==
            originRow,
      );
      native.require(
        await native.allocate(message.sessionId, floor, current) ==
            message.createdAt,
      );
      _requireCurrent(current);
    }
    await _checked(db.into(db.supportMessages).insert(encrypted), current);
    await _checked(
      db
          .into(db.supportContextBlocks)
          .insert(
            SupportContextBlocksCompanion(
              id: Value(block.id),
              sessionId: Value(block.sessionId),
              startMessageId: Value(block.startMessageId),
              endMessageId: Value(block.endMessageId),
              summaryCiphertext: Value(summary),
              protectedFactsCiphertext: Value(facts),
              isActive: const Value(false),
              createdAt: Value(block.createdAt),
            ),
          ),
      current,
    );
    final row = await _checked(messages.row(message.id), current);
    final context = await _checked(_contextRow(block.id), current);
    _require(row != null && context != null);
    final durable = await _checked(_message(row!, current), current);
    final provenance = await _checked(_provenance(context!, current), current);
    _require(durable == message && provenance == block);
    _require(await _checked(_parent(parent.id, current), current) == parent);
    if (originRow != null) {
      native.require(
        await native.allocate(
              message.sessionId,
              floor,
              current,
              excludingId: message.id,
            ) ==
            message.createdAt,
      );
      _requireCurrent(current);
    }
    await _checked(
      _unchanged(parent, message.id, block.id, row, context, current),
      current,
    );
    if (originRow != null) {
      native.require(
        await native.checked(current, () => native.userRow(originatingUser!)) ==
            originRow,
      );
      _requireCurrent(current);
    }
    return (message: durable, provenance: provenance);
  });

  Future<SupportMessage?> settle(
    SupportReplyReservation expected,
    String status,
    String? body,
    bool Function() current,
  ) => _transaction(current, () async {
    final message = expected.message;
    final block = expected.provenance;
    _require(_reply(message));
    _require(message.status == 'preparing' || message.status == 'pending');
    _require(
      _terminal.contains(status) ||
          (message.status == 'preparing' && status == 'pending'),
    );
    _require(body == null || _text(body));
    _require(status != 'pending' || body == null);
    _require(
      block.id == _provenanceId(message.id) &&
          block.sessionId == message.sessionId &&
          block.startMessageId == message.id &&
          block.endMessageId == message.id &&
          block.createdAt == message.createdAt &&
          !block.isActive &&
          !block.isLocked &&
          block.summary.isEmpty &&
          _text(block.protectedFactsJson) &&
          block.protectedFactsJson.trim().isNotEmpty,
    );
    final parent = await _checked(_parent(message.sessionId, current), current);
    final row = await _checked(messages.row(message.id), current);
    final context = await _checked(_contextRow(block.id), current);
    _require(row != null && context != null);
    _require(
      row!.sessionId == message.sessionId &&
          row.runId == message.runId &&
          row.status == message.status,
    );
    _require(await _checked(_message(row, current), current) == message);
    _require(await _checked(_provenance(context!, current), current) == block);
    final next = message.copyWith(body: body, status: status);
    final encryptedBody = body == null
        ? row.bodyCiphertext
        : await _checked(
            cipher.encrypt(
              plaintext: body,
              table: 'support_messages',
              rowId: message.id,
              sessionId: message.sessionId,
              field: 'body_ciphertext',
            ),
            current,
          );
    _requireCurrent(current);
    await _checked(
      _unchanged(parent, message.id, block.id, row, context, current),
      current,
    );
    final count = await _checked(
      (db.update(db.supportMessages)..where(
            (t) =>
                t.id.equals(message.id) &
                t.sessionId.equals(message.sessionId) &
                t.runId.equals(message.runId!) &
                t.status.equals(message.status),
          ))
          .write(
            SupportMessagesCompanion(
              bodyCiphertext: Value(encryptedBody),
              status: Value(status),
            ),
          ),
      current,
    );
    _require(count == 1);
    final written = await _checked(messages.row(message.id), current);
    _require(written != null);
    final durable = await _checked(_message(written!, current), current);
    _require(durable == next);
    _require(await _checked(_parent(parent.id, current), current) == parent);
    await _checked(
      _unchanged(parent, message.id, block.id, written, context, current),
      current,
    );
    return durable;
  });
}

/// Internal control flow only; never carries a payload or underlying exception.
final class _SupportReplyRefused implements Exception {
  const _SupportReplyRefused();
}
