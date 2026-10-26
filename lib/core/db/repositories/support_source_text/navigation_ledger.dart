part of '../support_source_text_repo.dart';

extension _NavLedger on SupportSourceNavigationRepo {
  List<nav.DataRecord> _summaryUnits(
    _NavSource source,
    Map<String, Object?> row,
  ) {
    _shape.fields(
      row,
      strings: const {'session_id', 'content', 'prompt'},
      ints: const {'native_rowid', 'enabled', 'message_count', 'updated_at'},
      nullable: const {'prompt'},
    );
    if ((row['enabled'] != 0 && row['enabled'] != 1) ||
        (row['message_count'] as int) < 0)
      _shape.bad();
    final prefix = 'summary:${row['native_rowid']}';
    return [
      _unit(
        source,
        'text',
        '$prefix:text',
        nav.SectionKind.summaryText,
        _strictText(row['content']),
      ),
      _unit(source, 'text', '$prefix:settings', nav.SectionKind.summaryText, {
        'enabled': row['enabled'] == 1,
        'messageCount': row['message_count'],
        'updatedAt': row['updated_at'],
      }),
      if (row['prompt'] != null)
        _unit(
          source,
          'template',
          '$prefix:template',
          nav.SectionKind.summaryTemplate,
          _strictText(row['prompt']),
        ),
    ];
  }

  String _strictText(Object? value) {
    if (value is! String) _shape.bad();
    return SupportSourceJson.decode(
          jsonEncode(value),
          maxBytes: nav.Limits.rawBytes,
        )
        as String;
  }

  Map<String, Object?> _trackerShape(
    Map<String, Object?> row,
    String session, {
    bool native = true,
  }) {
    final m = Map<String, Object?>.of(row)..remove('native_rowid');
    _shape.fields(
      m,
      strings: native
          ? const {
              'session_id',
              'name',
              'value',
              'scope',
              'provenance',
              'basis_revision_hash',
            }
          : const {
              'sessionId',
              'name',
              'value',
              'scope',
              'provenance',
              'basisRevisionHash',
            },
      ints: native
          ? const {'basis_revision', 'updated_at'}
          : const {'basisRevisionNumber', 'updatedAt'},
      required: native
          ? const {
              'session_id',
              'name',
              'value',
              'scope',
              'provenance',
              'basis_revision',
              'updated_at',
            }
          : const {'sessionId', 'name', 'value', 'scope', 'provenance'},
    );
    if (m[native ? 'session_id' : 'sessionId'] != session) _shape.bad();
    _shape.choice(m, 'scope', const {'ledger', 'chat', 'system', 'diagnostic'});
    if (m['name'] is! String || (m['name'] as String).isEmpty) _shape.bad();
    _strictText(m['value']);
    return m;
  }

  List<nav.DataRecord> _trackerUnits(
    _NavSource source,
    Map<String, Object?> row,
  ) {
    if (row.containsKey('clock_rows')) {
      final clock = <String, Object?>{};
      for (final raw in _shape.list(row['clock_rows'])) {
        final tracker = _trackerShape(
          _shape.map(raw),
          source.observation.key.nativeId,
        );
        final name = tracker['name'] as String;
        if (tracker['scope'] != 'ledger' ||
            !const {'world:time', 'world:date', 'world:day'}.contains(name) ||
            (tracker['value'] as String).trim().isEmpty ||
            clock.containsKey(name))
          _shape.bad();
        clock[name] = tracker['value'];
      }
      if (clock.length != 3) _shape.bad();
      final prefix = 'clock:${row['native_rowid']}';
      return [
        _unit(
          source,
          'trackers',
          '$prefix:tuple',
          nav.SectionKind.ledgerTrackers,
          {
            'time': clock['world:time'],
            'date': clock['world:date'],
            'day': clock['world:day'],
          },
          state: nav.SourceState.current,
        ),
        ..._fields(
          source,
          'trackers',
          prefix,
          nav.SectionKind.ledgerTrackers,
          clock,
          state: nav.SourceState.current,
        ),
      ];
    }
    final m = _trackerShape(row, source.observation.key.nativeId);
    if (m['scope'] != 'ledger') _shape.bad();
    return _fields(
      source,
      'trackers',
      'tracker:${row['native_rowid']}',
      nav.SectionKind.ledgerTrackers,
      m,
      private: const {'session_id', 'basis_revision_hash'},
      state: nav.SourceState.current,
    );
  }

