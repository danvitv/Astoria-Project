import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';

import '../../db/app_db.dart';
import '../../db/repositories/backup_export_repo.dart';
import '../file_export_service.dart';
import '../image_storage_service.dart';
import 'backup_archive_writer.dart';

class BackupExporter {
  // Schema version history:
  //   2 — initial v2 ZIP format (characters, chats, presets, api_configs,
  //         personas, lorebooks, embeddings, chat_summaries, memory_book_rows)
  //   3 — added extension_presets and info_blocks tables
  //   4 — added studio_config_rows (Studio agent profiles/settings)
  //   5 — added tracker_snapshots (per-message tracker state for rollback)
  //   6 — added pipeline_settings_rows (per-session pipeline LLM settings).
  //   7 — removed pipeline_settings_rows from the backup whitelist. Pipeline
  //         settings are now a singleton global in SharedPreferences; the
  //         Drift table was dropped in DB schema v52. The SharedPreferences
  //         payload ('pipelineSettings' key) is still captured via
  //         preferences.json.
  //   8 — added tracker_rows (live Tracker Values) alongside snapshots.
  //   9 — added studio_preset_rows (DB-backed Studio prompt block presets).
  //  10 — added atomic character facts and immutable session baselines.
  //  11 — added complete Card Rewriter/session-canon provenance.
  //  12 — added complete Agent Ops reconciliation and recovery provenance.
  //  13 — Collector journals use three-reconciliation batches.
  //  14 — durable memory event registry and provenance links.
  //  15 — append-only memory event provenance invalidations.
  static const int schemaVersion = 15;

  static const List<String> tableNames = [
    'characters',
    'character_revision_rows',
    'chat_sessions',
    'presets',
    'api_configs',
    'personas',
    'lorebooks',
    'lorebook_use_manifests',
    'lorebook_use_manifest_entries',
    'lorebook_use_acceptance_records',
    'embeddings',
    'chat_summaries',
    'memory_book_rows',
    'extension_presets',
    'info_blocks',
    'studio_config_rows',
    'studio_preset_rows',
    'tracker_rows',
    'tracker_snapshots',
    'character_folders',
    'character_folder_members',
    'memory_catalog_rows',
    'memory_entity_rows',
    'memory_salience_rows',
    'memory_cadence_rows',
    'memory_consolidation_rows',
    'memory_event_rows',
    'memory_event_source_rows',
    'memory_event_link_rows',
    'memory_event_invalidation_rows',
    'character_knowledge_fact_rows',
    'character_session_baseline_rows',
    'reconciliation_successful_runs',
    'ledger_reconciliation_effects',
    'reconciliation_run_invalidations',
    'ledger_reconciliation_checkpoints',
    'ledger_reconciliation_cleanup_journals',
    'card_evolution_collector_runs',
    'card_evolution_observations',
    'ledger_reconciliation_cursors',
    'rewrite_jobs',
    'rewrite_operations',
    'rewrite_operation_revisions',
    'rewrite_evidence_rows',
    'card_evolution_claims',
    'card_evolution_writer_calls',
    'card_evolution_proposal_runs',
    'applied_canon_transition_rows',
    'canon_transition_fact_refs',
    'session_canon_checkpoint_rows',
    'session_lorebook_evolution_rows',
    'session_lorebook_revision_rows',
  ];

  final AppDatabase _db;
  final ImageStorageService _imageStorage;

  BackupExporter(this._db, this._imageStorage);

  Future<String> export({bool includeApiKeys = false}) async {
    final tempFile = await buildArchive(
      Directory.systemTemp,
      includeApiKeys: includeApiKeys,
    );
    final filename = p.basename(tempFile.path);
    try {
      return await FileExportService.exportFile(
        sourcePath: tempFile.path,
        filename: filename,
        subfolder: 'backup',
      );
    } finally {
      try {
        await tempFile.delete();
      } catch (_) {}
    }
  }

  /// Builds the archive without the platform save/share dialog.
  @visibleForTesting
  Future<File> buildArchive(
    Directory directory, {
    bool includeApiKeys = false,
  }) async {
    // Platform preferences must be captured on the root isolate. Only plain
    // values/paths enter the worker; never capture this exporter or its DB.
    final prefs = await SharedPreferences.getInstance();
    final prefsMap = <String, dynamic>{};
    for (final key in prefs.getKeys()) {
      final value = prefs.get(key);
      if (value != null) prefsMap[key] = value;
    }
    return File(
      await _buildInWorker(
        _db,
        directory.path,
        _imageStorage.baseDir,
        includeApiKeys,
        prefsMap,
      ),
    );
  }
}

// Keep the closure outside the exporter instance so it cannot retain UI state,
// platform services, or an unsendable original database executor.
Future<String> _buildInWorker(
  AppDatabase db,
  String directory,
  String imageDirectory,
  bool includeApiKeys,
  Map<String, dynamic> preferences,
) => db.computeWithDatabase(
  connect: AppDatabase.backupReader,
  computation: (workerDb) =>
      BackupArchiveWriter(BackupExportRepo(workerDb)).build(
        directory: directory,
        imageDirectory: imageDirectory,
        tableNames: BackupExporter.tableNames,
        schemaVersion: BackupExporter.schemaVersion,
        includeApiKeys: includeApiKeys,
        preferences: preferences,
      ),
);
