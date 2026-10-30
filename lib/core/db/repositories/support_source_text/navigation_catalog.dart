part of '../support_source_text_repo.dart';

final class _NavListCursor {
  _NavListCursor(
    this.repo,
    this.domain,
    this.parent,
    this.rowid, {
    this.seconds,
    this.milliseconds,
  });
  final SupportSourceNavigationRepo repo;
  final nav.SourceDomain domain;
  final nav.SourceKey? parent;
  final int rowid;
  final (int, int)? seconds, milliseconds;
}

// Projection only: imported epoch seconds and milliseconds coexist. Values at
// least 1e11 are milliseconds; non-positive values have unknown activity.
const _navMillisecondFloor = 100000000000;
int _navActivity(int raw) => raw <= 0
    ? 0
    : raw < _navMillisecondFloor
    ? raw * 1000
    : raw;

const _navRoots = <nav.SourceDomain, Map<String, nav.SectionKind>>{
  nav.SourceDomain.ordinaryPreset: {
    'blocks': nav.SectionKind.presetBlock,
    'regex': nav.SectionKind.regexDefinitions,
    'reasoning': nav.SectionKind.reasoning,
    'templates': nav.SectionKind.templates,
  },
  nav.SourceDomain.studioPreset: {
    'blocks': nav.SectionKind.studioBlock,
    'agents': nav.SectionKind.studioAgents,
    'runtime': nav.SectionKind.runtime,
    'settings': nav.SectionKind.settings,
  },
  nav.SourceDomain.memory: {
    'entries': nav.SectionKind.memoryEntry,
    'revisions': nav.SectionKind.memoryRevision,
    'drafts': nav.SectionKind.memoryDraft,
    'derived': nav.SectionKind.memoryDerived,
    'settings': nav.SectionKind.settings,
  },
  nav.SourceDomain.savedSummary: {
    'text': nav.SectionKind.summaryText,
    'template': nav.SectionKind.summaryTemplate,
  },
  nav.SourceDomain.ledgerState: {'trackers': nav.SectionKind.ledgerTrackers},
  nav.SourceDomain.ledgerSnapshot: {
    'snapshots': nav.SectionKind.ledgerSnapshot,
  },
  nav.SourceDomain.reconciliation: {
    'checkpoint': nav.SectionKind.reconciliationCheckpoint,
    'results': nav.SectionKind.reconciliationSavedResult,
    'evidence': nav.SectionKind.reconciliationEvidence,
  },
  nav.SourceDomain.characterKnowledge: {'facts': nav.SectionKind.knowledgeFact},
};

extension _NavCatalog on SupportSourceNavigationRepo {
  String _savedExists(nav.SourceDomain domain) => switch (domain) {
    nav.SourceDomain.memory =>
      '(EXISTS(SELECT 1 FROM memory_book_rows m WHERE m.session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM memory_catalog_rows m WHERE m.chat_session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM memory_entity_rows m WHERE m.chat_session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM memory_salience_rows m WHERE m.chat_session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM memory_cadence_rows m WHERE m.chat_session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM memory_consolidation_rows m WHERE m.chat_session_id=s.session_id))',
    nav.SourceDomain.savedSummary =>
      'EXISTS(SELECT 1 FROM chat_summaries m WHERE m.session_id=s.session_id)',
    nav.SourceDomain.ledgerState =>
      "EXISTS(SELECT 1 FROM tracker_rows m INDEXED BY idx_trackers_session_scope WHERE m.session_id=s.session_id "
          "AND m.scope='ledger')",
    nav.SourceDomain.ledgerSnapshot =>
      'EXISTS(SELECT 1 FROM tracker_snapshots m WHERE m.session_id=s.session_id)',
    nav.SourceDomain.reconciliation =>
      '(EXISTS(SELECT 1 FROM ledger_reconciliation_checkpoints m WHERE m.session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM reconciliation_successful_runs m WHERE m.session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM ledger_reconciliation_effects m WHERE m.session_id=s.session_id) OR '
          'EXISTS(SELECT 1 FROM reconciliation_run_invalidations m WHERE m.session_id=s.session_id))',
    nav.SourceDomain.characterKnowledge =>
      'EXISTS(SELECT 1 FROM character_knowledge_fact_rows m WHERE m.chat_session_id=s.session_id)',
    _ => '1=1',
  };

