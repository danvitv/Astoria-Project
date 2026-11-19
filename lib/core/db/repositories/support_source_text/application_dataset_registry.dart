part of '../support_source_text_repo.dart';

/// Native schema, NOT a model-supplied table/column/path. Expressions below are
/// reviewed projections. Credential/authority columns are absent even from the
/// byte-budget SELECT. Schema additions require updating this finite registry.
final class _ApplicationTable {
  const _ApplicationTable(
    this.section,
    this.title,
    this.table,
    this.columns, {
    this.expressions = const {},
    this.session,
    this.supportSession = false,
    this.nullableSession = false,
    this.visible = '1',
    this.encryptedSummary = false,
    this.diagnostic = false,
  });
  final String section, title, table, columns, visible;
  final Map<String, String> expressions;
  final String? session;
  final bool encryptedSummary, diagnostic, supportSession, nullableSession;
  Map<String, String> get projection => {
    for (final c in columns.split(','))
      if (c.isNotEmpty) c: 't."$c"',
    ...expressions,
  };
}

final class _ApplicationDataset {
  const _ApplicationDataset(this.name, this.title, this.tables);
  final String name, title;
  final List<_ApplicationTable> tables;
}

// The indexed call lookup is bounded to two candidates: duplicates are ambiguous,
// not permission to pick the newest request or cross a session/run/attempt. Raw
// IDs are compared in SQLite only and never become selected/disclosed columns.
const _diagnosticRequestRow =
    '''(SELECT CASE WHEN count(*)=1 THEN min(rowid) END
  FROM (SELECT c.rowid FROM llm_request_capture_rows c
    WHERE typeof(t.call_id)='text' AND length(t.call_id)>0
      AND typeof(t.pipeline_run_id)='text' AND length(t.pipeline_run_id)>0
      AND typeof(t.session_id)='text' AND length(t.session_id)>0
      AND typeof(t.attempt)='integer' AND t.attempt>=1
      AND c.call_id=t.call_id COLLATE BINARY
      AND c.pipeline_run_id=t.pipeline_run_id COLLATE BINARY
      AND c.session_id=t.session_id COLLATE BINARY
      AND c.attempt=t.attempt LIMIT 2))''';

// These fixed comparisons retain private identity in SQLite. A unique original
// phase record can link a call to its phase; missing/duplicate phases stay unknown.
const _diagnosticIdentityValid =
    "(typeof(t.session_id)='text' AND length(t.session_id)>0 AND "
    "typeof(t.pipeline_run_id)='text' AND length(t.pipeline_run_id)>0 AND "
    "typeof(t.call_id)='text' AND length(t.call_id)>0 AND "
    "typeof(t.attempt)='integer' AND t.attempt BETWEEN 1 AND 3)";
const _diagnosticPhaseRow =
    '''(SELECT CASE WHEN count(*)=1 AND min(matches)=1 THEN min(rowid) END
  FROM (SELECT e.rowid,
      (e.pipeline_run_id=t.pipeline_run_id COLLATE BINARY
       AND e.session_id=t.session_id COLLATE BINARY
       AND e.stage='studio.pre_generation.phase'
       AND e.parser_name='studio_runtime_v1'
       AND e.kind IN ('pipeline_completed','pipeline_failed')) AS matches
    FROM llm_call_event_rows e
    WHERE e.call_id=t.parent_call_id COLLATE BINARY AND e.attempt=1 LIMIT 2))''';

