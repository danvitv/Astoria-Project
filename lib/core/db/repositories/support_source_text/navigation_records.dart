part of '../support_source_text_repo.dart';

final class _NavTable {
  const _NavTable(
    this.table,
    this.owner,
    this.columns,
    this.sections, {
    this.where = '',
    this.jsonArray,
    this.clock = false,
  });
  final String table, owner, columns, where;
  final Set<String> sections;
  final String? jsonArray;
  final bool clock;
}

final class _NavRecordCursor {
  _NavRecordCursor(
    this.source,
    this.scope,
    this.operation,
    this.section,
    this.literal,
    this.table,
    this.row,
    this.unit,
  );
  final _NavSource source;
  final nav.FrozenScope scope;
  final String operation;
  final nav.Selection? section;
  final String? literal;
  final int table, row, unit;
}

extension _NavRecords on SupportSourceNavigationRepo {
  List<_NavTable> _tables(nav.SourceDomain domain) => switch (domain) {
    nav.SourceDomain.ordinaryPreset => [
      const _NavTable('presets', 'preset_id', 'preset_id,name,data_json', {
        'blocks',
        'regex',
        'reasoning',
        'templates',
      }),
    ],
    nav.SourceDomain.studioPreset => [
      const _NavTable(
        'studio_preset_rows',
        'preset_id',
        'preset_id,name,blocks_json,agents_json,agent_enabled_json,runtime_settings_json,'
            'max_final_history_messages,execution_mode,expensive_api_config_id,cheap_api_config_id,'
            'cleaner_api_config_id,ledger_api_config_id,updated_at',
        {'blocks', 'agents', 'runtime', 'settings'},
      ),
    ],
    nav.SourceDomain.memory => _memoryTables,
    nav.SourceDomain.savedSummary => [
      const _NavTable(
        'chat_summaries',
        'session_id',
        'session_id,content,enabled,message_count,prompt,updated_at',
        {'text', 'template'},
      ),
    ],
    nav.SourceDomain.ledgerState => [
      const _NavTable(
        'tracker_rows',
        'session_id',
        'session_id,name,value,scope,provenance,basis_revision,basis_revision_hash,updated_at',
        {'trackers'},
        where:
            "AND scope = 'ledger' AND name NOT LIKE 'canon\\_%' ESCAPE '\\' "
            "AND name NOT IN ('world:time','world:date','world:day')",
      ),
      const _NavTable(
        'tracker_rows',
        'session_id',
        'session_id,name,value,scope,provenance,basis_revision,basis_revision_hash,updated_at',
        {'trackers'},
        clock: true,
      ),
    ],
    nav.SourceDomain.ledgerSnapshot => [
      const _NavTable(
        'tracker_snapshots',
        'session_id',
        'session_id,message_id,swipe_id,agent_swipe_id,trackers_json,committed,created_at',
        {'snapshots'},
      ),
    ],
    nav.SourceDomain.reconciliation => _reconciliationTables,
    nav.SourceDomain.characterKnowledge => [
      const _NavTable(
        'character_knowledge_fact_rows',
        'chat_session_id',
        'id,chat_session_id,knower_key,knower_name,subject_key,subject_name,fact_class,scope_key,'
            'predicate,object,epistemic_state,confidence,importance,entities_json,topics_json,'
            'source_message_id,source_swipe_id,source_agent_swipe_id,source_kind,supersedes_id,'
            'lifecycle,basis_revision,basis_revision_hash,created_at,updated_at',
        {'facts'},
      ),
    ],
    _ => const [],
  };

