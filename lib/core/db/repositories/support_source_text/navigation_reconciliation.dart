part of '../support_source_text_repo.dart';

const _reconciliationTables = <_NavTable>[
  _NavTable(
    'ledger_reconciliation_checkpoints',
    'session_id',
    'session_id,start_message_id,end_message_id,end_swipe_id,end_agent_swipe_id,message_ids_json,range_hash,reviewed_at',
    {'checkpoint', 'evidence'},
  ),
  _NavTable(
    'reconciliation_successful_runs',
    'session_id',
    'id,session_id,ordinal,start_message_id,start_swipe_id,start_agent_swipe_id,end_message_id,'
        'end_swipe_id,end_agent_swipe_id,anchors_json,range_hash,accepted_manifest_refs_json,'
        'effective_canon_stamp,effective_canon_revision,effective_canon_hash,canonical_result_json,'
        'content_hash,predecessor_chain_hash,chain_hash,contract_version,ops_applied_json,created_at',
    {'results', 'evidence'},
  ),
  _NavTable(
    'ledger_reconciliation_effects',
    'session_id',
    'run_id,session_id,before_ledger_json,after_ledger_json,before_knowledge_json,after_knowledge_json,'
        'actual_effects_json,before_state_hash,after_state_hash,effects_hash,created_at',
    {'results'},
  ),
  _NavTable(
    'reconciliation_run_invalidations',
    'session_id',
    'id,session_id,run_id,cause_message_id,reason,created_at',
    {'evidence'},
  ),
];

Object? _navCanonical(Object? value) {
  if (value is Map<String, Object?>) {
    final keys = value.keys.toList()..sort();
    return {for (final key in keys) key: _navCanonical(value[key])};
  }
  if (value is List) return value.map(_navCanonical).toList();
  return value;
}

String _navCanonicalJson(Object? value) => jsonEncode(_navCanonical(value));
String _navHash(String raw) => sha256.convert(utf8.encode(raw)).toString();

extension _NavReconciliation on SupportSourceNavigationRepo {
  Future<List<nav.DataRecord>> _reconciliationUnits(
    _NavSource source,
    _NavTable table,
    Map<String, Object?> row,
  ) async {
    final prefix = '${table.table}:${row['native_rowid']}';
    switch (table.table) {
      case 'ledger_reconciliation_checkpoints':
        _shape.fields(
          row,
          strings: const {
            'session_id',
            'start_message_id',
            'end_message_id',
            'message_ids_json',
            'range_hash',
          },
          ints: const {
            'native_rowid',
            'end_swipe_id',
            'end_agent_swipe_id',
            'reviewed_at',
          },
        );
        final ids = _shape.list(_decode(row['message_ids_json']));
        _shape.strings(ids, identities: true);
        if (ids.isEmpty ||
            ids.length > 16 ||
            ids.toSet().length != ids.length ||
            ids.first != row['start_message_id'] ||
            ids.last != row['end_message_id']) {
          _shape.bad();
        }
        final end = await _savedAnchor(
          source,
          row['end_message_id'] as String,
          row['end_swipe_id'] as int,
          row['end_agent_swipe_id'] as int,
        );
        _guard();
        // Selected checkpoint membership is saved evidence, not fabricated
        // ACTIVE contiguity. Unknown/removed start/member variations stay unknown.
        final binding = nav.Binding(
          sessionId: source.observation.key.nativeId,
          characterId: source.observation.binding.characterId,
          anchor: end,
          evidence: nav.Evidence(
            end == null ? nav.EvidenceState.missing : nav.EvidenceState.unknown,
          ),
        );
        return [
          _unit(
            source,
            'checkpoint',
            '$prefix:checkpoint',
            nav.SectionKind.reconciliationCheckpoint,
            {'reviewedAt': row['reviewed_at'], 'savedMemberCount': ids.length},
            binding: binding,
          ),
          _unit(
            source,
            'evidence',
            '$prefix:evidence',
            nav.SectionKind.reconciliationEvidence,
            {
              'storedMembership': true,
              'savedMemberCount': ids.length,
              'endVariationAvailable': end != null,
            },
            binding: binding,
          ),
        ];
      case 'reconciliation_successful_runs':
        return _runUnits(source, row, prefix);
      case 'ledger_reconciliation_effects':
        final related = await _sql(
          'SELECT ordinal FROM reconciliation_successful_runs '
          'WHERE session_id = ? AND id = ? LIMIT 1',
          [
            Variable.withString(source.observation.key.nativeId),
            Variable.withString(row['run_id'] as String),
          ],
        );
        _guard();
        if (related.isEmpty) _shape.bad();
        return _effectUnits(source, row, prefix);
      case 'reconciliation_run_invalidations':
        _shape.fields(
          row,
          strings: const {'session_id', 'run_id', 'cause_message_id', 'reason'},
          ints: const {'native_rowid', 'id', 'created_at'},
        );
        _shape.id(row['run_id']);
        _shape.id(row['cause_message_id']);
        return _fields(
          source,
          'evidence',
          prefix,
          nav.SectionKind.reconciliationEvidence,
          {
            'reason': row['reason'],
            'createdAt': row['created_at'],
            'invalidated': true,
          },
          state: nav.SourceState.retracted,
          binding: nav.Binding(
            sessionId: source.observation.key.nativeId,
            evidence: const nav.Evidence(nav.EvidenceState.invalid),
          ),
        );
    }
    _shape.bad();
  }

