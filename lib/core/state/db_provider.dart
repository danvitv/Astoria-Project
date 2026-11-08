import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:dio/io.dart';

import '../db/app_db.dart';
import '../db/repositories/character_repo.dart';
import '../db/repositories/chat_repo.dart';
import '../db/repositories/chat_session_branch_repo.dart';
import '../db/repositories/preset_repo.dart';
import '../models/preset.dart';
import '../db/repositories/api_config_repo.dart';
import '../db/repositories/persona_repo.dart';
import '../db/repositories/lorebook_repo.dart';
import '../db/repositories/session_lorebook_evolution_repo.dart';
import '../db/repositories/session_canon_checkpoint_repo.dart';
import '../db/repositories/session_canon_rollback_repo.dart';
import '../db/repositories/session_lorebook_revision_repo.dart';
import '../db/repositories/session_lorebook_embedding_job_repo.dart';
import '../db/repositories/lorebook_use_manifest_repo.dart';
import '../db/repositories/embedding_repo.dart';
import '../db/repositories/summary_repo.dart';
import '../db/repositories/memory_book_repo.dart';
import '../db/repositories/memory_event_registry_repo.dart';
import '../db/repositories/memory_consolidation_job_repo.dart';
import '../db/repositories/memory_consolidation_pack_builder.dart';
import '../db/repositories/memory_catalog_repo.dart';
import '../db/repositories/memory_entity_repo.dart';
import '../db/repositories/memory_salience_repo.dart';
import '../db/repositories/memory_cadence_repo.dart';
import '../db/repositories/studio_config_repo.dart';
import '../db/repositories/studio_preset_repo.dart';
import '../models/studio_config.dart';
import '../db/repositories/tracker_repo.dart';
import '../db/repositories/tracker_snapshot_repo.dart';
import '../db/repositories/ledger_raw_tracker_state_reader.dart';
import '../db/repositories/ledger_reconciliation_checkpoint_repo.dart';
import '../db/repositories/ledger_reconciliation_run_repo.dart';
import '../db/repositories/ledger_reconciliation_lease_repo.dart';
import '../db/repositories/ledger_debug_run_repo.dart';
import '../db/repositories/llm_request_capture_repo.dart';
import '../db/repositories/card_evolution_repo.dart';
import '../db/repositories/card_evolution_proposal_run_repo.dart';
import '../db/repositories/card_evolution_collector_run_repo.dart';
import '../db/repositories/card_evolution_writer_call_repo.dart';
import '../db/repositories/card_evolution_observation_repo.dart';
import '../db/repositories/character_knowledge_fact_repo.dart';
import '../db/repositories/character_session_baseline_repo.dart';
import '../db/repositories/character_revision_repo.dart';
import '../db/repositories/applied_canon_transition_repo.dart';
import '../db/repositories/canon_transition_fact_ref_repo.dart';
import '../db/repositories/manual_rewrite_apply_repo.dart';
import '../db/repositories/manual_rewrite_job_repo.dart';
import '../db/repositories/extension_presets_repository.dart';
import '../db/repositories/info_blocks_repository.dart';
import '../db/repositories/session_deletion_repo.dart';
import '../db/repositories/character_deletion_repo.dart';
import '../db/repositories/support_repo.dart';
import '../models/memory_book.dart';
import '../llm/transport/llm_request_capture.dart';
import '../llm/transport/llm_call_event.dart';
import '../services/character_importer.dart';
import '../services/image_storage_service.dart';
import '../services/migration_service.dart';
import '../services/memory_consolidation_acceptance_service.dart';
import '../services/memory_consolidation_batch_service.dart';
import '../services/memory_consolidation_coordinator.dart';
import '../services/memory_consolidation_service.dart';
import '../services/card_rewriter/effective_canon_context_loader.dart';
import '../services/card_rewriter/effective_canon_read_repository.dart';
import '../support/support_payload_cipher.dart';
import 'credential_vault_provider.dart';
import 'connection_revision_provider.dart';
import 'chat_source_mutation_provider.dart';
import 'studio_feature_provider.dart';
import 'native_provider_runtime.dart';

