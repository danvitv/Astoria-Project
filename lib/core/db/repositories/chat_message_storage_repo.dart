import 'dart:convert';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../../models/chat_message.dart';

final class StoredChatMessage {
  const StoredChatMessage(this.row, this.message);

  final ChatMessageRow row;
  final ChatMessage message;
}

final class ChatMessageStorageSnapshot {
  const ChatMessageStorageSnapshot.legacy(this.messages)
    : state = null,
      stored = const [];

  const ChatMessageStorageSnapshot.rows({
    required this.state,
    required this.stored,
  }) : messages = const [];

  final ChatMessageStorageStateRow? state;
  final List<StoredChatMessage> stored;
  final List<ChatMessage> messages;

  bool get isRowBacked => state != null;

  List<ChatMessage> get materialized => isRowBacked
      ? List.unmodifiable(stored.map((entry) => entry.message))
      : List.unmodifiable(messages);
}

/// Owns the canonical per-message rows and their active storage state.
///
/// Mutating methods deliberately do not open their own transaction: ChatRepo
/// composes them with the owning chat_sessions write and any tracker/canon/
/// manifest side effects in one outer transaction.
final class ChatMessageStorageRepo {
  ChatMessageStorageRepo(this._db);

  static const int positionStep = 1024;

  final AppDatabase _db;

  Future<ChatMessageStorageStateRow?> stateFor(String sessionId) => (_db.select(
    _db.chatMessageStorageRows,
  )..where((table) => table.sessionId.equals(sessionId))).getSingleOrNull();

  Future<List<ChatMessage>?> loadMessagesBySessionId(String sessionId) async {
    final rawMessages = await loadRawMessagesBySessionId(sessionId);
    if (rawMessages == null) return null;
    return List.unmodifiable(
      rawMessages.map((entry) {
        if (entry is! Map) {
          throw const FormatException('Chat message is not an object');
        }
        return ChatMessage.fromJson(Map<String, dynamic>.from(entry));
      }),
    );
  }