  String _catalogSql(nav.SourceDomain domain) {
    if (domain == nav.SourceDomain.ordinaryPreset ||
        domain == nav.SourceDomain.studioPreset) {
      final table = domain == nav.SourceDomain.ordinaryPreset
          ? 'presets'
          : 'studio_preset_rows';
      // Ordinary presets declare no activity timestamp. Keep it unknown rather
      // than reading a Studio-only column or inventing saved activity.
      final activity = domain == nav.SourceDomain.ordinaryPreset
          ? 'NULL AS updated_at'
          : 'updated_at';
      return 'SELECT rowid AS incarnation, CASE WHEN octet_length(preset_id)<=256 THEN preset_id END AS source_id, '
          'CASE WHEN octet_length(name) <= 1024 THEN name END AS label, $activity '
          'FROM $table WHERE rowid > ?';
    }
    return '''SELECT s.rowid AS incarnation, CASE WHEN octet_length(s.session_id)<=256 THEN s.session_id END AS source_id,
      CASE WHEN octet_length(s.character_id)<=256 THEN s.character_id END AS character_id, s.session_index, c.rowid AS character_incarnation,
      CASE WHEN octet_length(c.variant_group_id)<=256 THEN c.variant_group_id END AS variant_group_id, c.variant_order,
      (c.variant_group_id IS NULL OR octet_length(c.variant_group_id)<=256) AS identities_bounded,
      CASE WHEN octet_length(c.name) <= 1024 THEN c.name END AS label, s.updated_at
      FROM chat_sessions s INNER JOIN characters c ON c.char_id = s.character_id
      WHERE s.rowid > ? AND c.hidden = 0 AND ${_savedExists(domain)}''';
  }

  Future<nav.Page<nav.SourceObservation>> _discover(
    nav.SourceDomain domain,
    nav.SourceKey? parent,
    Object? cursor,
    nav.WorkBound bound,
  ) async {
    if (parent != null && !_sources.containsKey(parent)) _fail();
    var after = 0;
    _NavListCursor? issued;
    if (cursor != null) {
      if (cursor is! _NavListCursor ||
          !identical(cursor.repo, this) ||
          cursor.domain != domain ||
          cursor.parent != parent)
        _fail();
      after = cursor.rowid;
      issued = cursor;
    }
    final sessionDomain =
        domain != nav.SourceDomain.ordinaryPreset &&
        domain != nav.SourceDomain.studioPreset;
    if (parent != null &&
        (!sessionDomain ||
            domain == nav.SourceDomain.game ||
            parent.domain != nav.SourceDomain.game))
      return nav.Page(const []);
    // Freeze a bounded keyset BEFORE eligibility/EXISTS filtering. LIMIT after
    // such filters alone could inspect every absent/hidden session in the DB.
    if (sessionDomain && parent == null) {
      return _discoverSessions(domain, bound, issued);
    }
    final rows = await _sql(
      '${_catalogSql(domain)} '
      '${parent != null ? 'AND s.session_id = ?' : ''} '
      'ORDER BY incarnation LIMIT ?',
      [
        Variable.withInt(after),
        if (parent != null) Variable.withString(parent.nativeId),
        Variable.withInt(bound.pageSize),
      ],
    );
    _guard();
    final observations = <nav.SourceObservation>[];
    for (final row in rows) {
      final id = _shape.id(row.data['source_id']);
      observations.add(
        await _fromHeader(nav.SourceKey(domain, id), row, parent, bound),
      );
      _guard();
    }
    final examined = rows.length;
    final complete =
        parent != null || examined < min(bound.pageSize, bound.candidateLimit);
    return nav.Page(
      observations,
      complete: complete,
      next: complete
          ? null
          : _NavListCursor(
              this,
              domain,
              parent,
              rows.last.read<int>('incarnation'),
            ),
      candidatesExamined: examined,
      exhaustedWork: !complete && observations.isEmpty,
    );
  }

