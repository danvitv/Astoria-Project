import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../services/database_snapshot_service.dart';
import '../models/studio_preset_block_migration.dart';
import '../models/studio_preset_codec.dart';
import '../models/studio_agent_codec.dart';
import '../models/studio_config.dart';
import '../llm/studio_controller_ontology.dart';
import '../llm/transport/endpoint_normalizer.dart';
import '../utils/platform_paths.dart';
import '../utils/time_helpers.dart';
import 'tables.dart';

part 'app_db.g.dart';
part 'native_data_source_identity.dart';
part 'migrations/database_integrity.dart';
part 'migrations/studio_legacy.dart';
part 'studio_preset_seed.dart';
part 'migrations/upgrade_v2_v50.dart';
part 'migrations/upgrade_v51_v100.dart';
part 'migrations/upgrade_v101_v131.dart';
part 'migrations/upgrade_v132.dart';
part 'migrations/upgrade_v133.dart';
part 'migrations/upgrade_v134.dart';
part 'migrations/upgrade_v135.dart';
part 'migrations/upgrade_v137.dart';

@DriftDatabase(
  tables: [
    Characters,
    CharacterFolders,
    CharacterFolderMembers,
    ChatSessions,
    Presets,
    PresetFolders,
    PresetFolderMembers,
    ApiConfigs,
    Personas,
    Lorebooks,
    SessionLorebookEvolutionRows,
    SessionCanonCheckpointRows,
    SessionLorebookRevisionRows,
    SessionLorebookEmbeddingJobRows,
    LorebookUseManifests,
    LorebookUseManifestEntries,
    LorebookUseAcceptanceRecords,
    Embeddings,
    ChatSummaries,
    MemoryBookRows,
    MemoryCatalogRows,
    MemoryEntityRows,
    MemorySalienceRows,
    MemoryCadenceRows,
    MemoryConsolidationRows,
    StudioConfigRows,
    StudioPresetRows,
    TrackerRows,
    TrackerSnapshots,
    LedgerReconciliationCheckpoints,
    LedgerReconciliationCleanupJournals,
    LedgerReconciliationSuccessfulRuns,
    LedgerReconciliationEffects,
    LedgerReconciliationRunInvalidations,
    LedgerReconciliationCursors,
    LedgerReconciliationLeases,
    LedgerDebugRuns,
    LlmRequestCaptureRows,
    LlmCallEventRows,
    CardEvolutionClaims,
    CardEvolutionWriterCalls,
    CardEvolutionProposalRuns,
    CardEvolutionDebugRuns,
    CardEvolutionObservations,
    CardEvolutionCollectorRuns,
    CharacterKnowledgeFactRows,
    CharacterSessionBaselineRows,
    CharacterRevisionRows,
    AppliedCanonTransitionRows,
    RewriteJobs,
    RewriteOperations,
    RewriteOperationRevisions,
    RewriteEvidenceRows,
    CanonTransitionFactRefs,
    ExtensionPresets,
    InfoBlocks,
    SupportSessions,
    SupportMessages,
    SupportContextBlocks,
    SupportMutationJournal,
    SupportReports,
  ],
)
class AppDatabase extends _$AppDatabase {
  factory AppDatabase() => AppDatabase._native(_AppDatabaseNativeFile());

  AppDatabase._native(_AppDatabaseNativeFile native)
    : _nativeFile = native,
      super(_openConnection(native));

  AppDatabase.forTesting(super.e) : _nativeFile = null;

  /// Native composition only: file identity comes from THIS opened SQLite
  /// connection, not from a separately supplied path. Memory/attached sources
  /// remain usable as databases but do not acquire native snapshot authority.
  factory AppDatabase.openedNative(
    sqlite.Database connection, {
    bool closeUnderlyingOnClose = true,
  }) {
    final native = _AppDatabaseNativeFile.fromOpened(connection);
    return AppDatabase._openedNative(
      NativeDatabase.opened(
        connection,
        closeUnderlyingOnClose: closeUnderlyingOnClose,
      ),
      native,
    );
  }

  AppDatabase._openedNative(QueryExecutor executor, this._nativeFile)
    : super(executor);

  final _AppDatabaseNativeFile? _nativeFile;
  NativeDataSourceIdentity? _nativeIdentity;

  /// No path/value getter. Null until the original native executor has opened.
  NativeDataSourceIdentity? get nativeDataSourceIdentity {
    final native = _nativeFile;
    if (native == null || !native.current) return null;
    return _nativeIdentity ??= NativeDataSourceIdentity._(this, native);
  }

  @override
  Future<void> close() {
    _nativeFile?.retire(); // Invalidate BEFORE the async executor close.
    return super.close();
  }

  @override
  int get schemaVersion => 137;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (_) async {
      _nativeFile?.markOpened();
    },
    onCreate: (Migrator m) async {
      await m.createAll();
      final now = currentTimestampSeconds();
      await customStatement(
        'INSERT INTO studio_preset_rows '
        '(preset_id, name, blocks_json, agents_json, updated_at) '
        'VALUES (?, ?, ?, ?, ?)',
        [
          'default',
          'Default Studio Preset',
          jsonEncode(_legacyStudioPresetMigrationBlocks()),
          StudioAgentCodec.encodeAgents(
            StudioControllerOntology.buildDefaultAgents(
              sessionId: 'default',
              now: now,
            ),
          ),
          now,
        ],
      );
      await _ensureSchemaIntegrity();
    },
    onUpgrade: (Migrator m, int from, int to) async {
      await _upgradeV2ToV50(m, from);
      await _upgradeV51ToV100(m, from);
      await _upgradeV101ToV131(m, from);
      await _upgradeV132(from);
      await _upgradeV133(m, from);
      await _upgradeV134(m, from);
      await _upgradeV135(m, from);
      await _upgradeV137(m, from);
      // Local v136 repairs missing indexes/triggers and replaces the request
      // capture trigger. Only install current-schema integrity after all
      // historical table rebuilds and data normalization have finished.
      await _ensureSchemaIntegrity();
    },
  );

  Future<void> applyLegacyStudioRuntimePayloads(
    List<Map<String, dynamic>> rows,
  ) => _AppDatabaseStudioLegacyMigrations(
    this,
  ).applyLegacyStudioRuntimePayloads(rows);

  Future<void> purgeRetiredAgenticMicroMemory() =>
      _AppDatabaseStudioLegacyMigrations(this).purgeRetiredAgenticMicroMemory();
}

LazyDatabase _openConnection(_AppDatabaseNativeFile native) {
  return LazyDatabase(() async {
    final dbFolder = await getAppDataDir();
    final dir = Directory(dbFolder);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final file = File(p.join(dbFolder, 'astoria.db'));
    if (native.retired) throw StateError('Native database owner retired.');
    native.file = file; // SAME private File passed to the actual executor.
    return NativeDatabase.createInBackground(file);
  });
}