  Object? _canonicalSaved(Object? raw) {
    final value = _decode(raw);
    if (_navCanonicalJson(value) != raw) _shape.bad();
    return value;
  }

  Future<List<nav.DataRecord>> _runUnits(
    _NavSource source,
    Map<String, Object?> row,
    String prefix,
  ) async {
    _shape.fields(
      row,
      strings: const {
        'id',
        'session_id',
        'start_message_id',
        'end_message_id',
        'anchors_json',
        'range_hash',
        'accepted_manifest_refs_json',
        'effective_canon_stamp',
        'effective_canon_hash',
        'canonical_result_json',
        'content_hash',
        'predecessor_chain_hash',
        'chain_hash',
        'ops_applied_json',
      },
      ints: const {
        'native_rowid',
        'ordinal',
        'start_swipe_id',
        'start_agent_swipe_id',
        'end_swipe_id',
        'end_agent_swipe_id',
        'effective_canon_revision',
        'contract_version',
        'created_at',
      },
    );
    if ((row['ordinal'] as int) < 1 ||
        row['contract_version'] != 1 ||
        (row['effective_canon_revision'] as int) < 0) {
      _shape.bad();
    }
    _shape.id(row['id']);
    final anchors = _shape.list(_canonicalSaved(row['anchors_json']));
    if (anchors.isEmpty ||
        anchors.length > 16 ||
        _navHash(row['anchors_json'] as String) != row['range_hash']) {
      _shape.bad();
    }
    final refs = _shape.list(
      _canonicalSaved(row['accepted_manifest_refs_json']),
    );
    final result = _shape.map(_canonicalSaved(row['canonical_result_json']));
    final ops = _shape.list(_canonicalSaved(row['ops_applied_json']));
    _shape.strings(ops);
    final content = _navHash(
      _navCanonicalJson({
        'anchorSchemaVersion': 1,
        'sessionId': row['session_id'],
        'anchors': anchors,
        'rangeHash': row['range_hash'],
        'acceptedManifestRefs': refs,
        'effectiveCanonStamp': row['effective_canon_stamp'],
        'effectiveCanonRevision': row['effective_canon_revision'],
        'effectiveCanonHash': row['effective_canon_hash'],
        'canonicalResult': result,
        'cleanupOps': ops,
        'contractVersion': row['contract_version'],
      }),
    );
    if (content != row['content_hash'] ||
        _navHash(
              _navCanonicalJson({
                'sessionId': row['session_id'],
                'ordinal': row['ordinal'],
                'predecessorChainHash': row['predecessor_chain_hash'],
                'contentHash': content,
              }),
            ) !=
            row['chain_hash']) {
      _shape.bad();
    }
    if (row['ordinal'] == 1) {
      if (row['predecessor_chain_hash'] != '') _shape.bad();
    } else {
      final previous = await _sql(
        'SELECT chain_hash FROM reconciliation_successful_runs '
        'WHERE session_id = ? AND ordinal = ? LIMIT 1',
        [
          Variable.withString(source.observation.key.nativeId),
          Variable.withInt((row['ordinal'] as int) - 1),
        ],
      );
      _guard();
      if (previous.isEmpty ||
          previous.single.data['chain_hash'] != row['predecessor_chain_hash']) {
        _shape.bad();
      }
    }
    final seen = <String>{};
    nav.Anchor? start, end;
    var evidenceAvailable = true;
    for (final raw in anchors) {
      final a = _shape.map(raw);
      _shape.fields(
        a,
        strings: const {'messageId', 'role', 'contentHash'},
        ints: const {'swipeId', 'agentSwipeId'},
        required: const {
          'messageId',
          'role',
          'contentHash',
          'swipeId',
          'agentSwipeId',
        },
      );
      _shape.choice(a, 'role', const {'user', 'assistant', 'system'});
      if (!seen.add(_shape.id(a['messageId'])) ||
          !RegExp(r'^[0-9a-f]{64}$').hasMatch(a['contentHash'] as String)) {
        _shape.bad();
      }
      final admitted = await _savedAnchor(
        source,
        a['messageId'] as String,
        a['swipeId'] as int,
        a['agentSwipeId'] as int,
      );
      _guard();
      if (admitted == null) evidenceAvailable = false;
      if (identical(raw, anchors.first)) start = admitted;
      end = admitted;
    }
    final first = _shape.map(anchors.first), last = _shape.map(anchors.last);
    if (first['messageId'] != row['start_message_id'] ||
        first['swipeId'] != row['start_swipe_id'] ||
        first['agentSwipeId'] != row['start_agent_swipe_id'] ||
        last['messageId'] != row['end_message_id'] ||
        last['swipeId'] != row['end_swipe_id'] ||
        last['agentSwipeId'] != row['end_agent_swipe_id']) {
      _shape.bad();
    }
    for (final raw in refs) {
      final ref = _shape.map(raw);
      _shape.fields(
        ref,
        strings: const {
          'acceptanceId',
          'sessionId',
          'messageId',
          'manifestHash',
          'acceptedByUserMessageId',
        },
        ints: const {'swipeId', 'agentSwipeId'},
        required: const {
          'acceptanceId',
          'sessionId',
          'messageId',
          'manifestHash',
          'acceptedByUserMessageId',
          'swipeId',
          'agentSwipeId',
        },
      );
      for (final key in [
        'acceptanceId',
        'sessionId',
        'messageId',
        'acceptedByUserMessageId',
      ]) {
        _shape.id(ref[key]);
      }
      if (ref['sessionId'] != source.observation.key.nativeId ||
          !seen.contains(ref['messageId'])) {
        _shape.bad();
      }
    }
    final invalidations = await _sql(
      'SELECT 1 AS invalid FROM reconciliation_run_invalidations '
      'WHERE session_id = ? AND run_id = ? LIMIT 1',
      [
        Variable.withString(source.observation.key.nativeId),
        Variable.withString(row['id'] as String),
      ],
    );
    _guard();
    // Stored hashes are verified above. Fresh body fingerprints are not silently
    // reconstructed from current ChatMessage defaults: evidence remains unknown.
    final binding = nav.Binding(
      sessionId: source.observation.key.nativeId,
      characterId: source.observation.binding.characterId,
      anchor: end,
      evidence: nav.Evidence(
        invalidations.isNotEmpty
            ? nav.EvidenceState.invalid
            : evidenceAvailable
            ? nav.EvidenceState.unknown
            : nav.EvidenceState.missing,
      ),
    );
    final state = invalidations.isNotEmpty
        ? nav.SourceState.retracted
        : nav.SourceState.historicalCommitted;
    final safeResult = _reconciliationResult(result);
    final records = _fields(
      source,
      'results',
      '$prefix:result',
      nav.SectionKind.reconciliationSavedResult,
      safeResult,
      binding: binding,
      state: state,
      private: const {
        'id',
        'factId',
        'fromKey',
        'toKey',
        'knowerKey',
        'subjectKey',
        'supersedesId',
      },
    );
    // Ops strings contain native cleanup IDs; disclose operation counts only.
    records.add(
      _unit(
        source,
        'results',
        '$prefix:metadata',
        nav.SectionKind.reconciliationSavedResult,
        {
          'ordinal': row['ordinal'],
          'createdAt': row['created_at'],
          'contractVersion': row['contract_version'],
          'effectiveCanonRevision': row['effective_canon_revision'],
          'savedOpsCount': ops.length,
        },
        binding: binding,
        state: state,
      ),
    );
    records.add(
      _unit(
        source,
        'evidence',
        '$prefix:evidence',
        nav.SectionKind.reconciliationEvidence,
        {
          'savedAnchorCount': anchors.length,
          'savedAcceptedManifestCount': refs.length,
          'startVariationAvailable': start != null,
          'endVariationAvailable': end != null,
          'storedIntegrityVerified': true,
          'invalidated': invalidations.isNotEmpty,
        },
        binding: binding,
        state: state,
      ),
    );
    return records;
  }

