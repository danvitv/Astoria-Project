// Named public injection intentionally initializes the private hook.
// ignore_for_file: prefer_initializing_formals

import 'dart:convert';

import 'package:drift/drift.dart';

import '../../application/session_deletion_store.dart';
import '../../models/chat_message.dart';
import '../app_db.dart';
import 'session_deletion_queries.dart';
import 'card_evolution_proposal_run_repo.dart';

class SessionDeletionRepo implements SessionDeletionStore {
  final AppDatabase _db;
  final SessionMutationStarted? _onMutationStarted;

  SessionDeletionRepo(this._db, {SessionMutationStarted? onMutationStarted})
    : _onMutationStarted = onMutationStarted;

  @override
  Future<void> deleteSession(String sessionId) async {
    final inventory = SessionDeletionQueries.beginInventoryMutation(_db);
    void Function()? settle;
    try {
      settle = _onMutationStarted?.call(sessionId);
      await _db.transaction(
        () => SessionDeletionQueries(_db).deleteSessionRows(sessionId),
      );
    } finally {
      settle?.call();
      inventory();
    }
  }

  Future<ChatSession?> clearSession({
    required String sessionId,
    required List<ChatMessage> replacementMessages,
    bool resetBranchStamp = false,
    bool countDeletedMessages = false,
  }) async {
    final settle = _onMutationStarted?.call(sessionId);
    try {
      return await _db.transaction(() async {
        final row =
            await (_db.select(_db.chatSessions)
                  ..where((table) => table.sessionId.equals(sessionId)))
                .getSingleOrNull();
        if (row == null) return null;

        final existingMessages = (jsonDecode(row.messagesJson) as List<dynamic>)
            .map((item) => ChatMessage.fromJson(item as Map<String, dynamic>))
            .toList();
        final sessionVars = row.sessionVarsJson == null
            ? <String, dynamic>{}
            : Map<String, dynamic>.from(
                jsonDecode(row.sessionVarsJson!) as Map,
              );
        if (resetBranchStamp) sessionVars.remove('branchedAt');
        if (countDeletedMessages) {
          final previous =
              int.tryParse(
                sessionVars[ChatSessionX.deletedMessagesVarKey] as String? ??
                    '',
              ) ??
              0;
          sessionVars[ChatSessionX.deletedMessagesVarKey] =
              (previous + existingMessages.length).toString();
        }

        final messagesJson = jsonEncode(
          replacementMessages.map((message) => message.toJson()).toList(),
        );
        final sessionVarsJson = !resetBranchStamp && !countDeletedMessages
            ? row.sessionVarsJson
            : sessionVars.isEmpty
            ? null
            : jsonEncode(sessionVars);
        await CardEvolutionProposalRunRepo(
          _db,
        ).cancelPendingForMessageMutationInTransaction(
          sessionId: sessionId,
          messageIds: existingMessages
              .map((message) => message.id)
              .where((id) => id.isNotEmpty)
              .toSet(),
        );
        await (_db.update(
          _db.chatSessions,
        )..where((table) => table.sessionId.equals(sessionId))).write(
          ChatSessionsCompanion(
            messagesJson: Value(messagesJson),
            sessionVarsJson: Value(sessionVarsJson),
          ),
        );
        await SessionDeletionQueries(_db).deleteMessageDerivedRows(
          sessionId: sessionId,
          characterId: row.characterId,
          preserveMemoryBookSettings: true,
        );

        return ChatSession(
          id: row.sessionId,
          characterId: row.characterId,
          sessionIndex: row.sessionIndex,
          messages: replacementMessages,
          updatedAt: row.updatedAt,
          // Display projection only; keep JSON-null in the durable raw map.
          sessionVars: Map<String, String>.from({
            for (final entry in sessionVars.entries)
              if (entry.key != 'sessionName' || entry.value != null)
                entry.key: entry.value,
          }),
          authorsNote: _parseAuthorsNote(row.authorsNoteJson),
          draft: row.draft,
          lastScrollAnchor: row.lastScrollAnchorJson == null
              ? const {}
              : Map<String, dynamic>.from(
                  jsonDecode(row.lastScrollAnchorJson!) as Map,
                ),
        );
      });
    } finally {
      settle?.call();
    }
  }

  AuthorsNote? _parseAuthorsNote(String? value) {
    if (value == null || value.isEmpty) return null;
    final decoded = jsonDecode(value);
    return decoded is String
        ? AuthorsNote(content: decoded)
        : AuthorsNote.fromJson(decoded as Map<String, dynamic>);
  }
}
