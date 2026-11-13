part of '../app_db.dart';

extension _CardEvolutionJobsMigration on AppDatabase {
  Future<void> _upgradeV144(Migrator m, int from) async {
    if (from >= 144) return;
    await m.createTable(cardEvolutionJobs);
    // The final _ensureSchemaIntegrity pass installs all declared indexes.
    await _installCardEvolutionJobLifecycle();
  }

  Future<void> _installCardEvolutionJobLifecycle() async {
    // Existing connections do not uniformly enable SQLite foreign keys. Keep
    // the declared session cascade effective on those connections too, without
    // introducing a second provider-owned deletion list.
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS card_evolution_jobs_session_delete
      AFTER DELETE ON chat_sessions BEGIN
        DELETE FROM card_evolution_jobs WHERE session_id = OLD.session_id;
      END
    ''');
    // A fork must retire the old target permanently, even if the session later
    // points back to that character. Never rebind queued work to the new card.
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS card_evolution_jobs_session_fork
      AFTER UPDATE OF character_id ON chat_sessions
      WHEN OLD.character_id <> NEW.character_id BEGIN
        UPDATE card_evolution_jobs
        SET status = 'stale', owner_nonce = NULL, lease_until = NULL,
            result_detail = 'source_character_changed',
            updated_at = MAX(updated_at, NEW.updated_at)
        WHERE session_id = OLD.session_id AND status IN ('pending', 'running');
      END
    ''');
    // Clear-chat and source rollback remove committed runs while retaining the
    // session. Retain the reservation as stale rather than allowing a replay.
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS card_evolution_jobs_source_delete
      AFTER DELETE ON reconciliation_successful_runs BEGIN
        UPDATE card_evolution_jobs
        SET status = 'stale', owner_nonce = NULL, lease_until = NULL,
            result_detail = 'source_reconciliation_missing',
            updated_at = MAX(updated_at, CAST(strftime('%s', 'now') AS INTEGER))
        WHERE reconciliation_run_id = OLD.id
          AND status IN ('pending', 'running');
      END
    ''');
  }
}