  List<nav.DataRecord> _effectUnits(
    _NavSource source,
    Map<String, Object?> row,
    String prefix,
  ) {
    _shape.fields(
      row,
      strings: const {
        'run_id',
        'session_id',
        'before_ledger_json',
        'after_ledger_json',
        'before_knowledge_json',
        'after_knowledge_json',
        'actual_effects_json',
        'before_state_hash',
        'after_state_hash',
        'effects_hash',
      },
      ints: const {'native_rowid', 'created_at'},
    );
    _shape.id(row['run_id']);
    final beforeLedger = _shape.list(
      _canonicalSaved(row['before_ledger_json']),
    );
    final afterLedger = _shape.list(_canonicalSaved(row['after_ledger_json']));
    final beforeKnowledge = _shape.list(
      _canonicalSaved(row['before_knowledge_json']),
    );
    final afterKnowledge = _shape.list(
      _canonicalSaved(row['after_knowledge_json']),
    );
    final effects = _shape.map(_canonicalSaved(row['actual_effects_json']));
    if (_navHash(
              _navCanonicalJson({
                'ledger': beforeLedger,
                'knowledge': beforeKnowledge,
              }),
            ) !=
            row['before_state_hash'] ||
        _navHash(
              _navCanonicalJson({
                'ledger': afterLedger,
                'knowledge': afterKnowledge,
              }),
            ) !=
            row['after_state_hash'] ||
        _navHash(row['actual_effects_json'] as String) != row['effects_hash']) {
      _shape.bad();
    }
    final records = <nav.DataRecord>[];
    void trackerRows(List<Object?> values, String label) {
      final seen = <String>{};
      var i = 0;
      for (final raw in values) {
        final original = _shape.map(raw);
        const names = {
          'sessionId': 'session_id',
          'basisRevision': 'basis_revision',
          'basisRevisionHash': 'basis_revision_hash',
          'updatedAt': 'updated_at',
        };
        final m = {
          for (final e in original.entries) names[e.key] ?? e.key: e.value,
        };
        final parsed = _trackerShape(m, source.observation.key.nativeId);
        if (!seen.add(parsed['name'] as String) ||
            parsed['scope'] != 'ledger') {
          _shape.bad();
        }
        if ((parsed['name'] as String).startsWith('canon_')) continue;
        records.addAll(
          _fields(
            source,
            'results',
            '$prefix:$label:${i++}',
            nav.SectionKind.reconciliationSavedResult,
            parsed,
            private: const {'session_id', 'basis_revision_hash'},
            state: nav.SourceState.historicalCommitted,
          ),
        );
      }
    }

    void knowledgeRows(List<Object?> values, String label) {
      final seen = <String>{};
      var i = 0;
      for (final raw in values) {
        final parsed = _knowledgeShape(
          _shape.map(raw),
          source.observation.key.nativeId,
          camel: true,
        );
        if (!seen.add(parsed['id'] as String)) _shape.bad();
        records.addAll(
          _fields(
            source,
            'results',
            '$prefix:$label:${i++}',
            nav.SectionKind.reconciliationSavedResult,
            parsed,
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
            state: nav.SourceState.historicalCommitted,
          ),
        );
      }
    }

    trackerRows(beforeLedger, 'beforeLedger');
    trackerRows(afterLedger, 'afterLedger');
    knowledgeRows(beforeKnowledge, 'beforeKnowledge');
    knowledgeRows(afterKnowledge, 'afterKnowledge');
    _shape.fields(
      effects,
      nested: const {'ledger', 'knowledge'},
      required: const {'ledger', 'knowledge'},
    );
    for (final domain in ['ledger', 'knowledge']) {
      final diff = _shape.map(effects[domain]);
      _shape.fields(
        diff,
        nested: const {'added', 'removed', 'changed'},
        required: const {'added', 'removed', 'changed'},
      );
      for (final label in ['added', 'removed']) {
        final values = _shape.list(diff[label]);
        if (domain == 'ledger') {
          trackerRows(values, '$domain:$label');
        } else {
          knowledgeRows(values, '$domain:$label');
        }
      }
      var changeIndex = 0;
      for (final raw in _shape.list(diff['changed'])) {
        final change = _shape.map(raw);
        _shape.fields(
          change,
          nested: const {'before', 'after'},
          required: const {'before', 'after'},
        );
        if (domain == 'ledger') {
          trackerRows([change['before']], 'ledger:changedBefore$changeIndex');
          trackerRows([change['after']], 'ledger:changedAfter$changeIndex');
        } else {
          knowledgeRows([
            change['before'],
          ], 'knowledge:changedBefore$changeIndex');
          knowledgeRows([
            change['after'],
          ], 'knowledge:changedAfter$changeIndex');
        }
        changeIndex++;
      }
    }
    records.add(
      _unit(
        source,
        'results',
        '$prefix:effect',
        nav.SectionKind.reconciliationSavedResult,
        {
          'savedEffect': true,
          'storedIntegrityVerified': true,
          'createdAt': row['created_at'],
        },
        state: nav.SourceState.historicalCommitted,
      ),
    );
    return records;
  }