  Future<nav.Page<nav.SourceObservation>> _discoverSessions(
    nav.SourceDomain domain,
    nav.WorkBound bound,
    _NavListCursor? cursor,
  ) async {
    // Each ordered range walks the existing (updated_at,rowid) index backwards.
    // Bound *both* streams before joins/EXISTS. Peeks not consumed by the merge
    // are re-read next time, and count against this operation's work bound.
    final take = min(bound.pageSize, bound.candidateLimit ~/ 2);
    if (take < 1) _fail(SupportSourceReadFailure.tooLarge);
    Future<List<QueryRow>> stream(bool milliseconds, (int, int)? key) => _sql(
      'SELECT rowid AS candidate_rowid, updated_at FROM chat_sessions '
      'INDEXED BY idx_chat_sessions_updated_at WHERE updated_at '
      '${milliseconds ? '>=' : '<'} ? '
      '${key == null ? '' : 'AND (updated_at,rowid)<(?,?) '} '
      'ORDER BY updated_at DESC,rowid DESC LIMIT ?',
      [
        Variable.withInt(_navMillisecondFloor),
        if (key != null) ...[
          Variable.withInt(key.$1),
          Variable.withInt(key.$2),
        ],
        Variable.withInt(take),
      ],
    );
    final seconds = await stream(false, cursor?.seconds);
    _guard();
    final milliseconds = await stream(true, cursor?.milliseconds);
    _guard();
    final candidates = [...seconds, ...milliseconds]
      ..sort((a, b) {
        final ar = a.read<int>('updated_at'), br = b.read<int>('updated_at');
        final activity = _navActivity(br).compareTo(_navActivity(ar));
        if (activity != 0) return activity;
        final raw = br.compareTo(ar);
        return raw != 0
            ? raw
            : b
                  .read<int>('candidate_rowid')
                  .compareTo(a.read<int>('candidate_rowid'));
      });
    final selected = candidates.take(take).toList();
    if (selected.isEmpty) return nav.Page(const []);
    var sk = cursor?.seconds, mk = cursor?.milliseconds;
    for (final row in selected) {
      final raw = row.read<int>('updated_at');
      final key = (raw, row.read<int>('candidate_rowid'));
      if (raw < _navMillisecondFloor) {
        sk = key;
      } else {
        mk = key;
      }
    }
    final rows = await _sql(
      '${_catalogSql(domain)} AND s.rowid IN (${List.filled(selected.length, '?').join(',')}) LIMIT ?',
      [
        Variable.withInt(0),
        ...selected.map(
          (r) => Variable.withInt(r.read<int>('candidate_rowid')),
        ),
        Variable.withInt(take),
      ],
    );
    _guard();
    final byId = {for (final row in rows) row.read<int>('incarnation'): row};
    final observations = <nav.SourceObservation>[];
    for (final candidate in selected) {
      final row = byId[candidate.read<int>('candidate_rowid')];
      if (row == null) continue;
      observations.add(
        await _fromHeader(
          nav.SourceKey(domain, _shape.id(row.data['source_id'])),
          row,
          null,
          bound,
        ),
      );
      _guard();
    }
    final complete =
        candidates.length <= take &&
        seconds.length < take &&
        milliseconds.length < take;
    return nav.Page(
      observations,
      complete: complete,
      next: complete
          ? null
          : _NavListCursor(
              this,
              domain,
              null,
              0,
              seconds: sk,
              milliseconds: mk,
            ),
      candidatesExamined: candidates.length,
      exhaustedWork: !complete && observations.isEmpty,
    );
  }

  Future<nav.SourceObservation?> _observe(
    nav.SourceKey key,
    nav.WorkBound bound,
  ) async {
    _shape.id(key.nativeId);
    final retained = _sources[key];
    if (retained != null) return retained.observation;
    final session =
        key.domain != nav.SourceDomain.ordinaryPreset &&
        key.domain != nav.SourceDomain.studioPreset;
    final rows = await _sql(
      '${_catalogSql(key.domain)} AND '
      '${session ? 's.session_id' : 'preset_id'} = ? LIMIT 1',
      [Variable.withInt(0), Variable.withString(key.nativeId)],
    );
    _guard();
    return rows.isEmpty ? null : _fromHeader(key, rows.single, null, bound);
  }