// Re-export so existing call sites that `import db_provider.dart` can still
// read pipelineSettingsProvider (previously defined here as a
// FutureProvider.family before the singleton-global refactor).
export 'pipeline_settings_provider.dart' show pipelineSettingsProvider;

// Re-export the global Studio master switch so the generation pipeline stages
// (which already import db_provider) can gate Studio without extra imports.
export 'studio_feature_provider.dart' show studioFeatureEnabledProvider;
export 'native_provider_runtime.dart' show NativeProviderRuntime;

final _captureRepos = Expando<LlmRequestCaptureRepo>();
final _nativeProviderRuntimes = Expando<NativeProviderRuntime>();
Object? _captureInstallationOwner;

/// Constructed only on an explicitly dispatched native job; no shared client.
/// Synthetic root fixtures MUST override this before constructing the graph.
final nativeProviderAdapterFactoryProvider =
    Provider<NativeProviderAdapterFactory>((ref) => IOHttpClientAdapter.new);

final appDbProvider = Provider<AppDatabase>((ref) {
  final db = AppDatabase();
  ref.onDispose(() {
    final repo = _captureRepos[db];
    if (repo != null && identical(LlmRequestCapture.sink, repo)) {
      LlmRequestCapture.sink = null;
    }
    if (repo != null && identical(LlmCallEventCapture.sink, repo)) {
      LlmCallEventCapture.sink = null;
    }
    unawaited((repo?.close() ?? Future<void>.value()).whenComplete(db.close));
  });
  return db;
});

final llmRequestCaptureRepoProvider = Provider<LlmRequestCaptureRepo>((ref) {
  return LlmRequestCaptureRepo(ref.watch(appDbProvider));
});

/// Installs the database-backed request sink for the lifetime of the app scope.
final llmRequestCaptureInstallationProvider = Provider<void>((ref) {
  final repo = ref.watch(llmRequestCaptureRepoProvider);
  // A process-owned repo survives keyed scopes; repo identity is not a lease.
  final installationOwner = Object();
  _captureInstallationOwner = installationOwner;
  _captureRepos[repo.db] = repo;
  LlmRequestCapture.sink = repo;
  LlmCallEventCapture.sink = repo;
  ref.onDispose(() {
    if (!identical(_captureInstallationOwner, installationOwner)) return;
    _captureInstallationOwner = null;
    if (identical(LlmRequestCapture.sink, repo)) {
      LlmRequestCapture.sink = null;
    }
    if (identical(LlmCallEventCapture.sink, repo)) {
      LlmCallEventCapture.sink = null;
    }
  });
});

final imageStorageProvider = FutureProvider<ImageStorageService>((ref) async {
  return await ImageStorageService.create();
});

final characterImporterProvider = FutureProvider<CharacterImporter>((
  ref,
) async {
  final imageStorage = await ref.watch(imageStorageProvider.future);
  return CharacterImporter(imageStorage);
});

final migrationServiceProvider = FutureProvider<MigrationService>((ref) async {
  final imageStorage = await ref.watch(imageStorageProvider.future);
  return MigrationService(
    charRepo: ref.watch(characterRepoProvider),
    chatRepo: ref.watch(chatRepoProvider),
    personaRepo: ref.watch(personaRepoProvider),
    presetRepo: ref.watch(presetRepoProvider),
    apiRepo: ref.watch(apiConfigRepoProvider),
    imageStorage: imageStorage,
  );
});

final characterRepoProvider = Provider<CharacterRepo>((ref) {
  final mutations = ref.watch(chatSourceMutationRegistryProvider);
  return CharacterRepo(
    ref.watch(appDbProvider),
    onMutationStarted: (sessionId) =>
        mutations.beginMutation(sessionId: sessionId),
  );
});

final chatRepoProvider = Provider<ChatRepo>((ref) {
  final mutations = ref.watch(chatSourceMutationRegistryProvider);
  return ChatRepo(
    ref.watch(appDbProvider),
    onMutationStarted: (sessionId) =>
        mutations.beginMutation(sessionId: sessionId),
  );
});