  Future<nav.Page<nav.SectionDescriptor>> _contents(
    _NavSource source,
    nav.FrozenScope scope,
    nav.Selection? section,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (source.observation.key.domain == nav.SourceDomain.game) {
      if (section != null) _fail();
      final page = await _gamePage(
        source,
        scope,
        'contents',
        null,
        cursor,
        bound,
        bodies: false,
      );
      _guard();
      return nav.Page(
        page.items.map(
          (r) => nav.SectionDescriptor(
            r.selection,
            r.kind,
            state: r.state,
            binding: r.binding,
          ),
        ),
        next: page.next,
        complete: page.complete,
        exhaustedWork: page.exhaustedWork,
        candidatesExamined: page.candidatesExamined,
      );
    }
    if (section == null) {
      if (cursor != null) _fail();
      final descriptors = <nav.SectionDescriptor>[];
      for (final entry in _navRoots[source.observation.key.domain]!.entries) {
        if (!scope.sections.contains(entry.key)) continue;
        final selection = nav.Selection.section(entry.key);
        final record = nav.DataRecord(
          selection: selection,
          kind: entry.value,
          payload: null,
          state: source.observation.state,
          binding: source.observation.binding,
        );
        _keep(source, record, source.header, const []);
        descriptors.add(
          nav.SectionDescriptor(
            selection,
            entry.value,
            state: record.state,
            binding: record.binding,
          ),
        );
      }
      if (descriptors.length > bound.pageSize) {
        _fail(SupportSourceReadFailure.tooLarge);
      }
      return nav.Page(descriptors);
    }
    final page = await _recordPage(
      source,
      scope,
      'contents',
      section,
      null,
      cursor,
      bound,
    );
    _guard();
    return nav.Page(
      page.items.map(
        (r) => nav.SectionDescriptor(
          r.selection,
          r.kind,
          state: r.state,
          binding: r.binding,
        ),
      ),
      next: page.next,
      complete: page.complete,
      exhaustedWork: page.exhaustedWork,
      candidatesExamined: page.candidatesExamined,
    );
  }

  Future<nav.Page<nav.DataRecord>> _search(
    _NavSource source,
    nav.FrozenScope scope,
    String literal,
    nav.Selection? section,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    // Validate scalars before SQLite receives the literal; no regex/collation.
    SupportSourceJson.decode(jsonEncode(literal), maxBytes: 2048);
    if (literal.isEmpty || literal.runes.length > 256) _fail();
    if (source.observation.key.domain == nav.SourceDomain.game) {
      if (section != null) _fail();
      return _gamePage(source, scope, 'search', literal, cursor, bound);
    }
    return _recordPage(
      source,
      scope,
      'search',
      section,
      literal,
      cursor,
      bound,
    );
  }

  Future<nav.Page<nav.DataRecord>> _read(
    _NavSource source,
    nav.FrozenScope scope,
    nav.ReadQuery query,
    nav.WorkBound bound,
  ) async {
    if (!_allowed(source, scope, query.selection) ||
        query.before < 0 ||
        query.before > 2 ||
        query.after < 0 ||
        query.after > 2) {
      _fail();
    }
    final capture = source.captures[_selectionKey(query.selection)];
    if (capture == null) _fail();
    if (query.selection.range != null) {
      final range = query.selection.range!;
      final start = range.start.ordinal - query.before;
      final end = range.end.ordinal + query.after;
      if (end - start + 1 > bound.pageSize) _fail();
      final page = await _gamePage(
        source,
        scope,
        'read',
        null,
        null,
        bound,
        first: start,
        last: end,
      );
      _guard();
      if (!page.complete || page.items.length != end - start + 1) _fail();
      final selected = page.items[query.before].selection.range!.start;
      if (!selected.same(range.start) ||
          !page.items[page.items.length - query.after - 1].selection.range!.end
              .same(range.end)) {
        _fail(SupportSourceReadFailure.changed);
      }
      return page;
    }
    if (query.before != 0 ||
        query.after != 0 ||
        capture.record == null ||
        query.selection.kind != nav.SelectionKind.record) {
      _fail();
    }
    final record = capture.record!;
    if (_payloadBytes(record.payload) > bound.rawByteLimit) {
      _fail(SupportSourceReadFailure.tooLarge);
    }
    return nav.Page([record], candidatesExamined: 1);
  }

