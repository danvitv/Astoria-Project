part of '../support_text_context_repo.dart';

/// Reads only the uncompacted suffix; never loads old bodies to truncate them.
final class _SupportCompactedTextReader {
  const _SupportCompactedTextReader(this.reader);
  final _SupportTextReader reader;

  Future<(_TextRead, List<String>)> read(
    _WholeSessionSpec spec,
    SecretRedactor Function() redactor, {
    void Function()? checkpoint,
  }) async {
    final compact = spec._compaction;
    if (compact != null) {
      final restored = await SupportRepo(reader.db, reader.cipher)
          .readCompactionCheckpoint(
            sessionId: spec._sessionId,
            isCurrent: () {
              checkpoint?.call();
              return true;
            },
          );
      checkpoint?.call();
      if (restored == null ||
          restored.block != compact.block ||
          restored.source.digest != compact.source.digest) {
        _fail(SupportTextContextFailure.stale);
      }
    }
    final boundary = spec._boundary;
    QueryRow? current;
    if (boundary != null) {
      current = await _sessionBoundaryRow(
        reader.db,
        spec._sessionId,
        boundary._messageId,
        boundary._runId,
        checkpoint: checkpoint,
      );
      if (!_sameValues(current.data, boundary._metadata)) {
        _fail(SupportTextContextFailure.stale);
      }
    }
    final rows = await reader.db
        .customSelect(
          '''
      SELECT rowid AS native_identity, id, role, status, run_id, created_at,
        length(body_ciphertext) AS envelope_length
      FROM support_messages WHERE session_id = ?
      ${compact == null ? '' : 'AND (created_at > ? OR (created_at = ? AND id > ?))'}
      ${boundary == null ? '' : 'AND (created_at < ? OR (created_at = ? AND id < ?))'}
      ${spec._compactionBatch ? "AND role IN ('user','assistant') AND status IN ('complete','limited','stopped','error')" : ''}
      ORDER BY created_at, id LIMIT ${spec._compactionBatch ? 33 : SupportTextContextRepo.maxSourceMessages + 1}
    ''',
          variables: [
            Variable.withString(spec._sessionId),
            if (compact != null) ...[
              Variable.withInt(compact.endCreatedAt),
              Variable.withInt(compact.endCreatedAt),
              Variable.withString(compact.endMessageId),
            ],
            if (boundary != null) ...[
              Variable.withInt(boundary._createdAt),
              Variable.withInt(boundary._createdAt),
              Variable.withString(boundary._messageId),
            ],
          ],
        )
        .get();
    checkpoint?.call();
    if (rows.length > SupportTextContextRepo.maxSourceMessages) {
      _fail(SupportTextContextFailure.limited);
    }
    final ids = <String>[];
    var envelopes = 0;
    for (final row in rows) {
      final id = row.read<String>('id');
      if (!_identity(id, redactor()) ||
          row.read<int>('created_at') < 0 ||
          !const [
            'user',
            'assistant',
            'system',
          ].contains(row.read<String>('role'))) {
        _fail(SupportTextContextFailure.unavailable);
      }
      if (const ['user', 'assistant'].contains(row.read<String>('role')) &&
          const [
            'complete',
            'limited',
            'stopped',
            'error',
          ].contains(row.read<String>('status'))) {
        if (spec._compactionBatch &&
            (ids.length >= 32 ||
                envelopes + row.read<int>('envelope_length') >
                    SupportTextContextRepo.maxSelectedEnvelopeChars - 16000))
          break;
        envelopes += row.read<int>('envelope_length');
        ids.add(id);
      }
    }
    if (ids.length > SupportTextContextRepo.maxSelections) {
      _fail(SupportTextContextFailure.limited);
    }
    final read = await reader.read(
      spec._sessionId,
      ids,
      checkpoint: checkpoint,
      directConversation: true,
      boundedSuffix: true,
    );
    checkpoint?.call();
    return (
      _TextRead._session(read, [if (current != null) current, ...rows]),
      List<String>.unmodifiable(ids),
    );
  }
}
