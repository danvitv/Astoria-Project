part of '../support_source_text_repo.dart';

final class _ApplicationListCursor {
  const _ApplicationListCursor(this.repo, this.offset);
  final SupportSourceNavigationRepo repo;
  final int offset;
}

final class _ApplicationCursor {
  const _ApplicationCursor(
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

extension _NavApplication on SupportSourceNavigationRepo {
  int _applicationPosition(String table, int row) {
    final key = '$table:$row';
    final existing = _applicationPositions[key];
    if (existing != null) return existing;
    if (_applicationPositions.length >= nav.Limits.candidates)
      _fail(SupportSourceReadFailure.tooLarge);
    return _applicationPositions[key] = _applicationPositions.length + 1;
  }

  Future<nav.Page<nav.SourceObservation>> _discoverApplication(
    nav.SourceKey? parent,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (parent != null) return nav.Page(const []);
    var offset = 0;
    if (cursor != null) {
      if (cursor is! _ApplicationListCursor || !identical(cursor.repo, this))
        _fail();
      offset = cursor.offset;
    }
    final result = <nav.SourceObservation>[];
    for (final dataset
        in _applicationDatasets
            .skip(offset)
            .take(min(bound.pageSize, bound.candidateLimit))) {
      final key = nav.SourceKey(nav.SourceDomain.applicationData, dataset.name);
      var source = _sources[key];
      if (source == null) {
        // Indexed max(rowid) is a fixed upper membership bound, not a row count.
        // Own provenance writes never expand any of these frozen datasets.
        final maxima = <String, Object?>{};
        for (final table in dataset.tables) {
          final row = await _sql(
            'SELECT coalesce(max(rowid),0) AS last FROM "${table.table}"',
          );
          _guard();
          maxima[table.section] = row.single.read<int>('last');
        }
        source = _newApplicationSource(
          key,
          {'dataset': dataset.name, 'limits': maxima},
          dataset.title,
          dataset.tables.map((t) => t.section),
        );
      }
      result.add(source.observation);
    }
    final next = offset + result.length;
    return nav.Page(
      result,
      candidatesExamined: result.length,
      complete: next >= _applicationDatasets.length,
      next: next >= _applicationDatasets.length
          ? null
          : _ApplicationListCursor(this, next),
    );
  }

  _NavSource _newApplicationSource(
    nav.SourceKey key,
    Map<String, Object?> header,
    String? label,
    Iterable<String> sections, {
    nav.Binding binding = const nav.Binding(),
  }) {
    if (_sources.length >= nav.Limits.references)
      _fail(SupportSourceReadFailure.tooLarge);
    final stamp = _fence!;
    final digest = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              identityHashCode(_native),
              key.domain.name,
              key.nativeId,
              header,
              stamp.$1,
              stamp.$2,
            ]),
          ),
        )
        .toString();
    final source = _NavSource(
      nav.SourceObservation(
        key: key,
        snapshot: nav.Snapshot(digest, stamp.$1, privateIntegrity: digest),
        lease: _NavLease(this),
        state: nav.SourceState.currentSaved,
        binding: binding,
      ),
      Map.unmodifiable(header),
      label,
      nav.FrozenScope.sections(sections),
    );
    _sources[key] = source;
    return source;
  }

  List<_ApplicationTable> _applicationTables(_NavSource source) =>
      _applicationDatasets
          .firstWhere((d) => d.name == source.observation.key.nativeId)
          .tables;

  Future<nav.Page<nav.SectionDescriptor>> _applicationContents(
    _NavSource source,
    nav.FrozenScope scope,
    nav.Selection? section,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (source.observation.key.domain == nav.SourceDomain.astoriaConversation) {
      final page = await _astoriaPage(
        source,
        scope,
        'contents',
        section,
        null,
        cursor,
        bound,
      );
      return _applicationDescriptors(page);
    }
    if (section != null) {
      return _applicationDescriptors(
        await _applicationPage(
          source,
          scope,
          'contents',
          section,
          null,
          cursor,
          bound,
        ),
      );
    }
    if (cursor != null) _fail();
    final descriptors = <nav.SectionDescriptor>[];
    for (final table in _applicationTables(source)) {
      if (!scope.sections.contains(table.section)) continue;
      final record = nav.DataRecord(
        selection: nav.Selection.section(table.section),
        kind: nav.SectionKind.applicationRecord,
        payload: null,
        state: source.observation.state,
        label: table.title,
      );
      _keep(source, record, source.header, const []);
      descriptors.add(
        nav.SectionDescriptor(
          record.selection,
          record.kind,
          state: record.state,
          label: table.title,
        ),
      );
    }
    return nav.Page(descriptors);
  }

  nav.Page<nav.SectionDescriptor> _applicationDescriptors(
    nav.Page<nav.DataRecord> page,
  ) => nav.Page(
    page.items.map(
      (r) => nav.SectionDescriptor(
        r.selection,
        r.kind,
        state: r.state,
        binding: r.binding,
        label: r.label,
      ),
    ),
    next: page.next,
    complete: page.complete,
    exhaustedWork: page.exhaustedWork,
    candidatesExamined: page.candidatesExamined,
  );

  Future<nav.Page<nav.DataRecord>> _applicationPage(
    _NavSource source,
    nav.FrozenScope scope,
    String operation,
    nav.Selection? section,
    String? literal,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (source.observation.key.domain == nav.SourceDomain.astoriaConversation) {
      return _astoriaPage(
        source,
        scope,
        operation,
        section,
        literal,
        cursor,
        bound,
      );
    }
    if (section != null &&
        (section.kind != nav.SelectionKind.section ||
            !_allowed(source, scope, section) ||
            !source.captures.containsKey(_selectionKey(section))))
      _fail();
    var tableIndex = 0, after = 0, unit = 0;
    if (cursor != null) {
      if (cursor is! _ApplicationCursor ||
          !identical(cursor.source, source) ||
          !identical(cursor.scope, scope) ||
          cursor.operation != operation ||
          cursor.literal != literal ||
          (section == null
              ? cursor.section != null
              : cursor.section == null || !section.same(cursor.section!)))
        _fail();
      tableIndex = cursor.table;
      after = cursor.row;
      unit = cursor.unit;
    }
    final tables = _applicationTables(source);
    final maxima = source.header['limits'] as Map<String, Object?>;
    final result = <nav.DataRecord>[];
    var examined = 0, rawBytes = 0, payloadBytes = 0;
    var omitted = false;
    final clock = Stopwatch()..start();
    nav.Page<nav.DataRecord> partial() => nav.Page(
      result,
      complete: false,
      exhaustedWork: result.length < bound.pageSize,
      candidatesExamined: examined,
      next: _ApplicationCursor(
        source,
        scope,
        operation,
        section,
        literal,
        tableIndex,
        after,
        unit,
      ),
    );
    while (tableIndex < tables.length) {
      final table = tables[tableIndex];
      if (!scope.sections.contains(table.section) ||
          (section != null && section.sectionId != table.section)) {
        tableIndex++;
        after = 0;
        unit = 0;
        continue;
      }
      if (examined >= bound.candidateLimit ||
          clock.elapsedMilliseconds >= 1000 ||
          rawBytes + 65536 > bound.rawByteLimit ||
          result.length >= bound.pageSize)
        return partial();
      final row = await _applicationRow(
        table,
        after,
        maxima[table.section] as int,
        repeat: unit > 0,
        byteLimit: min(65536, bound.rawByteLimit - rawBytes),
      );
      _guard();
      if (row == null) {
        tableIndex++;
        after = 0;
        unit = 0;
        continue;
      }
      final rowid = row['native_rowid'] as int;
      rawBytes += row['_bytes'] as int;
      final records = await _applicationUnits(source, table, row);
      _guard();
      omitted =
          omitted ||
          row['_unreadable'] != null ||
          records.any(
            (r) =>
                r.payload is Map<String, Object?> &&
                (r.payload as Map<String, Object?>)['status'] != null &&
                (r.payload as Map<String, Object?>)['status'] !=
                    'safe_saved_projection',
          );
      if (records.isEmpty) examined++;
      for (var i = unit > 0 ? unit - 1 : 0; i < records.length; i++) {
        after = rowid;
        unit = i + 1;
        if (examined >= bound.candidateLimit ||
            clock.elapsedMilliseconds >= 1000 ||
            result.length >= bound.pageSize)
          return partial();
        final record = records[i];
        examined++;
        // These units were already projected as COMPLETE authored values by
        // _ApplicationProjection before flattening. Re-parsing a generated
        // redaction marker (e.g. [redacted]) as authored JSON would incorrectly
        // retire the source as malformed. Match only that safe immutable value;
        // original policy custody and final wire projection remain unchanged.
        _guard();
        final searchable = record.payload is String
            ? record.payload as String
            : jsonEncode(record.payload);
        if (!_allowed(source, scope, record.selection) ||
            (literal != null && !searchable.contains(literal)))
          continue;
        final bytes = _payloadBytes(record.payload);
        if (payloadBytes + bytes > bound.rawByteLimit) return partial();
        _keep(source, record, row, ['${table.table}:$rowid']);
        result.add(record);
        payloadBytes += bytes;
      }
      after = rowid;
      unit = 0;
    }
    return nav.Page(
      result,
      candidatesExamined: examined,
      complete: !omitted,
      exhaustedWork: omitted,
    );
  }

  Future<Map<String, Object?>?> _applicationRow(
    _ApplicationTable table,
    int after,
    int maximum, {
    required bool repeat,
    required int byteLimit,
  }) async {
    final projection = table.projection;
    // Exact-AAD identity/envelope are private input ONLY for this fixed reader.
    if (table.encryptedSummary)
      projection.addAll({
        '_id': 't.id',
        '_session': 't.session_id',
        '_summary': 't.summary_ciphertext',
      });
    if (table.session != null) projection['_session'] = 't."${table.session}"';
    var eligible = table.visible;
    if (table.session != null && !table.supportSession) {
      final owner =
          'EXISTS(SELECT 1 FROM chat_sessions s JOIN characters c ON c.char_id=s.character_id WHERE s.session_id=t."${table.session}" AND c.hidden=0)';
      eligible =
          '($eligible) AND (${table.nullableSession ? 't."${table.session}" IS NULL OR ' : ''}$owner)';
    }
    final size = projection.values
        .map((v) => 'coalesce(octet_length(($v)),0)')
        .join('+');
    final safeSize = size.isEmpty ? '0' : size;
    // Candidate seek is bounded BEFORE visibility/owner filtering. No WHERE
    // predicate can silently scan all hidden, missing or unsuitable records.
    final rows = await _sql(
      'SELECT t.rowid AS native_rowid, CASE WHEN ($eligible) THEN ($safeSize) ELSE 0 END AS _bytes, '
      '($eligible) AS _eligible, '
      '${projection.entries.map((e) => 'CASE WHEN ($eligible) THEN CASE WHEN ($safeSize)<=? THEN (${e.value}) END END AS "${e.key}"').join(',')} '
      'FROM "${table.table}" t WHERE t.rowid ${repeat ? '=' : '>'} ? AND t.rowid<=? ORDER BY t.rowid LIMIT 1',
      [
        for (final _ in projection.entries) Variable.withInt(byteLimit),
        Variable.withInt(after),
        Variable.withInt(maximum),
      ],
    );
    _guard();
    if (rows.isEmpty) return null;
    final row = Map<String, Object?>.of(rows.single.data);
    if (row['_eligible'] != 1)
      return {'native_rowid': row['native_rowid'], '_bytes': 0, '_skip': true};
    if ((row['_bytes'] as int) > byteLimit) {
      return {
        'native_rowid': row['native_rowid'],
        '_bytes': 0,
        '_unreadable': 'oversized_complete_unit',
      };
    }
    return row;
  }

  Future<List<nav.DataRecord>> _applicationUnits(
    _NavSource source,
    _ApplicationTable table,
    Map<String, Object?> row,
  ) async {
    if (row['_skip'] == true) return const [];
    final ordinal = row['native_rowid'] as int;
    final values = <String, Object?>{};
    final projection = _ApplicationProjection(this);
    var unavailable = row['_unreadable'] as String?;
    if (unavailable == null) {
      try {
        if (table.table == 'history_message_units' && row['_unitValid'] != 1)
          _fail(SupportSourceReadFailure.changed);
        for (final field in table.projection.keys) {
          if (field.startsWith('_')) continue;
          final raw = row[field];
          if (field.endsWith('_json') && raw is String && raw.isNotEmpty) {
            values[field] = projection.jsonColumn(raw, field);
          } else if (field.endsWith('_json') && (raw == null || raw == '')) {
            values[field] = null;
          } else if (field.endsWith('_json')) {
            throw const FormatException('Unsupported saved unit');
          } else if (field.endsWith('Reference') && raw is int) {
            final target = switch (field) {
              'folderReference' =>
                table.table == 'character_folder_members'
                    ? 'character_folders'
                    : 'preset_folders',
              'characterReference' => 'characters',
              'presetReference' =>
                row['kind'] == 'normal' ? 'presets' : 'studio_preset_rows',
              'transitionReference' => 'applied_canon_transition_rows',
              'knowledgeReference' => 'character_knowledge_fact_rows',
              'lorebookReference' => 'lorebooks',
              'checkpointReference' => 'session_canon_checkpoint_rows',
              'jobReference' => 'rewrite_jobs',
              'operationReference' => 'rewrite_operations',
              'claimReference' => 'card_evolution_claims',
              _ => throw const FormatException('Unsupported relation'),
            };
            values[field] = _applicationPosition(target, raw);
          } else {
            values[field] = projection.sanitize(raw);
          }
        }
        if (table.encryptedSummary) {
          final summary = await _readCipher.decrypt(
            envelopeText: row['_summary'] as String,
            table: 'support_context_blocks',
            rowId: _shape.id(row['_id']),
            sessionId: _shape.id(row['_session']),
            field: 'summary_ciphertext',
          );
          _guard();
          values['summary'] = projection.text(summary);
        }
      } on FormatException {
        unavailable = 'unknown_saved_format';
        values.clear();
      } on SupportCipherException {
        unavailable = 'locked_or_invalid_encrypted_unit';
        values.clear();
      }
    }
    values['projectionStatus'] = {
      'status': unavailable ?? 'safe_saved_projection',
      'privateFieldsOmitted': true,
      'unknownFieldsOmitted': projection.omitted,
      'filesystemAccess': false,
      'scriptsExecuted': false,
      if (table.table == 'api_configs')
        'credentialPresence': 'unknown_not_selected',
      if (table.diagnostic) ...{
        'retention': 'bounded_saved_diagnostic_only',
        'missingRows': 'not_proof_of_eviction',
        'historicalPrompt': table.table == 'llm_request_capture_rows'
            ? 'actual_sanitized_transport_capture_may_be_truncated'
            : 'not_proven_by_this_record',
      },
    };
    final result = <nav.DataRecord>[];
    var counter = 0;
    final binding = row['_session'] is String
        ? nav.Binding(sessionId: row['_session'] as String)
        : const nav.Binding();
    void emit(Object? value, String field) {
      final label =
          'Record ${_applicationPosition(table.table, ordinal)} · $field';
      result.add(
        nav.DataRecord(
          selection: nav.Selection.record(
            table.section,
            '${table.section}:$ordinal:${counter++}',
          ),
          kind: nav.SectionKind.applicationRecord,
          state: source.observation.state,
          binding: binding,
          payload: value,
          schemaKeysAttested: true,
          label: label.length <= 120 ? label : table.title,
        ),
      );
    }

    void flatten(Object? value, String field) {
      if (value is Map<String, Object?>) {
        var index = 0;
        for (final e in value.entries) {
          // Native positions preserve the logical entry/variation association.
          // Arbitrary authored variable names remain text VALUES, not paths or
          // model-usable selectors. Only known schema keys may label fields.
          final member =
              _applicationJsonFields.contains(e.key) &&
                  !field.startsWith('session_vars_json')
              ? e.key
              : 'item${index++}';
          flatten(e.key, '$field.$member.fieldName');
          flatten(e.value, '$field.$member');
        }
      } else if (value is List<Object?>) {
        for (var i = 0; i < value.length; i++) {
          flatten(value[i], '$field.item$i');
        }
      } else if (value is String) {
        emit(value, field);
      } else {
        emit({'field': field, 'value': value}, field);
      }
    }

    for (final e in values.entries) {
      if (e.key == 'projectionStatus' ||
          e.key == 'extra_request_parameters_json')
        emit(e.value, e.key);
      else
        flatten(e.value, e.key);
    }
    if (result.length > 4096) _fail(SupportSourceReadFailure.tooLarge);
    return result;
  }
}