  Future<List<nav.DataRecord>> _snapshotUnits(
    _NavSource source,
    Map<String, Object?> row,
  ) async {
    _shape.fields(
      row,
      strings: const {'session_id', 'message_id', 'trackers_json'},
      ints: const {
        'native_rowid',
        'swipe_id',
        'agent_swipe_id',
        'committed',
        'created_at',
      },
    );
    if (row['committed'] != 0 && row['committed'] != 1) _shape.bad();
    final bootstrap = row['message_id'] == '';
    if (bootstrap &&
        (row['committed'] != 1 ||
            row['swipe_id'] != 0 ||
            row['agent_swipe_id'] != 0))
      _shape.bad();
    final anchor = bootstrap
        ? null
        : await _savedAnchor(
            source,
            row['message_id'] as String,
            row['swipe_id'] as int,
            row['agent_swipe_id'] as int,
          );
    _guard();
    final state = bootstrap
        ? nav.SourceState.bootstrap
        : row['committed'] == 1
        ? nav.SourceState.historicalCommitted
        : nav.SourceState.tentative;
    final binding = nav.Binding(
      sessionId: source.observation.key.nativeId,
      characterId: source.observation.binding.characterId,
      anchor: anchor,
      savedAnchor: bootstrap ? null : nav.SavedAnchor(
        row['message_id'] as String, '${row['swipe_id']}', '${row['agent_swipe_id']}',
      ),
      evidence: nav.Evidence(!bootstrap && anchor == null ? nav.EvidenceState.missing : nav.EvidenceState.unknown),
    );
    final trackers = _shape.list(_decode(row['trackers_json']));
    final records = <nav.DataRecord>[];
    final seen = <String>{};
    var index = 0;
    for (final raw in trackers) {
      final m = _trackerShape(
        _shape.map(raw),
        source.observation.key.nativeId,
        native: false,
      );
      if (!seen.add(m['name'] as String)) _shape.bad();
      if (m['scope'] != 'ledger' || (m['name'] as String).startsWith('canon_'))
        continue;
      records.addAll(
        _fields(
          source,
          'snapshots',
          'snapshot:${row['native_rowid']}:${index++}',
          nav.SectionKind.ledgerSnapshot,
          m,
          binding: binding,
          state: state,
          private: const {'sessionId', 'basisRevisionHash'},
        ),
      );
    }
    records.add(
      _unit(
        source,
        'snapshots',
        'snapshot:${row['native_rowid']}:commit',
        nav.SectionKind.ledgerSnapshot,
        {'committed': row['committed'] == 1, 'createdAt': row['created_at']},
        binding: binding,
        state: state,
      ),
    );
    return records;
  }

