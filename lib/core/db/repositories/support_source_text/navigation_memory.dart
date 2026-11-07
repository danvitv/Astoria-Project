part of '../support_source_text_repo.dart';

const _memoryTables = <_NavTable>[
  _NavTable('memory_book_rows', 'session_id', '', {
    'entries',
    'revisions',
  }, jsonArray: 'entries_json'),
  _NavTable('memory_book_rows', 'session_id', '', {
    'drafts',
  }, jsonArray: 'pending_drafts_json'),
  _NavTable(
    'memory_book_rows',
    'session_id',
    'session_id,settings_json,last_processed_message_count,updated_at',
    {'settings'},
  ),
  _NavTable(
    'memory_catalog_rows',
    'chat_session_id',
    'id,chat_session_id,memory_entry_id,entry_revision,source_hash,title,keys_json,entities_json,'
        'locations_json,topics_json,message_range_start,message_range_end,importance,temporally_blind,'
        'token_count,abstract_text,status,stale,created_at,updated_at',
    {'derived'},
  ),
  _NavTable(
    'memory_entity_rows',
    'chat_session_id',
    'id,chat_session_id,memory_entry_id,name,entity_type,aliases_json,description,salience_avg,'
        'salience_peak,status,facts_json,emotional_valence_json,mention_count,last_seen_message_index,'
        'source_hash,created_at,updated_at',
    {'derived'},
  ),
  _NavTable(
    'memory_salience_rows',
    'chat_session_id',
    'id,chat_session_id,memory_entry_id,score,emotional_tags_json,narrative_flags_json,'
        'has_dialogue,has_action,word_count,score_source,scored_at,created_at',
    {'derived'},
  ),
  _NavTable(
    'memory_cadence_rows',
    'chat_session_id',
    'chat_session_id,assistant_messages_since_last_run,last_run_message_index,last_run_at,last_run_kind',
    {'derived'},
  ),
  _NavTable(
    'memory_consolidation_rows',
    'chat_session_id',
    'id,chat_session_id,tier,title,summary,source_entry_ids_json,entity_ids_json,message_range_start,'
        'message_range_end,salience_avg,emotional_tags_json,token_count,source_model,status,error_message,'
        'created_at,updated_at',
    {'derived'},
  ),
];

extension _NavMemory on SupportSourceNavigationRepo {
  nav.Binding _memoryBinding(_NavSource source, Map<String, Object?> object) {
    final manifest = object['sourceManifest'];
    var evidence = nav.EvidenceState.unknown;
    if (manifest != null) {
      final m = _shape.map(manifest);
      _shape.fields(
        m,
        strings: const {'originSessionId'},
        ints: const {'version'},
        bools: const {'invalidated'},
        nested: const {'messages'},
        required: const {
          'version',
          'originSessionId',
          'messages',
          'invalidated',
        },
      );
      if (m['version'] != 0 && m['version'] != 1) _shape.bad();
      _shape.id(m['originSessionId'], empty: m['version'] == 0);
      final seen = <String>{};
      for (final raw in _shape.list(m['messages'])) {
        final stamp = _shape.map(raw);
        _shape.fields(
          stamp,
          strings: const {'messageId', 'contentHash'},
          ints: const {'swipeId', 'agentSwipeId'},
          required: const {
            'messageId',
            'contentHash',
            'swipeId',
            'agentSwipeId',
          },
        );
        if (!seen.add(_shape.id(stamp['messageId'])) ||
            (stamp['swipeId'] as int) < 0 ||
            (stamp['agentSwipeId'] as int) < 0 ||
            !RegExp(
              r'^[0-9a-f]{64}$',
            ).hasMatch(stamp['contentHash'] as String)) {
          _shape.bad();
        }
      }
      if (m['invalidated'] == true || m['version'] == 0 || seen.isEmpty) {
        evidence = nav.EvidenceState.invalid;
      }
      // A well-formed saved manifest is NOT a fresh evidence verification.
    }
    return nav.Binding(
      sessionId: source.observation.key.nativeId,
      characterId: source.observation.binding.characterId,
      evidence: nav.Evidence(evidence),
    );
  }