  Future<nav.SourceObservation> _fromHeader(
    nav.SourceKey key,
    QueryRow row,
    nav.SourceKey? parent,
    nav.WorkBound bound,
  ) async {
    final existing = _sources[key];
    if (existing != null) return existing.observation;
    if (_sources.length >= 128) _fail(SupportSourceReadFailure.tooLarge);
    var header = Map<String, Object?>.unmodifiable(row.data);
    if (header['incarnation'] is! int) _shape.bad();
    final session =
        key.domain != nav.SourceDomain.ordinaryPreset &&
        key.domain != nav.SourceDomain.studioPreset;
    if (session) {
      if (header['identities_bounded'] != 1) _shape.bad();
      _shape.id(header['character_id']);
      if (header['character_incarnation'] is! int ||
          header['session_index'] is! int ||
          (header['session_index'] as int) < 0 ||
          (header['session_index'] as int) > 1000000 ||
          header['variant_order'] is! int ||
          (header['variant_order'] as int) < 0 ||
          (header['variant_order'] as int) > 1000000)
        _shape.bad();
      if (header['variant_group_id'] != null &&
          header['variant_group_id'] != '')
        _shape.id(header['variant_group_id']);
    }
    bool? active;
    if (key.domain == nav.SourceDomain.studioPreset && _activeStudio != null) {
      _guard();
      final selected = await _activeStudio();
      _guard();
      _shape.id(selected);
      // Mirror studioPresetProvider / StudioPresetRepo.getDefault(): existing
      // selected ID, otherwise the saved `default`. Probe identities only;
      // never hydrate or parse authored definitions merely for metadata.
      final resolved = await _sql(
        'SELECT preset_id FROM studio_preset_rows '
        'WHERE preset_id IN (?, ?) ORDER BY CASE WHEN preset_id = ? THEN 0 ELSE 1 END LIMIT 1',
        [
          Variable.withString(selected),
          Variable.withString('default'),
          Variable.withString(selected),
        ],
      );
      _guard();
      active = resolved.isEmpty
          ? null
          : key.nativeId == resolved.single.read<String>('preset_id');
    } else if (key.domain == nav.SourceDomain.ordinaryPreset &&
        _activeOrdinary != null) {
      final selected = await _activeOrdinary();
      _guard();
      if (selected != null) _shape.id(selected);
      active = selected == null ? null : key.nativeId == selected;
    }
    if (key.domain == nav.SourceDomain.game) {
      header = {...header, 'history_index': await _gameIndex(key.nativeId)};
      _guard();
    }
    final stamp = _fence!;
    final private = sha256
        .convert(
          utf8.encode(
            jsonEncode([
              identityHashCode(_native),
              key.domain.name,
              header,
              stamp.$1,
              stamp.$2,
            ]),
          ),
        )
        .toString();
    final observation = nav.SourceObservation(
      key: key,
      snapshot: nav.Snapshot(private, stamp.$1, privateIntegrity: private),
      lease: _NavLease(this),
      state:
          key.domain == nav.SourceDomain.game &&
              (header['history_index'] as Map<String, Object?>)['status'] !=
                  'ready'
          ? nav.SourceState.unknown
          : session
          ? nav.SourceState.current
          : nav.SourceState.currentSaved,
      parent: session && key.domain != nav.SourceDomain.game
          ? nav.SourceKey(nav.SourceDomain.game, key.nativeId)
          : parent,
      activeAtListing: active,
      binding: session
          ? nav.Binding(
              sessionId: key.nativeId,
              characterId: header['character_id'] as String,
            )
          : const nav.Binding(),
    );
    nav.FrozenScope? scope;
    if (key.domain == nav.SourceDomain.game) {
      scope = await _gameScope(key.nativeId, bound);
      _guard();
    } else {
      scope = nav.FrozenScope.sections(_navRoots[key.domain]!.keys);
    }
    final label = header['label'];
    _sources[key] = _NavSource(
      observation,
      header,
      label is String ? label : null,
      scope,
    );
    return observation;
  }
}