final ledgerReconciliationLeaseRepoProvider =
    Provider<LedgerReconciliationLeaseRepo>((ref) {
      return LedgerReconciliationLeaseRepo(ref.watch(appDbProvider));
    });

final chatSessionBranchRepoProvider = Provider<ChatSessionBranchRepo>((ref) {
  return ChatSessionBranchRepo(ref.watch(appDbProvider));
});

final sessionDeletionRepoProvider = Provider<SessionDeletionRepo>((ref) {
  final mutations = ref.watch(chatSourceMutationRegistryProvider);
  return SessionDeletionRepo(
    ref.watch(appDbProvider),
    onMutationStarted: (sessionId) =>
        mutations.beginMutation(sessionId: sessionId),
  );
});

final characterDeletionRepoProvider = Provider<CharacterDeletionRepo>((ref) {
  final mutations = ref.watch(chatSourceMutationRegistryProvider);
  return CharacterDeletionRepo(
    ref.watch(appDbProvider),
    onMutationStarted: (sessionId) =>
        mutations.beginMutation(sessionId: sessionId),
  );
});

final presetRepoProvider = Provider<PresetRepo>((ref) {
  return PresetRepo(ref.watch(appDbProvider));
});

final presetsListProvider = FutureProvider<List<Preset>>((ref) {
  return ref.watch(presetRepoProvider).getAll();
});

final apiConfigRepoProvider = Provider<ApiConfigRepo>((ref) {
  final adapter = ref.watch(apiConfigCredentialAdapterProvider);
  late final ApiConfigRepo repository;
  final runtime = NativeProviderRuntime(
    vault: ref.watch(credentialVaultProvider),
    redaction: ref.watch(secretRedactionCoordinatorProvider),
    revisions: ref.watch(connectionRevisionRegistryProvider),
    readSavedConnection: (id) => repository.getById(id),
    adapterFactory: ref.watch(nativeProviderAdapterFactoryProvider),
    isOriginalRoot: () => ref.mounted,
  );
  repository = ApiConfigRepo(
    ref.watch(appDbProvider),
    onConfigObserved: adapter.registerConfigSecrets,
    onMutationStarted: runtime.onApiMutationStarted,
    keylessMutations: runtime.keylessMutations,
    ordinaryMutations: runtime.ordinaryMutations,
  );
  _nativeProviderRuntimes[repository] = runtime;
  ref.onDispose(() {
    runtime.dispose();
    if (identical(_nativeProviderRuntimes[repository], runtime)) {
      _nativeProviderRuntimes[repository] = null;
    }
  });
  return repository;
});

/// An overridden legacy repository has NO native runtime. Do not instantiate a
/// default AppDatabase or vault to manufacture one for dependency injection.
final nativeProviderRuntimeProvider = Provider<NativeProviderRuntime?>((ref) {
  final runtime = _nativeProviderRuntimes[ref.watch(apiConfigRepoProvider)];
  return runtime != null && runtime.isCurrent ? runtime : null;
});

final supportPayloadCipherProvider = Provider<SupportPayloadCipher>((ref) {
  return SupportPayloadCipher(vault: ref.watch(credentialVaultProvider));
});

final supportRepoProvider = Provider<SupportRepo>((ref) {
  return SupportRepo(
    ref.watch(appDbProvider),
    ref.watch(supportPayloadCipherProvider),
  );
});

final personaRepoProvider = Provider<PersonaRepo>((ref) {
  return PersonaRepo(ref.watch(appDbProvider));
});

final lorebookRepoProvider = Provider<LorebookRepo>((ref) {
  return LorebookRepo(ref.watch(appDbProvider));
});

final sessionLorebookEvolutionRepoProvider =
    Provider<SessionLorebookEvolutionRepo>((ref) {
      return SessionLorebookEvolutionRepo(ref.watch(appDbProvider));
    });

final sessionCanonCheckpointRepoProvider = Provider<SessionCanonCheckpointRepo>(
  (ref) {
    return SessionCanonCheckpointRepo(ref.watch(appDbProvider));
  },
);