  Future<nav.Page<nav.DataRecord>> _recordPage(
    _NavSource source,
    nav.FrozenScope scope,
    String operation,
    nav.Selection? section,
    String? literal,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (section != null &&
        (section.kind != nav.SelectionKind.section ||
            !_allowed(source, scope, section) ||
            !source.captures.containsKey(_selectionKey(section)))) {
      _fail();
    }
    var tableIndex = 0, after = 0, unitIndex = 0;
    var repeating = false;
    if (cursor != null) {
      if (cursor is! _NavRecordCursor ||
          !identical(cursor.source, source) ||
          !identical(cursor.scope, scope) ||
          cursor.operation != operation ||
          cursor.literal != literal ||
          (section == null
              ? cursor.section != null
              : cursor.section == null || !section.same(cursor.section!))) {
        _fail();
      }
      tableIndex = cursor.table;
      after = cursor.row;
      repeating = cursor.unit > 0;
      unitIndex = repeating ? cursor.unit - 1 : 0;
    }
    final tables = _tables(source.observation.key.domain);
    final result = <nav.DataRecord>[];
    var examined = 0, pageBytes = 0, rawBytes = 0;
    final clock = Stopwatch()..start();
    while (tableIndex < tables.length) {
      _guard();
      final table = tables[tableIndex];
      if (!table.sections.any(
        (root) =>
            scope.sections.contains(root) &&
            (section == null || section.sectionId == root),
      )) {
        tableIndex++;
        after = 0;
        unitIndex = 0;
        repeating = false;
        continue;
      }
      if (rawBytes > 0 && rawBytes + 65536 > bound.rawByteLimit) {
        return nav.Page(
          result,
          complete: false,
          exhaustedWork: true,
          next: _NavRecordCursor(
            source,
            scope,
            operation,
            section,
            literal,
            tableIndex,
            after,
            repeating ? unitIndex + 1 : 0,
          ),
          candidatesExamined: examined,
        );
      }
      final row = await _nextRow(
        table,
        source.observation.key.nativeId,
        after,
        repeat: repeating,
        byteLimit: bound.rawByteLimit - rawBytes,
      );
      _guard();
      if (row == null) {
        tableIndex++;
        after = 0;
        unitIndex = 0;
        repeating = false;
        continue;
      }
      final ordinal = row['native_rowid'] as int;
      rawBytes += row['_native_bytes'] as int;
      final data = Map<String, Object?>.of(row)..remove('_native_bytes');
      final records = row['_native_skip'] == true
          ? <nav.DataRecord>[]
          : await _rowUnits(source, table, data);
      _guard();
      if (records.length > 4096) _fail(SupportSourceReadFailure.tooLarge);
      for (var i = unitIndex; i < records.length; i++) {
        final record = records[i];
        if (++examined > bound.candidateLimit ||
            clock.elapsedMilliseconds > 1000) {
          return nav.Page(
            result,
            complete: false,
            exhaustedWork: true,
            next: _NavRecordCursor(
              source,
              scope,
              operation,
              section,
              literal,
              tableIndex,
              ordinal,
              i + 1,
            ),
            candidatesExamined: examined - 1,
          );
        }
        if (!_allowed(source, scope, record.selection) ||
            (section != null &&
                section.sectionId != record.selection.sectionId)) {
          continue;
        }
        if (literal != null &&
            (record.payload is! String ||
                !_visibleMatch(record.payload as String, literal))) {
          continue;
        }
        final bytes = _payloadBytes(record.payload);
        if (bytes > bound.rawByteLimit) {
          _fail(SupportSourceReadFailure.tooLarge);
        }
        if (pageBytes + bytes > bound.rawByteLimit) {
          if (result.isEmpty) _fail(SupportSourceReadFailure.tooLarge);
          return nav.Page(
            result,
            complete: false,
            next: _NavRecordCursor(
              source,
              scope,
              operation,
              section,
              literal,
              tableIndex,
              ordinal,
              i + 1,
            ),
            candidatesExamined: examined,
          );
        }
        _keep(source, record, data, _rowIds(source, table, data, record));
        pageBytes += bytes;
        result.add(record);
        if (result.length == bound.pageSize) {
          return nav.Page(
            result,
            complete: false,
            next: _NavRecordCursor(
              source,
              scope,
              operation,
              section,
              literal,
              tableIndex,
              ordinal,
              i + 2,
            ),
            candidatesExamined: examined,
          );
        }
      }
      after = ordinal;
      unitIndex = 0;
      repeating = false;
      // An empty/filtered source row still consumes bounded logical work.
      if (records.isEmpty &&
          (++examined >= bound.candidateLimit ||
              clock.elapsedMilliseconds > 1000)) {
        return nav.Page(
          result,
          complete: false,
          exhaustedWork: true,
          next: _NavRecordCursor(
            source,
            scope,
            operation,
            section,
            literal,
            tableIndex,
            after,
            0,
          ),
          candidatesExamined: examined,
        );
      }
    }
    return nav.Page(result, candidatesExamined: examined);
  }