  Map<String, Object?> _reconciliationResult(Map<String, Object?> result) {
    // This is saved typed output, not raw model response, reasoning or prompts.
    _shape.fields(
      result,
      nested: const {'cleanupOps', 'export'},
      required: const {'cleanupOps', 'export'},
    );
    for (final raw in _shape.list(result['cleanupOps'])) {
      final op = _shape.map(raw);
      _shape.fields(
        op,
        strings: const {'type', 'factId', 'fromKey', 'toKey', 'canonicalName'},
        required: const {'type'},
      );
      _shape.choice(op, 'type', const {'retract', 'renameEntity'});
      for (final key in ['factId', 'fromKey', 'toKey']) {
        if (op.containsKey(key)) _shape.id(op[key]);
      }
    }
    final export = _shape.map(result['export']);
    _shape.fields(
      export,
      nested: const {
        'ops',
        'sceneState',
        'entities',
        'arcState',
        'knowledgeFacts',
      },
      nullable: const {'sceneState'},
    );
    for (final raw in _shape.list(export['ops'])) {
      final op = _shape.map(raw);
      _shape.fields(
        op,
        strings: const {'op', 'key', 'value', 'evidence', 'eventState'},
        required: const {'op', 'key'},
      );
      _shape.choice(op, 'op', const {'set', 'delete'});
      _shape.choice(op, 'eventState', const {
        '',
        'planned',
        'suggested',
        'threatened',
        'attempted',
        'completed',
        'failed',
        'cancelled',
        'unknown',
      });
    }
    // Diagnostic convenience sections are not canon authority. They are saved
    // typed result fields, admitted only when their actual schema is known.
    if (export['sceneState'] != null) {
      final scene = _shape.map(export['sceneState']);
      _shape.fields(
        scene,
        strings: const {'time', 'date', 'location', 'immediateThread'},
        nested: const {'presentEntities', 'activeTensions'},
      );
      if (scene.containsKey('activeTensions')) {
        _shape.strings(scene['activeTensions']);
      }
      for (final raw in _shape.list(scene['presentEntities'])) {
        _shape.fields(
          _shape.map(raw),
          strings: const {'name', 'status', 'reason', 'confidence'},
          required: const {'name'},
        );
      }
    }
    for (final raw in _shape.list(export['entities'])) {
      final entity = _shape.map(raw);
      _shape.fields(
        entity,
        strings: const {'name', 'type', 'relationshipToUser', 'attitudeToUser'},
        nested: const {'aliases', 'knowledge', 'boundaries', 'cardOverrides'},
        required: const {'name'},
      );
      for (final key in [
        'aliases',
        'knowledge',
        'boundaries',
        'cardOverrides',
      ]) {
        if (entity.containsKey(key)) _shape.strings(entity[key]);
      }
    }
    for (final raw in _shape.list(export['arcState'])) {
      final arc = _shape.map(raw);
      _shape.fields(
        arc,
        strings: const {'id', 'title', 'status', 'summary', 'cardOverride'},
        bools: const {'doNotReopen'},
        nested: const {'entities', 'topics'},
        required: const {'id'},
      );
      _shape.id(arc['id']);
      for (final key in ['entities', 'topics']) {
        if (arc.containsKey(key)) _shape.strings(arc[key]);
      }
    }
    for (final raw in _shape.list(export['knowledgeFacts'])) {
      final fact = _shape.map(raw);
      _shape.fields(
        fact,
        strings: const {
          'knowerKey',
          'knowerName',
          'subjectKey',
          'subjectName',
          'factClass',
          'scopeKey',
          'predicate',
          'object',
          'epistemicState',
          'supersedesId',
        },
        nums: const {'confidence', 'importance'},
        nested: const {'entities', 'topics'},
        nullable: const {'supersedesId'},
        required: const {'knowerKey', 'subjectKey', 'predicate', 'object'},
      );
      for (final key in ['knowerKey', 'subjectKey']) {
        _shape.id(fact[key]);
      }
      _shape.choice(fact, 'factClass', const {
        'knowledge',
        'relationship',
        'behavior_change',
        'commitment',
        'goal',
        'persistent_condition',
        'identity_development',
      });
      _shape.choice(fact, 'epistemicState', const {
        'observed',
        'heard_claim',
        'inferred',
        'confirmed',
        'disbelieved',
        'forgotten',
        'retracted',
      });
      for (final key in ['entities', 'topics']) {
        if (fact.containsKey(key)) _shape.strings(fact[key]);
      }
    }
    return result;
  }
}