final sessionCanonRollbackRepoProvider = Provider<SessionCanonRollbackRepo>((
  ref,
) {
  return SessionCanonRollbackRepo(ref.watch(appDbProvider));
});

final sessionLorebookRevisionRepoProvider =
    Provider<SessionLorebookRevisionRepo>((ref) {
      return SessionLorebookRevisionRepo(ref.watch(appDbProvider));
    });

final sessionLorebookEmbeddingJobRepoProvider =
    Provider<SessionLorebookEmbeddingJobRepo>((ref) {
      return SessionLorebookEmbeddingJobRepo(ref.watch(appDbProvider));
    });

final lorebookUseManifestRepoProvider = Provider<LorebookUseManifestRepo>((
  ref,
) {
  return LorebookUseManifestRepo(ref.watch(appDbProvider));
});

final ledgerReconciliationRunRepoProvider =
    Provider<LedgerReconciliationRunRepo>(
      (ref) => LedgerReconciliationRunRepo(ref.watch(appDbProvider)),
    );

final ledgerDebugRunRepoProvider = Provider<LedgerDebugRunRepo>(
  (ref) => LedgerDebugRunRepo(ref.watch(appDbProvider)),
);

final cardEvolutionCollectorRunRepoProvider =
    Provider<CardEvolutionCollectorRunRepo>(
      (ref) => CardEvolutionCollectorRunRepo(ref.watch(appDbProvider)),
    );

final cardEvolutionWriterCallRepoProvider =
    Provider<CardEvolutionWriterCallRepo>(
      (ref) => CardEvolutionWriterCallRepo(ref.watch(appDbProvider)),
    );

final cardEvolutionObservationRepoProvider =
    Provider<CardEvolutionObservationRepo>(
      (ref) => CardEvolutionObservationRepo(ref.watch(appDbProvider)),
    );

final cardEvolutionProposalRunRepoProvider =
    Provider<CardEvolutionProposalRunRepo>(
      (ref) => CardEvolutionProposalRunRepo(ref.watch(appDbProvider)),
    );

final embeddingRepoProvider = Provider<EmbeddingRepo>((ref) {
  return EmbeddingRepo(ref.watch(appDbProvider));
});

final summaryRepoProvider = Provider<SummaryRepo>((ref) {
  return SummaryRepo(ref.watch(appDbProvider));
});

final memoryBookRepoProvider = Provider<MemoryBookRepo>((ref) {
  return MemoryBookRepo(ref.watch(appDbProvider), ref);
});

final memoryEventRegistryRepoProvider = Provider<MemoryEventRegistryRepo>(
  (ref) => MemoryEventRegistryRepo(ref.watch(appDbProvider)),
);

final memoryConsolidationCoordinatorProvider =
    Provider<MemoryConsolidationCoordinator>((ref) {
      final db = ref.watch(appDbProvider);
      final registry = ref.watch(memoryEventRegistryRepoProvider);
      return MemoryConsolidationCoordinator(
        packBuilder: MemoryConsolidationPackBuilder(db),
        service: MemoryConsolidationService(),
        acceptance: MemoryConsolidationAcceptanceService(registry),
      );
    });

final memoryConsolidationJobRepoProvider = Provider<MemoryConsolidationJobRepo>(
  (ref) {
    return MemoryConsolidationJobRepo(ref.watch(appDbProvider));
  },
);

/// Owns the durable package flow: enqueue, one-call generation per package,
/// review loading and transactional explicit acceptance. Ordinary modes never
/// route through it.
final memoryConsolidationBatchProvider =
    Provider<MemoryConsolidationBatchService>((ref) {
      final db = ref.watch(appDbProvider);
      final registry = ref.watch(memoryEventRegistryRepoProvider);
      return MemoryConsolidationBatchService(
        db: db,
        jobRepo: ref.watch(memoryConsolidationJobRepoProvider),
        packBuilder: MemoryConsolidationPackBuilder(db),
        service: MemoryConsolidationService(),
        acceptance: MemoryConsolidationAcceptanceService(registry),
      );
    });

