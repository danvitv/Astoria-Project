part of '../support_source_text_repo.dart';

final class _AstoriaListCursor {
  const _AstoriaListCursor(this.repo, this.row);
  final SupportSourceNavigationRepo repo;
  final int row;
}

extension _NavAstoria on SupportSourceNavigationRepo {
  Future<nav.Page<nav.SourceObservation>> _discoverAstoria(
    nav.SourceKey? parent,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (parent != null) return nav.Page(const []);
    var after = 0;
    if (cursor != null) {
      if (cursor is! _AstoriaListCursor || !identical(cursor.repo, this))
        _fail();
      after = cursor.row;
    }
    final rows = await _sql(
      'SELECT rowid AS ordinal, '
      'CASE WHEN octet_length(id)<=256 THEN id END AS id, '
      'CASE WHEN octet_length(title_ciphertext)<=16384 THEN title_ciphertext END AS title, '
      'created_at,updated_at,pinned,CASE WHEN octet_length(mode)<=256 THEN mode END AS mode FROM support_sessions WHERE rowid>? ORDER BY rowid LIMIT ?',
      [
        Variable.withInt(after),
        Variable.withInt(min(bound.pageSize, bound.candidateLimit)),
      ],
    );
    _guard();
    final result = <nav.SourceObservation>[];
    var consumed = after;
    final clock = Stopwatch()..start();
    for (final row in rows) {
      if (clock.elapsedMilliseconds >= 1000) break;
      consumed = row.read<int>('ordinal');
      final id = row.data['id'];
      if (!SupportSourceJson.identity(id) || id == _ownSupportSessionId)
        continue;
      final key = nav.SourceKey(
        nav.SourceDomain.astoriaConversation,
        id as String,
      );
      var source = _sources[key];
      if (source == null) {
        String? title;
        if (row.data['title'] is String) {
          try {
            title = await _readCipher.decrypt(
              envelopeText: row.read<String>('title'),
              table: 'support_sessions',
              rowId: id,
              sessionId: id,
              field: 'title_ciphertext',
            );
            _guard();
            title = _ApplicationProjection(this).text(title);
          } on FormatException {
            title = null;
          } on SupportCipherException {
            /* Locked titles remain unknown. */
          }
        }
        // Global max(rowid) is a bounded index seek. Message enumeration then
        // uses its session+rowid index and never hydrates an entire conversation.
        final maximum = await _sql(
          'SELECT coalesce(max(rowid),0) AS last FROM support_messages',
        );
        _guard();
        final header = <String, Object?>{
          'incarnation': row.data['ordinal'],
          'title': title,
          'updated_at': row.data['updated_at'],
          'lastMessageRow': maximum.single.read<int>('last'),
          'settings': {'mode': row.data['mode'], 'pinned': row.data['pinned']},
        };
        source = _newApplicationSource(
          key,
          header,
          title ?? 'Astoria conversation (title unavailable)',
          const ['messages'],
          binding: nav.Binding(sessionId: id),
        );
      }
      result.add(source.observation);
    }
    final complete =
        rows.length < min(bound.pageSize, bound.candidateLimit) &&
        (rows.isEmpty || consumed == rows.last.read<int>('ordinal'));
    return nav.Page(
      result,
      complete: complete,
      exhaustedWork:
          !complete && (result.isEmpty || clock.elapsedMilliseconds >= 1000),
      candidatesExamined: rows.length,
      next: complete ? null : _AstoriaListCursor(this, consumed),
    );
  }

