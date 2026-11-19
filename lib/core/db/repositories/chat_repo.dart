import 'dart:async';
import 'dart:convert';
import 'dart:isolate';

import 'package:drift/drift.dart';

import '../app_db.dart';
import '../database_transaction_guard.dart';
import '../../llm/prompt/exact_lorebook_manifest.dart';
import 'lorebook_use_manifest_repo.dart';
import 'chat_message_storage_repo.dart';
import 'session_deletion_queries.dart';
import 'support_repo.dart';
import '../../models/support_models.dart';
import '../../models/chat_message.dart';
import '../../utils/time_helpers.dart';
import '../../application/sync_repo_interfaces.dart';
import '../../application/session_deletion_store.dart';

part 'chat_native_maintenance_source.dart';
part 'chat_native_session_title.dart';

final class ChatNativeSelectionInventory {
  ChatNativeSelectionInventory._(
    this._repo,
    List<({String sessionId, String characterId, int sessionIndex})> identities,
    this._lifetime,
  ) : _identities = List.unmodifiable(identities),
      sessions = List.unmodifiable(identities.map((s) => s.sessionId));
  final ChatRepo _repo;
  final List<({String sessionId, String characterId, int sessionIndex})>
  _identities;
  final List<String> sessions;
  final bool Function() _lifetime;
  bool _retired = false;
  bool get current {
    if (!_lifetime()) _retired = true;
    return !_retired;
  }
}

class _PreparedUserMessageAppend {
  const _PreparedUserMessageAppend({
    required this.messagesJson,
    required this.messages,
    this.didAppend = true,
  });

  final String messagesJson;
  final List<ChatMessage> messages;
  final bool didAppend;
}

class _GenerationCommitRetired implements Exception {
  const _GenerationCommitRetired();
}

class ChatRepo implements SyncChatStore {
  static const maxControlMetadataOffset = 0x7fffffff;

  final AppDatabase _db;
  final SessionMutationStarted? _onMutationStarted;
  ChatRepo(this._db, {this._onMutationStarted});
  late final ChatMessageStorageRepo _messageStorage = ChatMessageStorageRepo(
    _db,
  );
  bool usesDatabase(AppDatabase database) => identical(_db, database);

  /// Read-only native maintenance projection; not a chat/UI hydration path.
  Future<ChatNativeMaintenanceSource?> readNativeMaintenanceSource(
    String sessionId,
    bool Function() isCurrent,
  ) async {
    if (!isCurrent()) return null;
    try {
      // This owner chooses a read-only metadata snapshot before the repair
      // owner's later outer effect transaction. Never borrow ROOT's transaction.
      return await outsideDatabaseTransaction(
        _db,
        () {
          if (!isCurrent()) return Future<ChatNativeMaintenanceSource?>.value();
          return _db.transaction(
            () => _ChatNativeMaintenanceReader(_db).read(sessionId, isCurrent),
          );
        },
        onRejected: () =>
            StateError('Native maintenance transaction unavailable'),
      );
    } catch (_) {
      return null;
    }
  }

  Future<T> transaction<T>(Future<T> Function() action) =>
      _db.transaction(action);