/// Package jobs of one session, newest first — what the memory books tab's
/// package panel follows instead of polling.
final memoryConsolidationSessionJobsProvider = StreamProvider.autoDispose
    .family<List<MemoryConsolidationJobRow>, String>((ref, sessionId) {
      return ref
          .watch(memoryConsolidationJobRepoProvider)
          .watchSessionJobs(sessionId);
    });

/// Source items of one package job, for queue counts on the panel.
final memoryConsolidationJobItemsProvider = StreamProvider.autoDispose
    .family<List<MemoryConsolidationJobItemRow>, String>((ref, jobId) {
      return ref.watch(memoryConsolidationJobRepoProvider).watchItems(jobId);
    });

final memoryCatalogRepoProvider = Provider<MemoryCatalogRepo>((ref) {
  return MemoryCatalogRepo(ref.watch(appDbProvider));
});

final memoryEntityRepoProvider = Provider<MemoryEntityRepo>((ref) {
  return MemoryEntityRepo(ref.watch(appDbProvider));
});

final memorySalienceRepoProvider = Provider<MemorySalienceRepo>((ref) {
  return MemorySalienceRepo(ref.watch(appDbProvider));
});

final memoryCadenceRepoProvider = Provider<MemoryCadenceRepo>((ref) {
  return MemoryCadenceRepo(ref.watch(appDbProvider));
});

final studioConfigRepoProvider = Provider<StudioConfigRepo>((ref) {
  return StudioConfigRepo(ref.watch(appDbProvider));
});

final studioPresetRepoProvider = Provider<StudioPresetRepo>((ref) {
  return StudioPresetRepo(ref.watch(appDbProvider));
});

// `studioPresetProvider` — the preset a turn actually runs — lives in
// `active_studio_preset_provider.dart`: it needs the active-preset id, and that
// provider already imports this file.

final studioPresetListProvider = FutureProvider<List<StudioPreset>>((
  ref,
) async {
  return ref.watch(studioPresetRepoProvider).getAll();
});

/// Whether Studio is enabled globally. The session id remains part of the
/// provider API for its chat UI consumers, but no longer controls activation.
final sessionStudioEnabledProvider = FutureProvider.family<bool, String>((
  ref,
  sessionId,
) async {
  if (sessionId.isEmpty) return false;
  return ref.watch(studioFeatureEnabledProvider);
});

final trackerRepoProvider = Provider<TrackerRepo>((ref) {
  return TrackerRepo(ref.watch(appDbProvider));
});

final trackerSnapshotRepoProvider = Provider<TrackerSnapshotRepo>((ref) {
  return TrackerSnapshotRepo(ref.watch(appDbProvider));
});

/// Ref-free raw Ledger read boundary for transaction-fenced canon operations.
final ledgerRawTrackerStateReaderProvider =
    Provider<LedgerRawTrackerStateReader>((ref) {
      return LedgerRawTrackerStateReader(ref.watch(appDbProvider));
    });

final ledgerReconciliationCheckpointRepoProvider =
    Provider<LedgerReconciliationCheckpointRepo>((ref) {
      return LedgerReconciliationCheckpointRepo(ref.watch(appDbProvider));
    });

final characterKnowledgeFactRepoProvider = Provider<CharacterKnowledgeFactRepo>(
  (ref) {
    return CharacterKnowledgeFactRepo(ref.watch(appDbProvider));
  },
);

final characterSessionBaselineRepoProvider =
    Provider<CharacterSessionBaselineRepo>((ref) {
      return CharacterSessionBaselineRepo(ref.watch(appDbProvider));
    });

final characterRevisionRepoProvider = Provider<CharacterRevisionRepo>((ref) {
  return CharacterRevisionRepo(ref.watch(appDbProvider));
});

final appliedCanonTransitionRepoProvider = Provider<AppliedCanonTransitionRepo>(
  (ref) {
    return AppliedCanonTransitionRepo(ref.watch(appDbProvider));
  },
);

