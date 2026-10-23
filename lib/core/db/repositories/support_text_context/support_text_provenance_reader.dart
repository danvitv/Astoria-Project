part of '../support_text_context_repo.dart';

/// Only the settlement owner's reserved, message-bound provenance namespace.
/// No settings/permission blocks, summaries, cards or general context reader.
final class _SupportTextProvenanceReader {
  const _SupportTextProvenanceReader(this.db, this.cipher);
  final AppDatabase db;
  final SupportPayloadCipher cipher;
  static String _id(String messageId) => 'support.reply_provenance:$messageId';

  Future<(List<SupportTextContextProvenance>, List<QueryRow>)> read(
    String sessionId,
    List<String> ids,
    List<QueryRow> messages, {
    void Function()? checkpoint,
  }) async {
    checkpoint?.call();
    final contextIds = ids.map(_id).toList(growable: false);
    final slots = List.filled(contextIds.length, '?').join(',');
    final variables = [
      Variable.withString(sessionId),
      ...contextIds.map(Variable.withString),
    ];
    final budget = await db.customSelect('''
      SELECT COALESCE(SUM(length(protected_facts_ciphertext)), 0) AS chars
      FROM support_context_blocks WHERE session_id = ? AND id IN ($slots)
    ''', variables: variables).getSingle();
    checkpoint?.call();
    if (budget.read<int>('chars') >
        SupportTextContextRepo.maxSelectedEnvelopeChars) {
      _fail(SupportTextContextFailure.limited);
    }
    final rows = await db.customSelect('''
      SELECT rowid AS native_identity, id,
             CASE WHEN length(start_message_id) <= 256 THEN start_message_id END AS start_message_id,
             CASE WHEN length(end_message_id) <= 256 THEN end_message_id END AS end_message_id,
             is_active, created_at, protected_facts_ciphertext
      FROM support_context_blocks WHERE session_id = ? AND id IN ($slots)
    ''', variables: variables).get();
    checkpoint?.call();
    final byId = {for (final row in rows) row.read<String>('id'): row};
    final result = <SupportTextContextProvenance>[];
    var chars = 0;
    var bytes = 0;
    for (var i = 0; i < ids.length; i++) {
      final row = byId[contextIds[i]];
      String? facts;
      if (row != null) {
        if (row.readNullable<String>('start_message_id') != ids[i] ||
            row.readNullable<String>('end_message_id') != ids[i] ||
            row.read<int>('is_active') != 0 ||
            row.read<int>('created_at') !=
                messages[i].read<int>('created_at') ||
            messages[i].readNullable<String>('run_id') == null) {
          _fail(SupportTextContextFailure.unavailable);
        }
        facts = await cipher.decrypt(
          envelopeText: row.read<String>('protected_facts_ciphertext'),
          table: 'support_context_blocks',
          rowId: contextIds[i],
          sessionId: sessionId,
          field: 'protected_facts_ciphertext',
        );
        checkpoint?.call();
        chars += facts.length;
        bytes += _textBytes(facts);
        if (facts.trim().isEmpty ||
            chars > SupportTextContextRepo.maxTextChars ||
            bytes > SupportTextContextRepo.maxTextBytes) {
          _fail(SupportTextContextFailure.limited);
        }
      }
      result.add(
        SupportTextContextProvenance(
          messageId: ids[i],
          runId: messages[i].readNullable<String>('run_id'),
          dedicatedFactsJson: facts,
        ),
      );
    }
    // Preserve explicit selection order independently of SQLite IN ordering.
    return (
      result,
      [
        for (final id in contextIds)
          if (byId[id] != null) byId[id]!,
      ],
    );
  }
}