  void _memoryObject(
    Map<String, Object?> object, {
    bool revision = false,
    bool draft = false,
  }) {
    _shape.fields(
      object,
      strings: {
        'id',
        'title',
        'content',
        'ledgerRange',
        if (revision) ...{
          'author',
          'reason',
          'reviewer',
        } else ...{
          'status',
          'source',
        },
        if (!revision && !draft) ...{
          'arc',
          'kind',
          'sourceHash',
          'activeRevisionId',
        },
        if (draft) 'error',
      },
      bools: {
        if (!revision) 'vectorSearch',
        if (!revision && !draft) ...{
          'temporallyBlind',
          'locked',
          'excludeFromVectorization',
        },
      },
      ints: {
        'createdAt',
        if (revision) ...{
          'version',
          'reviewedAt',
        } else ...{
          'sourceSwipeId',
          'sourceAgentSwipeId',
        },
        if (draft) ...{'updatedAt', 'generatedAt'},
      },
      nums: {if (!revision && !draft) 'importance'},
      nullable: {
        'sourceManifest',
        'createdAt',
        if (revision) ...{'reviewer', 'reviewedAt'},
        if (draft) ...{'error', 'generatedAt'},
        if (!revision && !draft) 'activeRevisionId',
        if (!revision) 'messageRange',
      },
      nested: {
        'keys',
        'keyParagraphs',
        'messageIds',
        'sourceManifest',
        if (!revision) 'messageRange',
        if (draft) 'glazeKeys',
        if (!revision && !draft) 'revisions',
      },
      required: {
        'id',
        if (revision) ...{'version', 'createdAt'},
      },
    );
    _shape.id(object['id']);
    for (final key in ['keys', 'messageIds', if (draft) 'glazeKeys']) {
      if (object.containsKey(key)) {
        _shape.strings(object[key], identities: key == 'messageIds');
      }
    }
    if (object.containsKey('keyParagraphs')) {
      for (final entry in _shape.map(object['keyParagraphs']).entries) {
        if (entry.key.isEmpty ||
            _shape.list(entry.value).any((v) => v is! int || v < 0)) {
          _shape.bad();
        }
      }
    }
    if (object['messageRange'] != null) {
      final range = _shape.map(object['messageRange']);
      _shape.fields(
        range,
        ints: const {'start', 'end'},
        required: const {'start', 'end'},
      );
      if ((range['start'] as int) < 0 ||
          (range['end'] as int) < (range['start'] as int)) {
        _shape.bad();
      }
    }
    if (!revision) {
      _shape.choice(
        object,
        'status',
        draft
            ? const {
                'pending_generation',
                'pending_approval',
                'error',
                'needs_regeneration',
              }
            : const {'active', 'inactive', 'archived', 'invalidated'},
      );
      if (!draft) {
        _shape.choice(object, 'kind', const {
          'curated',
          'summary',
          'range_summary',
          'micro',
        });
      }
    }
  }

  Future<List<nav.DataRecord>> _memoryUnits(
    _NavSource source,
    _NavTable table,
    Map<String, Object?> row,
  ) async {
    final prefix =
        '${table.table}:${table.jsonArray ?? ''}:${row['native_rowid']}';
    if (table.jsonArray != null) {
      final object = _shape.map(_decode(row['raw']));
      final draft = table.jsonArray == 'pending_drafts_json';
      _memoryObject(object, draft: draft);
      final binding = _memoryBinding(source, object);
      final state = draft
          ? switch (object['status']) {
              'pending_generation' => nav.SourceState.pendingGeneration,
              'pending_approval' => nav.SourceState.pendingApproval,
              'error' => nav.SourceState.error,
              'needs_regeneration' => nav.SourceState.needsRegeneration,
              _ => nav.SourceState.unknown,
            }
          : object['status'] == 'active'
          ? nav.SourceState.active
          : nav.SourceState.currentSaved;
      final records = _fields(
        source,
        draft ? 'drafts' : 'entries',
        prefix,
        draft ? nav.SectionKind.memoryDraft : nav.SectionKind.memoryEntry,
        object,
        binding: binding,
        state: state,
        private: const {
          'id',
          'messageIds',
          'sourceHash',
          'sourceManifest',
          'sourceSwipeId',
          'sourceAgentSwipeId',
          'activeRevisionId',
          'revisions',
        },
      );
      if (!draft && object.containsKey('revisions')) {
        final seen = <String>{};
        var index = 0;
        for (final raw in _shape.list(object['revisions'])) {
          final revision = _shape.map(raw);
          _memoryObject(revision, revision: true);
          if (!seen.add(_shape.id(revision['id']))) _shape.bad();
          records.addAll(
            _fields(
              source,
              'revisions',
              '$prefix:r${index++}',
              nav.SectionKind.memoryRevision,
              revision,
              binding: _memoryBinding(source, revision),
              state: nav.SourceState.currentSaved,
              private: const {'id', 'messageIds', 'sourceManifest'},
            ),
          );
        }
        if (object['activeRevisionId'] != null &&
            !seen.contains(object['activeRevisionId'])) {
          _shape.bad();
        }
      }
      return records;
    }
    if (table.table == 'memory_book_rows') {
      final settings = _shape.map(_decode(row['settings_json']));
      _memorySettings(settings);
      return _fields(
        source,
        'settings',
        prefix,
        nav.SectionKind.settings,
        {
          ...settings,
          'lastProcessedMessageCount': row['last_processed_message_count'],
          'updatedAt': row['updated_at'],
        },
        state: nav.SourceState.currentSaved,
      );
    }
    final data = _derivedShape(table, row);
    return _fields(
      source,
      'derived',
      prefix,
      nav.SectionKind.memoryDerived,
      data,
      state: nav.SourceState.derived,
      private: const {
        'id',
        'chat_session_id',
        'memory_entry_id',
        'entry_revision',
        'source_hash',
        'source_entry_ids_json',
        'entity_ids_json',
      },
    );
  }