  Future<nav.Page<nav.DataRecord>> _astoriaPage(
    _NavSource source,
    nav.FrozenScope scope,
    String operation,
    nav.Selection? section,
    String? literal,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (section != null || !scope.sections.contains('messages')) _fail();
    var after = 0;
    if (cursor != null) {
      if (cursor is! _ApplicationCursor ||
          !identical(cursor.source, source) ||
          !identical(cursor.scope, scope) ||
          cursor.operation != operation ||
          cursor.literal != literal ||
          cursor.section != null)
        _fail();
      after = cursor.row;
    }
    final maximum = source.header['lastMessageRow'] as int;
    final bodies = operation != 'contents';
    final result = <nav.DataRecord>[];
    var examined = 0, rawBytes = 0, omitted = false;
    final clock = Stopwatch()..start();
    while (result.length < bound.pageSize &&
        examined < bound.candidateLimit &&
        clock.elapsedMilliseconds < 1000 &&
        rawBytes + 65536 <= bound.rawByteLimit) {
      final rows = await _sql(
        'SELECT rowid AS ordinal, '
        'CASE WHEN octet_length(id)<=256 THEN id END AS id, '
        'CASE WHEN octet_length(role)<=256 THEN role END AS role, '
        'CASE WHEN octet_length(status)<=256 THEN status END AS status,created_at, '
        '${bodies ? 'CASE WHEN octet_length(body_ciphertext)<=65536 THEN body_ciphertext END' : 'NULL'} AS body '
        'FROM support_messages INDEXED BY idx_support_messages_session_id '
        'WHERE session_id=? AND rowid>? AND rowid<=? ORDER BY rowid LIMIT 1',
        [
          Variable.withString(source.observation.key.nativeId),
          Variable.withInt(after),
          Variable.withInt(maximum),
        ],
      );
      _guard();
      if (rows.isEmpty)
        return nav.Page(
          result,
          complete: !omitted,
          exhaustedWork: omitted,
          candidatesExamined: examined,
        );
      final row = rows.single;
      after = row.read<int>('ordinal');
      examined++;
      final id = row.data['id'];
      if (id is! String ||
          !SupportSourceJson.identity(id) ||
          !const ['user', 'assistant', 'system'].contains(row.data['role'])) {
        omitted = true;
        continue;
      }
      final status = row.data['status'];
      if (!const [
        'complete',
        'error',
        'cancelled',
        'pending',
        'preparing',
      ].contains(status)) {
        omitted = true;
        continue;
      }
      if (bodies && row.data['body'] is String) {
        rawBytes += utf8.encode(row.read<String>('body')).length;
      }
      final record = await _astoriaRecord(source, row, bodies: bodies);
      _guard();
      omitted = omitted || (bodies && record.payload is Map);
      if (literal != null &&
          (record.payload is! String ||
              !(record.payload as String).contains(literal)))
        continue;
      _keep(source, record, Map<String, Object?>.of(row.data), [id]);
      result.add(record);
    }
    return nav.Page(
      result,
      complete: false,
      exhaustedWork: result.length < bound.pageSize,
      candidatesExamined: examined,
      next: _ApplicationCursor(
        source,
        scope,
        operation,
        null,
        literal,
        0,
        after,
        0,
      ),
    );
  }

  Future<nav.DataRecord> _astoriaRecord(
    _NavSource source,
    QueryRow row, {
    required bool bodies,
  }) async {
    final id = _shape.id(row.data['id']);
    final status = row.data['status'];
    var readStatus = bodies ? 'saved_message' : 'metadata_only';
    String? text;
    if (bodies && const ['pending', 'preparing'].contains(status)) {
      readStatus = 'pending_body_not_read';
    } else if (bodies && row.data['body'] is String) {
      try {
        text = await _readCipher.decrypt(
          envelopeText: row.read<String>('body'),
          table: 'support_messages',
          rowId: id,
          sessionId: source.observation.key.nativeId,
          field: 'body_ciphertext',
        );
        _guard();
        text = _ApplicationProjection(this).text(text);
      } on FormatException {
        text = null;
        readStatus = 'unknown_saved_format';
      } on SupportCipherException {
        readStatus = 'locked_or_invalid_encrypted_unit';
      }
    } else if (bodies) {
      readStatus = 'oversized_complete_unit';
    }
    return nav.DataRecord(
      selection: nav.Selection.record('messages', id),
      kind: nav.SectionKind.astoriaMessage,
      state: const ['pending', 'preparing'].contains(status)
          ? nav.SourceState.pendingGeneration
          : status == 'complete'
          ? nav.SourceState.currentSaved
          : nav.SourceState.error,
      binding: source.observation.binding,
      role: row.read<String>('role'),
      label:
          'Saved ${row.read<String>('role')} message · $status · $readStatus',
      payload: !bodies
          ? null
          : text ?? {'status': readStatus, 'bodyAvailable': false},
      schemaKeysAttested: true,
    );
  }

  Future<nav.Page<nav.DataRecord>> _astoriaRead(
    _NavSource source,
    nav.Selection selected,
    nav.WorkBound bound,
  ) async {
    final capture = source.captures[_selectionKey(selected)]!;
    final original = capture.raw as Map<String, Object?>;
    final rows = await _sql(
      'SELECT rowid AS ordinal,id, '
      'CASE WHEN octet_length(role)<=256 THEN role END AS role, '
      'CASE WHEN octet_length(status)<=256 THEN status END AS status,created_at, '
      'CASE WHEN octet_length(body_ciphertext)<=? THEN body_ciphertext END AS body '
      'FROM support_messages WHERE session_id=? AND id=? AND rowid=? AND rowid<=? LIMIT 1',
      [
        Variable.withInt(min(bound.rawByteLimit, 65536)),
        Variable.withString(source.observation.key.nativeId),
        Variable.withString(selected.recordId!),
        Variable.withInt(original['ordinal'] as int),
        Variable.withInt(source.header['lastMessageRow'] as int),
      ],
    );
    _guard();
    if (rows.length != 1 ||
        rows.single.data['role'] != original['role'] ||
        rows.single.data['status'] != original['status'])
      _fail(SupportSourceReadFailure.changed);
    final record = await _astoriaRecord(source, rows.single, bodies: true);
    _guard();
    _keep(source, record, Map<String, Object?>.of(rows.single.data), [
      selected.recordId!,
    ]);
    return nav.Page([record], candidatesExamined: 1);
  }
}