final canonTransitionFactRefRepoProvider = Provider<CanonTransitionFactRefRepo>(
  (ref) {
    return CanonTransitionFactRefRepo(ref.watch(appDbProvider));
  },
);

/// Construction only: [EffectiveCanonContextLoader] stays Ref-free.
final effectiveCanonContextLoaderProvider =
    Provider<EffectiveCanonContextLoader>((ref) {
      return EffectiveCanonContextLoader(
        db: ref.watch(appDbProvider),
        characterRepo: ref.watch(characterRepoProvider),
        characterRevisionRepo: ref.watch(characterRevisionRepoProvider),
        baselineRepo: ref.watch(characterSessionBaselineRepoProvider),
        factRepo: ref.watch(characterKnowledgeFactRepoProvider),
        transitionRepo: ref.watch(appliedCanonTransitionRepoProvider),
        transitionFactRefRepo: ref.watch(canonTransitionFactRefRepoProvider),
        loadRawTrackerState: ref
            .watch(ledgerRawTrackerStateReaderProvider)
            .read,
      );
    });

final memoryBookProvider = FutureProvider.family<MemoryBook?, String>((
  ref,
  sessionId,
) async {
  final repo = ref.watch(memoryBookRepoProvider);
  return repo.getBySessionId(sessionId);
});

final manualRewriteApplyRepoProvider = Provider<ManualRewriteApplyRepo>((ref) {
  return ManualRewriteApplyRepo(
    db: ref.watch(appDbProvider),
    lorebookEvolutionRepo: ref.watch(sessionLorebookEvolutionRepoProvider),
    checkpointRepo: ref.watch(sessionCanonCheckpointRepoProvider),
    lorebookRevisionRepo: ref.watch(sessionLorebookRevisionRepoProvider),
    embeddingJobRepo: ref.watch(sessionLorebookEmbeddingJobRepoProvider),
    canonReader: EffectiveCanonReadRepository(
      db: ref.watch(appDbProvider),
      characterRepo: ref.watch(characterRepoProvider),
      revisionRepo: ref.watch(characterRevisionRepoProvider),
      baselineRepo: ref.watch(characterSessionBaselineRepoProvider),
      factRepo: ref.watch(characterKnowledgeFactRepoProvider),
      transitionRepo: ref.watch(appliedCanonTransitionRepoProvider),
      transitionFactRefRepo: ref.watch(canonTransitionFactRefRepoProvider),
      rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
    ),
  );
});

/// Owns the durable Phase-4 job/review lifecycle. Advisory validation reads
/// through the same-DB raw Ledger reader; it never writes canon or characters.
final manualRewriteJobRepoProvider = Provider<ManualRewriteJobRepo>((ref) {
  return ManualRewriteJobRepo(
    db: ref.watch(appDbProvider),
    rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
  );
});

final cardEvolutionRepoProvider = Provider<CardEvolutionRepo>((ref) {
  final db = ref.watch(appDbProvider);
  return CardEvolutionRepo(
    db: db,
    canonReader: EffectiveCanonReadRepository(
      db: db,
      characterRepo: ref.watch(characterRepoProvider),
      revisionRepo: ref.watch(characterRevisionRepoProvider),
      baselineRepo: ref.watch(characterSessionBaselineRepoProvider),
      factRepo: ref.watch(characterKnowledgeFactRepoProvider),
      transitionRepo: ref.watch(appliedCanonTransitionRepoProvider),
      transitionFactRefRepo: ref.watch(canonTransitionFactRefRepoProvider),
      rawTrackerStateReader: ref.watch(ledgerRawTrackerStateReaderProvider),
    ),
    jobRepo: ref.watch(manualRewriteJobRepoProvider),
    lorebookEvolutionRepo: ref.watch(sessionLorebookEvolutionRepoProvider),
  );
});

final extensionPresetsRepoProvider = Provider<ExtensionPresetsRepository>((
  ref,
) {
  return ExtensionPresetsRepository(ref.watch(appDbProvider));
});

final infoBlocksRepoProvider = Provider<InfoBlocksRepository>((ref) {
  return InfoBlocksRepository(ref.watch(appDbProvider));
});
