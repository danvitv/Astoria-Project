part of '../support_repo.dart';

/// Native opaque observation; never serialized as send authority.
final class SupportCompactionSource {
  const SupportCompactionSource._(
    this._ownerDb,
    this.sessionId,
    this.endMessageId,
    this.endCreatedAt,
    this.digest,
    this.count,
    this.stamp,
    this.previous,
  );
  final String sessionId, endMessageId, digest;
  final AppDatabase _ownerDb;
  final int endCreatedAt, count;
  final (int, int) stamp;
  final SupportContextBlock? previous;
}

final class SupportCompactionCheckpoint {
  const SupportCompactionCheckpoint._(
    this.block,
    this.source,
    this.lineageJson,
  );
  final SupportContextBlock block;
  final SupportCompactionSource source;
  final String lineageJson;
  String get endMessageId => source.endMessageId;
  int get endCreatedAt => source.endCreatedAt;
}

/// Encrypted existing context storage, fixed namespace, no schema migration.
/// Prefix ciphertext is hashed in bounded pages, never decrypted or cached.
extension SupportCompactionStore on SupportRepo {
  static String checkpointId(String session) => 'support.compaction:$session';

  Future<(int, int)> _compactStamp() async {
    final row = await _context.db
        .customSelect(
          'SELECT total_changes() AS n, data_version AS v FROM pragma_data_version',
        )
        .getSingle();
    return (row.read<int>('n'), row.read<int>('v'));
  }

