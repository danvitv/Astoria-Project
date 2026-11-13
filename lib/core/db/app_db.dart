import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;
import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';

import '../services/database_snapshot_service.dart';
import '../services/android_snapshot_namespace.dart';
import 'repositories/database_background_snapshot_source_repo.dart';
import 'repositories/history_source_index_repo.dart';
import 'native_history/history_index_worker.dart';
import 'native_history/history_index_schema.dart';
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
part 'native_commit_send_fence.dart';
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
part 'migrations/upgrade_v138.dart';
part 'migrations/upgrade_v139.dart';
part 'migrations/upgrade_v140.dart';
part 'migrations/upgrade_v141.dart';
part 'migrations/upgrade_v142.dart';
part 'migrations/upgrade_v143.dart';
part 'migrations/upgrade_v144.dart';

@DriftDatabase(
  tables: [
    Characters,
    CharacterFolders,
    CharacterFolderMembers,
    ChatSessions,
    HistoryIndexClock,
    HistorySourceGenerations,
    HistoryMessageUnits,
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
    MemoryEventRows,
    MemoryEventSourceRows,
    MemoryEventLinkRows,
    MemoryEventInvalidationRows,
    MemoryConsolidationJobRows,
    MemoryConsolidationJobItemRows,
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
    CardEvolutionJobs,
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

  /// Native startup composition only, after fixed-path process admission. Uses
  /// the ordinary lazy background executor, never another default-path lookup.
  factory AppDatabase.fixedNativeFile(File file) =>
      AppDatabase._native(_AppDatabaseNativeFile(), fixedFile: file);

  AppDatabase._native(_AppDatabaseNativeFile native, {File? fixedFile})
    : this._nativeFenced(
        native,
        _NativeCommitSendFence.background(),
        fixedFile: fixedFile,
      );

  AppDatabase._nativeFenced(
    _AppDatabaseNativeFile native,
    _NativeCommitSendFence fence, {
    File? fixedFile,
  }) : _nativeFile = native,
       _commitSendFence = fence,
       _stockSingleConnectionExecutor = true,
       super(_openConnection(native, fence, fixedFile: fixedFile));

  AppDatabase.forTesting(super.e)
    : _nativeFile = null,
      _commitSendFence = null,
      _stockSingleConnectionExecutor = false;

  /// Original synthetic composition from first creation, not adoption of a
  /// supplied executor. No FILE identity, native ROOT or snapshot authority.
  AppDatabase.nativeMemoryForTesting({QueryInterceptor? interceptor})
    : this._memoryNative(_NativeCommitSendFence.local(), interceptor);

  AppDatabase._memoryNative(
    _NativeCommitSendFence fence,
    QueryInterceptor? observer,
  ) : _nativeFile = null,
      _commitSendFence = fence,
      _stockSingleConnectionExecutor = false,
      super(_nativeMemoryExecutor(fence, observer));

  /// Retains THIS raw from initial fixture construction. An optional observer
  /// is necessarily outside our original send fence. Subclasses can override
  /// migrations without replacing the database/executor after native admission.
  AppDatabase.openedNativeForTesting(
    sqlite.Database connection, {
    QueryInterceptor? interceptor,
    bool closeUnderlyingOnClose = true,
  }) : this._openedNativeTesting(
         connection,
         _AppDatabaseNativeFile.fromOpened(connection),
         _NativeCommitSendFence.local(),
         interceptor,
         closeUnderlyingOnClose,
       );

  AppDatabase._openedNativeTesting(
    sqlite.Database raw,
    _AppDatabaseNativeFile native,
    _NativeCommitSendFence fence,
    QueryInterceptor? observer,
    bool closeUnderlyingOnClose,
  ) : _nativeFile = native,
      _commitSendFence = fence,
      _stockSingleConnectionExecutor = false,
      super(
        _retainedNativeExecutor(
          raw,
          fence,
          closeUnderlyingOnClose: closeUnderlyingOnClose,
          observer: observer,
        ),
      );

  /// Native composition only: file identity comes from THIS opened SQLite
  /// connection, not from a separately supplied path. Memory/attached sources
  /// remain usable as databases but do not acquire native snapshot authority.
  factory AppDatabase.openedNative(
    sqlite.Database connection, {
    bool closeUnderlyingOnClose = true,
    void Function()? checkSnapshotSource,
    AndroidSnapshotNamespace? androidSnapshotNamespace,
  }) {
    final native = _AppDatabaseNativeFile.fromOpened(connection);
    native.checkSnapshotSource = checkSnapshotSource;
    if (androidSnapshotNamespace != null) {
      final file = native.file;
      if (!Platform.isAndroid ||
          file == null ||
          !p.posix.isWithin(androidSnapshotNamespace.dataRoot, file.path) ||
          p.posix.basename(file.path) != 'astoria.db') {
        throw StateError('Accepted native snapshot namespace unavailable');
      }
      // Install on THIS retained raw, not another opened/background connection.
      BackgroundDatabaseSnapshotWorker.install(
        connection,
        sourcePath: file.path,
        privateStageRoot: androidSnapshotNamespace.workerStageRoot,
      );
      native.androidSnapshotNamespace = androidSnapshotNamespace;
    }
    final fence = _NativeCommitSendFence.local();
    return AppDatabase._openedNative(
      _retainedNativeExecutor(
        connection,
        fence,
        closeUnderlyingOnClose: closeUnderlyingOnClose,
      ),
      native,
      fence,
    );
  }

  AppDatabase._openedNative(
    super.executor,
    this._nativeFile,
    this._commitSendFence,
  ) : _stockSingleConnectionExecutor = false;

  final _AppDatabaseNativeFile? _nativeFile;
  final _NativeCommitSendFence? _commitSendFence;
  final bool _stockSingleConnectionExecutor;

  /// Constructor attestation, not FILE identity or runtime read authority.
  /// Only our private lazy factory selects the fixed background executor with
  /// readPool: 0 and known worker setup. Externally opened/testing executors are
  /// unknown even if they have a real file. Actual ROOT admission still checks
  /// the original opened owner and busy_timeout=0 before reserving its writer.
  bool get hasAuditedStockSingleConnectionExecutor =>
      _stockSingleConnectionExecutor;
  NativeDataSourceIdentity? _nativeIdentity;
  bool _completedOpening = false;

  /// Factual lifecycle observation, not permission to open or reopen a database.
  /// Read-only maintenance uses this before any public executor-scope check.
  bool get hasCompletedOpening => _completedOpening;
  bool get isClosing => _closing != null;

  late final HistorySourceIndexRepo historySourceIndex = HistorySourceIndexRepo(
    database: this,
    isCurrent: () =>
        hasCompletedOpening && !isClosing && nativeDataSourceIdentity != null,
    joinLifetime: (work) {
      final native = _nativeFile;
      if (native == null) {
        return Future.error(StateError('Native history unavailable'));
      }
      return native.borrow(work);
    },
  );

  /// No path/value getter. Null until the original native executor has opened.
  NativeDataSourceIdentity? get nativeDataSourceIdentity {
    final native = _nativeFile;
    if (native == null || !native.current) return null;
    return _nativeIdentity ??= NativeDataSourceIdentity._(this, native);
  }

  @override
  Future<void> close() => _closing ??= _closeNative();
  Future<void>? _closing;

  Future<void> _closeNative() {
    final native = _nativeFile;
    _commitSendFence?.retire();
    native?.retire(); // Invalidate BEFORE the async executor close.
    if (native == null) return super.close();
    if (native._borrowed.isEmpty && native._unsettledSnapshots.isEmpty) {
      return super.close();
    }
    // Join original borrowed transaction futures, never just their canceled
    // controls or a synchronous SnapshotService.dispose notification.
    return native.drain().then((_) {
      if (native._unsettledSnapshots.isNotEmpty) {
        throw StateError('Original native snapshot resources not settled');
      }
      return super.close();
    });
  }

  @override
  int get schemaVersion => 144;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    beforeOpen: (_) async {
      _nativeFile?.markOpened();
      _completedOpening = true;
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
      await _installHistoryInvalidation();
      await _installCardEvolutionJobLifecycle();
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
      await _upgradeV138(m, from);
      await _upgradeV139(m, from);
      await _upgradeV140(m, from);
      await _upgradeV141(m, from);
      await _upgradeV142(m, from);
      await _upgradeV143(m, from);
      await _upgradeV144(m, from);
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

LazyDatabase _openConnection(
  _AppDatabaseNativeFile native,
  _NativeCommitSendFence fence, {
  File? fixedFile,
}) {
  return LazyDatabase(() async {
    final dbFolder = fixedFile?.parent.path ?? await getAppDataDir();
    final dir = Directory(dbFolder);
    if (!await dir.exists()) {
      await dir.create(recursive: true);
    }
    final canonicalFolder = Platform.isAndroid
        ? await dir.resolveSymbolicLinks()
        : dbFolder;
    final file = fixedFile ?? File(p.join(canonicalFolder, 'astoria.db'));
    final snapshotNamespace = await AndroidSnapshotNamespace.forSource(file);
    if (native.retired) throw StateError('Native database owner retired.');
    native.file = file; // SAME private File passed to the actual executor.
    native.androidSnapshotNamespace = snapshotNamespace;
    if (snapshotNamespace != null) {
      return NativeDatabase.createInBackground(
        file,
        readPool: 0,
        setup: _androidSnapshotWorkerSetup(
          file.path,
          snapshotNamespace.workerStageRoot,
        ),
      ).interceptWith(fence);
    }
    return NativeDatabase.createInBackground(
      file,
      readPool: 0,
      setup: NativeHistoryIndexWorker.install,
    ).interceptWith(fence);
  });
}

// A maker with ONLY immutable strings in its isolate capture context.
void Function(sqlite.Database) _androidSnapshotWorkerSetup(
  String sourcePath,
  String stageRoot,
) => (source) {
  NativeHistoryIndexWorker.install(source);
  BackgroundDatabaseSnapshotWorker.install(
    source,
    sourcePath: sourcePath,
    privateStageRoot: stageRoot,
  );
};
