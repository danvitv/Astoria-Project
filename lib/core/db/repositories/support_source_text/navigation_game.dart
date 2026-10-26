part of '../support_source_text_repo.dart';

final class _NavGameCursor {
  _NavGameCursor(
    this.source,
    this.scope,
    this.operation,
    this.literal,
    this.ordinal,
  );
  final _NavSource source;
  final nav.FrozenScope scope;
  final String operation;
  final String? literal;
  final int ordinal;
}

/// Indexed seeks into independently stored, authenticated COMPLETE objects.
/// No messages_json/json_each/window/offset read is reachable from these tools.
extension _NavGame on SupportSourceNavigationRepo {
  static const _anchorColumns = 'native_order,active_ordinal AS ordinal,message_id,swipe_id,agent_swipe_id,role,integrity,anchor_integrity,'
      'astoria_history_anchor_valid(session_id,incarnation,revision,native_order,active_ordinal,'
      'message_id,swipe_id,agent_swipe_id,role,integrity,anchor_integrity) AS anchor_valid';
  Future<Map<String, Object?>> _gameIndex(String session) async {
    final value = await _db.historySourceIndex.observe(session);
    _guard();
    return value;
  }

  Future<List<QueryRow>> _gameRows(
    String session,
    int incarnation,
    int revision,
    int start,
    int end,
    int limit,
  ) => _sql(
    '''SELECT $_anchorColumns,
      CASE WHEN octet_length(raw_json)<=65536 THEN raw_json END AS raw,
      astoria_history_unit_valid(session_id,incarnation,revision,native_order,
        active_ordinal,message_id,CASE WHEN octet_length(raw_json)<=65536 THEN raw_json END,integrity) AS valid
      FROM history_message_units INDEXED BY idx_history_units_active
      WHERE session_id=? AND incarnation=? AND revision=? AND active_ordinal BETWEEN ? AND ?
      ORDER BY active_ordinal LIMIT ?''',
    [
      Variable.withString(session),
      Variable.withInt(incarnation),
      Variable.withInt(revision),
      Variable.withInt(start),
      Variable.withInt(end),
      Variable.withInt(limit),
    ],
  );

  history.HistoryMessageUnit _message(QueryRow row) {
    if (row.data['valid'] != 1 || row.data['raw'] is! String)
      _fail(SupportSourceReadFailure.changed);
    final message = history.HistoryMessageUnit(row.read<String>('raw'));
    if (!message.eligible) _shape.bad();
    return message;
  }

  nav.Anchor _anchor(QueryRow row, {history.HistoryMessageUnit? message}) {
    if (row.data['anchor_valid'] != 1 || row.data['ordinal'] is! int) {
      _fail(SupportSourceReadFailure.changed);
    }
    final id = _shape.id(row.data['message_id']);
    final swipe = row.data['swipe_id'], agent = row.data['agent_swipe_id'];
    if (message != null && (message.id != id ||
        message.nativeSwipe != (swipe == null ? null : '$swipe') ||
        message.nativeAgentSwipe != (agent == null ? null : '$agent') ||
        message.role != row.data['role'])) _fail(SupportSourceReadFailure.changed);
    return nav.Anchor(
      id,
      row.read<int>('ordinal'),
      swipe: swipe == null ? null : '$swipe',
      agentSwipe: agent == null ? null : '$agent',
    );
  }

  Future<List<QueryRow>> _gameMetadata(
    String session, int incarnation, int revision, int start, int end, int limit,
  ) => _sql('SELECT $_anchorColumns FROM history_message_units INDEXED BY idx_history_units_active '
      'WHERE session_id=? AND incarnation=? AND revision=? AND active_ordinal BETWEEN ? AND ? '
      'ORDER BY active_ordinal LIMIT ?', [
        Variable.withString(session), Variable.withInt(incarnation), Variable.withInt(revision),
        Variable.withInt(start), Variable.withInt(end), Variable.withInt(limit),
      ]);

  Future<nav.FrozenScope?> _gameScope(
    String session,
    nav.WorkBound bound,
  ) async {
    final index = await _gameIndex(session);
    if (index['status'] != 'ready')
      return null; // Explicit local backfill only.
    final count = index['activeCount'] as int;
    if (count == 0) return null;
    final first = await _gameMetadata(
      session,
      index['incarnation'] as int,
      index['revision'] as int,
      0,
      0,
      1,
    );
    final last = count == 1
        ? first
        : await _gameMetadata(
            session,
            index['incarnation'] as int,
            index['revision'] as int,
            count - 1,
            count - 1,
            1,
          );
    _guard();
    if (first.length != 1 || last.length != 1)
      _fail(SupportSourceReadFailure.changed);
    return nav.FrozenScope.messages(
      nav.ActiveRange(_anchor(first.single), _anchor(last.single)),
    );
  }

