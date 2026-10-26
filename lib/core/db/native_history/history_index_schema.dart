/// One authoritative list shared by migration and the original native worker.
/// Attestation checks the ACTUAL stored SQL, including at first use/new owner.
final historyIndexTriggers = <String, String>{
  'history_source_insert': '''CREATE TRIGGER IF NOT EXISTS history_source_insert
    AFTER INSERT ON chat_sessions BEGIN
    UPDATE history_index_clock SET incarnation=incarnation+1 WHERE id=1;
    INSERT INTO history_source_generations (session_id,incarnation,revision,alive,state)
    SELECT NEW.session_id,incarnation,1,1,'incomplete' FROM history_index_clock WHERE id=1
    ON CONFLICT(session_id) DO UPDATE SET incarnation=excluded.incarnation,
      revision=history_source_generations.revision+1,alive=1,state='incomplete',
      checkpoint=0,unit_count=0,active_count=0,integrity=NULL;
    END''',
  'history_source_update': '''CREATE TRIGGER IF NOT EXISTS history_source_update
    AFTER UPDATE OF messages_json,character_id,session_index,session_id ON chat_sessions BEGIN
    UPDATE history_source_generations SET revision=revision+1,state='incomplete',
      checkpoint=0,integrity=NULL WHERE session_id=OLD.session_id;
    UPDATE history_index_clock SET incarnation=incarnation+1 WHERE id=1 AND OLD.session_id IS NOT NEW.session_id;
    UPDATE history_source_generations SET alive=0 WHERE session_id=OLD.session_id AND OLD.session_id IS NOT NEW.session_id;
    INSERT INTO history_source_generations (session_id,incarnation,revision,alive,state)
    SELECT NEW.session_id,incarnation,1,1,'incomplete' FROM history_index_clock
      WHERE id=1 AND OLD.session_id IS NOT NEW.session_id
    ON CONFLICT(session_id) DO UPDATE SET incarnation=excluded.incarnation,
      revision=history_source_generations.revision+1,alive=1,state='incomplete',checkpoint=0,integrity=NULL;
    END''',
  'history_source_delete': '''CREATE TRIGGER IF NOT EXISTS history_source_delete
    AFTER DELETE ON chat_sessions BEGIN
    UPDATE history_source_generations SET revision=revision+1,alive=0,state='incomplete',
      checkpoint=0,integrity=NULL WHERE session_id=OLD.session_id;
    END''',
  for (final event in ['INSERT', 'UPDATE', 'DELETE'])
    'history_character_${event.toLowerCase()}':
        '''CREATE TRIGGER IF NOT EXISTS history_character_${event.toLowerCase()}
    AFTER $event ON characters BEGIN
    UPDATE history_source_generations SET revision=revision+1,state='incomplete',checkpoint=0,integrity=NULL
      WHERE session_id IN (SELECT session_id FROM chat_sessions WHERE ${event == 'UPDATE' ? 'character_id IN (OLD.char_id,NEW.char_id)' : 'character_id=${event == 'DELETE' ? 'OLD' : 'NEW'}.char_id'});
    END''',
  // Corrupt/delete/replace derived rows invalidate readiness even if they lie
  // OUTSIDE selected units. Prevent UPDATE and disable truncate-DELETE bypass.
  'history_units_update': '''CREATE TRIGGER IF NOT EXISTS history_units_update
    BEFORE UPDATE ON history_message_units BEGIN SELECT RAISE(ABORT,'Derived history is immutable'); END''',
  for (final event in ['INSERT', 'DELETE'])
    'history_units_${event.toLowerCase()}':
        '''CREATE TRIGGER IF NOT EXISTS history_units_${event.toLowerCase()}
    AFTER $event ON history_message_units BEGIN
    UPDATE history_source_generations SET state='incomplete',integrity=NULL
      WHERE session_id=${event == 'DELETE' ? 'OLD' : 'NEW'}.session_id;
    END''',
};

/// A normal single-column secondary index stores (owner, rowid). It supports an
/// independently addressable keyset, unlike sorting an owner's compound PK or
/// applying eligibility after scanning unrelated owners. Fixed local schema;
/// no model-supplied table/column/index identifiers.
const sourceNavigationOwners = <String, String>{
  'presets': 'preset_id',
  'studio_preset_rows': 'preset_id',
  'memory_book_rows': 'session_id',
  'memory_catalog_rows': 'chat_session_id',
  'memory_entity_rows': 'chat_session_id',
  'memory_salience_rows': 'chat_session_id',
  'memory_cadence_rows': 'chat_session_id',
  'memory_consolidation_rows': 'chat_session_id',
  'chat_summaries': 'session_id',
  'tracker_rows': 'session_id',
  'tracker_snapshots': 'session_id',
  'ledger_reconciliation_checkpoints': 'session_id',
  'reconciliation_successful_runs': 'session_id',
  'ledger_reconciliation_effects': 'session_id',
  'reconciliation_run_invalidations': 'session_id',
  'character_knowledge_fact_rows': 'chat_session_id',
};
final sourceNavigationIndexes = <String, String>{
  for (final entry in sourceNavigationOwners.entries)
    'idx_navigation_${entry.key}_owner':
        'CREATE INDEX IF NOT EXISTS idx_navigation_${entry.key}_owner ON ${entry.key} (${entry.value})',
};

String normalizeHistorySchema(String sql) => sql
    .toLowerCase()
    .replaceAll(RegExp(r'\bif\s+not\s+exists\s+'), '')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();
