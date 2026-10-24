part of '../support_text_context_repo.dart';

final class _SupportTextReader {
  const _SupportTextReader(this.db, this.cipher);
  final AppDatabase db;
  final SupportPayloadCipher cipher;

  Future<_TextRead> read(
    String sessionId,
    List<String> ids, {
    void Function()? checkpoint,
    bool directConversation = false,
    bool boundedSuffix = false,
  }) async {
    checkpoint?.call();
    final header = await db
        .customSelect(
          '''
      SELECT rowid AS native_identity, created_at,
        CASE WHEN length(title_ciphertext) <= ? THEN title_ciphertext END AS title,
        (SELECT COUNT(*) FROM support_messages WHERE session_id = ?) AS source_count
      FROM support_sessions WHERE id = ? LIMIT 1
    ''',
          variables: [
            Variable.withInt(SupportTextContextRepo.maxSelectedEnvelopeChars),
            Variable.withString(sessionId),
            Variable.withString(sessionId),
          ],
        )
        .getSingleOrNull();
    checkpoint?.call();
    if (header == null || header.readNullable<String>('title') == null) {
      _fail(SupportTextContextFailure.unavailable);
    }
    if (!boundedSuffix &&
        header.read<int>('source_count') >
            SupportTextContextRepo.maxSourceMessages) {
      _fail(SupportTextContextFailure.limited);
    }
    final title = await cipher.decrypt(
      envelopeText: header.read<String>('title'),
      table: 'support_sessions',
      rowId: sessionId,
      sessionId: sessionId,
      field: 'title_ciphertext',
    );
    checkpoint?.call();
    _textBytes(title); // Readable parent only; never retained or returned.
    // Confirmed readable empty whole history: keep parent/count observations.
    // Exact public APIs never reach this branch with an empty selection.
    if (ids.isEmpty) return _TextRead(header, const [], const []);
    final slots = List.filled(ids.length, '?').join(',');
    final variables = [
      Variable.withString(sessionId),
      ...ids.map(Variable.withString),
    ];
    final budget = await db.customSelect('''
      SELECT COUNT(*) AS n, COALESCE(SUM(length(body_ciphertext)), 0) AS chars
      FROM support_messages WHERE session_id = ? AND id IN ($slots)
    ''', variables: variables).getSingle();
    checkpoint?.call();
    if (budget.read<int>('n') != ids.length) {
      _fail(SupportTextContextFailure.unavailable);
    }
    if (budget.read<int>('chars') >
        SupportTextContextRepo.maxSelectedEnvelopeChars) {
      _fail(SupportTextContextFailure.limited);
    }
    final rows = await db.customSelect('''
      WITH ordered AS (
        SELECT id,
               CASE WHEN role IN ('user', 'assistant', 'system') THEN role END AS role,
               CASE WHEN status IN (${directConversation ? "'complete', 'limited', 'stopped', 'error'" : "'complete'"}) THEN status END AS status,
               created_at, rowid AS native_identity,
               ROW_NUMBER() OVER (ORDER BY created_at ASC, id ASC) - 1 AS native_order
        FROM support_messages WHERE session_id = ?
      )
      SELECT o.*, m.body_ciphertext,
             CASE WHEN m.run_id IS NULL OR length(m.run_id) <= 256 THEN m.run_id END AS run_id,
             CASE WHEN m.run_id IS NULL OR length(m.run_id) <= 256 THEN 1 ELSE 0 END AS run_valid
      FROM ordered o JOIN support_messages m ON m.id = o.id
      WHERE o.id IN ($slots) ORDER BY o.native_order ASC
    ''', variables: variables).get();
    checkpoint?.call();
    if (rows.length != ids.length) _fail(SupportTextContextFailure.unavailable);
    final bodies = <_RawTextBody>[];
    var chars = 0;
    var bytes = 0;
    for (var i = 0; i < rows.length; i++) {
      final row = rows[i];
      final role = row.readNullable<String>('role');
      if (row.read<String>('id') != ids[i] ||
          !const ['user', 'assistant', 'system'].contains(role) ||
          !(directConversation
                  ? const ['complete', 'limited', 'stopped', 'error']
                  : const ['complete'])
              .contains(row.readNullable<String>('status')) ||
          row.read<int>('run_valid') != 1 ||
          row.read<int>('created_at') < 0 ||
          row.read<int>('created_at') > 8640000000000) {
        _fail(SupportTextContextFailure.unavailable);
      }
      final body = await cipher.decrypt(
        envelopeText: row.read<String>('body_ciphertext'),
        table: 'support_messages',
        rowId: ids[i],
        sessionId: sessionId,
        field: 'body_ciphertext',
      );
      checkpoint?.call();
      chars += body.length;
      bytes += _textBytes(body);
      if (chars > SupportTextContextRepo.maxTextChars ||
          bytes > SupportTextContextRepo.maxTextBytes) {
        _fail(SupportTextContextFailure.limited);
      }
      bodies.add(_RawTextBody(role!, body));
    }
    final provenance = await _SupportTextProvenanceReader(
      db,
      cipher,
    ).read(sessionId, ids, rows, checkpoint: checkpoint);
    checkpoint?.call();
    return _TextRead(
      header,
      rows,
      bodies,
      provenance: provenance.$1,
      provenanceRows: provenance.$2,
    );
  }
}