  Future<nav.Page<nav.DataRecord>> _gamePage(
    _NavSource source,
    nav.FrozenScope scope,
    String operation,
    String? literal,
    Object? cursor,
    nav.WorkBound bound, {
    int? first,
    int? last,
    bool bodies = true,
  }) async {
    final range = scope.messages!;
    var start = first ?? range.start.ordinal;
    if (cursor != null) {
      if (cursor is! _NavGameCursor ||
          !identical(cursor.source, source) ||
          !identical(cursor.scope, scope) ||
          cursor.operation != operation ||
          cursor.literal != literal)
        _fail();
      start = cursor.ordinal;
    }
    final end = last ?? range.end.ordinal;
    if (start < range.start.ordinal || end > range.end.ordinal || end < start)
      _fail();
    final index = source.header['history_index'] as Map<String, Object?>?;
    if (index == null || index['status'] != 'ready')
      _fail(SupportSourceReadFailure.unavailable);
    // Body operations bound complete indexed units. Contents authenticates only
    // separately MAC-bound metadata; it never hydrates game raw_json.
    final records = <nav.DataRecord>[];
    var next = start, examined = 0, rawBytes = 0;
    final clock = Stopwatch()..start();
    while (next <= end &&
        records.length < bound.pageSize &&
        examined < bound.candidateLimit &&
        clock.elapsedMilliseconds < 1000) {
      final count = min(
        min(bound.pageSize, bound.candidateLimit - examined),
        (bound.rawByteLimit - rawBytes) ~/ (bodies ? 65536 : 1024),
      );
      if (count < 1) {
        if (examined == 0) _fail(SupportSourceReadFailure.tooLarge);
        break;
      }
      final scanEnd = min(next + count - 1, end);
      final rows = await (bodies ? _gameRows : _gameMetadata)(
        source.observation.key.nativeId,
        index['incarnation'] as int,
        index['revision'] as int,
        next,
        scanEnd,
        count,
      );
      _guard();
      if (rows.length != scanEnd - next + 1)
        _fail(SupportSourceReadFailure.changed);
      // Account even prefetched/unemitted complete units, never just matches.
      rawBytes += rows.fold<int>(
        0,
        (n, row) => n + utf8.encode(bodies ? row.read<String>('raw') : jsonEncode(row.data)).length,
      );
      for (final row in rows) {
        if (row.read<int>('ordinal') != next)
          _fail(SupportSourceReadFailure.changed);
        final message = bodies ? _message(row) : null;
        final anchor = _anchor(row, message: message);
        next++;
        examined++;
        final selection = nav.Selection.messages(
          'active',
          nav.ActiveRange(anchor, anchor),
        );
        if (!_allowed(source, scope, selection)) _fail();
        if (literal != null && !_visibleMatch(message!.content, literal))
          continue;
        final record = nav.DataRecord(
          selection: selection,
          kind: nav.SectionKind.activeMessages,
          payload: message?.content,
          state: nav.SourceState.active,
          binding: nav.Binding(
            sessionId: source.observation.key.nativeId,
            characterId: source.observation.binding.characterId,
            anchor: anchor,
          ),
          role: row.read<String>('role'),
        );
        _keep(source, record, Map<String, Object?>.of(row.data), [
          anchor.messageId,
        ]);
        records.add(record);
        if (records.length == bound.pageSize) break;
      }
      if (literal == null) break;
    }
    final complete = next > end;
    return nav.Page(
      records,
      complete: complete,
      next: complete
          ? null
          : _NavGameCursor(source, scope, operation, literal, next),
      candidatesExamined: examined,
      exhaustedWork: !complete && records.length < bound.pageSize,
    );
  }

  Future<nav.Anchor?> _savedAnchor(
    _NavSource source,
    String id,
    int swipe,
    int agent,
  ) async {
    _shape.id(id);
    if (swipe < 0 || agent < 0) _shape.bad();
    final index = await _gameIndex(source.observation.key.nativeId);
    if (index['status'] != 'ready') return null;
    final rows = await _sql(
      '''SELECT $_anchorColumns FROM history_message_units INDEXED BY idx_history_units_identity
      WHERE session_id=? AND incarnation=? AND revision=? AND message_id=? AND active_ordinal IS NOT NULL LIMIT 1''',
      [
        Variable.withString(source.observation.key.nativeId),
        Variable.withInt(index['incarnation'] as int),
        Variable.withInt(index['revision'] as int),
        Variable.withString(id),
      ],
    );
    _guard();
    if (rows.length != 1) return null;
    final anchor = _anchor(rows.single);
    return (anchor.swipe ?? '0') == '$swipe' &&
            (anchor.agentSwipe ?? '0') == '$agent'
        ? anchor
        : null;
  }
}