  Future<List<ChatSession>> getByCharacterId(String charId) async {
    return _db.transaction(() async {
      final rows = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.characterId.equals(charId))).get();
      return _materializeSessions(rows);
    });
  }

  /// Lightweight per-character session listing: projects message metadata
  /// without deserializing every message. Use this when only
  /// session indexes/counts are needed (e.g. the "Open chat" picker) — the
  /// full [getByCharacterId] decodes all messages and is noticeably slower for
  /// characters with large histories.
  Future<List<SessionMetadata>> getMetadataByCharacterId(String charId) async {
    final rows = await _sessionMetadataQuery(
      where: 's.character_id = ?',
      variables: [Variable.withString(charId)],
      orderBy: 's.session_index',
    ).get();
    return rows.map(_projectedMetadata).toList();
  }

  /// How many chat sessions one character has, aggregated in SQL.
  ///
  /// The Quick Access session card needs the number and nothing else;
  /// [getByCharacterId] would decode every message of every session just to
  /// read `.length` off the result.
  Future<int> countByCharacterId(String charId) async {
    final countExpr = _db.chatSessions.sessionId.count();
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([countExpr])
      ..where(_db.chatSessions.characterId.equals(charId));
    final row = await query.getSingleOrNull();
    return row?.read(countExpr) ?? 0;
  }

  /// Number of chat sessions per character id, aggregated in SQL.
  ///
  /// Feeds the variations sheet, where "how many chats does this variation
  /// have" is the fact that tells two same-looking variations apart. Counting
  /// via [getAllSessionMetadata] would decode every session's messages just to
  /// throw them away.
  Stream<Map<String, int>> watchSessionCountsByCharacter() {
    final countExpr = _db.chatSessions.sessionId.count();
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([_db.chatSessions.characterId, countExpr])
      ..groupBy([_db.chatSessions.characterId]);
    return query.watch().map((rows) {
      final counts = <String, int>{};
      for (final row in rows) {
        final charId = row.read(_db.chatSessions.characterId);
        if (charId == null || charId.isEmpty) continue;
        counts[charId] = row.read(countExpr) ?? 0;
      }
      return counts;
    });
  }

  Future<List<ChatSession>> getAllSessions() async {
    return _db.transaction(() async {
      final rows = await (_db.select(
        _db.chatSessions,
      )..orderBy([(t) => OrderingTerm.desc(t.updatedAt)])).get();
      return _materializeSessions(rows);
    });
  }

  @override
  Future<List<SessionMetadata>> getAllSessionMetadata() async {
    final rows = await _sessionMetadataQuery().get();
    return rows.map(_projectedMetadata).toList();
  }

  /// One exact selection collateral inventory, captured before SQL and retained
  /// through final preference CAS and Undo. Never transfer message/title bodies.
  Future<ChatNativeSelectionInventory?> observeNativeSelectionInventory(
    bool Function() isCurrent,
  ) async {
    final lifetime = SessionDeletionQueries.captureInventoryLifetime(_db);
    if (lifetime == null || !isCurrent()) return null;
    final identities = await _selectionInventoryIdentities();
    if (!lifetime() || !isCurrent()) return null;
    return ChatNativeSelectionInventory._(this, identities, lifetime);
  }

  Future<List<({String sessionId, String characterId, int sessionIndex})>>
  _selectionInventoryIdentities() async {
    final rows =
        await (_db.selectOnly(_db.chatSessions)
              ..addColumns([
                _db.chatSessions.sessionId,
                _db.chatSessions.characterId,
                _db.chatSessions.sessionIndex,
              ])
              ..orderBy([OrderingTerm.asc(_db.chatSessions.sessionId)]))
            .get();
    return [
      for (final row in rows)
        (
          sessionId: row.read(_db.chatSessions.sessionId)!,
          characterId: row.read(_db.chatSessions.characterId)!,
          sessionIndex: row.read(_db.chatSessions.sessionIndex)!,
        ),
    ];
  }

  /// Compare against the SAME original collateral, never capture/extend a later
  /// inventory. SQL catches observed untracked differences, not external ABA.
  Future<bool> revalidateNativeSelectionInventory(
    ChatNativeSelectionInventory expected,
    bool Function() isCurrent,
  ) async {
    if (!identical(expected._repo, this) || !expected.current || !isCurrent()) {
      return false;
    }
    final latest = await _selectionInventoryIdentities();
    if (!expected.current || !isCurrent()) return false;
    if (latest.length != expected._identities.length ||
        latest.indexed.any((e) => e.$2 != expected._identities[e.$1])) {
      expected._retired = true;
      return false;
    }
    return true;
  }

  /// Native control discovery, without titles, message bodies or session vars.
  Future<
    ({
      List<({String sessionId, int sessionIndex, int messageCount})> rows,
      int count,
    })
  >
  getControlSessionMetadata({
    required int offset,
    int limit = 16,
    required bool Function() isCurrent,
  }) {
    if (offset < 0 ||
        offset > maxControlMetadataOffset ||
        limit < 1 ||
        limit > 16) {
      throw ArgumentError('Invalid control metadata page');
    }
    void requireCurrent() {
      if (!isCurrent()) throw StateError('Control metadata source retired');
    }

    requireCurrent();
    return _db.transaction(() async {
      requireCurrent();
      final count = await _db
          .customSelect(
            'SELECT count(*) AS n FROM chat_sessions',
            readsFrom: {_db.chatSessions},
          )
          .getSingle();
      requireCurrent();
      final total = count.read<int>('n');
      // A valid continuation past the end needs no potentially large OFFSET scan.
      if (offset >= total) {
        return (
          rows: <({String sessionId, int sessionIndex, int messageCount})>[],
          count: total,
        );
      }
      final rows = await _db
          .customSelect(
            r'''SELECT session_id, session_index,
         CASE WHEN storage.session_id IS NOT NULL THEN storage.message_count
           WHEN length(CAST(session.messages_json AS BLOB)) <= 524288 THEN
             CASE WHEN json_valid(session.messages_json) THEN
               CASE WHEN json_type(session.messages_json) = 'array'
                 THEN json_array_length(session.messages_json) ELSE 0 END
               ELSE 0 END
             ELSE 0 END AS message_count
        FROM chat_sessions session
        LEFT JOIN chat_message_storage_rows storage
          ON storage.session_id = session.session_id
        ORDER BY session.updated_at DESC, session.session_id
        LIMIT ? OFFSET ?''',
            variables: [Variable.withInt(limit), Variable.withInt(offset)],
            readsFrom: {_db.chatSessions, _db.chatMessageStorageRows},
          )
          .get();
      requireCurrent();
      return (
        rows: [
          for (final row in rows)
            (
              sessionId: row.read<String>('session_id'),
              sessionIndex: row.read<int>('session_index'),
              messageCount: row.read<int>('message_count'),
            ),
        ],
        count: total,
      );
    });
  }

  // Project only fields used by the list. Session variables and the last message
  // can contain large Studio payloads/swipes even in a short chat; transferring
  // and decoding either whole JSON object makes draft notifications expensive.
  Selectable<QueryRow> _sessionMetadataQuery({
    String? where,
    List<Variable<Object>> variables = const [],
    String orderBy = 's.updated_at DESC',
  }) => _db.customSelect(
    '''
WITH source AS (
  SELECT
    s.*,
    st.session_id AS row_storage_session_id,
    CASE WHEN st.session_id IS NULL
      THEN json_array_length(s.messages_json)
      ELSE st.message_count
    END AS stored_message_count,
    CASE WHEN st.session_id IS NULL
      THEN json_extract(s.messages_json, '\$[0].timestamp')
      ELSE (
        SELECT m.message_timestamp FROM chat_message_rows m
        WHERE m.session_id = s.session_id
          AND m.storage_generation = st.active_generation
        ORDER BY m.position_key LIMIT 1
      )
    END AS stored_first_timestamp,
    CASE WHEN st.session_id IS NULL
      THEN json_extract(s.messages_json, '\$[#-1]')
      ELSE (
        SELECT m.message_json FROM chat_message_rows m
        WHERE m.session_id = s.session_id
          AND m.storage_generation = st.active_generation
        ORDER BY m.position_key DESC LIMIT 1
      )
    END AS last_message_json
  FROM chat_sessions s
  LEFT JOIN chat_message_storage_rows st ON st.session_id = s.session_id
  ${where == null ? '' : 'WHERE $where'}
)
SELECT
  session_id,
  character_id,
  session_index,
  updated_at,
  CASE WHEN json_valid(session_vars_json) THEN
    CASE WHEN json_type(session_vars_json, '\$.sessionName') = 'text'
      THEN json_extract(session_vars_json, '\$.sessionName') END
  END AS session_name,
  CASE WHEN json_valid(session_vars_json) THEN
    CASE WHEN json_type(session_vars_json, '\$.branchedAt') = 'text'
      THEN json_extract(session_vars_json, '\$.branchedAt') END
  END AS branched_at,
  stored_message_count AS message_count,
  stored_first_timestamp AS first_timestamp,
  json_extract(last_message_json, '\$.timestamp') AS last_timestamp,
  json_extract(last_message_json, '\$.continuationOffset') AS continuation_offset,
  CASE json_type(last_message_json, '\$.content')
    WHEN 'text' THEN json_extract(last_message_json, '\$.content')
    WHEN 'array' THEN (
      SELECT group_concat(json_extract(part.value, '\$.text'), ' ')
      FROM json_each(json_extract(last_message_json, '\$.content')) AS part
      WHERE part.type = 'object'
        AND json_extract(part.value, '\$.type') = 'text'
        AND json_type(part.value, '\$.text') = 'text'
    )
  END AS last_content
FROM source s
ORDER BY $orderBy
''',
    variables: variables,
    readsFrom: {
      _db.chatSessions,
      _db.chatMessageStorageRows,
      _db.chatMessageRows,
    },
  );

  Stream<List<SessionMetadata>> watchAllSessionMetadata() {
    return _sessionMetadataQuery()
        .watch()
        .map((rows) => rows.map(_projectedMetadata).toList())
        .distinct(_metadataEqual);
  }

  static bool _metadataEqual(List<SessionMetadata> a, List<SessionMetadata> b) {
    if (a.length != b.length) return false;
    for (int i = 0; i < a.length; i++) {
      if (a[i].sessionId != b[i].sessionId ||
          a[i].characterId != b[i].characterId ||
          a[i].sessionIndex != b[i].sessionIndex ||
          a[i].updatedAt != b[i].updatedAt ||
          a[i].messageCount != b[i].messageCount ||
          a[i].sessionName != b[i].sessionName ||
          a[i].lastMessageContent != b[i].lastMessageContent ||
          a[i].lastMessageTimestamp != b[i].lastMessageTimestamp ||
          a[i].originTimestamp != b[i].originTimestamp ||
          a[i].originKind != b[i].originKind) {
        return false;
      }
    }
    return true;
  }

  @override
  Future<ChatSession?> getById(String sessionId) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return null;
      final storage = await _messageStorage.load(row);
      return _toModel(row, messages: storage.materialized);
    });
  }

  @override
  Future<void> put(ChatSession session) async {
    // Authoritative replacement intent retires prior observations even when the
    // title compares equal or this write / the caller's later sync work fails.
    final inventory = SessionDeletionQueries.beginInventoryMutation(_db);
    void Function()? settle;
    try {
      settle = _onMutationStarted?.call(session.id);
      await _db.transaction(() async {
        final existing =
            await (_db.select(_db.chatSessions)
                  ..where((table) => table.sessionId.equals(session.id)))
                .getSingleOrNull();
        if (existing == null) {
          // Import/sync/recovery creation remains legacy-backed until those
          // boundaries explicitly adopt row storage. Ordinary app-created
          // sessions use insertIfAbsent below.
          await _db.into(_db.chatSessions).insert(_toCompanion(session));
          return;
        }
        final storage = await _messageStorage.load(existing);
        if (!storage.isRowBacked) {
          await _db
              .into(_db.chatSessions)
              .insertOnConflictUpdate(_toCompanion(session));
          return;
        }
        await _messageStorage.replaceMessages(
          sessionId: session.id,
          before: storage,
          messages: session.messages,
          updatedAt: normalizeTimestampSeconds(session.updatedAt),
        );
        await (_db.update(_db.chatSessions)
              ..where((table) => table.sessionId.equals(session.id)))
            .write(_toCompanion(session, includeMessages: false));
      });
    } finally {
      settle?.call();
      inventory();
    }
  }

  /// Inserts a newly allocated session without replacing an existing owner of
  /// the same globally unique session id.
  Future<bool> insertIfAbsent(ChatSession session) async {
    final inventory = SessionDeletionQueries.beginInventoryMutation(_db);
    try {
      return _db.transaction(() async {
        final inserted = await _db
            .into(_db.chatSessions)
            .insertReturningOrNull(
              _toCompanion(session, includeMessages: false),
              mode: InsertMode.insertOrIgnore,
            );
        if (inserted == null) return false;
        await _messageStorage.createForSession(
          sessionId: session.id,
          messages: session.messages,
          updatedAt: normalizeTimestampSeconds(session.updatedAt),
        );
        return true;
      });
    } finally {
      inventory();
    }
  }

  /// Atomically appends a user message and clears the draft.
  ///
  /// This avoids the send path writing a whole stale session blob while the
  /// input draft debounce is also persisting. The returned session is the
  /// durable DB state that generation should use for prompt assembly.
  Future<ChatSession?> appendUserMessageAndClearDraft({
    required String sessionId,
    required ChatMessage message,
    required int updatedAt,
  }) async {
    if (await _messageStorage.stateFor(sessionId) != null) {
      return _appendRowBackedUserMessage(
        sessionId: sessionId,
        message: message,
        updatedAt: updatedAt,
      );
    }
    while (true) {
      final snapshot = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (snapshot == null) return null;

      final prepared = await _prepareUserMessageAppend(
        snapshot.messagesJson,
        message,
      );

      final result = await _db.transaction<({bool retry, ChatSession? value})>(
        () async {
          final current = await (_db.select(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
          if (current == null) return (retry: false, value: null);
          if (current.messagesJson != snapshot.messagesJson) {
            return (retry: true, value: null);
          }
          await (_db.update(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).write(
            ChatSessionsCompanion(
              messagesJson: Value(prepared.messagesJson),
              draft: const Value(''),
              updatedAt: Value(updatedAt),
            ),
          );
          return (
            retry: false,
            value: _toModel(
              current.copyWith(
                messagesJson: prepared.messagesJson,
                draft: const Value(''),
                updatedAt: updatedAt,
              ),
              messages: prepared.messages,
            ),
          );
        },
      );
      if (!result.retry) return result.value;
    }
  }

  /// Atomically appends a user message, clears the draft, and records that the
  /// caller-observed assistant variation was accepted.
  ///
  /// The assistant identity is a compare-and-swap guard: selection may change
  /// between the UI capturing it and this transaction reading the session. A
  /// legacy variation without a manifest remains sendable; an immutable
  /// manifest, when present, must receive its acceptance in this transaction.
  Future<ChatSession?> appendUserMessageAndAcceptCurrentVariation({
    required String sessionId,
    required ChatMessage message,
    required LorebookUseGenerationIdentity expectedPrecedingAssistant,
    required int updatedAt,
  }) async {
    if (expectedPrecedingAssistant.sessionId != sessionId) {
      return null;
    }
    if (await _messageStorage.stateFor(sessionId) != null) {
      return _appendRowBackedAcceptedUserMessage(
        sessionId: sessionId,
        message: message,
        expectedPrecedingAssistant: expectedPrecedingAssistant,
        updatedAt: updatedAt,
      );
    }
    while (true) {
      final snapshot = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (snapshot == null) return null;

      final prepared = await _prepareAcceptedUserMessageAppend(
        messagesJson: snapshot.messagesJson,
        message: message,
        expectedPrecedingAssistant: expectedPrecedingAssistant,
      );
      if (prepared == null) return null;

      // A retry after a completed transaction must not append the same user
      // message or a second acceptance event. The draft still has to go: this
      // branch reports the send as accepted, and the session it returns is
      // published into `ChatState` and the session cache, so a draft left on
      // it is the text of the message that was just sent — sitting in the
      // composer again the next time the chat is opened.
      if (!prepared.didAppend) {
        if ((snapshot.draft ?? '').isEmpty) {
          return _toModel(snapshot, messages: prepared.messages);
        }
        await (_db.update(_db.chatSessions)
              ..where((t) => t.sessionId.equals(sessionId)))
            .write(const ChatSessionsCompanion(draft: Value('')));
        return _toModel(
          snapshot.copyWith(draft: const Value('')),
          messages: prepared.messages,
        );
      }

      final result = await _db.transaction<({bool retry, ChatSession? value})>(
        () async {
          final row = await (_db.select(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
          if (row == null) return (retry: false, value: null);
          if (row.messagesJson != snapshot.messagesJson) {
            return (retry: true, value: null);
          }

          final manifest =
              await (_db.select(_db.lorebookUseManifests)
                    ..where((t) => t.sessionId.equals(sessionId))
                    ..where(
                      (t) => t.messageId.equals(
                        expectedPrecedingAssistant.messageId,
                      ),
                    )
                    ..where(
                      (t) =>
                          t.swipeId.equals(expectedPrecedingAssistant.swipeId),
                    )
                    ..where(
                      (t) => t.agentSwipeId.equals(
                        expectedPrecedingAssistant.agentSwipeId,
                      ),
                    ))
                  .getSingleOrNull();

          await (_db.update(
            _db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionId))).write(
            ChatSessionsCompanion(
              messagesJson: Value(prepared.messagesJson),
              draft: const Value(''),
              updatedAt: Value(updatedAt),
            ),
          );

          if (manifest != null) {
            await LorebookUseManifestRepo(_db).insertVariationAcceptance(
              acceptanceId: 'variation:$sessionId:${message.id}',
              identity: expectedPrecedingAssistant,
              acceptedByUserMessageId: message.id,
              acceptedAt: updatedAt,
            );
          }

          return (
            retry: false,
            value: _toModel(
              row.copyWith(
                messagesJson: prepared.messagesJson,
                draft: const Value(''),
                updatedAt: updatedAt,
              ),
              messages: prepared.messages,
            ),
          );
        },
      );
      if (!result.retry) return result.value;
    }
  }

  Future<ChatSession?> _appendRowBackedUserMessage({
    required String sessionId,
    required ChatMessage message,
    required int updatedAt,
  }) => _db.transaction(() async {
    final row = await (_db.select(
      _db.chatSessions,
    )..where((table) => table.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    final storage = await _messageStorage.load(row);
    if (!storage.isRowBacked) return null;
    final messages = List<ChatMessage>.from(storage.materialized)..add(message);
    await _messageStorage.replaceMessages(
      sessionId: sessionId,
      before: storage,
      messages: messages,
      updatedAt: updatedAt,
    );
    await (_db.update(
      _db.chatSessions,
    )..where((table) => table.sessionId.equals(sessionId))).write(
      ChatSessionsCompanion(
        draft: const Value(''),
        updatedAt: Value(updatedAt),
      ),
    );
    return _toModel(
      row.copyWith(draft: const Value(''), updatedAt: updatedAt),
      messages: messages,
    );
  });

  Future<ChatSession?> _appendRowBackedAcceptedUserMessage({
    required String sessionId,
    required ChatMessage message,
    required LorebookUseGenerationIdentity expectedPrecedingAssistant,
    required int updatedAt,
  }) => _db.transaction(() async {
    final row = await (_db.select(
      _db.chatSessions,
    )..where((table) => table.sessionId.equals(sessionId))).getSingleOrNull();
    if (row == null) return null;
    final storage = await _messageStorage.load(row);
    if (!storage.isRowBacked) return null;
    final messages = List<ChatMessage>.from(storage.materialized);

    if (messages.any((existing) => existing.id == message.id)) {
      if ((row.draft ?? '').isNotEmpty) {
        await (_db.update(_db.chatSessions)
              ..where((table) => table.sessionId.equals(sessionId)))
            .write(const ChatSessionsCompanion(draft: Value('')));
      }
      return _toModel(
        row.draft == null || row.draft!.isEmpty
            ? row
            : row.copyWith(draft: const Value('')),
        messages: messages,
      );
    }

    final preceding = messages.lastOrNull;
    if (preceding == null ||
        preceding.role != 'assistant' ||
        preceding.id != expectedPrecedingAssistant.messageId ||
        preceding.swipeId != expectedPrecedingAssistant.swipeId ||
        preceding.agentSwipeId != expectedPrecedingAssistant.agentSwipeId) {
      return null;
    }

    final manifest =
        await (_db.select(_db.lorebookUseManifests)
              ..where((table) => table.sessionId.equals(sessionId))
              ..where(
                (table) => table.messageId.equals(
                  expectedPrecedingAssistant.messageId,
                ),
              )
              ..where(
                (table) =>
                    table.swipeId.equals(expectedPrecedingAssistant.swipeId),
              )
              ..where(
                (table) => table.agentSwipeId.equals(
                  expectedPrecedingAssistant.agentSwipeId,
                ),
              ))
            .getSingleOrNull();

    messages.add(message);
    await _messageStorage.replaceMessages(
      sessionId: sessionId,
      before: storage,
      messages: messages,
      updatedAt: updatedAt,
    );
    await (_db.update(
      _db.chatSessions,
    )..where((table) => table.sessionId.equals(sessionId))).write(
      ChatSessionsCompanion(
        draft: const Value(''),
        updatedAt: Value(updatedAt),
      ),
    );
    if (manifest != null) {
      await LorebookUseManifestRepo(_db).insertVariationAcceptance(
        acceptanceId: 'variation:$sessionId:${message.id}',
        identity: expectedPrecedingAssistant,
        acceptedByUserMessageId: message.id,
        acceptedAt: updatedAt,
      );
    }
    return _toModel(
      row.copyWith(draft: const Value(''), updatedAt: updatedAt),
      messages: messages,
    );
  });

  /// Updates only the draft column, and only if [expectedMessageCount] still
  /// matches the row. A delayed input debounce from before Send must not write
  /// an old draft over a session that has since gained the user message.
  /// Returns the persisted draft, or null when the guard did not match. Count
  /// in SQLite on the database executor: never transfer/decode the history just
  /// to save text in an unrelated column.
  Future<String?> updateDraftIfMessageCount({
    required String sessionId,
    required String draft,
    required int expectedMessageCount,
  }) async {
    final changed = await _db.customUpdate(
      '''UPDATE chat_sessions SET draft = ?
         WHERE session_id = ? AND
         CASE WHEN EXISTS (
           SELECT 1 FROM chat_message_storage_rows storage
           WHERE storage.session_id = chat_sessions.session_id
         ) THEN (
           SELECT storage.message_count FROM chat_message_storage_rows storage
           WHERE storage.session_id = chat_sessions.session_id
         ) ELSE json_array_length(messages_json) END = ?''',
      variables: [
        Variable.withString(draft),
        Variable.withString(sessionId),
        Variable.withInt(expectedMessageCount),
      ],
      updates: {_db.chatSessions},
    );
    return changed == 1 ? draft : null;
  }

  /// Atomically transforms the latest durable message list for a session.
  ///
  /// The callback runs inside the database transaction, so callers never have
  /// to persist a full session snapshot captured before another mutation.
  Future<ChatSession?> mutateMessages({
    required String sessionId,
    required List<ChatMessage> Function(List<ChatMessage> messages) mutate,
    required int updatedAt,
  }) async {
    return mutateSession(
      sessionId: sessionId,
      updatedAt: updatedAt,
      mutate: (session) => session.copyWith(
        messages: mutate(List<ChatMessage>.from(session.messages)),
      ),
    );
  }

  Future<ChatSession?> mutateMessagesWithBeforeWrite({
    required String sessionId,
    required List<ChatMessage> Function(List<ChatMessage> messages) mutate,
    required int updatedAt,
    required Future<void> Function(ChatSession before, ChatSession after)
    beforeWrite,
  }) => _mutateSession(
    sessionId: sessionId,
    updatedAt: updatedAt,
    mutate: (session) => session.copyWith(
      messages: mutate(List<ChatMessage>.from(session.messages)),
    ),
    beforeWrite: beforeWrite,
  );

  /// Atomically transforms one message identified by its durable ID.
  Future<ChatSession?> mutateMessage({
    required String sessionId,
    required String messageId,
    required ChatMessage? Function(ChatMessage message) mutate,
    required int updatedAt,
  }) {
    return mutateSession(
      sessionId: sessionId,
      updatedAt: updatedAt,
      mutate: (session) {
        final index = session.messages.indexWhere(
          (message) => message.id == messageId,
        );
        if (index < 0) return null;
        final updatedMessage = mutate(session.messages[index]);
        if (updatedMessage == null) return null;
        final messages = List<ChatMessage>.from(session.messages);
        messages[index] = updatedMessage;
        return session.copyWith(messages: messages);
      },
    );
  }

  /// Atomically updates only the author's note against the latest session.
  Future<ChatSession?> mutateAuthorsNote({
    required String sessionId,
    required AuthorsNote? Function(AuthorsNote? note) mutate,
    required int updatedAt,
  }) {
    return mutateSession(
      sessionId: sessionId,
      updatedAt: updatedAt,
      mutate: (session) =>
          session.copyWith(authorsNote: mutate(session.authorsNote)),
    );
  }

  /// Atomically renames a session without replacing other session variables.
  Future<ChatSession?> renameSession({
    required String sessionId,
    required String name,
  }) {
    return mutateSession(
      sessionId: sessionId,
      mutate: (session) => session.copyWith(
        sessionVars: {...session.sessionVars, 'sessionName': name},
      ),
    );
  }

  /// Atomically transforms the latest durable chat session while preserving
  /// columns the callback did not change.
  Future<ChatSession?> mutateSession({
    required String sessionId,
    required ChatSession? Function(ChatSession session) mutate,
    int? updatedAt,
  }) => _mutateSession(
    sessionId: sessionId,
    mutate: mutate,
    updatedAt: updatedAt,
  );

  /// Reads only the session owner. Useful after a transaction that may rebind
  /// canon without paying to transfer and decode a large message history.
  Future<String?> getCharacterIdBySessionId(String sessionId) async {
    final query = _db.selectOnly(_db.chatSessions)
      ..addColumns([_db.chatSessions.characterId])
      ..where(_db.chatSessions.sessionId.equals(sessionId));
    final row = await query.getSingleOrNull();
    return row?.read(_db.chatSessions.characterId);
  }

  Future<ChatSession?> _mutateSession({
    required String sessionId,
    required ChatSession? Function(ChatSession session) mutate,
    int? updatedAt,
    Future<void> Function(ChatSession before, ChatSession after)? beforeWrite,
  }) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) return null;

      final storage = await _messageStorage.load(row);
      final current = _toModel(row, messages: storage.materialized);
      final updated = mutate(current);
      if (updated == null) return null;
      if (beforeWrite != null) await beforeWrite(current, updated);
      final sessionVarsJson = _sessionVarsJsonWithDelta(
        row.sessionVarsJson,
        current.sessionVars,
        updated.sessionVars,
      );
      final authorsNoteJson = updated.authorsNote != null
          ? jsonEncode(updated.authorsNote!.toJson())
          : null;
      final lastScrollAnchorJson = updated.lastScrollAnchor.isNotEmpty
          ? jsonEncode(updated.lastScrollAnchor)
          : null;
      final durableUpdatedAt = updatedAt ?? updated.updatedAt;

      String? messagesJson;
      if (storage.isRowBacked) {
        await _messageStorage.replaceMessages(
          sessionId: sessionId,
          before: storage,
          messages: updated.messages,
          updatedAt: durableUpdatedAt,
        );
      } else {
        messagesJson = jsonEncode(
          updated.messages.map((e) => e.toJson()).toList(),
        );
      }

      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          messagesJson: messagesJson != null
              ? Value(messagesJson)
              : const Value.absent(),
          sessionVarsJson: Value(sessionVarsJson),
          authorsNoteJson: Value(authorsNoteJson),
          draft: Value(updated.draft),
          lastScrollAnchorJson: Value(lastScrollAnchorJson),
          updatedAt: Value(durableUpdatedAt),
        ),
      );

      return _toModel(
        row.copyWith(
          messagesJson: messagesJson ?? row.messagesJson,
          sessionVarsJson: Value(sessionVarsJson),
          authorsNoteJson: Value(authorsNoteJson),
          draft: Value(updated.draft),
          lastScrollAnchorJson: Value(lastScrollAnchorJson),
          updatedAt: durableUpdatedAt,
        ),
        messages: updated.messages,
      );
    });
  }

  /// Commits a generated assistant variation and, when supplied, its exact
  /// lorebook-use manifest in one database transaction.  The message mutation
  /// deliberately mirrors the guarded generation commit path: a stale regen
  /// cannot attach provenance (or replace text) after its anchor changed.
  Future<ChatSession?> commitGenerationResult({
    required ChatSession baseSession,
    required ChatSession generatedSession,
    required String? regenTargetId,
    ExactLorebookManifest? manifest,
    Future<void> Function(ChatSession before, ChatSession after)? beforeWrite,
    bool Function(ChatSession latest)? canCommit,
    Map<String, bool Function(String? value)> sessionVarKeysToRemove = const {},
  }) async {
    try {
      return await _db.transaction(() async {
        final row =
            await (_db.select(_db.chatSessions)..where(
                  (table) => table.sessionId.equals(generatedSession.id),
                ))
                .getSingleOrNull();
        if (row == null) return null;

        final storage = await _messageStorage.load(row);
        final latest = _toModel(row, messages: storage.materialized);
        final messages = List<ChatMessage>.from(latest.messages);
        if (canCommit != null && !canCommit(latest)) return null;
        ChatMessage? committed;
        if (regenTargetId != null) {
          final baseIndex = baseSession.messages.indexWhere(
            (message) => message.id == regenTargetId,
          );
          final generatedIndex = generatedSession.messages.indexWhere(
            (message) => message.id == regenTargetId,
          );
          final latestIndex = messages.indexWhere(
            (message) => message.id == regenTargetId,
          );
          if (baseIndex < 0 || generatedIndex < 0 || latestIndex < 0) {
            return null;
          }
          final base = baseSession.messages[baseIndex];
          final current = messages[latestIndex];
          if (!_sameGenerationAnchor(base, current)) return null;
          committed = generatedSession.messages[generatedIndex].copyWith(
            isHidden: current.isHidden,
            imageHidden: current.imageHidden,
          );
          messages[latestIndex] = committed;
        } else {
          if (generatedSession.messages.length !=
              baseSession.messages.length + 1) {
            return null;
          }
          final expectedTail = baseSession.messages.lastOrNull?.id;
          final currentTail = messages.lastOrNull?.id;
          if (expectedTail != currentTail) return null;
          committed = generatedSession.messages.last;
          messages.add(committed);
        }

        final committedVars = applySessionVarDelta(
          latest.sessionVars,
          baseSession.sessionVars,
          generatedSession.sessionVars,
        );
        for (final entry in sessionVarKeysToRemove.entries) {
          if (entry.value(latest.sessionVars[entry.key])) {
            committedVars.remove(entry.key);
          }
        }
        final updated = latest.copyWith(
          messages: messages,
          sessionVars: committedVars,
        );
        if (beforeWrite != null) await beforeWrite(latest, updated);
        if (canCommit != null && !canCommit(latest)) {
          throw const _GenerationCommitRetired();
        }
        String? messagesJson;
        if (storage.isRowBacked) {
          await _messageStorage.replaceMessages(
            sessionId: generatedSession.id,
            before: storage,
            messages: updated.messages,
            updatedAt: generatedSession.updatedAt,
          );
        } else {
          messagesJson = jsonEncode(
            updated.messages.map((e) => e.toJson()).toList(),
          );
        }
        final sessionVarsJson = _sessionVarsJsonWithDelta(
          row.sessionVarsJson,
          latest.sessionVars,
          committedVars,
        );
        final authorsNoteJson = updated.authorsNote != null
            ? jsonEncode(updated.authorsNote!.toJson())
            : null;
        final lastScrollAnchorJson = updated.lastScrollAnchor.isNotEmpty
            ? jsonEncode(updated.lastScrollAnchor)
            : null;

        await (_db.update(
          _db.chatSessions,
        )..where((table) => table.sessionId.equals(generatedSession.id))).write(
          ChatSessionsCompanion(
            messagesJson: messagesJson != null
                ? Value(messagesJson)
                : const Value.absent(),
            sessionVarsJson: Value(sessionVarsJson),
            authorsNoteJson: Value(authorsNoteJson),
            draft: Value(updated.draft),
            lastScrollAnchorJson: Value(lastScrollAnchorJson),
            updatedAt: Value(generatedSession.updatedAt),
          ),
        );

        if (manifest != null) {
          // A durable round trip verifies all strict schema/content/hash
          // invariants before any provenance row can be written.
          final durable = ExactLorebookManifest.decodeDurable(
            manifest.toJson(),
          );
          await LorebookUseManifestRepo(_db).insertGenerationManifest(
            identity: LorebookUseGenerationIdentity(
              sessionId: updated.id,
              messageId: committed.id,
              swipeId: committed.swipeId,
              agentSwipeId: committed.agentSwipeId,
            ),
            manifest: LorebookUseManifestInput(
              manifestJson: durable.canonicalJson,
              manifestHash: durable.canonicalHash,
              manifestSchemaVersion: 1,
              finalPromptHash: durable.providerMessagesHash,
              presetSnapshotHash: durable.promptProvenance.presetSnapshotHash,
            ),
            createdAt: generatedSession.updatedAt,
            entries: [
              for (var index = 0; index < durable.entries.length; index++)
                LorebookUseManifestEntryInput(
                  lorebookId: durable.entries[index].lorebookId,
                  entryId: durable.entries[index].entryId,
                  entryOrder: index,
                  evidenceJson: jsonEncode(durable.entries[index].toJson()),
                ),
            ],
          );
        }

        // The transaction must still belong to the generation after every
        // awaited write. Throwing here rolls back the message, session vars,
        // reconciliation side effects and optional provenance together.
        if (canCommit != null && !canCommit(latest)) {
          throw const _GenerationCommitRetired();
        }

        return _toModel(
          row.copyWith(
            messagesJson: messagesJson ?? row.messagesJson,
            sessionVarsJson: Value(sessionVarsJson),
            authorsNoteJson: Value(authorsNoteJson),
            draft: Value(updated.draft),
            lastScrollAnchorJson: Value(lastScrollAnchorJson),
            updatedAt: generatedSession.updatedAt,
          ),
          messages: updated.messages,
        );
      });
    } on _GenerationCommitRetired {
      return null;
    }
  }

  static bool _sameGenerationAnchor(ChatMessage expected, ChatMessage current) {
    return expected.content == current.content &&
        expected.swipeId == current.swipeId &&
        expected.agentSwipeId == current.agentSwipeId &&
        jsonEncode(expected.swipes) == jsonEncode(current.swipes) &&
        jsonEncode(expected.swipesMeta) == jsonEncode(current.swipesMeta) &&
        jsonEncode(
              expected.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            ) ==
            jsonEncode(
              current.agentSwipes.map((swipe) => swipe.toJson()).toList(),
            );
  }

  Future<Map<String, dynamic>> updateSessionVarsJson(
    String sessionId,
    Map<String, dynamic> Function(Map<String, dynamic> vars) update,
  ) async {
    return _db.transaction(() async {
      final row = await (_db.select(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
      if (row == null) {
        throw StateError('Chat session "$sessionId" was not found');
      }

      final current = _decodeJsonMap(row.sessionVarsJson);
      final updated = update(Map<String, dynamic>.from(current));
      await (_db.update(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).write(
        ChatSessionsCompanion(
          sessionVarsJson: Value(
            updated.isNotEmpty ? jsonEncode(updated) : null,
          ),
        ),
      );
      return updated;
    });
  }

  static Map<String, String> applySessionVarDelta(
    Map<String, String> latest,
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final merged = Map<String, String>.from(latest);
    for (final key in before.keys) {
      if (!after.containsKey(key)) merged.remove(key);
    }
    for (final entry in after.entries) {
      if (before[entry.key] != entry.value) merged[entry.key] = entry.value;
    }
    return merged;
  }

  /// The typed display projection cannot represent JSON-null titles. Only
  /// explicit typed deltas may change raw storage; message/note edits must not
  /// normalize it, and generated variable deltas must preserve newer raw keys.
  String? _sessionVarsJsonWithDelta(
    String? raw,
    Map<String, String> before,
    Map<String, String> after,
  ) {
    final removed = before.keys
        .where((key) => !after.containsKey(key))
        .toList();
    final changed = after.entries
        .where(
          (entry) =>
              !before.containsKey(entry.key) ||
              before[entry.key] != entry.value,
        )
        .toList();
    if (removed.isEmpty && changed.isEmpty) return raw;
    final vars = _decodeJsonMap(raw);
    for (final key in removed) {
      vars.remove(key);
    }
    for (final entry in changed) {
      vars[entry.key] = entry.value;
    }
    return vars.isEmpty ? null : jsonEncode(vars);
  }

  @override
  Future<void> delete(String sessionId) async {
    final inventory = SessionDeletionQueries.beginInventoryMutation(_db);
    void Function()? settle;
    try {
      settle = _onMutationStarted?.call(sessionId);
      await (_db.delete(
        _db.chatSessions,
      )..where((t) => t.sessionId.equals(sessionId))).go();
    } finally {
      settle?.call();
      inventory();
    }
  }

  Future<bool> _mutateLastMessageById({
    required String sessionId,
    required String messageId,
    required ChatMessage? Function(ChatMessage message) mutate,
  }) async {
    var changed = false;
    final result = await _mutateSession(
      sessionId: sessionId,
      mutate: (session) {
        final messages = List<ChatMessage>.from(session.messages);
        for (var index = messages.length - 1; index >= 0; index--) {
          if (messages[index].id != messageId) continue;
          final updated = mutate(messages[index]);
          if (updated == null) return null;
          messages[index] = updated;
          changed = true;
          return session.copyWith(messages: messages);
        }
        return null;
      },
    );
    return changed && result != null;
  }

  /// Atomically updates a single message's content and appends a new swipe.
  ///
  /// Used by the POST-cleaner (Stage 4) to replace the assistant text while
  /// preserving the original as a swipe. Wraps the read-modify-write in a
  /// transaction so concurrent writes cannot interleave (database.md Rule 3).
  ///
  /// [messageId] — the message to update.
  /// [newContent] — the cleaned text that becomes the active content.
  /// [previousContent] — the original text, appended as the last swipe.
  /// Returns `true` if the message was found and updated.
  Future<bool> appendSwipeToMessage({
    required String sessionId,
    required String messageId,
    required String newContent,
    required String previousContent,
  }) => _mutateLastMessageById(
    sessionId: sessionId,
    messageId: messageId,
    mutate: (message) {
      final swipes = List<String>.from(message.swipes);
      // Preserve original as previous swipe, add cleaned as new swipe.
      if (swipes.isNotEmpty) swipes[swipes.length - 1] = previousContent;
      swipes.add(newContent);
      return message.copyWith(
        content: newContent,
        swipes: swipes,
        swipeId: swipes.length - 1,
      );
    },
  );

  /// Atomically appends a new green swipe carrying [cleanedText] to a
  /// message, then sets that swipe as the active content. Used by the
  /// POST-cleaner (Stage 4) to preserve the original as the previous swipe
  /// and make the cleaned text the current one. Wraps the read-modify-write
  /// in a transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message was found and updated.
  Future<bool> appendCleanerSwipe({
    required String sessionId,
    required String messageId,
    required String cleanedText,
  }) => _mutateLastMessageById(
    sessionId: sessionId,
    messageId: messageId,
    mutate: (message) {
      final swipes = List<String>.from(message.swipes);
      final swipesMeta = List<Map<String, dynamic>>.from(message.swipesMeta);
      if (swipes.isEmpty) swipes.add(message.content);
      while (swipesMeta.length < swipes.length) {
        swipesMeta.add(<String, dynamic>{});
      }
      swipes.add(cleanedText);
      swipesMeta.add(<String, dynamic>{});
      return message.copyWith(
        content: cleanedText,
        swipes: swipes,
        swipesMeta: swipesMeta,
        swipeId: swipes.length - 1,
      );
    },
  );

  /// Atomically appends a nested agent swipe ([kind]: 'cleaned' | 'final') to
  /// a message and sets it as the active agent swipe. Used by the POST-cleaner
  /// to write a blue 'cleaned' sub-swipe (preserving the original 'final' as
  /// the parent) and by Studio final-regen to write a new 'final' sub-swipe.
  ///
  /// Lazy-migrates a 'final' from the current content when the first 'cleaned'
  /// swipe is added to a message that predates the agentSwipes model. Inherits
  /// `studioOutputs` from the parent 'final' so the Studio regen button stays
  /// visible on the cleaned swipe. Wraps the read-modify-write in a
  /// transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message was found and updated.
  Future<bool> appendAgentSwipe({
    required String sessionId,
    required String messageId,
    required String content,
    required String kind,
    String? reasoning,
    String? genTime,
    int? tokens,
    List<Map<String, dynamic>> studioOutputs = const [],
  }) => _mutateLastMessageById(
    sessionId: sessionId,
    messageId: messageId,
    mutate: (message) {
      final agentSwipes = List<AgentSwipe>.from(message.agentSwipes);
      if (agentSwipes.isEmpty && kind == 'cleaned') {
        agentSwipes.add(
          AgentSwipe(
            content: message.content,
            kind: 'final',
            reasoning: message.reasoning,
            genTime: message.genTime,
            tokens: message.tokens,
            time: message.time,
            studioOutputs: message.studioOutputs,
          ),
        );
      }
      var parentSwipeId = kind == 'cleaned' && agentSwipes.isNotEmpty
          ? agentSwipes.lastIndexWhere((swipe) => swipe.kind == 'final')
          : null;
      if (kind == 'cleaned' &&
          parentSwipeId == null &&
          agentSwipes.isNotEmpty) {
        parentSwipeId = agentSwipes.length - 1;
      }
      final effectiveStudioOutputs = studioOutputs.isNotEmpty
          ? studioOutputs
          : (kind == 'cleaned' && parentSwipeId != null
                ? agentSwipes[parentSwipeId].studioOutputs
                : const <Map<String, dynamic>>[]);
      final effectiveReasoning =
          reasoning ??
          (kind == 'cleaned' && parentSwipeId != null
              ? agentSwipes[parentSwipeId].reasoning
              : null);
      final appendedSwipe = AgentSwipe(
        content: content,
        kind: kind,
        reasoning: effectiveReasoning,
        genTime: genTime,
        tokens: tokens,
        time: kind == 'cleaned' && parentSwipeId != null
            ? agentSwipes[parentSwipeId].time
            : null,
        studioOutputs: effectiveStudioOutputs,
        parentSwipeId: parentSwipeId,
      );
      agentSwipes.add(appendedSwipe);
      return message.copyWith(
        content: content,
        genTime: genTime ?? message.genTime,
        tokens: tokens ?? message.tokens,
        time: appendedSwipe.time,
        agentSwipes: agentSwipes,
        agentSwipeId: agentSwipes.length - 1,
        swipesMeta: _syncAgentSwipesToMeta(
          message.swipesMeta,
          message.swipeId,
          agentSwipes,
          agentSwipes.length - 1,
        ),
      );
    },
  );

  /// Atomically updates the content (and optional genTime/tokens) of an
  /// existing nested agent swipe in place, without appending a new one.
  ///
  /// Used by the POST-cleaner swipe-first flow (Fix 1): a blue 'cleaned' swipe
  /// is pre-created at cleaner start, the rewrite streams into the chat bubble
  /// for live preview, and on completion this method fills the pre-created
  /// swipe with the final cleaned text + per-swipe badge metadata. On cleaner
  /// failure with partial text, the same method persists the truncated
  /// partial text.
  ///
  /// When [agentSwipeId] is the active swipe for the message, the top-level
  /// `content`/`genTime`/`tokens` are also updated so the chat list and the
  /// rendered bubble reflect the new text immediately.
  ///
  /// Wraps the read-modify-write in a transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message and swipe were found and updated.
  Future<bool> updateAgentSwipeContent({
    required String sessionId,
    required String messageId,
    required int agentSwipeId,
    required String content,
    String? genTime,
    int? tokens,
  }) => _mutateLastMessageById(
    sessionId: sessionId,
    messageId: messageId,
    mutate: (message) {
      if (agentSwipeId < 0 || agentSwipeId >= message.agentSwipes.length) {
        return null;
      }
      final agentSwipes = List<AgentSwipe>.from(message.agentSwipes);
      final previous = agentSwipes[agentSwipeId];
      agentSwipes[agentSwipeId] = previous.copyWith(
        content: content,
        genTime: genTime ?? previous.genTime,
        tokens: tokens ?? previous.tokens,
      );
      final isActive = message.agentSwipeId == agentSwipeId;
      return message.copyWith(
        content: isActive ? content : message.content,
        genTime: isActive ? (genTime ?? message.genTime) : message.genTime,
        tokens: isActive ? (tokens ?? message.tokens) : message.tokens,
        agentSwipes: agentSwipes,
        swipesMeta: _syncAgentSwipesToMeta(
          message.swipesMeta,
          message.swipeId,
          agentSwipes,
          message.agentSwipeId,
        ),
      );
    },
  );

  /// Atomically removes a nested agent swipe and resets the active swipe to
  /// the last remaining one (typically the parent 'final'). Used by the
  /// POST-cleaner swipe-first flow (Fix 1) when the cleaner wrote nothing at
  /// all on failure — the pre-created empty 'cleaned' swipe is deleted and the
  /// UI reverts to the original 'final' text.
  ///
  /// After removal, the active [agentSwipeId] is clamped to the last remaining
  /// swipe, and the top-level `content`/`genTime`/`tokens` are restored from
  /// that swipe so the bubble shows the original text. Does NOT remove the
  /// last remaining swipe (preserves the parent 'final').
  ///
  /// Wraps the read-modify-write in a transaction (database.md Rule 3).
  ///
  /// Returns `true` if the message and swipe were found and removed.
  Future<bool> removeAgentSwipe({
    required String sessionId,
    required String messageId,
    required int agentSwipeId,
  }) => _mutateLastMessageById(
    sessionId: sessionId,
    messageId: messageId,
    mutate: (message) {
      if (agentSwipeId < 0 ||
          agentSwipeId >= message.agentSwipes.length ||
          message.agentSwipes.length <= 1) {
        return null;
      }
      final agentSwipes = List<AgentSwipe>.from(message.agentSwipes)
        ..removeAt(agentSwipeId);
      final newActiveId = message.agentSwipeId >= agentSwipes.length
          ? agentSwipes.length - 1
          : (message.agentSwipeId > agentSwipeId
                ? message.agentSwipeId - 1
                : message.agentSwipeId);
      final active = agentSwipes[newActiveId];
      return message.copyWith(
        content: active.content,
        genTime: active.genTime,
        tokens: active.tokens,
        time: active.time,
        agentSwipes: agentSwipes,
        agentSwipeId: newActiveId,
        swipesMeta: _syncAgentSwipesToMeta(
          message.swipesMeta,
          message.swipeId,
          agentSwipes,
          newActiveId,
        ),
      );
    },
  );

  /// Sync [agentSwipes] + [agentSwipeId] into `swipesMeta[swipeId]` so that
  /// green-swipe round-trips preserve agent swipes even without an explicit
  /// `setSwipe` navigation-away. This eliminates the dual-storage mismatch
  /// where `appendAgentSwipe` wrote only the top-level field.
  static List<Map<String, dynamic>> _syncAgentSwipesToMeta(
    List<Map<String, dynamic>> swipesMeta,
    int swipeId,
    List<AgentSwipe> agentSwipes,
    int agentSwipeId,
  ) {
    if (swipeId < 0) return swipesMeta;
    final meta = List<Map<String, dynamic>>.from(swipesMeta);
    while (meta.length <= swipeId) {
      meta.add(<String, dynamic>{});
    }
    meta[swipeId] = {
      ...meta[swipeId],
      'agentSwipes': agentSwipes.map((e) => e.toJson()).toList(),
      'agentSwipeId': agentSwipeId,
    };
    return meta;
  }

  /// Deletes all sessions belonging to [characterId], along with all per-session
  /// dependent data (memory books, summaries). Returns the deleted session IDs
  /// for sync-deletion tracking.
  Future<List<String>> deleteByCharacterId(String characterId) async {
    final inventory = SessionDeletionQueries.beginInventoryMutation(_db);
    final settlements = <void Function()>[];
    try {
      return await _db.transaction(() async {
        final rows = await (_db.select(
          _db.chatSessions,
        )..where((t) => t.characterId.equals(characterId))).get();
        final ids = rows.map((r) => r.sessionId).toList();
        for (final id in ids) {
          final settle = _onMutationStarted?.call(id);
          if (settle != null) settlements.add(settle);
        }
        final deletion = SessionDeletionQueries(_db);
        for (final id in ids) {
          await deletion.deleteSessionRows(id);
        }
        return ids;
      });
    } finally {
      for (final settle in settlements.reversed) {
        settle();
      }
      inventory();
    }
  }

  SessionMetadata _projectedMetadata(QueryRow row) {
    // Offsets are Dart UTF-16 positions, not SQLite character positions. Keep
    // continuation slicing here so emoji before the boundary remain correct.
    var lastContent = previewSource(
      row.readNullable<String>('last_content') ?? '',
      row.readNullable<int>('continuation_offset'),
    );
    if (lastContent.length > 250) {
      lastContent = lastContent.substring(0, 250);
    }
    final branchedAt = int.tryParse(
      row.readNullable<String>('branched_at') ?? '',
    );
    final firstTimestamp = row.readNullable<int>('first_timestamp') ?? 0;
    final hasBranchTimestamp = branchedAt != null && branchedAt > 0;
    return SessionMetadata(
      sessionId: row.read<String>('session_id'),
      characterId: row.read<String>('character_id'),
      sessionIndex: row.read<int>('session_index'),
      updatedAt: normalizeTimestampSeconds(row.read<int>('updated_at')),
      messageCount: row.readNullable<int>('message_count') ?? 0,
      lastMessageContent: lastContent,
      lastMessageTimestamp: row.readNullable<int>('last_timestamp') ?? 0,
      sessionName: row.readNullable<String>('session_name'),
      originTimestamp: hasBranchTimestamp ? branchedAt : firstTimestamp,
      originKind: hasBranchTimestamp
          ? 'branched'
          : firstTimestamp > 0
          ? 'created'
          : null,
    );
  }

  ChatSession _toModel(ChatSessionRow c, {List<ChatMessage>? messages}) =>
      ChatSession(
        id: c.sessionId,
        characterId: c.characterId,
        sessionIndex: c.sessionIndex,
        messages:
            messages ??
            (jsonDecode(c.messagesJson) as List)
                .map((e) => ChatMessage.fromJson(e as Map<String, dynamic>))
                .toList(),
        updatedAt: normalizeTimestampSeconds(c.updatedAt),
        sessionVars: _modelSessionVars(c.sessionVarsJson),
        authorsNote: _parseAuthorsNote(c.authorsNoteJson),
        draft: c.draft,
        lastScrollAnchor:
            c.lastScrollAnchorJson != null && c.lastScrollAnchorJson!.isNotEmpty
            ? Map<String, dynamic>.from(
                jsonDecode(c.lastScrollAnchorJson!) as Map,
              )
            : {},
      );

  Future<List<ChatSession>> _materializeSessions(
    List<ChatSessionRow> rows,
  ) async {
    final storage = await _messageStorage.loadMany(rows);
    return [
      for (final row in rows)
        _toModel(row, messages: storage[row.sessionId]!.materialized),
    ];
  }

  ChatSessionsCompanion _toCompanion(
    ChatSession m, {
    bool includeMessages = true,
  }) => ChatSessionsCompanion(
    sessionId: Value(m.id),
    characterId: Value(m.characterId),
    sessionIndex: Value(m.sessionIndex),
    messagesJson: includeMessages
        ? Value(jsonEncode(m.messages.map((e) => e.toJson()).toList()))
        : const Value('[]'),
    updatedAt: Value(normalizeTimestampSeconds(m.updatedAt)),
    sessionVarsJson: Value(
      m.sessionVars.isNotEmpty ? jsonEncode(m.sessionVars) : null,
    ),
    authorsNoteJson: Value(
      m.authorsNote != null ? jsonEncode(m.authorsNote!.toJson()) : null,
    ),
    draft: Value(m.draft),
    lastScrollAnchorJson: Value(
      m.lastScrollAnchor.isNotEmpty ? jsonEncode(m.lastScrollAnchor) : null,
    ),
  );

  AuthorsNote? _parseAuthorsNote(String? json) {
    if (json == null || json.isEmpty) return null;
    try {
      final decoded = jsonDecode(json);
      if (decoded is String) {
        return AuthorsNote(content: decoded);
      }
      if (decoded is Map<String, dynamic>) {
        return AuthorsNote.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  Map<String, dynamic> _decodeJsonMap(String? text) {
    if (text == null || text.isEmpty) return <String, dynamic>{};
    try {
      final decoded = jsonDecode(text);
      if (decoded is Map) return Map<String, dynamic>.from(decoded);
    } catch (_) {}
    return <String, dynamic>{};
  }
}

/// Decoding and encoding a long chat history is CPU-bound. Keep it out of the
/// UI isolate. Callers do this before opening a short compare-and-swap
/// transaction so an isolate delay cannot occupy the database executor.
Future<_PreparedUserMessageAppend> _prepareUserMessageAppend(
  String messagesJson,
  ChatMessage message,
) => Isolate.run(
  () => _decodeAndAppendUserMessage(messagesJson, message.toJson()),
);

Future<_PreparedUserMessageAppend?> _prepareAcceptedUserMessageAppend({
  required String messagesJson,
  required ChatMessage message,
  required LorebookUseGenerationIdentity expectedPrecedingAssistant,
}) => Isolate.run(
  () => _decodeAndAppendAcceptedUserMessage(
    messagesJson,
    message.toJson(),
    expectedPrecedingAssistant.messageId,
    expectedPrecedingAssistant.swipeId,
    expectedPrecedingAssistant.agentSwipeId,
  ),
);

_PreparedUserMessageAppend _decodeAndAppendUserMessage(
  String messagesJson,
  Map<String, dynamic> messageJson,
) {
  final messages = _decodeChatMessages(messagesJson)
    ..add(ChatMessage.fromJson(messageJson));
  return _PreparedUserMessageAppend(
    messagesJson: jsonEncode(
      messages.map((message) => message.toJson()).toList(),
    ),
    messages: messages,
  );
}

_PreparedUserMessageAppend? _decodeAndAppendAcceptedUserMessage(
  String messagesJson,
  Map<String, dynamic> messageJson,
  String expectedMessageId,
  int expectedSwipeId,
  int expectedAgentSwipeId,
) {
  final messages = _decodeChatMessages(messagesJson);
  final message = ChatMessage.fromJson(messageJson);
  if (messages.any((existing) => existing.id == message.id)) {
    return _PreparedUserMessageAppend(
      messagesJson: messagesJson,
      messages: messages,
      didAppend: false,
    );
  }

  // A user send accepts only the assistant immediately before it, never an
  // older assistant found by scanning history after a concurrent change.
  final preceding = messages.isNotEmpty ? messages.last : null;
  if (preceding == null ||
      preceding.role != 'assistant' ||
      preceding.id != expectedMessageId ||
      preceding.swipeId != expectedSwipeId ||
      preceding.agentSwipeId != expectedAgentSwipeId) {
    return null;
  }

  messages.add(message);
  return _PreparedUserMessageAppend(
    messagesJson: jsonEncode(messages.map((item) => item.toJson()).toList()),
    messages: messages,
  );
}

List<ChatMessage> _decodeChatMessages(String messagesJson) =>
    (jsonDecode(messagesJson) as List<dynamic>)
        .map((entry) => ChatMessage.fromJson(entry as Map<String, dynamic>))
        .toList();