  void _memorySettings(Map<String, Object?> settings) {
    _shape.fields(
      settings,
      strings: const {
        'memoryMode',
        'memoryPackingMode',
        'memoryBudgetPreset',
        'injectionTarget',
        'keyMatchMode',
        'promptPreset',
      },
      bools: const {
        'enabled',
        'autoCreateEnabled',
        'autoGenerateEnabled',
        'memoryExcerptingEnabled',
        'useDelayedAutomation',
        'vectorSearchEnabled',
        'diversityAware',
        'recencyBoost',
        'importanceBoost',
        'sourceWindowExclusion',
        'factualContinuityGuardEnabled',
        'queryIncludeAssistant',
        'consolidationEnabled',
      },
      ints: const {
        'maxInjectedEntries',
        'memoryExcerptTokensPerChunk',
        'memoryExcerptChunksPerEntry',
        'chunkFirstTopEntries',
        'chunkFirstTopChunks',
        'maxInjectedTokens',
        'autoCreateInterval',
        'autoCreateLagMessages',
        'batchSize',
        'queryRecentTurns',
        'queryMaxChars',
        'cadenceInterval',
        'consolidationThreshold',
      },
      nums: const {
        'maxInjectionBudgetPercent',
        'diversityPenalty',
        'recencyHalfLifeDays',
        'importanceWeight',
      },
      nullable: const {'maxInjectedTokens'},
    );
    _shape.choice(settings, 'memoryMode', const {
      'legacy',
      'fast',
      'balanced',
      'deep',
      'agentic',
      'memory_links',
    });
    _shape.choice(settings, 'memoryPackingMode', const {
      'hybrid',
      'chunk_first',
      'full',
    });
    _shape.choice(settings, 'memoryBudgetPreset', const {
      'auto',
      'small',
      'medium',
      'large',
      'custom',
    });
    _shape.choice(settings, 'injectionTarget', const {
      'hard_block',
      'macro',
      'summary_block',
      'summary_macro',
    });
    _shape.choice(settings, 'keyMatchMode', const {'glaze', 'both', 'plain'});
    // promptPreset is a saved built-in OR custom selection key, not a closed
    // enum. Preserve the typed string; never resolve preferences or execute it.
  }

  Map<String, Object?> _derivedShape(
    _NavTable table,
    Map<String, Object?> row,
  ) {
    final m = Map<String, Object?>.of(row)..remove('native_rowid');
    final jsonKeys = m.keys.where((k) => k.endsWith('_json')).toList();
    for (final k in jsonKeys) {
      final value = _decode(m[k]);
      if (k == 'emotional_valence_json') {
        if (_shape.map(value).values.any((v) => v is! num || !v.isFinite)) {
          _shape.bad();
        }
      } else {
        _shape.strings(
          value,
          identities: k == 'source_entry_ids_json' || k == 'entity_ids_json',
        );
      }
      m[k] = value;
    }
    _shape.fields(
      m,
      strings: const {
        'id',
        'chat_session_id',
        'memory_entry_id',
        'entry_revision',
        'source_hash',
        'title',
        'abstract_text',
        'status',
        'name',
        'entity_type',
        'description',
        'score_source',
        'last_run_kind',
        'summary',
        'source_model',
        'error_message',
      },
      ints: const {
        'message_range_start',
        'message_range_end',
        'temporally_blind',
        'token_count',
        'stale',
        'created_at',
        'updated_at',
        'mention_count',
        'last_seen_message_index',
        'has_dialogue',
        'has_action',
        'word_count',
        'scored_at',
        'assistant_messages_since_last_run',
        'last_run_message_index',
        'last_run_at',
        'tier',
      },
      nums: const {'importance', 'salience_avg', 'salience_peak', 'score'},
      nested: jsonKeys.toSet(),
      nullable: const {'message_range_start', 'message_range_end'},
    );
    for (final key in [
      'temporally_blind',
      'stale',
      'has_dialogue',
      'has_action',
    ]) {
      if (m.containsKey(key) && m[key] != 0 && m[key] != 1) _shape.bad();
    }
    _shape.choice(m, 'status', const {
      'active',
      'inactive',
      'archived',
      'pending',
      'done',
      'completed',
      'error',
      'stale',
    });
    _shape.choice(m, 'entity_type', const {
      'character',
      'location',
      'object',
      'organization',
      'concept',
      'event',
    });
    _shape.choice(m, 'score_source', const {
      'heuristic',
      'llm',
      'manual',
      'hybrid',
    });
    _shape.choice(m, 'last_run_kind', const {
      'graph',
      'consolidation',
      'catalog',
    });
    return m;
  }
}