  int _payloadBytes(Object? payload) =>
      utf8.encode(payload is String ? payload : jsonEncode(payload)).length;

  Future<Map<String, Object?>?> _nextRow(
    _NavTable table,
    String owner,
    int after, {
    required bool repeat,
    required int byteLimit,
  }) async {
    byteLimit = min(byteLimit, 65536);
    final op = repeat ? '=' : '>';
    final variables = [Variable.withString(owner), Variable.withInt(after)];
    if (table.clock) {
      if (!repeat && after != 0) return null;
      final size = table.columns
          .split(',')
          .map((c) => 'coalesce(octet_length($c),0)')
          .join('+');
      const where =
          "WHERE session_id = ? AND scope = 'ledger' "
          "AND name IN ('world:time','world:date','world:day')";
      final budget = await _sql(
        'SELECT count(*) AS n, coalesce(sum($size),0) AS bytes '
        'FROM tracker_rows INDEXED BY sqlite_autoindex_tracker_rows_1 $where',
        [Variable.withString(owner)],
      );
      _guard();
      if (budget.single.read<int>('n') == 0) return null;
      if (budget.single.read<int>('n') != 3) _shape.bad();
      if (budget.single.read<int>('bytes') > byteLimit) {
        _fail(SupportSourceReadFailure.tooLarge);
      }
      final rows = await _sql(
        'SELECT rowid AS native_rowid, ${table.columns} '
        'FROM tracker_rows INDEXED BY sqlite_autoindex_tracker_rows_1 $where ORDER BY name LIMIT 3',
        [Variable.withString(owner)],
      );
      _guard();
      if (rows.length != 3) _fail(SupportSourceReadFailure.changed);
      return {
        'native_rowid': rows
            .map((r) => r.read<int>('native_rowid'))
            .reduce((a, b) => a > b ? a : b),
        'clock_rows': rows.map((r) => Map<String, Object?>.of(r.data)).toList(),
        '_native_bytes': budget.single.read<int>('bytes'),
      };
    }
    if (table.jsonArray != null) {
      // A small whole row is physically bounded. Large legacy book arrays are
      // explicitly unreadable, NOT scanned with json_each per navigation call.
      final column = table.jsonArray!;
      final rows = await _sql(
        'SELECT CASE WHEN octet_length($column)<=? THEN $column END AS raw '
        'FROM ${table.table} WHERE ${table.owner}=? LIMIT 1',
        [Variable.withInt(byteLimit), Variable.withString(owner)],
      );
      _guard();
      if (rows.isEmpty) return null;
      if (rows.single.data['raw'] == null) {
        _fail(SupportSourceReadFailure.tooLarge);
      }
      final items = _shape.list(_decode(rows.single.data['raw']));
      // Validate ALL complete objects/identities in this bounded original row.
      final seen = <String>{};
      for (final item in items) {
        final object = _shape.map(item);
        if (!seen.add(_shape.id(object['id']))) _shape.bad();
        _memoryObject(object, draft: column == 'pending_drafts_json');
      }
      final ordinal = repeat ? after : after + 1;
      if (ordinal < 1 || ordinal > items.length) return null;
      return {
        'native_rowid': ordinal,
        'raw': jsonEncode(items[ordinal - 1]),
        '_native_bytes': utf8.encode(rows.single.read<String>('raw')).length,
      };
    }
    final size = table.columns
        .split(',')
        .map((c) => 'coalesce(octet_length($c),0)')
        .join('+');
    final eligibility = table.where.isEmpty ? '1' : table.where.substring(4);
    final address =
        '${table.table} INDEXED BY idx_navigation_${table.table}_owner';
    final metadata = await _sql(
      'SELECT rowid AS native_rowid, $size AS bytes, '
      'CASE WHEN ($size)<=? THEN ($eligibility) ELSE 1 END AS eligible '
      'FROM $address WHERE ${table.owner} = ? AND rowid $op ? '
      'ORDER BY rowid LIMIT 1',
      [Variable.withInt(byteLimit), ...variables],
    );
    _guard();
    if (metadata.isEmpty) return null;
    if (metadata.single.read<int>('bytes') > byteLimit) {
      _fail(SupportSourceReadFailure.tooLarge);
    }
    if (metadata.single.read<int>('eligible') != 1) {
      return {
        'native_rowid': metadata.single.read<int>('native_rowid'),
        '_native_bytes': 0,
        '_native_skip': true,
      };
    }
    final rows = await _sql(
      'SELECT rowid AS native_rowid, ${table.columns} '
      'FROM $address WHERE ${table.owner} = ? AND rowid = ? AND ($size) <= ? ${table.where} LIMIT 1',
      [
        Variable.withString(owner),
        Variable.withInt(metadata.single.read<int>('native_rowid')),
        Variable.withInt(byteLimit),
      ],
    );
    _guard();
    if (rows.length != 1) _fail(SupportSourceReadFailure.changed);
    return Map<String, Object?>.unmodifiable({
      ...rows.single.data,
      '_native_bytes': metadata.single.read<int>('bytes'),
    });
  }

