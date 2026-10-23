part of '../support_repo.dart';

/// Native input custody and metadata-only per-session ordering. No history
/// bodies/cards are fetched to allocate a timestamp. All helpers run inside the
/// owning append/reservation transaction; none grants disclosure authority.
final class _SupportNativeInputStore {
  _SupportNativeInputStore(this.db, this.mapper, this.sessions, this.messages);
  final AppDatabase db;
  final _SupportRowMapper mapper;
  final _SupportSessionStore sessions;
  final _SupportMessageStore messages;

  static const maxTime = 9007199254740991; // Inclusive 2^53 - 1.
  static const _maxIdentifierUnits = 128;
  static const _maxInputUnits = 8192;

  void require(bool condition) {
    if (!condition) throw const _SupportReplyRefused();
  }

  Future<T> checked<T>(
    bool Function() current,
    Future<T> Function() work,
  ) async {
    require(current());
    final result = await work();
    require(current());
    return result;
  }

  bool time(int value) => value >= 0 && value <= maxTime;

  bool identifier(String? value) =>
      value != null &&
      value.isNotEmpty &&
      value.length <= _maxIdentifierUnits &&
      messages.replies._identifier(value);

  bool user(SupportMessage message) =>
      identifier(message.id) &&
      identifier(message.sessionId) &&
      identifier(message.runId) &&
      message.role == 'user' &&
      message.status == 'complete' &&
      message.cardsJson.isEmpty &&
      !message.isLocked &&
      message.body.length <= _maxInputUnits &&
      time(message.createdAt);

  Future<SupportSessionRow> parent(String id, bool Function() current) async {
    final invalid = await checked(
      current,
      () => db
          .customSelect(
            'SELECT 1 AS invalid_parent FROM support_sessions WHERE id = ? AND ('
            "typeof(created_at) != 'integer' OR created_at < 0 OR created_at > $maxTime "
            "OR typeof(updated_at) != 'integer' OR updated_at < 0 "
            'OR updated_at > $maxTime) LIMIT 1',
            variables: [Variable<String>(id)],
            readsFrom: {db.supportSessions},
          )
          .get(),
    );
    require(invalid.isEmpty);
    final row = await checked(current, () => sessions.row(id));
    require(row != null);
    require(time(row!.createdAt) && time(row.updatedAt));
    final readable = await checked(current, () => mapper.session(row));
    _requireUnlocked(readable.isLocked);
    return row;
  }

  Future<bool> absent(String id, bool Function() current) async {
    final rows = await checked(
      current,
      () => db
          .customSelect(
            'SELECT 1 AS present FROM support_messages WHERE id = ? LIMIT 1',
            variables: [Variable<String>(id)],
            readsFrom: {db.supportMessages},
          )
          .get(),
    );
    return rows.isEmpty;
  }

  /// Reject SQLite's dynamic malformed/fractional/negative/out-of-range metadata
  /// BEFORE MAX. Only numeric metadata is projected; no old payload is mapped.
  Future<int> allocate(
    String sessionId,
    int floor,
    bool Function() current, {
    String? excludingId,
  }) async {
    require(time(floor));
    final selection =
        'session_id = ?${excludingId == null ? '' : ' AND id != ?'}';
    final variables = <Variable>[
      Variable<String>(sessionId),
      if (excludingId != null) Variable<String>(excludingId),
    ];
    final invalid = await checked(
      current,
      () => db
          .customSelect(
            'SELECT 1 AS invalid_order FROM support_messages WHERE $selection '
            "AND (typeof(created_at) != 'integer' OR created_at < 0 "
            'OR created_at > $maxTime) LIMIT 1',
            variables: variables,
            readsFrom: {db.supportMessages},
          )
          .get(),
    );
    require(invalid.isEmpty);
    final metadata = await checked(
      current,
      () => db
          .customSelect(
            'SELECT MAX(created_at) AS latest_order FROM support_messages '
            'WHERE $selection',
            variables: variables,
            readsFrom: {db.supportMessages},
          )
          .getSingle(),
    );
    final latest = metadata.data['latest_order'];
    require(latest == null || (latest is int && time(latest)));
    final highest = latest == null ? floor : math.max(floor, latest as int);
    require(highest < maxTime);
    return highest + 1;
  }

  /// Reads exactly the explicitly supplied originating user, never ancestors.
  /// SQL matches metadata before returning payload columns: a moved/replaced
  /// identity is not permission to fetch the foreign row's body.
  Future<SupportMessageRow?> userRow(SupportMessage expected) =>
      (db.select(db.supportMessages)..where(
            (t) =>
                t.id.equals(expected.id) &
                t.sessionId.equals(expected.sessionId) &
                t.role.equals('user') &
                t.runId.equals(expected.runId!) &
                t.status.equals('complete') &
                t.createdAt.equals(expected.createdAt) &
                t.cardsCiphertext.equals(''),
          ))
          .getSingleOrNull();

  Future<SupportMessageRow> matchUser(
    SupportMessage expected,
    bool Function() current,
  ) async {
    require(user(expected));
    final row = await checked(current, () => userRow(expected));
    require(
      row != null &&
          row.cardsCiphertext.isEmpty &&
          row.sessionId == expected.sessionId &&
          row.role == expected.role &&
          row.runId == expected.runId &&
          row.status == expected.status &&
          row.createdAt == expected.createdAt,
    );
    final durable = await checked(current, () => mapper.message(row!));
    _requireUnlocked(durable.isLocked);
    require(durable == expected);
    return row!;
  }

  Future<SupportMessage?> append(
    SupportMessage message,
    bool Function() current,
  ) async {
    try {
      require(current() && user(message));
      return await db.transaction(() async {
        require(current());
        final originalParent = await parent(message.sessionId, current);
        require(await absent(message.id, current));
        final timestamp = await allocate(
          message.sessionId,
          message.createdAt,
          current,
        );
        final next = message.copyWith(createdAt: timestamp);
        final encrypted = await checked(current, () => messages._encrypt(next));
        require(
          await checked(current, () => sessions.row(message.sessionId)) ==
              originalParent,
        );
        require(await absent(message.id, current));
        require(
          await allocate(message.sessionId, message.createdAt, current) ==
              timestamp,
        );
        await checked(
          current,
          () => db.into(db.supportMessages).insert(encrypted),
        );
        final row = await checked(current, () => messages.row(message.id));
        require(row != null && row.cardsCiphertext.isEmpty);
        final durable = await checked(current, () => mapper.message(row!));
        _requireUnlocked(durable.isLocked);
        require(durable == next);
        require(await checked(current, () => messages.row(message.id)) == row);
        require(
          await checked(current, () => sessions.row(message.sessionId)) ==
              originalParent,
        );
        require(
          await allocate(
                message.sessionId,
                message.createdAt,
                current,
                excludingId: message.id,
              ) ==
              timestamp,
        );
        final updatedAt = math.max(originalParent.updatedAt, timestamp);
        final count = await checked(
          current,
          () =>
              (db.update(db.supportSessions)
                    ..where((t) => t.id.equals(message.sessionId)))
                  .write(SupportSessionsCompanion(updatedAt: Value(updatedAt))),
        );
        require(count == 1);
        require(
          await allocate(
                message.sessionId,
                message.createdAt,
                current,
                excludingId: message.id,
              ) ==
              timestamp,
        );
        require(
          await checked(current, () => sessions.row(message.sessionId)) ==
              originalParent.copyWith(updatedAt: updatedAt),
        );
        require(await checked(current, () => messages.row(message.id)) == row);
        require(current());
        return durable;
      });
    } on _SupportReplyRefused {
      return null;
    }
  }
}