  Future<SupportCompactionSource?> captureCompactionSource({
    required String sessionId,
    required String endMessageId,
    required bool Function() isCurrent,
  }) => _context.db.transaction(() async {
    if (!isCurrent()) return null;
    final stamp = await _compactStamp();
    final parent = await _context.sessions.requireParent(sessionId);
    if (!isCurrent()) return null;
    final identity = await _context.db
        .customSelect(
          'SELECT rowid AS n FROM support_sessions WHERE id = ?',
          variables: [Variable.withString(sessionId)],
        )
        .getSingle();
    if (!isCurrent()) return null;
    final end = await _context.db
        .customSelect(
          "SELECT created_at FROM support_messages WHERE session_id = ? AND id = ? "
          "AND role = 'assistant' AND status IN ('complete','limited','stopped','error')",
          variables: [
            Variable.withString(sessionId),
            Variable.withString(endMessageId),
          ],
        )
        .getSingleOrNull();
    if (end == null || !isCurrent()) return null;
    final at = end.read<int>('created_at');
    var digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              sessionId,
              parent.createdAt,
              identity.read<int>('n'),
              endMessageId,
              at,
            ]),
          ),
        )
        .toString();
    var count = 0, cursorAt = -1;
    var cursorId = '';
    while (true) {
      final rows = await _context.db
          .customSelect(
            '''
        SELECT m.rowid AS native_identity, m.id, m.created_at, m.role,
          m.status, m.run_id,
          CASE WHEN length(m.body_ciphertext) <= 350000 THEN m.body_ciphertext END AS body,
          p.rowid AS provenance_identity, p.start_message_id, p.end_message_id,
          p.is_active, p.created_at AS provenance_at,
          CASE WHEN length(p.protected_facts_ciphertext) <= 350000
            THEN p.protected_facts_ciphertext END AS facts,
          length(p.protected_facts_ciphertext) AS facts_length
        FROM support_messages m LEFT JOIN support_context_blocks p
          ON p.id = 'support.reply_provenance:' || m.id AND p.session_id = m.session_id
        WHERE m.session_id = ?
          AND (m.created_at < ? OR (m.created_at = ? AND m.id <= ?))
          AND (m.created_at > ? OR (m.created_at = ? AND m.id > ?))
        ORDER BY m.created_at, m.id LIMIT 16
      ''',
            variables: [
              Variable.withString(sessionId),
              Variable.withInt(at),
              Variable.withInt(at),
              Variable.withString(endMessageId),
              Variable.withInt(cursorAt),
              Variable.withInt(cursorAt),
              Variable.withString(cursorId),
            ],
          )
          .get();
      if (!isCurrent()) return null;
      for (final row in rows) {
        if (++count > 100000 ||
            row.data['body'] == null ||
            (row.data['facts_length'] != null && row.data['facts'] == null)) {
          throw StateError('Compaction source exceeds its bounded projection.');
        }
        digest = sha256
            .convert(utf8.encode(jsonEncode([digest, row.data])))
            .toString();
        cursorAt = row.read<int>('created_at');
        cursorId = row.read<String>('id');
      }
      if (rows.length < 16) break;
    }
    final previous = await _context.get(checkpointId(sessionId));
    if (!isCurrent() || await _compactStamp() != stamp) return null;
    return SupportCompactionSource._(
      _context.db,
      sessionId,
      endMessageId,
      at,
      digest,
      count,
      stamp,
      previous,
    );
  });

  Future<SupportCompactionCheckpoint?> readCompactionCheckpoint({
    required String sessionId,
    required bool Function() isCurrent,
  }) async {
    final raw = await _context.row(checkpointId(sessionId));
    if (!isCurrent() || raw == null) return null;
    if (raw.summaryCiphertext.length > 50000 ||
        raw.protectedFactsCiphertext.length > 350000) {
      throw StateError('Compaction checkpoint exceeds its storage bound.');
    }
    final block = await _context.mapper.context(raw);
    if (!isCurrent() ||
        block.isLocked ||
        !block.isActive ||
        block.sessionId != sessionId ||
        block.summary.isEmpty ||
        block.summary.length > 8192 ||
        block.protectedFactsJson.length > 200000) {
      throw StateError('Compaction checkpoint unavailable.');
    }
    final facts = jsonDecode(block.protectedFactsJson);
    if (facts is! Map<String, dynamic> ||
        facts.length != 6 ||
        jsonEncode(facts) != block.protectedFactsJson ||
        facts['version'] != 1 ||
        facts['digest'] is! String ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(facts['digest'] as String) ||
        facts['count'] is! int ||
        facts['endCreatedAt'] is! int ||
        facts['lineage'] is! String ||
        facts['endMessageId'] != block.endMessageId) {
      throw StateError('Compaction checkpoint malformed.');
    }
    final source = await captureCompactionSource(
      sessionId: sessionId,
      endMessageId: block.endMessageId,
      isCurrent: isCurrent,
    );
    if (!isCurrent()) return null;
    if (source == null ||
        source.digest != facts['digest'] ||
        source.count != facts['count'] ||
        source.endCreatedAt != facts['endCreatedAt'] ||
        source.previous != block) {
      throw StateError('Compaction prefix changed.');
    }
    return SupportCompactionCheckpoint._(
      block,
      source,
      facts['lineage'] as String,
    );
  }

  /// Exact source + previous checkpoint CAS, including encryption awaits. A
  /// stale/failed/cancelled candidate never replaces a valid checkpoint.
  Future<SupportCompactionCheckpoint?> installCompactionCheckpoint({
    required SupportCompactionSource expected,
    required String summary,
    required String lineageJson,
    required int createdAt,
    required bool Function() isCurrent,
  }) => _context.db.transaction(() async {
    if (!identical(expected._ownerDb, _context.db) ||
        !isCurrent() ||
        summary.isEmpty ||
        summary.length > 8192 ||
        lineageJson.length > 65536 ||
        await _compactStamp() != expected.stamp)
      return null;
    final fresh = await captureCompactionSource(
      sessionId: expected.sessionId,
      endMessageId: expected.endMessageId,
      isCurrent: isCurrent,
    );
    if (!isCurrent() ||
        fresh == null ||
        fresh.digest != expected.digest ||
        fresh.count != expected.count ||
        fresh.previous != expected.previous)
      return null;
    final block = await _context.write(
      SupportContextBlock(
        id: checkpointId(expected.sessionId),
        sessionId: expected.sessionId,
        startMessageId: expected.endMessageId,
        endMessageId: expected.endMessageId,
        summary: summary,
        createdAt: createdAt,
        protectedFactsJson: jsonEncode({
          'version': 1,
          'digest': expected.digest,
          'count': expected.count,
          'endMessageId': expected.endMessageId,
          'endCreatedAt': expected.endCreatedAt,
          'lineage': lineageJson,
        }),
      ),
      isCurrent: isCurrent,
      requireReadableResult: true,
    );
    return SupportCompactionCheckpoint._(block, expected, lineageJson);
  });

  /// Bounded body-free membership proof for old recipe references. The caller
  /// must have validated this checkpoint's complete ciphertext prefix first.
  Future<Map<String, ({String role, String? runId, int order})>>
  compactionMembers({
    required SupportCompactionCheckpoint checkpoint,
    required List<String> messageIds,
    required bool Function() isCurrent,
  }) async {
    if (!identical(checkpoint.source._ownerDb, _context.db) ||
        messageIds.length > 4096) {
      throw StateError('Compaction membership bound/owner.');
    }
    final result = <String, ({String role, String? runId, int order})>{};
    for (var i = 0; i < messageIds.length; i += 128) {
      final ids = messageIds.skip(i).take(128).toList();
      final rows = await _context.db
          .customSelect(
            '''
        WITH ordered AS (SELECT id, role, run_id, created_at,
          ROW_NUMBER() OVER (ORDER BY created_at, id) AS n
          FROM support_messages WHERE session_id = ?)
        SELECT * FROM ordered WHERE id IN (${List.filled(ids.length, '?').join(',')})
          AND (created_at < ? OR (created_at = ? AND id <= ?))
      ''',
            variables: [
              Variable.withString(checkpoint.source.sessionId),
              ...ids.map(Variable.withString),
              Variable.withInt(checkpoint.endCreatedAt),
              Variable.withInt(checkpoint.endCreatedAt),
              Variable.withString(checkpoint.endMessageId),
            ],
          )
          .get();
      if (!isCurrent()) throw StateError('Compaction source retired.');
      for (final row in rows) {
        result[row.read<String>('id')] = (
          role: row.read<String>('role'),
          runId: row.readNullable<String>('run_id'),
          order: row.read<int>('n'),
        );
      }
    }
    return Map.unmodifiable(result);
  }
}