const _applicationDatasets = [
  _ApplicationDataset('savedCharacters', 'Saved character cards', [
    _ApplicationTable(
      'cards',
      'Character card fields',
      'characters',
      'name,avatar_path,description,personality,scenario,first_mes,mes_example,system_prompt,post_history_instructions,creator,creator_notes,color,tags_json,alternate_greetings_json,gallery_json,extensions_json,character_version,macro_name,token_count,variant_name,variant_order,fav,created_at,updated_at',
      visible: 't.hidden=0',
    ),
  ]),
  _ApplicationDataset('personas', 'Saved personas', [
    _ApplicationTable(
      'personas',
      'Persona name and prompt',
      'personas',
      'name,prompt,avatar_path,created_at',
    ),
  ]),
  _ApplicationDataset('lorebooks', 'Saved lorebooks', [
    _ApplicationTable(
      'lorebooks',
      'Lorebook entries and settings',
      'lorebooks',
      'name,enabled,activation_scope,description,entries_json,settings_json,updated_at',
    ),
  ]),
  _ApplicationDataset('folders', 'Character and preset folders', [
    _ApplicationTable(
      'characterFolders',
      'Character folders',
      'character_folders',
      'name,color,sort_order,created_at,updated_at',
    ),
    _ApplicationTable(
      'characterMembers',
      'Character folder membership',
      'character_folder_members',
      'added_at',
      expressions: {
        'folderReference':
            '(SELECT f.rowid FROM character_folders f WHERE f.folder_id=t.folder_id LIMIT 1)',
        'characterReference':
            '(SELECT c.rowid FROM characters c WHERE c.char_id=t.char_id AND c.hidden=0 LIMIT 1)',
      },
      visible:
          'EXISTS(SELECT 1 FROM characters c WHERE c.char_id=t.char_id AND c.hidden=0)',
    ),
    _ApplicationTable(
      'presetFolders',
      'Preset folders',
      'preset_folders',
      'name,color,sort_order,created_at,updated_at',
    ),
    _ApplicationTable(
      'presetMembers',
      'Preset folder membership',
      'preset_folder_members',
      'kind,added_at',
      expressions: {
        'folderReference':
            '(SELECT f.rowid FROM preset_folders f WHERE f.folder_id=t.folder_id LIMIT 1)',
        'presetReference':
            "CASE WHEN t.kind='normal' THEN (SELECT p.rowid FROM presets p WHERE p.preset_id=t.preset_id LIMIT 1) WHEN t.kind='agentic' THEN (SELECT p.rowid FROM studio_preset_rows p WHERE p.preset_id=t.preset_id LIMIT 1) END",
      },
    ),
  ]),
  _ApplicationDataset(
    'sessionSavedData',
    'Session notes, variables and stored variations',
    [
      _ApplicationTable(
        'sessionData',
        'Session note, draft and stored message metadata',
        'chat_sessions',
        'session_index,session_vars_json,authors_note_json,draft,updated_at',
        session: 'session_id',
        expressions: {
          'historyIndexStatus':
              '(SELECT g.state FROM history_source_generations g WHERE g.session_id=t.session_id LIMIT 1)',
        },
      ),
      // Canonical message arrays are never fetched whole. The native bounded
      // history index supplies ONE authenticated original logical message unit.
      _ApplicationTable(
        'storedVariations',
        'Stored message variations, reasoning and attachment metadata',
        'history_message_units',
        'raw_json',
        expressions: {
          'activeOrdinal': 't.active_ordinal',
          '_unitValid':
              'astoria_history_unit_valid(t.session_id,t.incarnation,t.revision,t.native_order,t.active_ordinal,t.message_id,t.raw_json,t.integrity)',
        },
        session: 'session_id',
        visible:
            "EXISTS(SELECT 1 FROM history_source_generations g WHERE g.session_id=t.session_id AND g.incarnation=t.incarnation AND g.revision=t.revision AND g.alive=1 AND g.state='ready')",
      ),
      _ApplicationTable(
        'studioActivation',
        'Session Studio activation',
        'studio_config_rows',
        'enabled,created_at,updated_at',
        session: 'session_id',
      ),
      _ApplicationTable(
        'nonLedgerTrackers',
        'Saved non-Ledger trackers',
        'tracker_rows',
        'name,value,scope,updated_at',
        session: 'session_id',
        visible: "t.scope<>'ledger'",
      ),
    ],
  ),
  _ApplicationDataset('canon', 'Saved character canon and revisions', [
    _ApplicationTable(
      'baselines',
      'Session source card baseline',
      'character_session_baseline_rows',
      'baseline_card_json,card_update_policy,created_at,updated_at',
      session: 'chat_session_id',
      expressions: {
        'characterReference':
            '(SELECT c.rowid FROM characters c WHERE c.char_id=t.character_id AND c.hidden=0 LIMIT 1)',
      },
    ),
    _ApplicationTable(
      'characterRevisions',
      'Saved character revision',
      'character_revision_rows',
      'revision,snapshot_json,created_at',
      expressions: {
        'characterReference':
            '(SELECT c.rowid FROM characters c WHERE c.char_id=t.character_id AND c.hidden=0 LIMIT 1)',
      },
      visible:
          'EXISTS(SELECT 1 FROM characters c WHERE c.char_id=t.character_id AND c.hidden=0)',
    ),
    _ApplicationTable(
      'checkpoints',
      'Session canon checkpoints',
      'session_canon_checkpoint_rows',
      'sequence,character_revision,created_at',
      session: 'chat_session_id',
    ),
    _ApplicationTable(
      'transitions',
      'Applied canon transition',
      'applied_canon_transition_rows',
      'revision,canonical_claim,promotion_destination,transition_json,applied_at',
      session: 'chat_session_id',
      nullableSession: true,
      visible:
          'EXISTS(SELECT 1 FROM characters c WHERE c.char_id=t.character_id AND c.hidden=0)',
    ),
    _ApplicationTable(
      'factReferences',
      'Canon transition fact relationships',
      'canon_transition_fact_refs',
      'created_at',
      visible:
          'EXISTS(SELECT 1 FROM applied_canon_transition_rows a JOIN characters c ON c.char_id=a.character_id WHERE a.id=t.applied_canon_transition_id AND c.hidden=0 AND (a.chat_session_id IS NULL OR EXISTS(SELECT 1 FROM chat_sessions s JOIN characters sc ON sc.char_id=s.character_id WHERE s.session_id=a.chat_session_id AND sc.hidden=0))) AND EXISTS(SELECT 1 FROM character_knowledge_fact_rows k JOIN chat_sessions s ON s.session_id=k.chat_session_id JOIN characters c ON c.char_id=s.character_id WHERE k.id=t.character_knowledge_fact_id AND c.hidden=0)',
      expressions: {
        'transitionReference':
            '(SELECT a.rowid FROM applied_canon_transition_rows a WHERE a.id=t.applied_canon_transition_id LIMIT 1)',
        'knowledgeReference':
            '(SELECT k.rowid FROM character_knowledge_fact_rows k WHERE k.id=t.character_knowledge_fact_id LIMIT 1)',
      },
    ),
  ]),
  _ApplicationDataset(
    'lorebookHistory',
    'Session lorebook evolution and use evidence',
    [
      _ApplicationTable(
        'evolution',
        'Session evolved lorebook content',
        'session_lorebook_evolution_rows',
        'base_content,content,created_at,updated_at',
        session: 'chat_session_id',
        expressions: {
          'lorebookReference':
              '(SELECT l.rowid FROM lorebooks l WHERE l.lorebook_id=t.lorebook_id LIMIT 1)',
        },
      ),
      _ApplicationTable(
        'revisions',
        'Session lorebook revision',
        'session_lorebook_revision_rows',
        'content,created_at',
        session: 'chat_session_id',
        expressions: {
          'lorebookReference':
              '(SELECT l.rowid FROM lorebooks l WHERE l.lorebook_id=t.lorebook_id LIMIT 1)',
          'checkpointReference':
              '(SELECT c.rowid FROM session_canon_checkpoint_rows c WHERE c.id=t.checkpoint_id LIMIT 1)',
        },
      ),
      _ApplicationTable(
        'manifests',
        'Saved lorebook use manifest',
        'lorebook_use_manifests',
        'manifest_json,manifest_schema_version,created_at',
        session: 'session_id',
      ),
      _ApplicationTable(
        'selectedEntries',
        'Selected lorebook entry evidence',
        'lorebook_use_manifest_entries',
        'entry_order,evidence_json',
        session: 'session_id',
      ),
      _ApplicationTable(
        'acceptance',
        'Saved lorebook acceptance evidence',
        'lorebook_use_acceptance_records',
        'acceptance_kind,selected_entry_order,evidence_json,accepted_at',
        session: 'session_id',
      ),
    ],
  ),
  _ApplicationDataset('rewrites', 'Saved Card Rewriter jobs and evidence', [
    _ApplicationTable(
      'jobs',
      'Rewrite job request and status',
      'rewrite_jobs',
      'status,status_reason,request_json,applied_character_revision,created_at,updated_at',
      session: 'chat_session_id',
    ),
    _ApplicationTable(
      'operations',
      'Rewrite operation and review status',
      'rewrite_operations',
      'operation_json,status,decision,validation_status,applied_character_revision,created_at,updated_at',
      session: 'chat_session_id',
      expressions: {
        'jobReference':
            '(SELECT j.rowid FROM rewrite_jobs j WHERE j.id=t.rewrite_job_id LIMIT 1)',
      },
    ),
    _ApplicationTable(
      'operationRevisions',
      'Saved rewrite operation revisions',
      'rewrite_operation_revisions',
      'revision,snapshot_json,created_at',
      visible: _applicationRewriteChildVisible,
      expressions: {
        '_session':
            '(SELECT o.chat_session_id FROM rewrite_operations o WHERE o.id=t.rewrite_operation_id LIMIT 1)',
        'operationReference':
            '(SELECT o.rowid FROM rewrite_operations o WHERE o.id=t.rewrite_operation_id LIMIT 1)',
      },
    ),
    _ApplicationTable(
      'evidence',
      'Saved rewrite evidence',
      'rewrite_evidence_rows',
      'evidence_json,created_at',
      visible: _applicationRewriteChildVisible,
      expressions: {
        '_session':
            '(SELECT o.chat_session_id FROM rewrite_operations o WHERE o.id=t.rewrite_operation_id LIMIT 1)',
        'operationReference':
            '(SELECT o.rowid FROM rewrite_operations o WHERE o.id=t.rewrite_operation_id LIMIT 1)',
      },
    ),
  ]),
  _ApplicationDataset(
    'requestDiagnostics',
    'Retained transport requests and call diagnostics',
    [
      _ApplicationTable(
        'requests',
        'Actual sanitized transport capture (retention limited)',
        'llm_request_capture_rows',
        'created_at_ms,stage,stage_ordinal,attempt,protocol,truncated,event_json',
        session: 'session_id',
        diagnostic: true,
      ),
      _ApplicationTable(
        'calls',
        'Retained transport and parser outcomes',
        'llm_call_event_rows',
        'created_at_ms,stage,stage_ordinal,attempt,kind,status,status_code,response_text,error,parser_name,parser_code,parser_detail,payload_json,truncated',
        session: 'session_id',
        diagnostic: true,
        expressions: {
          '_diagnosticRequestRow': _diagnosticRequestRow,
          '_diagnosticIdentityValid': _diagnosticIdentityValid,
          '_diagnosticPhaseRow': _diagnosticPhaseRow,
        },
      ),
      _ApplicationTable(
        'ledgerDebug',
        'Rolling, potentially truncated Ledger diagnostics',
        'ledger_debug_runs',
        'kind,status,model,parse_failure,rejection_reason,rejected_ops_json,repair_attempted,repair_failure,response_text,repair_response_text,attempts_json,error,ops_applied,elapsed_ms,prompt_chars,response_chars,created_at',
        session: 'session_id',
        diagnostic: true,
      ),
    ],
  ),
  _ApplicationDataset(
    'cardEvolution',
    'Saved Card Evolution inputs, outputs and observations',
    [
      _ApplicationTable(
        'claims',
        'Evolution claim input and status (no ownership)',
        'card_evolution_claims',
        'status,selected_input_json,writer_options_json,failure_code,failure_detail,created_at,completed_at,failed_at',
        session: 'session_id',
      ),
      _ApplicationTable(
        'writerCalls',
        'Writer stage saved prompt and output',
        'card_evolution_writer_calls',
        'ordinal,stage,stage_ordinal,status,prompt,response_text,result_json,source,parser_code,parser_detail,failure_code,failure_detail,created_at,updated_at,completed_at,failed_at',
        session: 'session_id',
        expressions: {
          'claimReference':
              '(SELECT c.rowid FROM card_evolution_claims c WHERE c.id=t.claim_id LIMIT 1)',
        },
      ),
      _ApplicationTable(
        'proposals',
        'Evolution proposal saved input and output',
        'card_evolution_proposal_runs',
        'selected_input_json,model_output,operation_snapshot_json,created_at',
        session: 'session_id',
        expressions: {
          'claimReference':
              '(SELECT c.rowid FROM card_evolution_claims c WHERE c.id=t.claim_id LIMIT 1)',
          'jobReference':
              '(SELECT j.rowid FROM rewrite_jobs j WHERE j.id=t.rewrite_job_id LIMIT 1)',
        },
      ),
      _ApplicationTable(
        'debug',
        'Latest evolution diagnostic (retention limited)',
        'card_evolution_debug_runs',
        'stage,status,model,output,attempts_json,updated_at',
        session: 'session_id',
        diagnostic: true,
      ),
      _ApplicationTable(
        'observations',
        'Evolution observation and evidence',
        'card_evolution_observations',
        'run_ordinal,observed_change,canonical_claim,evidence_clusters_json,target_kind,card_field_path,confidence,status,first_seen_run,repeat_count,last_confirmed_run,created_at,updated_at',
        session: 'session_id',
      ),
      _ApplicationTable(
        'collector',
        'Collector completion and failure status (no lease owner)',
        'card_evolution_collector_runs',
        'collector_ordinal,reconciliation_run_ordinal,status,failure_code,failure_detail,created_at,completed_at,failed_at',
        session: 'session_id',
      ),
    ],
  ),
  _ApplicationDataset(
    'extensions',
    'Saved extension definitions and outputs (inert text)',
    [
      _ApplicationTable(
        'presets',
        'Extension preset scripts, prompts and configuration',
        'extension_presets',
        'name,config_json,created_at',
      ),
      _ApplicationTable(
        'infoBlocks',
        'Saved extension output and status',
        'info_blocks',
        'block_name,block_type,content,status,created_at',
        session: 'session_id',
      ),
    ],
  ),
  _ApplicationDataset(
    'embeddingStatus',
    'Embedding source metadata and work status (no vectors)',
    [
      _ApplicationTable(
        'embeddings',
        'Embedding status and retrieval hints',
        'embeddings',
        'source_type,retrieval_hints_json,error_json,updated_at',
        expressions: {'hasVectors': 't.vectors_blob IS NOT NULL'},
      ),
      _ApplicationTable(
        'jobs',
        'Session lorebook embedding work status',
        'session_lorebook_embedding_job_rows',
        'operation,status,attempt_count,last_error,created_at,updated_at',
        session: 'chat_session_id',
      ),
    ],
  ),
  _ApplicationDataset(
    'maintenanceStatus',
    'Maintenance status: cleanup, cursors, leases and Memory consolidation',
    [
      _ApplicationTable(
        'cleanup',
        'Cleanup journal saved status',
        'ledger_reconciliation_cleanup_journals',
        'created_at',
        session: 'session_id',
        expressions: {'hasBeforeImages': "t.before_images_json<>'[]'"},
      ),
      _ApplicationTable(
        'cursors',
        'Saved reconciliation cursor progress (not execution authority)',
        'ledger_reconciliation_cursors',
        'sequence,through_run_ordinal,created_at',
        session: 'session_id',
      ),
      _ApplicationTable(
        'leases',
        'Reconciliation lease purpose and dates (no owner)',
        'ledger_reconciliation_leases',
        'purpose,lease_expires_at,acquired_at',
        session: 'session_id',
      ),
      _ApplicationTable(
        'memoryConsolidationJobs',
        'Saved Memory consolidation packages (local queue status only)',
        'memory_consolidation_job_rows',
        'status,attempt_count,created_at,updated_at',
        session: 'session_id',
        expressions: {
          'reasonCode': '''CASE WHEN t.last_error IS NULL THEN NULL
            WHEN t.last_error IN ('cancelled_by_user','rejected_by_user',
              'source_context_changed','mode_disabled','context_changed',
              'worker_stopped','item_failed','package_generation_failed',
              'source_pack_exceeds_context_budget','lease_expired') THEN t.last_error
            ELSE 'unknown' END''',
        },
      ),
    ],
  ),
  _ApplicationDataset(
    'astoriaSavedContext',
    'Astoria saved summaries, settings and action/report status',
    [
      _ApplicationTable(
        'settings',
        'Astoria saved conversation settings',
        'support_sessions',
        'mode,active_model_id,pinned,created_at,updated_at',
        session: 'id',
        supportSession: true,
      ),
      _ApplicationTable(
        'summaries',
        'Astoria saved context summaries (no provenance receipts)',
        'support_context_blocks',
        'is_active,created_at',
        encryptedSummary: true,
        session: 'session_id',
        supportSession: true,
        visible:
            "t.id NOT LIKE 'workspace-%' AND t.id NOT LIKE 'support.reply_provenance:%'",
      ),
      _ApplicationTable(
        'actions',
        'Astoria saved action status (no before/after payloads)',
        'support_mutation_journal',
        'domain,status,created_at',
        session: 'session_id',
        supportSession: true,
      ),
      _ApplicationTable(
        'reports',
        'Astoria saved report status (no file/hash authority)',
        'support_reports',
        'status,created_at',
        session: 'session_id',
        supportSession: true,
      ),
    ],
  ),
  _ApplicationDataset(
    'apiConfigurations',
    'Saved API configuration (credentials never selected)',
    [
      _ApplicationTable(
        'configurations',
        'API settings and safe custom parameters',
        'api_configs',
        'name,provider_id,protocol,endpoint,model,mode,max_tokens,context_size,history_trim_mode,history_trim_trigger_percent,history_trim_step_percent,temperature,top_p,top_k,frequency_penalty,presence_penalty,stream,reasoning_effort,request_reasoning,use_responses_api,show_native_reasoning,include_last_reasoning,reasoning_history_count,exclude_reasoning_from_context_budget,reasoning_tag_start,reasoning_tag_end,omit_temperature,omit_top_p,omit_top_k,omit_frequency_penalty,omit_presence_penalty,omit_reasoning,omit_reasoning_effort,embedding_use_same,embedding_enabled,embedding_endpoint,embedding_model,embedding_max_chunk_tokens,embedding_requests_per_minute,cache_control_ttl,cache_breakpoint_mode,session_id_mode,first_chunk_timeout_ms,prompt_post_processing,use_system_instruction,extra_request_parameters_json',
      ),
    ],
  ),
  _ApplicationDataset(
    'savedMemoryPreferences',
    'Saved global Memory preferences and prompts',
    [],
  ),
  _ApplicationDataset(
    'savedPipelinePreferences',
    'Saved global pipeline settings',
    [],
  ),
  _ApplicationDataset(
    'savedRegexPreferences',
    'Saved global and Studio regex scripts (inert)',
    [],
  ),
  _ApplicationDataset(
    'savedSelectionPreferences',
    'Saved global selections and bindings',
    [],
  ),
  _ApplicationDataset(
    'savedGlobalVariables',
    'Saved legacy and extension global variables',
    [],
  ),
];

