part of '../support_text_context_repo.dart';

/// Whole-session discovery returns only bounded identities/eligibility facts.
/// The existing strict reader alone projects active body/variation primitives.
final class _RoleplaySessionTextReader {
  const _RoleplaySessionTextReader(this._reader);
  final _RoleplayTextReader _reader;

  Future<(_TextRead, List<String>)> read(
    String sessionId,
    SecretRedactor Function() currentRedactor, {
    void Function()? checkpoint,
  }) async {
    // Checks the visible own character, parent identity, byte/shape/count cap
    // BEFORE discovery. CASE also guards json_each in this separate SQL query.
    final empty = await _reader.read(
      sessionId,
      const [],
      checkpoint: checkpoint,
    );
    checkpoint?.call();
    final rows = await _reader.db
        .customSelect(
          '''
      ${_RoleplayTextReader._entries}
      SELECT native_order, message_id,
        CASE WHEN
          message_id IS NOT NULL AND length(message_id) > 0 AND
          json_type(o, '\$.role') = 'text' AND json_extract(o, '\$.role') IN ('user', 'assistant', 'system') AND
          json_type(o, '\$.content') = 'text' AND
          COALESCE(json_type(o, '\$.isHidden'), 'null') IN ('true', 'false', 'null') AND
          COALESCE(json_type(o, '\$.isError'), 'null') IN ('true', 'false', 'null') AND
          COALESCE(json_type(o, '\$.isTyping'), 'null') IN ('true', 'false', 'null') AND
          COALESCE(json_type(o, '\$.isEditing'), 'null') IN ('true', 'false', 'null') AND
          COALESCE(json_type(o, '\$.isLocked'), 'null') IN ('true', 'false', 'null') AND
          COALESCE(json_type(o, '\$.isAllReasoning'), 'null') IN ('true', 'false', 'null') AND
          COALESCE(json_type(o, '\$.status'), 'null') IN ('text', 'null') AND
          (COALESCE(json_type(o, '\$.swipeId'), 'null') = 'null' OR
            (json_type(o, '\$.swipeId') = 'integer' AND json_extract(o, '\$.swipeId') BETWEEN 0 AND 1000000)) AND
          (COALESCE(json_type(o, '\$.agentSwipeId'), 'null') = 'null' OR
            (json_type(o, '\$.agentSwipeId') = 'integer' AND json_extract(o, '\$.agentSwipeId') BETWEEN 0 AND 1000000)) AND
          (COALESCE(json_type(o, '\$.timestamp'), 'null') = 'null' OR
            (json_type(o, '\$.timestamp') = 'integer' AND json_extract(o, '\$.timestamp') BETWEEN 0 AND 8640000000000000)) AND
          COALESCE(json_type(o, '\$.swipes'), 'null') IN ('array', 'null') AND
          COALESCE(json_type(o, '\$.agentSwipes'), 'null') IN ('array', 'null') AND
          (SELECT COUNT(*) = COUNT(DISTINCT key) FROM json_each(o)
            WHERE key IN ('id', 'role', 'content', 'isHidden', 'isError', 'isTyping', 'isEditing',
              'isLocked', 'isAllReasoning', 'status', 'swipeId', 'agentSwipeId', 'timestamp', 'swipes', 'agentSwipes'))
          THEN 1 ELSE 0 END AS shape_valid,
        CASE WHEN
          COALESCE(json_type(o, '\$.isHidden'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isError'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isTyping'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isEditing'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isLocked'), 'null') IN ('false', 'null') AND
          COALESCE(json_type(o, '\$.isAllReasoning'), 'null') IN ('false', 'null') AND
          (COALESCE(json_type(o, '\$.status'), 'null') = 'null' OR
            (json_type(o, '\$.status') = 'text' AND json_extract(o, '\$.status') = 'complete'))
          THEN 1 ELSE 0 END AS visible
      FROM identified ORDER BY native_order ASC
      LIMIT ${SupportTextContextRepo.maxSourceMessages + 1}
    ''',
          variables: [Variable.withString(sessionId)],
        )
        .get();
    checkpoint?.call();
    if (rows.length > SupportTextContextRepo.maxSourceMessages) {
      _fail(SupportTextContextFailure.limited);
    }
    final allIds = <String>{};
    final ids = <String>[];
    for (final row in rows) {
      final id = row.readNullable<String>('message_id');
      if (row.read<int>('shape_valid') != 1 ||
          id == null ||
          !_identity(id, currentRedactor()) ||
          !allIds.add(id)) {
        _fail(SupportTextContextFailure.unavailable);
      }
      if (row.read<int>('visible') == 1) ids.add(id);
    }
    if (ids.length > SupportTextContextRepo.maxSelections) {
      _fail(SupportTextContextFailure.limited);
    }
    final read = ids.isEmpty
        ? empty
        : await _reader.read(sessionId, ids, checkpoint: checkpoint);
    checkpoint?.call();
    return (_TextRead._session(read, rows), List<String>.unmodifiable(ids));
  }
}
