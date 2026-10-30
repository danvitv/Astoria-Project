part of 'chat_repo.dart';

/// Opaque original native source. No JSON importer, bodies or fingerprints are
/// exposed. The repair repository remains the owner of full head/revision CAS.
final class ChatNativeMaintenanceSource {
  ChatNativeMaintenanceSource._(
    this._db,
    this.sessionId,
    this.characterId,
    this._session,
    this._collectors,
  );
  final AppDatabase _db;
  final String sessionId, characterId;
  final Map<String, Object?> _session;
  final List<Map<String, Object?>> _collectors;
  bool sameOriginal(ChatNativeMaintenanceSource other) =>
      identical(_db, other._db) &&
      sessionId == other.sessionId &&
      characterId == other.characterId &&
      jsonEncode(_session) == jsonEncode(other._session) &&
      jsonEncode(_collectors) == jsonEncode(other._collectors);
  @override
  String toString() => 'ChatNativeMaintenanceSource(protected)';
}

/// Finite session-source metadata ownership, DB-only and strictly read-only.
/// Related actor absence is part of this session's native maintenance contract,
/// not a public table/path query. Unknown, expired claims and stored leases are
/// never guessed idle or repaired by this reader.
final class _ChatNativeMaintenanceReader {
  const _ChatNativeMaintenanceReader(this.db);
  final AppDatabase db;
  Future<ChatNativeMaintenanceSource?> read(
    String id,
    bool Function() current,
  ) async {
    if (!current() || id.isEmpty || id.length > 96) return null;
    try {
      final rowSize = db.chatSessions.$columns
          .map((column) => 'coalesce(length(CAST("${column.name}" AS BLOB)),0)')
          .join(' + ');
      final size = await db
          .customSelect(
            'SELECT ($rowSize) AS bytes '
            'FROM chat_sessions WHERE session_id IS ? COLLATE BINARY LIMIT 2',
            variables: [Variable<String>(id)],
            readsFrom: {db.chatSessions},
          )
          .get();
      if (!current() ||
          size.length != 1 ||
          size.single.data['bytes'] is! int ||
          (size.single.data['bytes'] as int) > 65536) {
        return null;
      }
      final rows = await db
          .customSelect(
            'SELECT * FROM chat_sessions WHERE session_id IS ? COLLATE BINARY '
            'AND ($rowSize) <= 65536 LIMIT 2',
            variables: [Variable<String>(id)],
            readsFrom: {db.chatSessions},
          )
          .get();
      if (!current() || rows.length != 1) return null;
      final session = rows.single.data;
      for (final column in db.chatSessions.$columns) {
        final value = session[column.name];
        if (value == null
            ? !column.$nullable
            : column.type == DriftSqlType.string
            ? value is! String
            : column.type == DriftSqlType.double
            ? value is! num || !value.isFinite
            : value is! int ||
                  (column.type == DriftSqlType.bool &&
                      value != 0 &&
                      value != 1)) {
          return null;
        }
      }
      final char = session['character_id'];
      if (session['session_id'] != id ||
          char is! String ||
          char.isEmpty ||
          char.length > 96 ||
          session['session_index'] is! int ||
          (session['session_index'] as int) < 0 ||
          session['updated_at'] is! int ||
          (session['updated_at'] as int) < 0 ||
          session['messages_json'] is! String) {
        return null;
      }
      final messages = jsonDecode(session['messages_json'] as String);
      if (messages is! List) return null;
      final ids = <String>{};
      for (final message in messages) {
        if (message is! Map<String, dynamic> ||
            message['id'] is! String ||
            (message['id'] as String).isEmpty ||
            !ids.add(message['id'] as String) ||
            message['role'] is! String ||
            message['content'] is! String) {
          return null;
        }
      }
      for (final field in [
        'session_vars_json',
        'authors_note_json',
        'last_scroll_anchor_json',
      ]) {
        final raw = session[field];
        if (raw != null &&
            (raw is! String || jsonDecode(raw) is! Map<String, dynamic>)) {
          return null;
        }
      }
      final characters = await db
          .customSelect(
            'SELECT 1 AS present FROM characters WHERE char_id IS ? COLLATE BINARY LIMIT 2',
            variables: [Variable<String>(char)],
            readsFrom: {db.characters},
          )
          .get();
      if (!current() || characters.length != 1) return null;
      // A stored owner is not proof of a dead job, regardless of lease expiry.
      // Fetch at most one scalar from each finite related actor store; do not
      // hydrate prompts, evidence, values, calls or tolerant legacy DTOs.
      for (final spec in <(TableInfo<Table, dynamic>, String)>[
        (db.cardEvolutionClaims, 'session_id'),
        (db.cardEvolutionProposalRuns, 'session_id'),
        (db.cardEvolutionWriterCalls, 'session_id'),
        (db.rewriteJobs, 'chat_session_id'),
        (db.rewriteOperations, 'chat_session_id'),
        (db.ledgerReconciliationLeases, 'session_id'),
      ]) {
        final actors = await db
            .customSelect(
              'SELECT 1 AS present FROM "${spec.$1.actualTableName}" '
              'WHERE "${spec.$2}" IS ? COLLATE BINARY LIMIT 1',
              variables: [Variable<String>(id)],
              readsFrom: {spec.$1},
            )
            .get();
        if (!current() || actors.isNotEmpty) return null;
      }
      final collectors = await db
          .customSelect(
            'SELECT CASE WHEN length(CAST(id AS BLOB)) <= 96 THEN id END AS id, '
            'CASE WHEN length(CAST(character_id AS BLOB)) <= 96 THEN character_id END AS character_id, '
            'CASE WHEN length(CAST(status AS BLOB)) <= 16 THEN status END AS status, '
            'CASE WHEN length(CAST(owner_id AS BLOB)) <= 96 THEN owner_id END AS owner_id, lease_expires_at, '
            'collector_ordinal FROM card_evolution_collector_runs '
            'WHERE session_id IS ? COLLATE BINARY ORDER BY collector_ordinal LIMIT 65',
            variables: [Variable<String>(id)],
            readsFrom: {db.cardEvolutionCollectorRuns},
          )
          .get();
      if (!current() || collectors.length > 64) return null;
      for (final row in collectors) {
        final data = row.data;
        if (data['id'] is! String ||
            (data['id'] as String).isEmpty ||
            data['character_id'] != char ||
            data['owner_id'] is! String ||
            !RegExp(
              r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,95}$',
            ).hasMatch(data['owner_id'] as String) ||
            !const {'failed', 'completed'}.contains(data['status']) ||
            data['lease_expires_at'] is! int ||
            (data['lease_expires_at'] as int) < 0 ||
            data['collector_ordinal'] is! int ||
            (data['collector_ordinal'] as int) <= 0 ||
            (data['status'] == 'failed' && data['lease_expires_at'] != 0)) {
          return null;
        }
      }
      final blocks = await db
          .customSelect(
            'SELECT CASE WHEN length(CAST(status AS BLOB)) <= 16 THEN status END AS status '
            'FROM info_blocks WHERE session_id IS ? COLLATE BINARY LIMIT 65',
            variables: [Variable<String>(id)],
            readsFrom: {db.infoBlocks},
          )
          .get();
      if (!current() ||
          blocks.length > 64 ||
          blocks.any(
            (row) => !const {
              'done',
              'error',
              'stopped',
            }.contains(row.data['status']),
          )) {
        return null;
      }
      return ChatNativeMaintenanceSource._(
        db,
        id,
        char,
        Map.unmodifiable(session),
        List.unmodifiable(
          collectors.map((r) => Map<String, Object?>.unmodifiable(r.data)),
        ),
      );
    } catch (_) {
      // Closed DB, invalid raw types/JSON and incomplete/unknown source all deny.
      return null;
    }
  }
}