  Iterable<String> _rowIds(
    _NavSource source,
    _NavTable table,
    Map<String, Object?> row,
    nav.DataRecord record,
  ) sync* {
    for (final field in [
      'id',
      'run_id',
      'message_id',
      'source_message_id',
      'knower_key',
      'subject_key',
      'start_message_id',
      'end_message_id',
    ]) {
      final value = row[field];
      if (value is String && value.isNotEmpty) yield _shape.id(value);
    }
    if (row['raw'] is String) {
      final object = _shape.map(_decode(row['raw']));
      yield _shape.id(object['id']);
      if (record.kind == nav.SectionKind.memoryRevision) {
        final match = RegExp(
          r':r(\d+):',
        ).firstMatch(record.selection.recordId!);
        if (match == null) _shape.bad();
        final revision = _shape.map(
          _shape.list(object['revisions'])[int.parse(match.group(1)!)],
        );
        yield _shape.id(revision['id']);
      }
    }
    for (final key in ['message_ids_json', 'anchors_json']) {
      if (row[key] is! String) continue;
      for (final item in _shape.list(_decode(row[key]))) {
        final id = item is String ? item : _shape.map(item)['messageId'];
        yield _shape.id(id);
      }
    }
  }

  Future<List<nav.DataRecord>> _rowUnits(
    _NavSource source,
    _NavTable table,
    Map<String, Object?> row,
  ) async => switch (source.observation.key.domain) {
    nav.SourceDomain.ordinaryPreset => _ordinaryUnits(source, row),
    nav.SourceDomain.studioPreset => _studioUnits(source, row),
    nav.SourceDomain.memory => _memoryUnits(source, table, row),
    nav.SourceDomain.savedSummary => _summaryUnits(source, row),
    nav.SourceDomain.ledgerState => _trackerUnits(source, row),
    nav.SourceDomain.ledgerSnapshot => _snapshotUnits(source, row),
    nav.SourceDomain.reconciliation => _reconciliationUnits(source, table, row),
    nav.SourceDomain.characterKnowledge => _knowledgeUnits(source, row),
    _ => const [],
  };
}