  Map<String, Object?> _knowledgeShape(
    Map<String, Object?> row,
    String session, {
    bool camel = false,
  }) {
    final m = Map<String, Object?>.of(row)..remove('native_rowid');
    if (camel) {
      const keys = <String, String>{
        'chatSessionId': 'chat_session_id',
        'knowerKey': 'knower_key',
        'knowerName': 'knower_name',
        'subjectKey': 'subject_key',
        'subjectName': 'subject_name',
        'factClass': 'fact_class',
        'scopeKey': 'scope_key',
        'epistemicState': 'epistemic_state',
        'entitiesJson': 'entities_json',
        'topicsJson': 'topics_json',
        'sourceMessageId': 'source_message_id',
        'sourceSwipeId': 'source_swipe_id',
        'sourceAgentSwipeId': 'source_agent_swipe_id',
        'sourceKind': 'source_kind',
        'supersedesId': 'supersedes_id',
        'basisRevision': 'basis_revision',
        'basisRevisionHash': 'basis_revision_hash',
        'createdAt': 'created_at',
        'updatedAt': 'updated_at',
      };
      for (final e in keys.entries) {
        if (m.containsKey(e.key)) m[e.value] = m.remove(e.key);
      }
    }
    _shape.fields(
      m,
      strings: const {
        'id',
        'chat_session_id',
        'knower_key',
        'knower_name',
        'subject_key',
        'subject_name',
        'fact_class',
        'scope_key',
        'predicate',
        'object',
        'epistemic_state',
        'entities_json',
        'topics_json',
        'source_message_id',
        'source_kind',
        'supersedes_id',
        'lifecycle',
        'basis_revision_hash',
      },
      ints: const {
        'source_swipe_id',
        'source_agent_swipe_id',
        'basis_revision',
        'created_at',
        'updated_at',
      },
      nums: const {'confidence', 'importance'},
      nullable: const {'supersedes_id'},
      required: const {
        'id',
        'chat_session_id',
        'knower_key',
        'subject_key',
        'fact_class',
        'predicate',
        'object',
        'epistemic_state',
        'confidence',
        'importance',
        'source_message_id',
        'source_swipe_id',
        'source_agent_swipe_id',
        'lifecycle',
      },
    );
    if (m['chat_session_id'] != session) _shape.bad();
    for (final key in ['id', 'knower_key', 'subject_key']) _shape.id(m[key]);
    if (m['supersedes_id'] != null) _shape.id(m['supersedes_id']);
    _shape.id(m['source_message_id'], empty: true);
    _shape.choice(m, 'fact_class', const {
      'knowledge',
      'relationship',
      'behavior_change',
      'commitment',
      'goal',
      'persistent_condition',
      'identity_development',
    });
    _shape.choice(m, 'epistemic_state', const {
      'observed',
      'heard_claim',
      'inferred',
      'confirmed',
      'disbelieved',
      'forgotten',
      'retracted',
    });
    _shape.choice(m, 'lifecycle', const {
      'tentative',
      'active',
      'superseded',
      'retracted',
    });
    if ((m['confidence'] as num) < 0 ||
        (m['confidence'] as num) > 1 ||
        (m['importance'] as num) < 0 ||
        (m['importance'] as num) > 1 ||
        (m['source_swipe_id'] as int) < 0 ||
        (m['source_agent_swipe_id'] as int) < 0)
      _shape.bad();
    for (final key in ['entities_json', 'topics_json']) {
      if (!m.containsKey(key)) continue;
      final values = _decode(m[key]);
      _shape.strings(values);
      m[key] = values;
    }
    return m;
  }

  Future<List<nav.DataRecord>> _knowledgeUnits(
    _NavSource source,
    Map<String, Object?> row,
  ) async {
    final m = _knowledgeShape(row, source.observation.key.nativeId);
    final anchor = m['source_message_id'] == ''
        ? null
        : await _savedAnchor(
            source,
            m['source_message_id'] as String,
            m['source_swipe_id'] as int,
            m['source_agent_swipe_id'] as int,
          );
    _guard();
    final binding = nav.Binding(
      sessionId: source.observation.key.nativeId,
      characterId: source.observation.binding.characterId,
      knowerId: m['knower_key'] as String,
      subjectId: m['subject_key'] as String,
      anchor: anchor,
      evidence: nav.Evidence(
        anchor == null && m['source_message_id'] != ''
            ? nav.EvidenceState.missing
            : nav.EvidenceState.unknown,
      ),
    );
    final state = switch (m['lifecycle']) {
      'active' => nav.SourceState.active,
      'tentative' => nav.SourceState.tentative,
      'superseded' => nav.SourceState.superseded,
      'retracted' => nav.SourceState.retracted,
      _ => nav.SourceState.unknown,
    };
    return _fields(
      source,
      'facts',
      'fact:${row['native_rowid']}',
      nav.SectionKind.knowledgeFact,
      {...m, 'hasSupersedes': m['supersedes_id'] != null},
      binding: binding,
      state: state,
      private: const {
        'id',
        'chat_session_id',
        'knower_key',
        'subject_key',
        'source_message_id',
        'source_swipe_id',
        'source_agent_swipe_id',
        'supersedes_id',
        'basis_revision_hash',
      },
    );
  }
}