  /// Loads the original message JSON values through one SQLite snapshot.
  ///
  /// Evidence readers use this narrower representation so unrelated fields
  /// from an older message dialect cannot invalidate content/variation anchors
  /// merely because the current full [ChatMessage] codec is stricter.
  Future<List<Object?>?> loadRawMessagesBySessionId(String sessionId) async {
    // One SQLite statement is the snapshot boundary. In particular, never read
    // state and active rows in separate autocommit snapshots: an equal-count
    // edit or generation switch could otherwise be observed half-old/half-new.
    final rows = await _db
        .customSelect(
          '''
          SELECT session.messages_json AS legacy_json,
            storage.active_generation, storage.revision,
            storage.message_count, message.row_id, message.position_key,
            message.message_id, message.role, message.message_timestamp,
            message.message_json
          FROM chat_sessions AS session
          LEFT JOIN chat_message_storage_rows AS storage
            ON storage.session_id = session.session_id
          LEFT JOIN chat_message_rows AS message
            ON message.session_id = session.session_id
            AND message.storage_generation = storage.active_generation
          WHERE session.session_id = ?
          ORDER BY message.position_key
          ''',
          variables: [Variable.withString(sessionId)],
          readsFrom: {
            _db.chatSessions,
            _db.chatMessageStorageRows,
            _db.chatMessageRows,
          },
        )
        .get();
    if (rows.isEmpty) return null;
    final first = rows.first;
    final generation = first.readNullable<int>('active_generation');
    if (generation == null) {
      final decoded = jsonDecode(first.read<String>('legacy_json'));
      if (decoded is! List) {
        throw const FormatException('Chat messages payload is not an array');
      }
      return List<Object?>.unmodifiable(decoded);
    }
    final revision = first.readNullable<int>('revision');
    final expectedCount = first.readNullable<int>('message_count');
    if (generation <= 0 ||
        revision == null ||
        revision <= 0 ||
        expectedCount == null ||
        expectedCount < 0) {
      throw StateError('Chat message storage state mismatch for $sessionId');
    }
    final messages = <Object?>[];
    var previousPosition = 0;
    for (final row in rows) {
      if (row.readNullable<int>('row_id') == null) continue;
      final position = row.readNullable<int>('position_key');
      final raw = row.readNullable<String>('message_json');
      if (position == null || position <= previousPosition || raw == null) {
        throw StateError('Chat message order is invalid for $sessionId');
      }
      previousPosition = position;
      final decoded = jsonDecode(raw);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Chat message row is not an object');
      }
      if (decoded['id'] != row.readNullable<String>('message_id') ||
          decoded['role'] != row.readNullable<String>('role') ||
          decoded['timestamp'] != row.readNullable<int>('message_timestamp')) {
        throw StateError('Chat message projection mismatch for $sessionId');
      }
      messages.add(decoded);
    }
    if (messages.length != expectedCount) {
      throw StateError('Chat message count mismatch for $sessionId');
    }
    return List.unmodifiable(messages);
  }

  Future<String?> materializeMessagesJson(String sessionId) async {
    final messages = await loadMessagesBySessionId(sessionId);
    if (messages == null) return null;
    return jsonEncode(messages.map((message) => message.toJson()).toList());
  }

  Future<ChatMessageStorageSnapshot> load(ChatSessionRow session) async {
    final state = await stateFor(session.sessionId);
    if (state == null) {
      return ChatMessageStorageSnapshot.legacy(
        _decodeLegacyMessages(session.messagesJson),
      );
    }
    final stored = await _loadActiveRows(state);
    return ChatMessageStorageSnapshot.rows(state: state, stored: stored);
  }

  Future<Map<String, ChatMessageStorageSnapshot>> loadMany(
    List<ChatSessionRow> sessions,
  ) async {
    if (sessions.isEmpty) return const {};
    final byId = {for (final session in sessions) session.sessionId: session};
    final states = <String, ChatMessageStorageStateRow>{};
    for (final ids in _chunks(byId.keys.toList(growable: false), 400)) {
      final rows = await (_db.select(
        _db.chatMessageStorageRows,
      )..where((table) => table.sessionId.isIn(ids))).get();
      for (final row in rows) {
        states[row.sessionId] = row;
      }
    }

    final activeRows = <String, List<ChatMessageRow>>{};
    final rowBackedIds = states.keys.toList(growable: false);
    for (final ids in _chunks(rowBackedIds, 400)) {
      final rows =
          await (_db.select(_db.chatMessageRows)
                ..where((table) => table.sessionId.isIn(ids))
                ..orderBy([
                  (table) => OrderingTerm.asc(table.sessionId),
                  (table) => OrderingTerm.asc(table.positionKey),
                ]))
              .get();
      for (final row in rows) {
        final state = states[row.sessionId];
        if (state == null || row.storageGeneration != state.activeGeneration) {
          continue;
        }
        (activeRows[row.sessionId] ??= []).add(row);
      }
    }

    final result = <String, ChatMessageStorageSnapshot>{};
    for (final session in sessions) {
      final state = states[session.sessionId];
      if (state == null) {
        result[session.sessionId] = ChatMessageStorageSnapshot.legacy(
          _decodeLegacyMessages(session.messagesJson),
        );
        continue;
      }
      result[session.sessionId] = ChatMessageStorageSnapshot.rows(
        state: state,
        stored: _decodeAndValidateRows(
          state,
          activeRows[session.sessionId] ?? const [],
        ),
      );
    }
    return result;
  }

  Future<void> createForSession({
    required String sessionId,
    required List<ChatMessage> messages,
    required int updatedAt,
  }) async {
    const generation = 1;
    // Publish state last. Besides keeping a partial generation invisible inside
    // the owning transaction, this lets per-row history triggers ignore the
    // initial bulk insert; the state trigger invalidates the source once.
    await _insertGeneration(
      sessionId: sessionId,
      generation: generation,
      messages: messages,
      updatedAt: updatedAt,
    );
    await _db
        .into(_db.chatMessageStorageRows)
        .insert(
          ChatMessageStorageRowsCompanion.insert(
            sessionId: sessionId,
            activeGeneration: const Value(generation),
            revision: const Value(1),
            messageCount: Value(messages.length),
          ),
        );
  }

  /// Reconciles one active generation while retaining physical rows for equal
  /// prefix/suffix messages. Common append, edit and suffix-delete operations
  /// touch only their changed rows. A rare exhausted ordering gap falls back to
  /// an atomic generation replacement instead of unsafe in-place renumbering.
  Future<ChatMessageStorageSnapshot> replaceMessages({
    required String sessionId,
    required ChatMessageStorageSnapshot before,
    required List<ChatMessage> messages,
    required int updatedAt,
  }) async {
    final state = before.state;
    if (state == null) {
      throw StateError('Row-backed message state required');
    }
    if (state.sessionId != sessionId ||
        state.messageCount != before.stored.length) {
      throw StateError('Chat message storage state mismatch');
    }
    final previous = before.stored.map((entry) => entry.message).toList();
    if (_sameMessages(previous, messages)) return before;

    var prefix = 0;
    while (prefix < previous.length &&
        prefix < messages.length &&
        previous[prefix] == messages[prefix]) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < previous.length - prefix &&
        suffix < messages.length - prefix &&
        previous[previous.length - 1 - suffix] ==
            messages[messages.length - 1 - suffix]) {
      suffix++;
    }

    final oldMiddle = before.stored.sublist(
      prefix,
      before.stored.length - suffix,
    );
    final newMiddle = messages.sublist(prefix, messages.length - suffix);
    final leftKey = prefix == 0 ? 0 : before.stored[prefix - 1].row.positionKey;
    final rightKey = suffix == 0
        ? null
        : before.stored[before.stored.length - suffix].row.positionKey;

    if (oldMiddle.length == newMiddle.length) {
      for (var index = 0; index < oldMiddle.length; index++) {
        if (oldMiddle[index].message == newMiddle[index]) continue;
        await (_db.update(
              _db.chatMessageRows,
            )..where((table) => table.rowId.equals(oldMiddle[index].row.rowId)))
            .write(_messageUpdate(newMiddle[index], updatedAt));
      }
    } else {
      final keys = _allocateKeys(
        left: leftKey,
        right: rightKey,
        count: newMiddle.length,
      );
      if (keys == null) {
        return _replaceGeneration(
          sessionId: sessionId,
          state: state,
          messages: messages,
          updatedAt: updatedAt,
        );
      }
      if (oldMiddle.isNotEmpty) {
        await (_db.delete(_db.chatMessageRows)..where(
              (table) =>
                  table.rowId.isIn(oldMiddle.map((entry) => entry.row.rowId)),
            ))
            .go();
      }
      for (var index = 0; index < newMiddle.length; index++) {
        await _db
            .into(_db.chatMessageRows)
            .insert(
              _messageInsert(
                sessionId: sessionId,
                generation: state.activeGeneration,
                positionKey: keys[index],
                message: newMiddle[index],
                updatedAt: updatedAt,
              ),
            );
      }
    }

    final changed =
        await (_db.update(_db.chatMessageStorageRows)..where(
              (table) =>
                  table.sessionId.equals(sessionId) &
                  table.revision.equals(state.revision),
            ))
            .write(
              ChatMessageStorageRowsCompanion(
                revision: Value(state.revision + 1),
                messageCount: Value(messages.length),
              ),
            );
    if (changed != 1) throw StateError('Chat message revision changed');
    return load(
      ChatSessionRow(
        sessionId: sessionId,
        characterId: '',
        sessionIndex: 0,
        messagesJson: '[]',
        updatedAt: updatedAt,
        sessionVarsJson: null,
        authorsNoteJson: null,
        draft: null,
        lastScrollAnchorJson: null,
      ),
    );
  }

  Future<ChatMessageStorageSnapshot> _replaceGeneration({
    required String sessionId,
    required ChatMessageStorageStateRow state,
    required List<ChatMessage> messages,
    required int updatedAt,
  }) async {
    final generation = state.activeGeneration + 1;
    await _insertGeneration(
      sessionId: sessionId,
      generation: generation,
      messages: messages,
      updatedAt: updatedAt,
    );
    final changed =
        await (_db.update(_db.chatMessageStorageRows)..where(
              (table) =>
                  table.sessionId.equals(sessionId) &
                  table.revision.equals(state.revision),
            ))
            .write(
              ChatMessageStorageRowsCompanion(
                activeGeneration: Value(generation),
                revision: Value(state.revision + 1),
                messageCount: Value(messages.length),
              ),
            );
    if (changed != 1) throw StateError('Chat message revision changed');
    await (_db.delete(_db.chatMessageRows)..where(
          (table) =>
              table.sessionId.equals(sessionId) &
              table.storageGeneration.equals(state.activeGeneration),
        ))
        .go();
    final nextState = state.copyWith(
      activeGeneration: generation,
      revision: state.revision + 1,
      messageCount: messages.length,
    );
    return ChatMessageStorageSnapshot.rows(
      state: nextState,
      stored: await _loadActiveRows(nextState),
    );
  }

  Future<void> _insertGeneration({
    required String sessionId,
    required int generation,
    required List<ChatMessage> messages,
    required int updatedAt,
  }) async {
    for (var index = 0; index < messages.length; index++) {
      await _db
          .into(_db.chatMessageRows)
          .insert(
            _messageInsert(
              sessionId: sessionId,
              generation: generation,
              positionKey: (index + 1) * positionStep,
              message: messages[index],
              updatedAt: updatedAt,
            ),
          );
    }
  }

  Future<List<StoredChatMessage>> _loadActiveRows(
    ChatMessageStorageStateRow state,
  ) async {
    final rows =
        await (_db.select(_db.chatMessageRows)
              ..where(
                (table) =>
                    table.sessionId.equals(state.sessionId) &
                    table.storageGeneration.equals(state.activeGeneration),
              )
              ..orderBy([(table) => OrderingTerm.asc(table.positionKey)]))
            .get();
    return _decodeAndValidateRows(state, rows);
  }

  List<StoredChatMessage> _decodeAndValidateRows(
    ChatMessageStorageStateRow state,
    List<ChatMessageRow> rows,
  ) {
    if (rows.length != state.messageCount) {
      throw StateError('Chat message count mismatch for ${state.sessionId}');
    }
    var previousPosition = 0;
    final stored = <StoredChatMessage>[];
    for (final row in rows) {
      if (row.positionKey <= previousPosition) {
        throw StateError(
          'Chat message order is invalid for ${state.sessionId}',
        );
      }
      previousPosition = row.positionKey;
      final decoded = jsonDecode(row.messageJson);
      if (decoded is! Map<String, dynamic>) {
        throw const FormatException('Chat message row is not an object');
      }
      final message = ChatMessage.fromJson(decoded);
      if (message.id != row.messageId ||
          message.role != row.role ||
          message.timestamp != row.messageTimestamp) {
        throw StateError(
          'Chat message projection mismatch for ${state.sessionId}',
        );
      }
      stored.add(StoredChatMessage(row, message));
    }
    return List.unmodifiable(stored);
  }

  ChatMessageRowsCompanion _messageInsert({
    required String sessionId,
    required int generation,
    required int positionKey,
    required ChatMessage message,
    required int updatedAt,
  }) => ChatMessageRowsCompanion.insert(
    sessionId: sessionId,
    storageGeneration: generation,
    positionKey: positionKey,
    messageId: message.id,
    role: message.role,
    messageTimestamp: Value(message.timestamp),
    messageJson: jsonEncode(message.toJson()),
    updatedAt: Value(updatedAt),
  );

  ChatMessageRowsCompanion _messageUpdate(ChatMessage message, int updatedAt) =>
      ChatMessageRowsCompanion(
        messageId: Value(message.id),
        role: Value(message.role),
        messageTimestamp: Value(message.timestamp),
        messageJson: Value(jsonEncode(message.toJson())),
        updatedAt: Value(updatedAt),
      );

  List<int>? _allocateKeys({
    required int left,
    required int? right,
    required int count,
  }) {
    if (count == 0) return const [];
    if (right == null) {
      return [
        for (var index = 1; index <= count; index++)
          left + index * positionStep,
      ];
    }
    final gap = right - left - 1;
    if (gap < count) return null;
    final keys = <int>[];
    var previous = left;
    for (var index = 1; index <= count; index++) {
      final key = left + (gap * index ~/ (count + 1));
      if (key <= previous || key >= right) return null;
      keys.add(key);
      previous = key;
    }
    return keys;
  }

  static bool _sameMessages(List<ChatMessage> a, List<ChatMessage> b) {
    if (a.length != b.length) return false;
    for (var index = 0; index < a.length; index++) {
      if (a[index] != b[index]) return false;
    }
    return true;
  }

  static List<ChatMessage> _decodeLegacyMessages(String messagesJson) =>
      (jsonDecode(messagesJson) as List<dynamic>)
          .map(
            (entry) =>
                ChatMessage.fromJson(Map<String, dynamic>.from(entry as Map)),
          )
          .toList(growable: false);

  static Iterable<List<T>> _chunks<T>(List<T> values, int size) sync* {
    for (var offset = 0; offset < values.length; offset += size) {
      final end = offset + size < values.length ? offset + size : values.length;
      yield values.sublist(offset, end);
    }
  }
}