// Fixed ownership traversal for both descendant tables. Missing operations,
// sessions or character owners fail closed before any body projection.
const _applicationRewriteChildVisible =
    'EXISTS(SELECT 1 FROM rewrite_operations o JOIN chat_sessions s ON s.session_id=o.chat_session_id JOIN characters c ON c.char_id=s.character_id WHERE o.id=t.rewrite_operation_id AND c.hidden=0)';

/// Testable schema coverage, not a permission or a claim that every private field
/// is readable. Each entry names an implemented dataset or the existing reader.
abstract final class SupportApplicationDataRegistry {
  static List<String> projectedFieldsForTable(String table) =>
      List.unmodifiable([
        for (final dataset in _applicationDatasets)
          for (final definition in dataset.tables)
            if (definition.table == table) ...definition.projection.keys,
      ]);
  static Map<String, String> get tableCoverage => Map.unmodifiable({
    for (final dataset in _applicationDatasets)
      for (final table in dataset.tables)
        table.table: 'applicationData/${dataset.name}/${table.section}',
    'history_index_clock':
        'private infrastructure: monotonic history index clock',
    'history_source_generations':
        'private infrastructure: history generations/receipts',
    // Logical units are consumed through the original authenticated index port,
    // never by SELECTing the original canonical array or private unit locator.
    'history_message_units':
        'applicationData/sessionSavedData/storedVariations (authenticated unit read port)',
    'presets':
        'ordinaryPreset: saved definition blocks/regex/reasoning/templates',
    'studio_preset_rows': 'studioPreset: saved blocks/agents/runtime/settings',
    'memory_book_rows': 'memory: entries/revisions/drafts/settings',
    'memory_catalog_rows': 'memory: saved catalog metadata',
    'memory_entity_rows': 'memory: saved entity metadata',
    'memory_salience_rows': 'memory: saved salience',
    'memory_cadence_rows': 'memory: saved cadence',
    'memory_consolidation_rows': 'memory: saved consolidation',
    'chat_summaries': 'savedSummary: content/template and saved flags',
    'tracker_rows':
        'ledgerState: saved canonical trackers; applicationData/sessionSavedData/nonLedgerTrackers: remaining scopes',
    'tracker_snapshots':
        'ledgerSnapshot: committed/tentative/bootstrap saved state',
    'ledger_reconciliation_checkpoints': 'reconciliation: saved checkpoint',
    'reconciliation_successful_runs':
        'reconciliation: saved canonical result/operations',
    'ledger_reconciliation_effects':
        'reconciliation: saved before/after/effects evidence',
    'reconciliation_run_invalidations': 'reconciliation: saved invalidations',
    'character_knowledge_fact_rows':
        'characterKnowledge: saved fact/lifecycle/evidence',
    'support_messages':
        'astoriaConversation: bounded exact-AAD individual messages/status (no cards/provenance)',
  });
  static List<String> get datasets =>
      List.unmodifiable(_applicationDatasets.map((d) => d.name));
}
