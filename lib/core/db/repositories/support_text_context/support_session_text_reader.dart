part of '../support_text_context_repo.dart';

/// Exact encrypted own parent, native complete rows strictly before the captured
/// user. No role/status heuristic is used to omit the current input/reply.
final class _SupportSessionTextReader {
  const _SupportSessionTextReader(this._reader);
  final _SupportTextReader _reader;

  Future<(_TextRead, List<String>)> read(
    _OwnedSessionHistoryBoundary boundary,
    SecretRedactor Function() currentRedactor, {
    void Function()? checkpoint,
  }) async {
    final current = await _sessionBoundaryRow(
      _reader.db,
      boundary._sessionId,
      boundary._messageId,
      boundary._runId,
      checkpoint: checkpoint,
    );
    checkpoint?.call();
    if (!_sameValues(current.data, boundary._metadata)) {
      _fail(SupportTextContextFailure.stale);
    }
    final empty = await _reader.read(
      boundary._sessionId,
      const [],
      checkpoint: checkpoint,
    );
    checkpoint?.call();
    final rows = await _reader.db
        .customSelect(
          '''
      SELECT rowid AS native_identity,
        CASE WHEN typeof(id) = 'text' AND length(id) BETWEEN 1 AND 256
          THEN id END AS id,
        CASE WHEN typeof(created_at) = 'integer' AND created_at BETWEEN 0 AND 8640000000000
          THEN created_at END AS created_at,
        CASE WHEN typeof(role) = 'text' AND role IN ('user', 'assistant', 'system')
          AND typeof(status) = 'text' AND length(status) BETWEEN 1 AND 64
          AND (run_id IS NULL OR (typeof(run_id) = 'text' AND length(run_id) BETWEEN 1 AND 256))
          THEN 1 ELSE 0 END AS shape_valid,
        CASE WHEN created_at < ? OR (created_at = ? AND id < ?)
          THEN 1 ELSE 0 END AS before_current,
        CASE WHEN status = 'complete' THEN 1 ELSE 0 END AS complete
      FROM support_messages WHERE session_id = ?
      ORDER BY created_at ASC, id ASC
      LIMIT ${SupportTextContextRepo.maxSourceMessages + 1}
    ''',
          variables: [
            Variable.withInt(boundary._createdAt),
            Variable.withInt(boundary._createdAt),
            Variable.withString(boundary._messageId),
            Variable.withString(boundary._sessionId),
          ],
        )
        .get();
    checkpoint?.call();
    if (rows.length > SupportTextContextRepo.maxSourceMessages) {
      _fail(SupportTextContextFailure.limited);
    }
    final allIds = <String>{};
    final ids = <String>[];
    for (final row in rows) {
      final id = row.readNullable<String>('id');
      if (id == null ||
          !_identity(id, currentRedactor()) ||
          !allIds.add(id) ||
          row.readNullable<int>('created_at') == null ||
          row.read<int>('shape_valid') != 1) {
        _fail(SupportTextContextFailure.unavailable);
      }
      if (row.read<int>('before_current') == 1 &&
          row.read<int>('complete') == 1) {
        ids.add(id);
      }
    }
    if (ids.length > SupportTextContextRepo.maxSelections) {
      _fail(SupportTextContextFailure.limited);
    }
    final read = ids.isEmpty
        ? empty
        : await _reader.read(boundary._sessionId, ids, checkpoint: checkpoint);
    checkpoint?.call();
    return (
      _TextRead._session(read, [current, ...rows]),
      List<String>.unmodifiable(ids),
    );
  }
}
