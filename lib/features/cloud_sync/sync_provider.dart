import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_riverpod/legacy.dart';

import '../../core/state/db_provider.dart';
import '../../core/state/credential_vault_provider.dart';
import '../../core/state/shared_prefs_provider.dart';
import '../../core/credentials/cloud_oauth_credential_owner.dart';
import '../../core/credentials/cloud_oauth_record.dart';
import '../../core/credentials/credential_vault.dart';
import 'services/dropbox/dropbox_auth.dart';
import 'services/gdrive/gdrive_auth.dart';
import '../../core/db/repositories/sync_session_consistency_repo.dart';
import '../../core/db/repositories/rewrite_job_history_sync_repo.dart';
import '../../core/state/character_folder_provider.dart'
    show characterFolderRepoProvider;
import '../../core/state/lorebook_provider.dart' show saveLorebookActivations;
import '../../shared/theme/theme_preset_storage.dart';
import 'adapters/ext_blocks_sync_stores.dart';
import 'services/sync_conflict.dart';
import 'services/sync_engine.dart';
import 'services/sync_service.dart';
import 'sync_config.dart';
import 'sync_models.dart';

final syncServiceProvider = FutureProvider<SyncService>((ref) async {
  // Capture stable vault/redaction and ORIGINAL prefs producer before any await.
  final vault = ref.watch(credentialVaultProvider);
  final redaction = ref.watch(secretRedactionCoordinatorProvider);
  final originalPreferences = ref.watch(sharedPreferencesProvider.future);
  final dropbox = DropboxAuth(
    credentials: CloudOAuthCredentialOwner(
      vault: vault,
      redaction: redaction,
      originalPreferences: originalPreferences,
      provider: CloudOAuthProvider.dropbox,
    ),
  );
  final gdrive = GDriveAuth(
    redaction: redaction,
    credentials: Platform.isAndroid || Platform.isIOS
        ? null
        : CloudOAuthCredentialOwner(
            vault: vault,
            redaction: redaction,
            originalPreferences: originalPreferences,
            provider: CloudOAuthProvider.gdrive,
          ),
  );
  var disposed = false;
  SyncService? owned;
  ref.onDispose(() {
    disposed = true;
    final service = owned;
    if (service != null) {
      service.dispose();
    } else {
      dropbox.dispose();
      gdrive.dispose();
    }
  });
  await SyncConfig.load();
  if (disposed) throw StateError('Cloud sync owner retired');

  final imageStorage = await ref.watch(imageStorageProvider.future);
  if (disposed) throw StateError('Cloud sync owner retired');
  final themeStorage = await ThemePresetStorage.create();
  if (disposed) throw StateError('Cloud sync owner retired');

  final service = SyncService(
    dropboxAuth: dropbox,
    gdriveAuth: gdrive,
    originalPreferences: originalPreferences,
    redaction: redaction,
    characterRepo: ref.watch(characterRepoProvider),
    chatRepo: ref.watch(chatRepoProvider),
    personaRepo: ref.watch(personaRepoProvider),
    presetRepo: ref.watch(presetRepoProvider),
    apiRepo: ref.watch(apiConfigRepoProvider),
    memoryBookRepo: ref.watch(memoryBookRepoProvider),
    lorebookRepo: ref.watch(lorebookRepoProvider),
    embeddingRepo: ref.watch(embeddingRepoProvider),
    imageStorage: imageStorage,
    themePresetRepo: themeStorage,
    extensionPresetRepo: ExtensionPresetSyncStore(
      ref.watch(extensionPresetsRepoProvider),
    ),
    extensionsSettingsStore: ExtensionsSettingsSyncStore(),
    infoBlockStore: InfoBlockSyncStore(ref.watch(infoBlocksRepoProvider)),
    trackerSnapshotStore: TrackerSnapshotSyncStore(
      ref.watch(trackerSnapshotRepoProvider),
    ),
    trackerValueStore: TrackerValueSyncStore(ref.watch(trackerRepoProvider)),
    studioConfigStore: ref.watch(studioConfigRepoProvider),
    studioPresetStore: ref.watch(studioPresetRepoProvider),
    chatSummaryStore: ChatSummarySyncStore(ref.watch(summaryRepoProvider)),
    characterFolderStore: CharacterFolderSyncStore(
      ref.watch(characterFolderRepoProvider),
    ),
    memoryGraphStore: MemoryGraphSyncStore(ref.watch(appDbProvider)),
    characterKnowledgeStore: CharacterKnowledgeSyncStore(
      ref.watch(appDbProvider),
    ),
    sessionLorebookOverlayStore: SessionLorebookOverlaySyncStore(
      ref.watch(appDbProvider),
    ),
    reconciliationStateStore: ReconciliationStateSyncStore(
      ref.watch(appDbProvider),
    ),
    rewriteJobHistoryStore: RewriteJobHistorySyncRepo(ref.watch(appDbProvider)),
    sessionDeletionStore: ref.watch(sessionDeletionRepoProvider),
    characterDeletionStore: ref.watch(characterDeletionRepoProvider),
    saveLorebookActivations: (activations) {
      // Capture the issuing workflow BEFORE preferences acquisition. Never ask
      // for a later service's publication guard after that await.
      final original = owned!.capturePublicationGuard();
      return saveLorebookActivations(activations, null, () {
        if (disposed || !original())
          throw const CredentialVaultAdmissionDenied();
      }, originalPreferences);
    },
    reconcilePulledSessions: SyncSessionConsistencyRepo(
      ref.watch(appDbProvider),
    ).reconcile,
  );
  owned = service;
  final initializing = service.init();
  final originalWorkflow = service.capturePublicationGuard();
  await initializing;
  if (disposed || !originalWorkflow())
    throw StateError('Cloud sync owner retired');

  ref.read(syncProviderProvider.notifier).state = service.provider;
  ref.read(syncConnectedProvider.notifier).state = service.isConnected();
  ref.read(syncAutoEnabledProvider.notifier).state = service.autoSyncEnabled;
  ref.read(syncLastErrorProvider.notifier).state = service.warning;

  return service;
});

final syncStatusProvider = StateProvider<SyncStatus>((ref) => SyncStatus.idle);
final syncProviderProvider = StateProvider<SyncProvider>(
  (ref) => SyncProvider.dropbox,
);
final syncConnectedProvider = StateProvider<bool>((ref) => false);
final syncAutoEnabledProvider = StateProvider<bool>((ref) => false);
final syncConflictsProvider = StateProvider<List<SyncConflict>>((ref) => []);
final syncProgressProvider = StateProvider<SyncProgress?>((ref) => null);
final syncLastErrorProvider = StateProvider<String?>((ref) => null);

final autoSyncMessageCounterProvider = StateProvider<int>((ref) => 0);

void notifySyncMessageGenerated(Ref ref) {
  final autoEnabled = ref.read(syncAutoEnabledProvider);
  if (!autoEnabled) return;

  final counter = ref.read(autoSyncMessageCounterProvider) + 1;
  ref.read(autoSyncMessageCounterProvider.notifier).state = counter;

  final threshold = 5;
  if (counter >= threshold) {
    ref.read(autoSyncMessageCounterProvider.notifier).state = 0;
    final syncAsync = ref.read(syncServiceProvider);
    syncAsync.whenData((service) {
      unawaited(service.tryAutoPush().catchError((_) => false));
    });
  }
}
