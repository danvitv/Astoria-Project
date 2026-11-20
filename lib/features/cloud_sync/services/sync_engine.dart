import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../../../core/preferences/saved_preferences_owner.dart';
import '../../../core/preferences/tracked_shared_preferences.dart';
import '../../../core/credentials/cloud_oauth_credential_owner.dart';

import '../cloud_adapter.dart';
import '../sync_models.dart';
import 'sync_binary_asset_syncer.dart';
import 'sync_conflict.dart';
import 'sync_conflict_diagnostics.dart';
import 'sync_queue.dart';
import 'sync_image_stripper.dart';
import 'sync_serialization.dart';
import 'sync_tracker_snapshot_decoder.dart';
import 'sync_payload_transport.dart';
import 'reconciliation_page_transport.dart';
import 'reconciliation_page_cache.dart';
import 'sync_character_hash.dart';
import 'sync_character_world_equivalence.dart';
import 'sync_unordered_aggregate_bridge.dart';
import '../../../core/models/character.dart';
import '../../../core/models/gallery_entry.dart';
import '../../../core/models/memory_book.dart';
import '../../../core/models/persona.dart';
import '../../../core/models/chat_message.dart';
import '../../../core/models/chat_session_content.dart';
import '../../../core/models/tracker_snapshot.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/extra_request_parameter.dart';
import '../../../core/models/preset.dart';
import '../../../core/llm/transport/endpoint_normalizer.dart';
import '../../../core/services/backup/backup_secret_routes.dart';
import '../../../core/services/backup/backup_secret_runtime.dart';
import '../../../core/services/backup/backup_secret_urls.dart';
import '../../../core/services/backup/backup_secrets.dart';
import '../../../core/models/studio_agent_codec.dart';
import '../../../core/models/studio_preset_codec.dart';
import '../../../core/application/session_deletion_store.dart';
import '../../../core/application/character_deletion_store.dart';
import '../../../core/application/sync_reconciliation_source.dart';
import '../../../shared/theme/theme_preset.dart';
import '../sync_repo_interfaces.dart';
import '../../../features/extensions/models/extension_preset.dart';
import '../../../features/extensions/models/extensions_settings.dart';
import '../../../features/extensions/models/info_block.dart';
import '../../settings/app_settings_provider.dart';

class SyncProgress {
  final int current;
  final int total;
  final String? message;

  const SyncProgress({this.current = 0, this.total = 0, this.message});
}

class SyncPullRequiredBeforePush implements Exception {
  const SyncPullRequiredBeforePush(this.message);

  final String message;

  @override
  String toString() => message;
}

class SyncEngine {
  final CloudAdapter _adapter;
  final SyncManifestProvider _manifestBuilder;
  final SyncCharacterStore _characterRepo;
  final SyncChatStore _chatRepo;
  final SyncPersonaStore _personaRepo;
  final SyncPresetStore _presetRepo;
  final SyncApiConfigStore _apiRepo;
  final SyncMemoryBookStore _memoryBookRepo;
  final SyncLorebookStore _lorebookRepo;
  final SyncEmbeddingStore _embeddingRepo;
  final SyncImageStore _imageStorage;
  final SyncThemePresetStore _themePresetRepo;
  final SyncExtensionPresetStore _extensionPresetRepo;
  final SyncExtensionsSettingsStore _extensionsSettingsStore;
  final SyncInfoBlockStore _infoBlockStore;
  final SyncTrackerSnapshotStore _trackerSnapshotStore;
  final SyncTrackerValueStore _trackerValueStore;
  final SyncStudioConfigStore _studioConfigStore;
  final SyncStudioPresetStore? _studioPresetStore;
  final SyncChatSummaryStore? _chatSummaryStore;
  final SyncCharacterFolderStore? _characterFolderStore;
  final SyncMemoryGraphStore? _memoryGraphStore;
  final SyncCharacterKnowledgeStore? _characterKnowledgeStore;
  final SyncReconciliationStateStore? _reconciliationStateStore;
  final SyncSessionLorebookOverlayStore? _sessionLorebookOverlayStore;
  final SyncRewriteJobHistoryStore? _rewriteJobHistoryStore;
  final SyncMemoryEventRegistryStore? _memoryEventRegistryStore;
  final SessionDeletionStore _sessionDeletionStore;
  final CharacterDeletionStore _characterDeletionStore;
  final Future<void> Function(LorebookActivations) _saveLorebookActivations;
  final Future<void> Function(Set<String>)? _reconcilePulledSessions;
  final Future<void> Function(Map<String, Set<String>>)?
  _reconcileMemoryConsolidationJobs;
  final int _operationDelayMs;
  final Duration _wipePollInterval;
  final SyncQueue _queue = SyncQueue();
  late final SyncBinaryAssetSyncer _binarySyncer;
  late final SyncUnorderedAggregateBridge _unorderedBridge;
  bool _includeApiKeys = false;
  final void Function()? _checkOriginalWorkflow;
  final ReconciliationPageCache? _reconciliationPageCache;
  int _committedLocalWrites = 0;

  void _checkCurrent() {
    try {
      _checkOriginalWorkflow?.call();
    } catch (_) {
      throw SyncWorkflowRetired(_committedLocalWrites);
    }
  }

  Future<T> _read<T>(Future<T> Function() original) async {
    _checkCurrent();
    final result = await original();
    _checkCurrent();
    return result;
  }

  Future<void> _commit(Future<void> Function() original) async {
    _checkCurrent();
    await original(); // Settle the invoked write; retirement is not rollback.
    _committedLocalWrites++;
    _checkCurrent();
  }

  void Function(SyncProgress) _guardProgress(
    void Function(SyncProgress) original,
  ) => (progress) {
    _checkCurrent();
    original(progress);
  };
  void Function() _captureActiveGuard() {
    final queue = _queue.captureActiveGuard();
    return () {
      _checkCurrent();
      queue();
    };
  }

  SyncEngine(
    this._adapter,
    this._manifestBuilder,
    this._characterRepo,
    this._chatRepo,
    this._personaRepo,
    this._presetRepo,
    this._apiRepo,
    this._memoryBookRepo,
    this._lorebookRepo,
    this._embeddingRepo,
    this._imageStorage,
    this._themePresetRepo,
    this._extensionPresetRepo,
    this._extensionsSettingsStore,
    this._infoBlockStore,
    this._trackerSnapshotStore,
    this._trackerValueStore,
    this._studioConfigStore,
    this._studioPresetStore,
    this._chatSummaryStore,
    this._characterFolderStore,
    this._memoryGraphStore,
    this._characterKnowledgeStore,
    this._sessionDeletionStore,
    this._characterDeletionStore,
    this._saveLorebookActivations, [
    this._reconciliationStateStore,
    this._sessionLorebookOverlayStore,
    this._reconcilePulledSessions,
    this._operationDelayMs = 300,
    this._wipePollInterval = const Duration(seconds: 2),
    this._rewriteJobHistoryStore,
    this._checkOriginalWorkflow,
    this._reconciliationPageCache,
    this._memoryEventRegistryStore,
    this._reconcileMemoryConsolidationJobs,
  ]) {
    _binarySyncer = SyncBinaryAssetSyncer(
      _adapter,
      _characterRepo,
      _personaRepo,
      _presetRepo,
      _imageStorage,
      _checkCurrent,
      _commit,
    );
    _unorderedBridge = SyncUnorderedAggregateBridge(
      download: (path) => _read(() => _adapter.download(path)),
      readLocal: _readLocalEntity,
      isDeleted: (type, id) =>
          _read(() => _manifestBuilder.isDeleted(type, id)),
    );
  }

  Future<SyncConflictDiagnosticReport> diagnoseConflicts(
    List<SyncConflict> conflicts, {
    required Future<String> Function(String) diagnosticDownload,
  }) => SyncConflictDiagnostics(
    readLocal: _readLocalEntity,
    download: diagnosticDownload,
  ).diagnose(conflicts);

  Future<void> pushEntities({
    required void Function(SyncProgress) onProgress,
    bool? includeApiKeys,
  }) async {
    _checkCurrent();
    onProgress = _guardProgress(onProgress);
    _includeApiKeys =
        includeApiKeys ??
        ((await _read(
              SharedPreferences.getInstance,
            )).getBool(SyncSerialization.syncIncludeApiKeysPrefKey) ??
            false);
    await _adapter.ensureFolder(cloudBase);
    await _runBounded(const [
      'characters',
      'personas',
      'chats',
      'memory_books',
      'persona_avatars',
      'preset_images',
      'extension_presets',
      'info_blocks',
      'tracker_snapshots',
      'tracker_values',
      'studio_configs',
      'studio_presets',
      'chat_summaries',
      'memory_graphs',
      'character_knowledge',
      'session_lorebook_overlays',
      'reconciliation_state',
      'rewrite_job_history',
      'memory_event_registry',
    ], (folder) => _adapter.ensureFolder('$cloudBase/$folder'));

    onProgress(const SyncProgress(message: 'Building sync manifest...'));
    final previousManifest = await _read(_manifestBuilder.readLocalManifest);
    SyncManifest? cloudManifest;
    try {
      final raw = await _adapter.download(cloudPath('manifest', 'manifest'));
      cloudManifest = SyncManifest.fromJson(
        jsonDecode(raw) as Map<String, dynamic>,
      );
    } on CloudFileNotFoundException {
      // A missing manifest means this is the first push or cloud data was wiped.
    } catch (e, st) {
      debugPrint('[sync] cloud manifest download failed: $e\n$st');
      rethrow;
    }
    final missingAvatarKeys = cloudManifest == null
        ? <String>{}
        : await _repairPreviouslySyncedAvatars(cloudManifest, previousManifest);
    await _mergeCloudReconciliationState(cloudManifest, previousManifest);
    // This aggregate is a union of applied jobs. On a push-first device,
    // merge any cloud-only history before computing the final manifest; a
    // local prefix must not replace a longer cloud history.
    await _mergeCloudRewriteJobHistory(cloudManifest);
    await _mergeCloudMemoryEventRegistry(cloudManifest, previousManifest);
    var localManifest = await _read(
      () => _manifestBuilder.buildLocalManifest(cloudManifest: cloudManifest),
    );
    if (cloudManifest != null) {
      for (final key in localManifest.trackerSnapshotRestoreHashes.keys) {
        final snapshot = localManifest.entries[key];
        if (snapshot == null) continue;
        final chatKey = entryKey('chat', snapshot.id);
        final localChat = localManifest.entries[chatKey];
        final previousChat = previousManifest.entries[chatKey];
        final cloudChat = cloudManifest.entries[chatKey];
        if (localChat != null &&
            !localChat.deleted &&
            previousChat != null &&
            !previousChat.deleted &&
            cloudChat != null &&
            localChat.hash == previousChat.hash &&
            (cloudChat.deleted || cloudChat.hash != localChat.hash)) {
          // Protect the owner too: publishing its old message prefix would
          // orphan complete cloud snapshots and make the repair truncate again.
          // Do not advance the local owner baseline without importing that chat.
          throw StateError(
            'Pull required before push: cloud chat changed during snapshot history repair',
          );
        }
      }
    }
    localManifest = await _bridgeCharacterHashes(localManifest, cloudManifest);
    localManifest = await _unorderedBridge.bridge(localManifest, cloudManifest);
    // Fingerprint the bytes that include keys, not an accepted keyless hash.
    final apiPushSnapshot = (await _read(_apiRepo.getAll)).map((a) {
      return (_includeApiKeys ? a : a.copyWith(apiKey: '', embeddingApiKey: ''))
          .toJson();
    }).toList();
    final apiSnapshotHash = SyncSerialization.computeSyncHash(apiPushSnapshot);
    if (_includeApiKeys) {
      final apiEntry =
          localManifest.entries[entryKey('api_presets', 'api_presets')];
      if (apiEntry != null && !apiEntry.deleted) {
        final entriesWithKeys = Map<String, SyncManifestEntry>.from(
          localManifest.entries,
        );
        entriesWithKeys[apiEntry.key] = SyncManifestEntry(
          type: apiEntry.type,
          id: apiEntry.id,
          path: apiEntry.path,
          updatedAt: DateTime.now().millisecondsSinceEpoch,
          hash: apiSnapshotHash,
        );
        localManifest = localManifest.copyWith(entries: entriesWithKeys);
      }
    }
    if (missingAvatarKeys.isNotEmpty) {
      // A vanished local file cannot be uploaded, and a vanished cloud file
      // cannot be restored. Keep the last cloud entity instead of publishing a
      // new hash that falsely represents the missing bytes as an avatar edit.
      final entries = Map<String, SyncManifestEntry>.from(
        localManifest.entries,
      );
      final accepted = Map<String, String>.from(
        localManifest.acceptedLocalHashes,
      );
      for (final key in missingAvatarKeys) {
        final cloudEntry = cloudManifest!.entries[key]!;
        final localEntry = entries[key];
        if (localEntry == null || localEntry.deleted) continue;
        final localData = await _readLocalEntity(
          cloudEntry.type,
          cloudEntry.id,
        );
        final cloudData = await SyncSerialization.readRequiredCloudEntity(
          _adapter,
          cloudEntry,
        );
        if (localData != null &&
            _sameEntityWithoutImagePaths(
              localData,
              cloudData,
              ignoreCharacterMetadata: cloudEntry.type == 'character',
            )) {
          entries[key] = cloudEntry;
          if (cloudEntry.type != 'character' ||
              localEntry.hash != cloudEntry.hash) {
            accepted[key] = localEntry.hash;
          } else if (accepted[key] == cloudEntry.hash) {
            // A published normalized card needs no self-referential marker;
            // keep an existing distinct anchor for a legacy missing avatar.
            accepted.remove(key);
          }
        } else {
          // A real authored edit must still be pushed even if its old avatar is
          // gone; only unchanged entities may reuse the old cloud hash.
          accepted.remove(key);
        }
      }
      localManifest = localManifest.copyWith(
        entries: entries,
        acceptedLocalHashes: accepted,
      );
    }
    final entries = localManifest.entries.values.toList();
    final candidatePaths = cloudManifest == null
        ? const <String>[]
        : entries
              .where((entry) {
                if (entry.deleted) return false;
                final cloudEntry = cloudManifest?.entries[entry.key];
                return cloudEntry != null &&
                    !cloudEntry.deleted &&
                    cloudEntry.hash == entry.hash;
              })
              .map((entry) => entry.path)
              .toList();
    final cloudListing = candidatePaths.isEmpty
        ? (paths: <String>{}, foldersWithFiles: <String>{})
        : await _loadCloudFilePathsForEntries(
            candidatePaths,
            onProgress: onProgress,
          );

    await _unorderedBridge.verifyAnchors(localManifest);
    final tasks = <Future<void> Function()>[];
    var processed = 0;
    final hashSkippedKeys = <String>[];
    var apiPayloadUploaded = false;

    for (final entry in entries) {
      final cloudEntry = cloudManifest?.entries[entry.key];

      if (localManifest.trackerSnapshotRestoreHashes.containsKey(entry.key)) {
        // Even a changed cloud hash or missing payload must not cause this
        // known truncated local aggregate to replace the cloud history.
        hashSkippedKeys.add(entry.key);
        continue;
      }

      if (entry.deleted) {
        if (cloudEntry != null && !cloudEntry.deleted) {
          tasks.add(() async {
            onProgress(
              SyncProgress(
                current: processed,
                total: tasks.length,
                message: 'Deleting ${entry.type}:${entry.id}',
              ),
            );
            await SyncSerialization.deleteCloudFileIfExists(_adapter, entry);
            _checkCurrent();
            processed++;
            onProgress(
              SyncProgress(
                current: processed,
                total: tasks.length,
                message: 'Deleted ${entry.key}',
              ),
            );
          });
        }
        continue;
      }

      final cloudFileExists = cloudSyncPathExists(
        cloudListing.paths,
        entry.path,
      );

      // Trust the cloud manifest hash for the skip decision. A fresh folder
      // listing only serves to repair an entry whose file is genuinely missing.
      // Previously, when the listing came back empty or errored, every
      // hash-matching entry was re-uploaded because file existence could not be
      // confirmed — producing a full-cloud re-push with no duplicates. See the
      // empty-body fall-through that this replaces.
      final keysMissing =
          entry.type == 'api_presets' &&
          _includeApiKeys &&
          cloudManifest?.apiKeysIncluded != true;
      if (!keysMissing &&
          cloudEntry != null &&
          !cloudEntry.deleted &&
          cloudEntry.hash == entry.hash) {
        final listingVerifiedMissing =
            cloudListing.foldersWithFiles.contains(
              _cloudParentFolder(entry.path),
            ) &&
            !cloudFileExists;
        if (listingVerifiedMissing) {
          // Listing succeeded and the file is actually absent — repair it.
          // Falls through to the push task below.
        } else {
          hashSkippedKeys.add(entry.key);
          continue;
        }
      }

      tasks.add(() async {
        onProgress(
          SyncProgress(
            current: processed,
            total: tasks.length,
            message: 'Pushing ${entry.type}:${entry.id}',
          ),
        );
        if (entry.type == 'api_presets') {
          final payload = jsonEncode({
            '__singleton': true,
            'items': apiPushSnapshot,
          });
          if (utf8.encode(payload).length > maxSyncPayloadBytes) {
            throw StateError('API presets exceed sync payload limit');
          }
          await _adapter.upload(entry.path, payload);
        } else {
          await _pushEntry(
            entry,
            onProgress: (message) => onProgress(
              SyncProgress(
                current: processed,
                total: tasks.length,
                message: message,
              ),
            ),
          );
        }
        _checkCurrent();
        if (entry.type == 'api_presets') apiPayloadUploaded = true;
        processed++;
        onProgress(
          SyncProgress(
            current: processed,
            total: tasks.length,
            message: 'Pushed ${entry.key}',
          ),
        );
      });
    }

    onProgress(
      SyncProgress(
        current: 0,
        total: tasks.length,
        message: tasks.isEmpty
            ? 'Nothing to push'
            : 'Pushing ${tasks.length} items...',
      ),
    );

    List<Object>? taskErrors;
    if (tasks.isNotEmpty) {
      final result = await _queue.enqueueAll(
        tasks,
        concurrency: 3,
        delayMs: _operationDelayMs,
      );
      taskErrors = result.errors;
    }

    if (taskErrors != null && taskErrors.isNotEmpty) {
      throw SyncQueueAggregateError(taskErrors);
    }

    final cleanedEntries = <String, SyncManifestEntry>{
      ...?cloudManifest?.entries,
      ...localManifest.entries,
    };
    for (final entry in localManifest.entries.values) {
      if (entry.deleted && entry.type != 'memory_event_registry') {
        cleanedEntries.remove(entry.key);
      }
    }
    final acceptedLocalHashes = Map<String, String>.from(
      localManifest.acceptedLocalHashes,
    );
    for (final key in localManifest.trackerSnapshotRestoreHashes.keys) {
      final cloudEntry = cloudManifest?.entries[key];
      if (cloudEntry == null) {
        cleanedEntries.remove(key);
      } else {
        cleanedEntries[key] = cloudEntry;
      }
    }
    if (apiPayloadUploaded) {
      final key = entryKey('api_presets', 'api_presets');
      final entry = cleanedEntries[key];
      if (entry != null) {
        cleanedEntries[key] = SyncManifestEntry(
          type: entry.type,
          id: entry.id,
          path: entry.path,
          updatedAt: entry.updatedAt,
          hash: apiSnapshotHash,
        );
        acceptedLocalHashes.remove(key);
      }
    }
    // A device that has not pulled a cloud chat yet must not erase its applied
    // history (or its owning chat) merely by pushing other local changes first.
    // Keep those cloud manifest entries until the normal pull imports the chat.
    if (cloudManifest != null &&
        (_rewriteJobHistoryStore != null ||
            _memoryEventRegistryStore != null)) {
      for (final history in cloudManifest.entries.values) {
        if ((history.type != 'rewrite_job_history' ||
                _rewriteJobHistoryStore == null) &&
            (history.type != 'memory_event_registry' ||
                _memoryEventRegistryStore == null)) {
          continue;
        }
        if (history.deleted) continue;
        final chatKey = entryKey('chat', history.id);
        final cloudChat = cloudManifest.entries[chatKey];
        if (cloudChat == null ||
            cloudChat.deleted ||
            await _read(() => _manifestBuilder.isDeleted('chat', history.id))) {
          continue;
        }
        if (!cleanedEntries.containsKey(chatKey)) {
          cleanedEntries[chatKey] = cloudChat;
          cleanedEntries[history.key] = history;
        }
      }
    }

    await _unorderedBridge.verifyAnchors(localManifest);
    final updatedManifest = localManifest.copyWith(
      version: SyncManifest.currentVersion,
      lastSync: DateTime.now().millisecondsSinceEpoch,
      entries: cleanedEntries,
      acceptedLocalHashes: acceptedLocalHashes,
      apiKeysIncluded: apiPayloadUploaded
          ? _includeApiKeys
          : (cloudManifest?.apiKeysIncluded ?? false),
    );
    final manifestJson = jsonEncode(
      updatedManifest.toJson(includeLocalState: false),
    );
    onProgress(
      SyncProgress(
        current: processed,
        total: tasks.length,
        message: 'Publishing sync manifest...',
      ),
    );
    await _adapter.upload(cloudPath('manifest', 'manifest'), manifestJson);
    await _unorderedBridge.verifyAnchors(localManifest);
    await _commit(() => _manifestBuilder.writeLocalManifest(updatedManifest));
    await _commit(_manifestBuilder.clearDeleted);
  }

  Future<({Set<String> paths, Set<String> foldersWithFiles})>
  _loadCloudFilePathsForEntries(
    List<String> entryPaths, {
    required void Function(SyncProgress) onProgress,
  }) async {
    onProgress(const SyncProgress(message: 'Checking cloud files...'));
    final folders = entryPaths.map(_cloudParentFolder).toSet();
    final paths = <String>{};
    final foldersWithFiles = <String>{};
    await _runBounded(folders, (folder) async {
      try {
        final files = await _adapter.listFolder(folder);
        _checkCurrent();
        if (files.any((file) => !file.isFolder)) {
          foldersWithFiles.add(folder);
        }
        paths.addAll(
          files
              .where((f) => !f.isFolder)
              .map((f) => normalizeCloudSyncPath(f.path)),
        );
      } catch (e, st) {
        // A failed listing used to silently drop the folder from cloudFilePaths,
        // which collapsed the skip gate and triggered a full re-push. Log it so
        // the cause is visible; the skip logic now trusts the manifest hash
        // regardless of listing success.
        debugPrint('[sync] listFolder failed for "$folder": $e\n$st');
      }
    });
    return (paths: paths, foldersWithFiles: foldersWithFiles);
  }

  Future<void> _runBounded<T>(
    Iterable<T> items,
    Future<void> Function(T item) operation, {
    int concurrency = 4,
  }) async {
    final pending = items.toList(growable: false);
    var next = 0;

    Future<void> worker() async {
      while (next < pending.length) {
        _checkCurrent();
        final item = pending[next++];
        await operation(item);
        _checkCurrent();
      }
    }

    await Future.wait(
      List.generate(pending.length.clamp(0, concurrency), (_) => worker()),
    );
  }

  String _cloudParentFolder(String path) {
    final slash = path.lastIndexOf('/');
    if (slash <= 0) return cloudBase;
    return path.substring(0, slash);
  }

  Future<void> pullEntities({
    required void Function(SyncProgress) onProgress,
    required void Function(SyncConflict) onConflict,
  }) async {
    _checkCurrent();
    onProgress = _guardProgress(onProgress);
    final cloudManifest = await _downloadCloudManifest();
    _checkCurrent();
    if (cloudManifest == null) return;
    final previousManifest = await _read(_manifestBuilder.readLocalManifest);
    final isFirstSync = previousManifest.lastSync == 0;
    final localManifest = await _unorderedBridge.bridge(
      await _bridgeCharacterHashes(
        await _read(
          () =>
              _manifestBuilder.buildLocalManifest(cloudManifest: cloudManifest),
        ),
        cloudManifest,
      ),
      cloudManifest,
    );

    final entries = cloudManifest.entries.values.toList();
    final conflicts = <SyncConflict>[];
    final pullEntries = <SyncManifestEntry>[];
    final acceptedCloudEntries = <SyncManifestEntry>[];

    for (final cloudEntry in entries) {
      if (cloudEntry.type == 'rewrite_job_history') {
        if (_rewriteJobHistoryStore == null || cloudEntry.deleted) continue;
        final chatEntry =
            cloudManifest.entries[entryKey('chat', cloudEntry.id)];
        if (chatEntry == null || chatEntry.deleted) {
          // The owning cloud chat is absent or deleted; don't import an orphan.
          // A local deletion marker does not apply here: this pull can restore
          // the chat before the ordered rewrite-history import. The marker is
          // cleared only after the pull finishes.
          continue;
        }
      } else if (cloudEntry.type == 'memory_event_registry') {
        if (_memoryEventRegistryStore == null) continue;
        if (!cloudEntry.deleted) {
          final chatEntry =
              cloudManifest.entries[entryKey('chat', cloudEntry.id)];
          if (chatEntry == null || chatEntry.deleted) continue;
        }
      }
      final localEntry = localManifest.entries[cloudEntry.key];
      final previouslyAccepted = previousManifest.entries[cloudEntry.key];
      final ambiguousRegistryDeletion =
          cloudEntry.type == 'memory_event_registry' &&
          cloudEntry.deleted &&
          localEntry != null &&
          !localEntry.deleted &&
          (previouslyAccepted == null ||
              (!previouslyAccepted.deleted &&
                  previouslyAccepted.hash != localEntry.hash));
      if (ambiguousRegistryDeletion) {
        conflicts.add(
          SyncConflict(
            key: cloudEntry.key,
            type: cloudEntry.type,
            id: cloudEntry.id,
            localEntry: localEntry,
            cloudEntry: cloudEntry,
            name: SyncConflictDetector.getConflictName(
              cloudEntry.type,
              null,
              null,
              cloudEntry.id,
            ),
          ),
        );
        continue;
      }

      if (localManifest.trackerSnapshotRestoreHashes.containsKey(
        cloudEntry.key,
      )) {
        if (await _canRestoreTrackerSnapshots(
          cloudEntry,
          localManifest,
          previousManifest,
          cloudManifest,
        )) {
          pullEntries.add(cloudEntry);
        }
        // Defer unsafe owner states rather than falling through to a generic
        // timestamp-based replacement of the known truncated aggregate.
        continue;
      }

      if (!previousManifest.needsReconciliationRestore(cloudEntry.key) &&
          _isAlreadyCurrentOrAccepted(
            cloudEntry,
            localEntry,
            previouslyAccepted,
            ignorePreviouslyAccepted:
                (cloudEntry.type == 'reconciliation_state' ||
                    cloudEntry.type == 'session_lorebook_overlays') &&
                (await _read(
                      () => _manifestBuilder.isDeleted('chat', cloudEntry.id),
                    ) ||
                    (previousManifest.acceptedLocalHashes[cloudEntry.key] !=
                            '' &&
                        await _dependentStateMissing(cloudEntry))),
          )) {
        if (!cloudEntry.deleted) {
          await _repairMissingBinaryAssets(cloudEntry);
        }
        continue;
      }

      // Before first successful sync, local manifest timestamps are unreliable
      // (no previous entries → updatedAt defaults to now or entity timestamp).
      // Auto-prefer cloud for everything on first sync.
      if (isFirstSync && localEntry != null) {
        pullEntries.add(cloudEntry);
        continue;
      }

      // This aggregate is merge-only, but validating it reads the owning chat.
      // Defer the merge until the ordered pull phase has applied that chat.
      if (cloudEntry.type == 'reconciliation_state' ||
          cloudEntry.type == 'rewrite_job_history' ||
          (cloudEntry.type == 'memory_event_registry' && !cloudEntry.deleted)) {
        pullEntries.add(cloudEntry);
        continue;
      }

      if (await _entriesSemanticallyEqual(
        cloudEntry,
        localEntry,
        cloudManifest,
      )) {
        acceptedCloudEntries.add(cloudEntry);
        if (!cloudEntry.deleted) {
          await _repairMissingBinaryAssets(cloudEntry);
        }
        continue;
      }

      if (SyncConflictDetector.needsConflict(localEntry, cloudEntry)) {
        final localData = await _readLocalEntity(
          cloudEntry.type,
          cloudEntry.id,
        );
        String? characterName;
        if (cloudEntry.type == 'chat') {
          final charId = localData?['characterId'] as String?;
          if (charId != null) {
            final character = await _read(() => _characterRepo.getById(charId));
            characterName = character?.name;
          }
        }
        final name = SyncConflictDetector.getConflictName(
          cloudEntry.type,
          localData,
          null,
          cloudEntry.id,
          characterName: characterName,
        );
        conflicts.add(
          SyncConflict(
            key: cloudEntry.key,
            type: cloudEntry.type,
            id: cloudEntry.id,
            localEntry: localEntry!,
            cloudEntry: cloudEntry,
            name: name,
          ),
        );
        continue;
      }

      pullEntries.add(cloudEntry);
    }

    for (final c in conflicts) {
      _checkCurrent();
      onConflict(c);
    }

    if (pullEntries.isNotEmpty) {
      await _applyPullEntries(
        pullEntries,
        localManifest,
        cloudManifest,
        onProgress,
        acceptedCloudEntries: acceptedCloudEntries,
      );
    } else if (conflicts.isEmpty) {
      onProgress(
        const SyncProgress(current: 0, total: 0, message: 'Nothing to pull'),
      );
      await _finalizePull(
        localManifest,
        cloudManifest,
        acceptedCloudEntries: acceptedCloudEntries,
        onPhase: (message) => onProgress(
          SyncProgress(current: 0, total: 0, message: message),
        ),
      );
    } else {
      await _saveCloudManifestForPendingPull(cloudManifest);
    }
  }

  Future<void> applyPendingPull({
    required void Function(SyncProgress) onProgress,
    List<String>? resolvedAsCloud,
    bool pushLocalChanges = false,
  }) async {
    _checkCurrent();
    onProgress = _guardProgress(onProgress);
    final cloudManifest =
        await _loadCloudManifestForPendingPull() ??
        await _downloadCloudManifest();
    if (cloudManifest == null) return;
    final previousManifest = await _read(_manifestBuilder.readLocalManifest);
    final localManifest = await _unorderedBridge.bridge(
      await _bridgeCharacterHashes(
        await _read(
          () =>
              _manifestBuilder.buildLocalManifest(cloudManifest: cloudManifest),
        ),
        cloudManifest,
      ),
      cloudManifest,
    );

    final pullEntries = <SyncManifestEntry>[];
    final acceptedCloudEntries = <SyncManifestEntry>[];
    final locallyRejectedRegistryTombstones = <SyncManifestEntry>[];

    for (final cloudEntry in cloudManifest.entries.values) {
      if (cloudEntry.type == 'rewrite_job_history') {
        if (_rewriteJobHistoryStore == null || cloudEntry.deleted) continue;
        final chatEntry =
            cloudManifest.entries[entryKey('chat', cloudEntry.id)];
        if (chatEntry == null || chatEntry.deleted) {
          continue;
        }
      } else if (cloudEntry.type == 'memory_event_registry') {
        if (_memoryEventRegistryStore == null) continue;
        if (!cloudEntry.deleted) {
          final chatEntry =
              cloudManifest.entries[entryKey('chat', cloudEntry.id)];
          if (chatEntry == null || chatEntry.deleted) continue;
        }
      }
      final localEntry = localManifest.entries[cloudEntry.key];
      final previouslyAccepted = previousManifest.entries[cloudEntry.key];
      final ambiguousRegistryDeletion =
          cloudEntry.type == 'memory_event_registry' &&
          cloudEntry.deleted &&
          localEntry != null &&
          !localEntry.deleted &&
          (previouslyAccepted == null ||
              (!previouslyAccepted.deleted &&
                  previouslyAccepted.hash != localEntry.hash));
      if (ambiguousRegistryDeletion) {
        if (resolvedAsCloud != null &&
            resolvedAsCloud.contains(cloudEntry.key)) {
          pullEntries.add(cloudEntry);
        } else {
          locallyRejectedRegistryTombstones.add(cloudEntry);
        }
        continue;
      }
      if (localManifest.trackerSnapshotRestoreHashes.containsKey(
        cloudEntry.key,
      )) {
        if (await _canRestoreTrackerSnapshots(
          cloudEntry,
          localManifest,
          previousManifest,
          cloudManifest,
        )) {
          pullEntries.add(cloudEntry);
        }
        continue;
      }
      if (!previousManifest.needsReconciliationRestore(cloudEntry.key) &&
          _isAlreadyCurrentOrAccepted(
            cloudEntry,
            localEntry,
            previouslyAccepted,
            ignorePreviouslyAccepted:
                (cloudEntry.type == 'reconciliation_state' ||
                    cloudEntry.type == 'session_lorebook_overlays') &&
                (await _read(
                      () => _manifestBuilder.isDeleted('chat', cloudEntry.id),
                    ) ||
                    (previousManifest.acceptedLocalHashes[cloudEntry.key] !=
                            '' &&
                        await _dependentStateMissing(cloudEntry))),
          )) {
        if (!cloudEntry.deleted) {
          await _repairMissingBinaryAssets(cloudEntry);
        }
        continue;
      }
      if (cloudEntry.type == 'reconciliation_state' ||
          cloudEntry.type == 'rewrite_job_history' ||
          (cloudEntry.type == 'memory_event_registry' && !cloudEntry.deleted)) {
        pullEntries.add(cloudEntry);
        continue;
      }
      if (await _entriesSemanticallyEqual(
        cloudEntry,
        localEntry,
        cloudManifest,
      )) {
        acceptedCloudEntries.add(cloudEntry);
        if (!cloudEntry.deleted) {
          await _repairMissingBinaryAssets(cloudEntry);
        }
        continue;
      }
      if (SyncConflictDetector.needsConflict(localEntry, cloudEntry)) {
        if (resolvedAsCloud != null &&
            resolvedAsCloud.contains(cloudEntry.key)) {
          pullEntries.add(cloudEntry);
        }
        continue;
      }
      pullEntries.add(cloudEntry);
    }
    final baselineOverrides = {
      for (final tombstone in locallyRejectedRegistryTombstones)
        tombstone.key: tombstone,
    };

    if (pullEntries.isNotEmpty) {
      await _applyPullEntries(
        pullEntries,
        localManifest,
        cloudManifest,
        onProgress,
        acceptedCloudEntries: acceptedCloudEntries,
        baselineOverrides: baselineOverrides,
      );
    } else {
      onProgress(
        const SyncProgress(current: 0, total: 0, message: 'Nothing to pull'),
      );
      await _finalizePull(
        localManifest,
        cloudManifest,
        acceptedCloudEntries: acceptedCloudEntries,
        baselineOverrides: baselineOverrides,
        onPhase: (message) => onProgress(
          SyncProgress(current: 0, total: 0, message: message),
        ),
      );
    }

    // A local conflict winner must become cloud truth immediately. In
    // particular, this preserves additive local entities (such as Loom
    // presets) absent from an older cloud manifest.
    if (pushLocalChanges) {
      await pushEntities(onProgress: onProgress);
    }

    await _clearPendingPullManifest();
  }

  Future<void> _applyPullEntries(
    List<SyncManifestEntry> pullEntries,
    SyncManifest localManifest,
    SyncManifest cloudManifest,
    void Function(SyncProgress) onProgress, {
    List<SyncManifestEntry> acceptedCloudEntries = const [],
    Map<String, SyncManifestEntry> baselineOverrides = const {},
  }) => SavedPreferencesWrites.run(
    [
      if (pullEntries.any((e) => e.type == 'local_storage')) ...[
        SyncSerialization.pipelineSettingsKey,
        SyncSerialization.activeStudioPresetKey,
        SyncSerialization.globalRegexScriptsKey,
        SyncSerialization.studioRegexScriptsKey,
      ],
    ],
    () async {
      final appliedEntries = <SyncManifestEntry>[];
      final consolidationChanges = <String, Set<String>>{};
      var processed = 0;
      final primaryEntries = pullEntries
          .where(
            (entry) =>
                entry.type != 'session_lorebook_overlays' &&
                entry.type != 'reconciliation_state' &&
                entry.type != 'rewrite_job_history' &&
                entry.type != 'memory_event_registry' &&
                !localManifest.trackerSnapshotRestoreHashes.containsKey(
                  entry.key,
                ),
          )
          .toList(growable: false);
      final snapshotRestoreEntries = pullEntries
          .where(
            (entry) => localManifest.trackerSnapshotRestoreHashes.containsKey(
              entry.key,
            ),
          )
          .toList(growable: false);
      final overlayEntries = pullEntries
          .where((entry) => entry.type == 'session_lorebook_overlays')
          .toList(growable: false);
      final reconciliationEntries = pullEntries
          .where((entry) => entry.type == 'reconciliation_state')
          .toList(growable: false);
      final rewriteEntries = pullEntries
          .where((entry) => entry.type == 'rewrite_job_history')
          .toList(growable: false);
      final registryEntries = pullEntries
          .where((entry) => entry.type == 'memory_event_registry')
          .toList(growable: false);

      Future<List<Object>> applyEntries(List<SyncManifestEntry> entries) async {
        final tasks = <Future<void> Function()>[];
        for (final entry in entries) {
          tasks.add(() async {
            _checkCurrent();
            onProgress(
              SyncProgress(
                current: processed,
                total: pullEntries.length,
                message: 'Pulling ${entry.type}:${entry.id}',
              ),
            );
            if (localManifest.trackerSnapshotRestoreHashes.containsKey(
              entry.key,
            )) {
              await _restoreTrackerSnapshots(
                entry,
                localManifest,
                cloudManifest,
              );
              appliedEntries.add(entry);
            } else if (entry.type == 'rewrite_job_history' && !entry.deleted) {
              final cloudData = await SyncSerialization.readRequiredCloudEntity(
                _adapter,
                entry,
              );
              _verifyRewriteHistoryHash(entry, cloudData);
              late Map<String, dynamic> merged;
              await _commit(() async {
                merged = await _rewriteJobHistoryStore!.mergeBySessionId(
                  entry.id,
                  cloudData,
                );
              });
              // Only accept the cloud hash when it covers the entire local
              // union; otherwise the next push must publish local-only jobs.
              if (SyncSerialization.computeSyncHash(merged) == entry.hash) {
                appliedEntries.add(entry);
              }
            } else if (entry.type == 'rewrite_job_history') {
              // Only deleting the owning chat removes immutable job history.
              // A standalone cloud tombstone must not erase local records.
            } else if (entry.type == 'memory_event_registry' &&
                !entry.deleted) {
              final cloudData = await SyncSerialization.readRequiredCloudEntity(
                _adapter,
                entry,
              );
              _verifyMergePayloadHash(entry, cloudData);
              late Map<String, dynamic> merged;
              await _commit(() async {
                merged = await _memoryEventRegistryStore!.mergeBySessionId(
                  entry.id,
                  cloudData,
                );
              });
              if (SyncSerialization.computeSyncHash(merged) == entry.hash) {
                appliedEntries.add(entry);
              }
            } else if (entry.type == 'memory_event_registry') {
              await _commit(
                () => _memoryEventRegistryStore!.deleteBySessionId(entry.id),
              );
              final remaining = await _read(
                () => _memoryEventRegistryStore!.getBySessionId(entry.id),
              );
              if (remaining != null) {
                throw StateError(
                  'Memory event registry tombstone was not applied: ${entry.id}',
                );
              }
              appliedEntries.add(entry);
            } else {
              await _pullEntry(
                entry,
                onProgress: (message) {
                  _checkCurrent();
                  onProgress(
                    SyncProgress(
                      current: processed,
                      total: pullEntries.length,
                      message: message,
                    ),
                  );
                },
              );
              _checkCurrent();
              appliedEntries.add(entry);
            }
            if (entry.type == 'chat' ||
                entry.type == 'memory_book' ||
                entry.type == 'memory_event_registry') {
              consolidationChanges
                  .putIfAbsent(entry.id, () => <String>{})
                  .add(entry.type);
            }
            _checkCurrent();
            processed++;
            onProgress(
              SyncProgress(
                current: processed,
                total: pullEntries.length,
                message: 'Pulled ${entry.key}',
              ),
            );
          });
        }
        if (tasks.isEmpty) return const [];
        final result = await _queue.enqueueAll(
          tasks,
          concurrency: 3,
          delayMs: _operationDelayMs,
        );
        return result.errors;
      }

      onProgress(
        SyncProgress(
          current: 0,
          total: pullEntries.length,
          message: 'Pulling ${pullEntries.length} items...',
        ),
      );

      // Both dependent aggregates validate against chats/base lorebooks. Apply
      // primary entities first, current lore projections second, and immutable
      // reconciliation provenance last.
      final primaryErrors = await applyEntries(primaryEntries);
      _checkCurrent();
      if (primaryErrors.isNotEmpty) {
        throw SyncQueueAggregateError(primaryErrors);
      }
      // Restore only after any owning chat import has completed, but before the
      // session consistency pass and the dependent history imports.
      final snapshotErrors = await applyEntries(snapshotRestoreEntries);
      _checkCurrent();
      if (snapshotErrors.isNotEmpty) {
        throw SyncQueueAggregateError(snapshotErrors);
      }
      final touchedSessionIds = [...primaryEntries, ...snapshotRestoreEntries]
          .where(
            (entry) =>
                entry.type == 'chat' ||
                entry.type == 'tracker_snapshot' ||
                entry.type == 'tracker_value',
          )
          .map((entry) => entry.id)
          .toSet();
      final reconcile = _reconcilePulledSessions;
      if (reconcile != null) {
        // Each callback owns ONE atomic session transaction. A started session
        // may settle; its completion cannot admit the next session transaction.
        for (final sessionId in touchedSessionIds) {
          await _commit(() => reconcile({sessionId}));
        }
      }

      final taskErrors = <Object>[
        ...await applyEntries(overlayEntries),
        ...await applyEntries(reconciliationEntries),
        ...await applyEntries(rewriteEntries),
        ...await applyEntries(registryEntries),
      ];

      final reconcileMemoryJobs = _reconcileMemoryConsolidationJobs;
      if (reconcileMemoryJobs != null && consolidationChanges.isNotEmpty) {
        await _commit(() => reconcileMemoryJobs(consolidationChanges));
      }

      await _finalizePull(
        localManifest,
        cloudManifest,
        acceptedCloudEntries: [...acceptedCloudEntries, ...appliedEntries],
        baselineOverrides: baselineOverrides,
        onPhase: (message) => onProgress(
          SyncProgress(
            current: processed,
            total: pullEntries.length,
            message: message,
          ),
        ),
      );

      if (taskErrors.isNotEmpty) {
        throw SyncQueueAggregateError(taskErrors);
      }
    },
  );

  Future<void> _finalizePull(
    SyncManifest localManifest,
    SyncManifest cloudManifest, {
    List<SyncManifestEntry> acceptedCloudEntries = const [],
    Map<String, SyncManifestEntry> baselineOverrides = const {},
    void Function(String)? onPhase,
  }) async {
    _checkCurrent();
    onPhase?.call('Rebuilding local sync manifest...');
    final rebuilt = await _read(
      () => _manifestBuilder.buildLocalManifest(
        cloudManifest: cloudManifest,
        applyAcceptedHashes: false,
      ),
    );
    onPhase?.call('Verifying sync anchors...');
    await _unorderedBridge.verifyAnchors(localManifest);
    final entries = Map<String, SyncManifestEntry>.from(rebuilt.entries);
    final acceptedLocalHashes = <String, String>{};
    final trackerSnapshotRestoreHashes = Map<String, String>.from(
      rebuilt.trackerSnapshotRestoreHashes,
    );

    for (final accepted in localManifest.acceptedLocalHashes.entries) {
      final rebuiltEntry = rebuilt.entries[accepted.key];
      final baselineEntry = localManifest.entries[accepted.key];
      if (baselineEntry == null) continue;
      final explicitlyAcceptedEmpty =
          accepted.value.isEmpty &&
          (baselineEntry.type == 'reconciliation_state' ||
              baselineEntry.type == 'session_lorebook_overlays');
      if ((explicitlyAcceptedEmpty &&
              await _read(
                () => _manifestBuilder.isDeleted('chat', baselineEntry.id),
              )) ||
          (rebuiltEntry == null
              ? !explicitlyAcceptedEmpty
              : rebuiltEntry.hash != accepted.value)) {
        continue;
      }
      entries[accepted.key] = baselineEntry;
      acceptedLocalHashes[accepted.key] = accepted.value;
    }
    for (final entry in acceptedCloudEntries) {
      trackerSnapshotRestoreHashes.remove(entry.key);
      final rebuiltEntry = rebuilt.entries[entry.key];
      entries[entry.key] = entry;
      if (rebuiltEntry != null && rebuiltEntry.hash == entry.hash) {
        acceptedLocalHashes.remove(entry.key);
      } else if (rebuiltEntry != null ||
          entry.type == 'reconciliation_state' ||
          entry.type == 'session_lorebook_overlays') {
        // An empty normalized result has no local row to hash. Record that
        // explicitly so a later deletion can be distinguished from a state
        // that was accepted but intentionally normalized to nothing.
        acceptedLocalHashes[entry.key] = rebuiltEntry?.hash ?? '';
      }
    }
    for (final override in baselineOverrides.entries) {
      // An explicitly retained local registry has observed and rejected the
      // cloud tombstone. Persist that authorization in the final manifest's
      // single write so an interrupted retry cannot reinterpret it as stale.
      entries[override.key] = override.value;
      acceptedLocalHashes.remove(override.key);
      trackerSnapshotRestoreHashes.remove(override.key);
    }
    onPhase?.call('Saving local sync manifest...');
    await _commit(
      () => _manifestBuilder.writeLocalManifest(
        rebuilt.copyWith(
          version: SyncManifest.currentVersion,
          createdAt: cloudManifest.createdAt != 0
              ? cloudManifest.createdAt
              : rebuilt.createdAt,
          lastSync: DateTime.now().millisecondsSinceEpoch,
          entries: entries,
          acceptedLocalHashes: acceptedLocalHashes,
          trackerSnapshotRestoreHashes: trackerSnapshotRestoreHashes,
        ),
      ),
    );
    await _commit(_manifestBuilder.clearDeleted);
  }

  Future<bool> _canRestoreTrackerSnapshots(
    SyncManifestEntry snapshot,
    SyncManifest local,
    SyncManifest previous,
    SyncManifest cloud,
  ) async {
    if (snapshot.type != 'tracker_snapshot' || snapshot.deleted) return false;
    final chatKey = entryKey('chat', snapshot.id);
    final localChat = local.entries[chatKey];
    final cloudChat = cloud.entries[chatKey];
    if (localChat == null ||
        localChat.deleted ||
        cloudChat == null ||
        cloudChat.deleted ||
        await _read(() => _manifestBuilder.isDeleted('chat', snapshot.id))) {
      return false;
    }
    if (localChat.hash == cloudChat.hash) return true;
    // A cloud-only chat advance can be applied first. Never use the migration
    // to overwrite snapshots alongside authored local-only/conflicting edits.
    return previous.entries[chatKey]?.deleted == false &&
        localChat.hash == previous.entries[chatKey]?.hash &&
        !SyncConflictDetector.needsConflict(localChat, cloudChat);
  }

  Future<void> _restoreTrackerSnapshots(
    SyncManifestEntry entry,
    SyncManifest local,
    SyncManifest cloud,
  ) async {
    final queueActive = _queue.captureActiveGuard();
    void checkActive() {
      _checkCurrent();
      queueActive();
    }

    final data = await SyncSerialization.readRequiredCloudEntity(
      _adapter,
      entry,
    );
    final items = data['items'];
    if (data['__trackerSnapshots'] != true ||
        items is! List ||
        items.any((item) => item is! Map<String, dynamic>) ||
        SyncSerialization.computeSyncHash(data) != entry.hash) {
      throw const FormatException('Invalid tracker snapshot restore payload');
    }
    // Decode every row before replacement: a malformed later row must not
    // delete the accepted local history before its import fails.
    final decoded = SyncTrackerSnapshotDecoder.decode(
      entry.id,
      items.cast<Map<String, dynamic>>(),
    );
    final chatKey = entryKey('chat', entry.id);
    final expectedChat = await _read(() => _chatRepo.getById(entry.id));
    final metadata = await _read(_chatRepo.getAllSessionMetadata);
    final chats = metadata.where((chat) => chat.sessionId == entry.id);
    final currentChatHash = chats.isEmpty
        ? null
        : SyncSerialization.computeChatMetadataHash(chats.first);
    final initialChatHash =
        local.acceptedLocalHashes[chatKey] ?? local.entries[chatKey]?.hash;
    final current = await _readLocalEntity(entry.type, entry.id);
    if (await _read(() => _manifestBuilder.isDeleted('chat', entry.id)) ||
        await _read(() => _manifestBuilder.isDeleted(entry.type, entry.id)) ||
        expectedChat == null ||
        currentChatHash == null ||
        (currentChatHash != initialChatHash &&
            currentChatHash != cloud.entries[chatKey]?.hash) ||
        current == null ||
        SyncSerialization.computeSyncHash(current) !=
            local.trackerSnapshotRestoreHashes[entry.key]) {
      throw StateError(
        'Session changed during tracker snapshot restore; retry',
      );
    }
    if (!chatSessionContentEquals(
      await _read(() => _chatRepo.getById(entry.id)),
      expectedChat,
    )) {
      throw StateError('Chat changed during tracker snapshot restore; retry');
    }
    checkActive();
    final store = _trackerSnapshotStore;
    if (store is SyncAtomicTrackerSnapshotStore) {
      await _commit(
        () => store.replaceBySessionId(
          entry.id,
          decoded.snapshots,
          expectedSnapshots: (current['items'] as List)
              .cast<Map<String, dynamic>>()
              .map(TrackerSnapshot.fromJson)
              .toList(),
          expectedChat: expectedChat,
          checkCurrent: checkActive,
        ),
      );
    } else {
      await _applyCloudTrackerSnapshots(entry.id, data);
    }
  }

  bool _isAlreadyCurrentOrAccepted(
    SyncManifestEntry cloudEntry,
    SyncManifestEntry? localEntry,
    SyncManifestEntry? previouslyAccepted, {
    bool ignorePreviouslyAccepted = false,
  }) {
    if (cloudEntry.hash == localEntry?.hash &&
        cloudEntry.deleted == localEntry?.deleted) {
      return true;
    }
    return !ignorePreviouslyAccepted &&
        (cloudEntry.type == 'reconciliation_state' ||
            cloudEntry.type == 'session_lorebook_overlays') &&
        cloudEntry.hash == previouslyAccepted?.hash &&
        cloudEntry.deleted == previouslyAccepted?.deleted;
  }

  Future<bool> _dependentStateMissing(SyncManifestEntry entry) async {
    switch (entry.type) {
      case 'reconciliation_state':
        return !await _hasReconciliationState(entry.id);
      case 'session_lorebook_overlays':
        return await _read(
              () async =>
                  _sessionLorebookOverlayStore?.getBySessionId(entry.id),
            ) ==
            null;
      default:
        return false;
    }
  }

  Future<SyncManifest?> _downloadCloudManifest() async {
    try {
      final raw = await _adapter.download(cloudPath('manifest', 'manifest'));
      return SyncManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      _checkCurrent();
      return null;
    }
  }

  static const _pendingManifestKey = 'gz_sync_pending_pull_manifest';

  Future<void> _saveCloudManifestForPendingPull(SyncManifest manifest) async {
    final prefs = await _read(SharedPreferences.getInstance);
    await _commit(() async {
      await prefs.setString(_pendingManifestKey, jsonEncode(manifest.toJson()));
    });
  }

  Future<SyncManifest?> _loadCloudManifestForPendingPull() async {
    final prefs = await _read(SharedPreferences.getInstance);
    final raw = prefs.getString(_pendingManifestKey);
    if (raw == null) return null;
    try {
      return SyncManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return null;
    }
  }

  Future<void> _clearPendingPullManifest() async {
    final prefs = await _read(SharedPreferences.getInstance);
    await _commit(() async {
      await prefs.remove(_pendingManifestKey);
    });
  }

  Future<void> resolveConflict(SyncConflict conflict, String choice) async {
    final deferCloudApply =
        conflict.type == 'session_lorebook_overlays' && choice == 'cloud';
    if (choice == 'cloud' && !deferCloudApply) {
      await _pullEntry(conflict.cloudEntry);
    }

    final rebuiltManifest = await _read(
      () => _manifestBuilder.buildLocalManifest(),
    );
    final updatedEntries = Map<String, SyncManifestEntry>.from(
      rebuiltManifest.entries,
    );
    final rebuiltEntry = updatedEntries[conflict.key];

    if (choice == 'cloud' && !deferCloudApply) {
      // Align manifest with cloud so the same conflict does not reappear.
      updatedEntries[conflict.key] = conflict.cloudEntry;
    } else if (choice == 'local' && rebuiltEntry != null) {
      updatedEntries[conflict.key] = rebuiltEntry.copyWith(
        updatedAt: conflict.localEntry.updatedAt,
      );
    }

    final restoreHashes = Map<String, String>.from(
      rebuiltManifest.trackerSnapshotRestoreHashes,
    );
    if (choice == 'cloud' && !deferCloudApply) {
      restoreHashes.remove(conflict.key);
    }
    await _commit(
      () => _manifestBuilder.writeLocalManifest(
        rebuiltManifest.copyWith(
          entries: updatedEntries,
          trackerSnapshotRestoreHashes: restoreHashes,
        ),
      ),
    );
  }

  Future<bool> cloudHasData() async {
    try {
      final files = await _adapter.listFolder(cloudBase);
      return files.isNotEmpty;
    } catch (_) {
      return false;
    }
  }

  Future<void> wipeCloudData({
    required void Function(SyncProgress) onProgress,
  }) async {
    _checkCurrent();
    onProgress = _guardProgress(onProgress);
    onProgress(const SyncProgress(message: 'Deleting cloud data...'));
    try {
      await _adapter.deleteFolder(cloudBase);
    } catch (e) {
      final msg = e.toString();
      if (!msg.contains('not_found') && !msg.contains('path_not_found')) {
        rethrow;
      }
    }

    onProgress(const SyncProgress(message: 'Waiting for cloud to finalize...'));
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(_wipePollInterval);
      try {
        final files = await _adapter.listFolder(cloudBase);
        if (files.isEmpty) break;
      } catch (_) {
        break;
      }
    }

    onProgress(const SyncProgress(message: 'Recreating cloud folder...'));
    await _adapter.invalidateFolderCache();
    try {
      await _adapter.ensureFolder(cloudBase);
    } catch (_) {}
  }

  Future<void> _pushEntry(
    SyncManifestEntry entry, {
    void Function(String)? onProgress,
  }) async {
    final checkActive = _captureActiveGuard();
    checkActive();
    final reconciliation = _reconciliationStateStore;
    if (entry.type == 'reconciliation_state' &&
        reconciliation is SyncPagedReconciliationStateStore) {
      await ReconciliationPageTransport(
        checkActive: checkActive,
        onProgress: onProgress,
        pageCache: _reconciliationPageCache,
      ).upload(_adapter, entry, reconciliation);
      return;
    }
    final data = await _readLocalEntity(entry.type, entry.id);
    checkActive();
    if (data == null) return;
    await SyncPayloadTransport.upload(
      _adapter,
      entry,
      data,
      checkActive: checkActive,
    );
    checkActive();

    if (entry.type == 'character') {
      await _binarySyncer.pushCharacterAvatar(entry.id);
      await _binarySyncer.pushCharacterGallery(entry.id);
    }
    if (entry.type == 'persona') {
      await _binarySyncer.pushPersonaAvatar(entry.id);
    }
    // Presets travel as one singleton entry, so their covers are pushed as a
    // batch keyed by preset id rather than per manifest entry.
    if (entry.type == 'theme_presets') {
      await _binarySyncer.pushPresetImages();
    }
  }

  Future<void> _pullEntry(
    SyncManifestEntry entry, {
    void Function(String)? onProgress,
  }) async {
    _checkCurrent();
    if (entry.deleted) {
      await _deleteLocalEntity(entry.type, entry.id);
      return;
    }

    if (entry.type == 'reconciliation_state' &&
        _reconciliationStateStore is SyncPagedReconciliationStateStore) {
      await _mergeReconciliationEntry(entry, onProgress: onProgress);
      return;
    }

    // A missing or corrupt chat part must fail the task, not silently accept
    // its manifest hash while leaving the previous local conversation intact.
    final cloudData = entry.type == 'chat'
        ? await SyncSerialization.readRequiredCloudEntity(_adapter, entry)
        : await SyncSerialization.readCloudEntity(_adapter, entry);
    _checkCurrent();
    if (cloudData == null) return;

    await _applyCloudEntity(entry.type, entry.id, cloudData);
    _checkCurrent();

    if (entry.type == 'character') {
      await _binarySyncer.pullCharacterAvatar(entry.id);
      await _binarySyncer.pullCharacterGallery(entry.id);
    }
    if (entry.type == 'persona') {
      await _binarySyncer.pullPersonaAvatar(entry.id);
    }
    if (entry.type == 'theme_presets') {
      await _binarySyncer.pullPresetImages();
    }
    if (entry.type == 'chat') {
      final charId = cloudData['characterId'] as String?;
      if (charId != null) {
        final character = await _read(() => _characterRepo.getById(charId));
        if (character != null &&
            !_binarySyncer.localFileExists(character.avatarPath)) {
          await _binarySyncer.pullCharacterAvatar(charId);
        }
      }
    }
  }

  /// Entity hashes cover text and avatar size, not whether a previously synced
  /// binary is still present on this device. Retry missing assets even when the
  /// entity itself is already current, without reapplying its cloud JSON.
  Future<void> _repairMissingBinaryAssets(SyncManifestEntry entry) async {
    if (entry.type == 'character') {
      var character = await _read(() => _characterRepo.getById(entry.id));
      if (character == null) return;
      if (!_binarySyncer.localFileExists(character.avatarPath)) {
        await _binarySyncer.pullCharacterAvatar(entry.id);
      }
      if (character.gallery.any(
        (image) => !_binarySyncer.localFileExists(image.imagePath),
      )) {
        await _binarySyncer.pullCharacterGallery(entry.id);
      }
    } else if (entry.type == 'persona') {
      final persona = await _read(() => _personaRepo.getById(entry.id));
      if (persona != null &&
          !_binarySyncer.localFileExists(persona.avatarPath)) {
        await _binarySyncer.pullPersonaAvatar(entry.id);
      }
    } else if (entry.type == 'theme_presets') {
      await _binarySyncer.pullPresetImages();
    }
  }

  /// Restore lost bytes before push-first hashing.
  /// Only a previously accepted cloud version can supply the old avatar; a
  /// local change to the avatar path must remain a local change.
  Future<Set<String>> _repairPreviouslySyncedAvatars(
    SyncManifest cloudManifest,
    SyncManifest previousManifest,
  ) async {
    final missing = <String>{};
    for (final entry in cloudManifest.entries.values) {
      if (entry.deleted ||
          previousManifest.entries[entry.key]?.hash != entry.hash) {
        continue;
      }
      if (entry.type == 'character') {
        final character = await _read(() => _characterRepo.getById(entry.id));
        if (character?.avatarPath != null &&
            !_binarySyncer.localFileExists(character!.avatarPath)) {
          final repaired = await _binarySyncer.pullCharacterAvatar(entry.id);
          if (!repaired) {
            missing.add(entry.key);
          }
        }
      } else if (entry.type == 'persona') {
        final persona = await _read(() => _personaRepo.getById(entry.id));
        if (persona?.avatarPath != null &&
            !_binarySyncer.localFileExists(persona!.avatarPath)) {
          final repaired = await _binarySyncer.pullPersonaAvatar(entry.id);
          if (!repaired) {
            missing.add(entry.key);
          }
        }
      }
    }
    return missing;
  }

  bool _sameEntityWithoutImagePaths(
    Map<String, dynamic> local,
    Map<String, dynamic> cloud, {
    bool ignoreCharacterMetadata = false,
  }) {
    if (ignoreCharacterMetadata) {
      // Character.toJson retains GalleryEntry objects; cloud JSON has maps.
      // Never discard an unrecognized item and mistake a gallery edit for
      // equality. Keep the legacy persona comparison below unchanged.
      for (final data in [local, cloud]) {
        final gallery = data['gallery'];
        if (gallery != null &&
            (gallery is! List ||
                gallery.any(
                  (item) =>
                      item is! GalleryEntry && item is! Map<String, dynamic>,
                ))) {
          return false;
        }
      }
    }
    Map<String, dynamic> portable(Map<String, dynamic> data) {
      final result = Map<String, dynamic>.from(data)..remove('avatarPath');
      if (ignoreCharacterMetadata) {
        result.remove('currentSessionIndex');
        result.remove('tokenCount');
        result.remove('updatedAt');
      }
      final gallery = result['gallery'];
      if (gallery is List) {
        result['gallery'] = [
          for (final item in gallery)
            if (ignoreCharacterMetadata && item is GalleryEntry)
              item.toJson()..remove('imagePath')
            else if (item is Map<String, dynamic>)
              Map<String, dynamic>.from(item)..remove('imagePath'),
        ];
      }
      return result;
    }

    return jsonEncode(portable(local)) == jsonEncode(portable(cloud));
  }

  Future<bool> _entriesSemanticallyEqual(
    SyncManifestEntry cloudEntry,
    SyncManifestEntry? localEntry,
    SyncManifest cloudManifest,
  ) async {
    if (localEntry == null) return false;
    if (cloudEntry.hash == localEntry.hash) return true;

    switch (cloudEntry.type) {
      case 'reconciliation_state':
        final store = _reconciliationStateStore;
        if (store == null) return false;
        await _mergeReconciliationEntry(cloudEntry);
        // This aggregate intentionally normalizes or discards stale derived
        // provenance. A successful merge is therefore semantic equality even
        // when the resulting canonical payload no longer has the cloud hash.
        return true;
      case 'memory_book':
        final localMb = await _read(
          () => _memoryBookRepo.getBySessionId(cloudEntry.id),
        );
        if (localMb == null) return false;
        final cloudData = await SyncSerialization.readCloudEntity(
          _adapter,
          cloudEntry,
        );
        if (cloudData == null) return false;
        final localHash = SyncSerialization.computeMemoryBookHash(
          localMb.toJson(),
        );
        final cloudHash = SyncSerialization.computeMemoryBookHash(cloudData);
        final equal = localHash == cloudHash;
        return equal;
      case 'studio_config':
        final localConfig = await _read(
          () => _studioConfigStore.getById(cloudEntry.id),
        );
        if (localConfig == null) return false;
        final cloudData = await SyncSerialization.readCloudEntity(
          _adapter,
          cloudEntry,
        );
        if (cloudData == null) return false;
        return SyncSerialization.computeStudioConfigHash(cloudData) ==
            SyncSerialization.computeStudioConfigHash(localConfig.toJson());
      case 'api_presets':
        if (cloudManifest.apiKeysIncluded) return false;
        final localAll = await _read(_apiRepo.getAll);
        final cloudData = await SyncSerialization.readCloudEntity(
          _adapter,
          cloudEntry,
        );
        if (cloudData == null) return false;
        final List<Map<String, dynamic>> cloudItems;
        if (cloudData['__singleton'] == true) {
          cloudItems = (cloudData['items'] as List)
              .cast<Map<String, dynamic>>();
        } else if (cloudData.containsKey('items')) {
          cloudItems = (cloudData['items'] as List)
              .cast<Map<String, dynamic>>();
        } else {
          cloudItems = [cloudData];
        }
        final localHash = SyncSerialization.computeApiPresetsHash(
          localAll.map((a) => a.toJson()),
        );
        final cloudHash = SyncSerialization.computeApiPresetsHash(cloudItems);
        return localHash == cloudHash;
      default:
        return false;
    }
  }

  /// Prove equivalence against the payload, never infer it from hash drift.
  /// The cloud fingerprint also verifies avatar size before accepting the
  /// normalized card. Local-only markers remain anchored to that cloud entry.
  Future<SyncManifest> _bridgeCharacterHashes(
    SyncManifest localManifest,
    SyncManifest? cloudManifest,
  ) async {
    if (cloudManifest == null) return localManifest;
    final entries = Map<String, SyncManifestEntry>.from(localManifest.entries);
    final accepted = Map<String, String>.from(
      localManifest.acceptedLocalHashes,
    );
    for (final cloudEntry in cloudManifest.entries.values) {
      final localEntry = entries[cloudEntry.key];
      if (cloudEntry.type != 'character' ||
          cloudEntry.deleted ||
          localEntry == null ||
          localEntry.deleted ||
          cloudEntry.hash == localEntry.hash) {
        continue;
      }
      final character = await _read(
        () => _characterRepo.getById(cloudEntry.id),
      );
      if (character == null) continue;
      final localData = character.toJson();
      final cloudData = await SyncSerialization.readRequiredCloudEntity(
        _adapter,
        cloudEntry,
      );
      final size = SyncCharacterHash.avatarSize(localData, _imageStorage);
      // Reject malformed world values before model parsing can erase evidence.
      if (!SyncCharacterWorldEquivalence.isValid(localData) ||
          !SyncCharacterWorldEquivalence.isValid(cloudData)) {
        continue;
      }
      final cloudCard = Character.fromJson(cloudData).toJson();
      if (cloudData.keys.any((key) => !cloudCard.containsKey(key))) continue;
      final cloudHash = SyncCharacterHash.compute(cloudCard, size);
      final legacyCloudHash = SyncCharacterHash.compute(
        cloudCard,
        size,
        legacy: true,
      );
      final localHash = SyncCharacterHash.compute(localData, size);
      // Authenticate the existing fingerprint BEFORE comparing repository
      // materialization. Never publish the projected cloud fingerprint.
      if ((cloudEntry.hash == cloudHash ||
              cloudEntry.hash == legacyCloudHash) &&
          SyncCharacterHash.compute(
                SyncCharacterWorldEquivalence.project(localData)!,
                size,
              ) ==
              SyncCharacterHash.compute(
                SyncCharacterWorldEquivalence.project(cloudCard)!,
                size,
              )) {
        // Downloading introduced a checkpoint: do not accept an older local
        // snapshot if a card edit or binary replacement landed meanwhile.
        final current = await _read(
          () => _characterRepo.getById(cloudEntry.id),
        );
        if (current == null) continue;
        final currentData = current.toJson();
        if (SyncCharacterHash.compute(
              currentData,
              SyncCharacterHash.avatarSize(currentData, _imageStorage),
            ) !=
            localHash) {
          throw StateError('Character changed during sync hash upgrade; retry');
        }
        entries[cloudEntry.key] = cloudEntry;
        if (localHash != cloudEntry.hash) {
          accepted[cloudEntry.key] = localHash;
        } else {
          accepted.remove(cloudEntry.key);
        }
      }
    }
    return localManifest.copyWith(
      entries: entries,
      acceptedLocalHashes: accepted,
    );
  }

  Future<Map<String, dynamic>?> _readLocalEntity(String type, String id) async {
    _checkCurrent();
    try {
      switch (type) {
        case 'character':
          final c = await _read(() => _characterRepo.getById(id));
          if (c == null) return null;
          return c.toJson();
        case 'persona':
          final p = await _read(() => _personaRepo.getById(id));
          if (p == null) return null;
          return p.toJson();
        case 'chat':
          final s = await _read(() => _chatRepo.getById(id));
          if (s == null) return null;
          return stripImagesFromSession(s.toJson());
        case 'memory_book':
          final mb = await _read(() => _memoryBookRepo.getBySessionId(id));
          if (mb == null) return null;
          return mb.toJson();
        case 'lorebooks':
          final all = await _read(_lorebookRepo.getAll)
            ..sort((a, b) => a.id.compareTo(b.id));
          return {
            '__singleton': true,
            'items': all.map((l) => l.toJson()).toList(),
          };
        case 'api_presets':
          final all = await _read(_apiRepo.getAll);
          final items = all.map((a) {
            if (!_includeApiKeys) {
              return a.copyWith(apiKey: '', embeddingApiKey: '').toJson();
            }
            return a.toJson();
          }).toList();
          return {'__singleton': true, 'items': items};
        case 'theme_presets':
          final all = await _read(_presetRepo.getAll);
          return {
            '__singleton': true,
            'items': all.map((p) => p.toJson()).toList(),
          };
        case 'ui_themes':
          final all = await _read(_themePresetRepo.getAll);
          return {
            '__singleton': true,
            'items': all.map((t) => t.toJson()).toList(),
          };
        case 'extension_preset':
          final ep = await _read(() => _extensionPresetRepo.getById(id));
          if (ep == null) return null;
          return ep.toJson();
        case 'extensions_settings':
          final s = await _read(_extensionsSettingsStore.get);
          return {'__singleton': true, 'settings': s.toJson()};
        case 'local_storage':
          return _readLocalStorage();
        case 'info_block':
          // id == sessionId for info_block entries
          final blocks = await _read(() => _infoBlockStore.getBySessionId(id));
          if (blocks.isEmpty) return null;
          return SyncSerialization.infoBlocksPayload(blocks);
        case 'tracker_snapshot':
          final snaps = await _read(
            () => _trackerSnapshotStore.getBySessionId(id),
          );
          return {'__trackerSnapshots': true, 'items': snaps};
        case 'tracker_value':
          final trackers = await _read(
            () => _trackerValueStore.getBySessionId(id),
          );
          return {'__trackerValues': true, 'items': trackers};
        case 'studio_config':
          final config = await _read(() => _studioConfigStore.getById(id));
          return config?.toJson();
        case 'studio_preset':
          if (_studioPresetStore == null) return null;
          final preset = await _read(() => _studioPresetStore.getById(id));
          return preset?.toJson();
        case 'chat_summary':
          if (_chatSummaryStore == null) return null;
          return _read(() => _chatSummaryStore.getBySessionId(id));
        case 'character_folders':
          if (_characterFolderStore == null) return null;
          return _read(_characterFolderStore.getAll);
        case 'memory_graph':
          if (_memoryGraphStore == null) return null;
          return _read(() => _memoryGraphStore.getBySessionId(id));
        case 'memory_event_registry':
          if (_memoryEventRegistryStore == null) return null;
          return _read(() => _memoryEventRegistryStore.getBySessionId(id));
        case 'character_knowledge':
          if (_characterKnowledgeStore == null) return null;
          return _read(() => _characterKnowledgeStore.getBySessionId(id));
        case 'session_lorebook_overlays':
          if (_sessionLorebookOverlayStore == null) return null;
          return _read(() => _sessionLorebookOverlayStore.getBySessionId(id));
        case 'reconciliation_state':
          if (_reconciliationStateStore == null) return null;
          return _read(() => _reconciliationStateStore.getBySessionId(id));
        case 'rewrite_job_history':
          if (_rewriteJobHistoryStore == null) return null;
          return _read(() => _rewriteJobHistoryStore.getBySessionId(id));
        default:
          return null;
      }
    } catch (_) {
      _checkCurrent();
      return null;
    }
  }

  Future<void> _applyCloudEntity(
    String type,
    String id,
    Map<String, dynamic> data,
  ) async {
    _checkCurrent();
    try {
      switch (type) {
        case 'character':
          await _applyCloudCharacter(id, data);
          break;
        case 'persona':
          await _applyCloudPersona(id, data);
          break;
        case 'chat':
          await _commit(() => _chatRepo.put(ChatSession.fromJson(data)));
          break;
        case 'memory_book':
          await _commit(() => _memoryBookRepo.put(MemoryBook.fromJson(data)));
          break;
        case 'lorebooks':
          await _applyLorebooksWithEmbeddingCleanup(data);
          break;
        case 'api_presets':
          await _applyApiConfigs(data);
          break;
        case 'theme_presets':
          await _applySingleton<Preset>(
            data,
            Preset.fromJson,
            _presetRepo,
            idOf: (p) => p.id,
          );
          break;
        case 'ui_themes':
          await _applyUiThemes(data);
          break;
        case 'extension_preset':
          await _commit(
            () => _extensionPresetRepo.put(ExtensionPreset.fromJson(data)),
          );
          break;
        case 'extensions_settings':
          final settingsJson = data['settings'] as Map<String, dynamic>?;
          if (settingsJson != null) {
            await _commit(
              () => _extensionsSettingsStore.put(
                ExtensionsSettings.fromJson(settingsJson),
              ),
            );
          }
          break;
        case 'local_storage':
          await _applyLocalStorage(data);
          break;
        case 'info_block':
          await _applyCloudInfoBlocks(id, data);
          break;
        case 'tracker_snapshot':
          await _applyCloudTrackerSnapshots(id, data);
          break;
        case 'tracker_value':
          await _applyCloudTrackerValues(id, data);
          break;
        case 'studio_config':
          await _commit(
            () => _studioConfigStore.put(StudioAgentCodec.decodeConfig(data)),
          );
          break;
        case 'studio_preset':
          if (_studioPresetStore != null) {
            await _commit(
              () => _studioPresetStore.put(
                StudioPresetCodec.decodePreset(data).preset,
              ),
            );
          }
          break;
        case 'chat_summary':
          if (_chatSummaryStore != null) {
            await _commit(() => _chatSummaryStore.putRaw(data));
          }
          break;
        case 'character_folders':
          if (_characterFolderStore != null) {
            await _commit(() => _characterFolderStore.applyAll(data));
          }
          break;
        case 'memory_graph':
          if (_memoryGraphStore != null) {
            await _commit(() => _memoryGraphStore.applyBySessionId(id, data));
          }
          break;
        case 'memory_event_registry':
          if (_memoryEventRegistryStore != null) {
            await _commit(() async {
              await _memoryEventRegistryStore.mergeBySessionId(id, data);
            });
          }
          break;
        case 'character_knowledge':
          if (_characterKnowledgeStore != null) {
            await _commit(
              () => _characterKnowledgeStore.applyBySessionId(id, data),
            );
          }
          break;
        case 'session_lorebook_overlays':
          if (_sessionLorebookOverlayStore != null) {
            await _commit(
              () => _sessionLorebookOverlayStore.applyBySessionId(id, data),
            );
          }
          break;
        case 'reconciliation_state':
          if (_reconciliationStateStore != null) {
            await _commit(() async {
              await _reconciliationStateStore.mergeBySessionId(id, data);
            });
          }
          break;
        case 'rewrite_job_history':
          if (_rewriteJobHistoryStore == null) {
            throw StateError('Rewrite history sync store unavailable');
          }
          await _commit(() async {
            await _rewriteJobHistoryStore.mergeBySessionId(id, data);
          });
          break;
      }
    } catch (_) {
      _checkCurrent();
      if (type == 'chat' ||
          type == 'lorebooks' ||
          type == 'extension_preset' ||
          type == 'tracker_snapshot' ||
          type == 'tracker_value' ||
          type == 'memory_graph' ||
          type == 'memory_event_registry' ||
          type == 'character_knowledge' ||
          type == 'reconciliation_state' ||
          type == 'rewrite_job_history' ||
          type == 'session_lorebook_overlays') {
        rethrow;
      }
    }
  }

  Future<void> _applyCloudInfoBlocks(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__infoBlocks'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      return;
    }

    // Replace existing blocks for this session with the cloud version.
    await _commit(() => _infoBlockStore.deleteBySessionId(sessionId));
    for (final item in items) {
      await _commit(() => _infoBlockStore.insert(InfoBlock.fromJson(item)));
    }
  }

  Future<void> _applyCloudTrackerSnapshots(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__trackerSnapshots'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      return;
    }

    // Normalize legacy nested branch-owner labels without accepting a foreign
    // outer snapshot. Decode every row before any deletion in either adapter.
    final decoded = SyncTrackerSnapshotDecoder.decode(sessionId, items);
    final store = _trackerSnapshotStore;
    if (store is SyncAtomicTrackerSnapshotStore) {
      await _commit(
        () => store.replaceBySessionId(
          sessionId,
          decoded.snapshots,
          checkCurrent: _checkCurrent,
        ),
      );
      return;
    }
    await _commit(() => _trackerSnapshotStore.deleteBySessionId(sessionId));
    for (final item in decoded.items) {
      await _commit(() => _trackerSnapshotStore.insertRaw(item));
    }
  }

  Future<void> _applyCloudTrackerValues(
    String sessionId,
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__trackerValues'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      return;
    }

    await _commit(() => _trackerValueStore.deleteBySessionId(sessionId));
    for (final item in items) {
      await _commit(() => _trackerValueStore.insertRaw(item));
    }
  }

  /// Keep local paths, but restore cloud gallery metadata so the binary pull
  /// knows which gallery image IDs to fetch on a fresh installation.
  Future<void> _applyCloudCharacter(
    String id,
    Map<String, dynamic> data,
  ) async {
    final local = await _read(() => _characterRepo.getById(id));
    final json = Map<String, dynamic>.from(data);
    json.remove('avatarPath');
    if (data.containsKey('gallery')) {
      json['gallery'] = _cloudGallery(id, data).map((e) => e.toJson()).toList();
    } else {
      json['gallery'] = local?.gallery.map((e) => e.toJson()).toList() ?? [];
    }
    var character = Character.fromJson(json);
    if (local != null) {
      character = character.copyWith(
        avatarPath: local.avatarPath,
        gallery: data.containsKey('gallery')
            ? [
                for (final cloudImage in character.gallery)
                  local.gallery
                          .where(
                            (image) =>
                                image.id == cloudImage.id &&
                                _binarySyncer.localFileExists(image.imagePath),
                          )
                          .firstOrNull
                          ?.copyWith(
                            label: cloudImage.label,
                            createdAt: cloudImage.createdAt,
                          ) ??
                      cloudImage,
              ]
            : local.gallery,
      );
    }
    await _commit(() => _characterRepo.put(character));
  }

  List<GalleryEntry> _cloudGallery(String id, Map<String, dynamic> data) {
    final gallery = data['gallery'] as List?;
    if (gallery == null) return [];
    return [
      for (final raw in gallery.whereType<Map<String, dynamic>>())
        if (raw['id'] is String)
          GalleryEntry.fromJson({
            ...Map<String, dynamic>.from(raw),
            // The source path can be absolute on another device. Binary pulls
            // use the image id, so keep only a portable local placeholder.
            'imagePath':
                'gallery/$id/${raw['id']}.${_galleryExtension(raw['imagePath'])}',
          }),
    ];
  }

  String _galleryExtension(Object? path) {
    final extension = path is String ? path.split('.').last.toLowerCase() : '';
    return const {'png', 'jpg', 'webp', 'gif'}.contains(extension)
        ? extension
        : 'png';
  }

  Future<void> _applyCloudPersona(String id, Map<String, dynamic> data) async {
    final local = await _read(() => _personaRepo.getById(id));
    final json = Map<String, dynamic>.from(data);
    json.remove('avatarPath');
    var persona = Persona.fromJson(json);
    if (local != null) {
      persona = persona.copyWith(avatarPath: local.avatarPath);
    }
    await _commit(() => _personaRepo.put(persona));
  }

  Future<void> _applySingleton<T>(
    Map<String, dynamic> data,
    T Function(Map<String, dynamic>) fromJson,
    dynamic repo, {
    String Function(T)? idOf,
  }) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }

    final getAll = repo.getAll as Future<List<T>> Function();
    final put = repo.put as Future<void> Function(T);
    final delete = repo.delete as Future<void> Function(String);

    final cloudIds = <String>{};
    final parsed = <T>[];
    for (final item in items) {
      final entity = fromJson(item);
      parsed.add(entity);
      if (idOf != null) {
        cloudIds.add(idOf(entity));
      }
    }

    if (idOf != null) {
      final existing = await _read(getAll);
      for (final entity in existing) {
        final id = idOf(entity);
        if (!cloudIds.contains(id)) {
          await _commit(() => delete(id));
        }
      }
    }

    for (final entity in parsed) {
      await _commit(() => put(entity));
    }
  }

  /// Applies the lorebook singleton from cloud data, cleaning up embeddings for
  /// removed lorebooks and rebuilding the lorebookActivations SharedPreferences
  /// from the DB truth after the apply completes.
  Future<void> _applyLorebooksWithEmbeddingCleanup(
    Map<String, dynamic> data,
  ) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }

    final parsed = items.map(Lorebook.fromJson).toList();
    final cloudIds = {for (final lb in parsed) lb.id};

    // Delete lorebooks no longer in the cloud, including their embedding vectors.
    final existing = await _read(_lorebookRepo.getAll);
    for (final lb in existing) {
      if (!cloudIds.contains(lb.id)) {
        await _commit(() => _lorebookRepo.delete(lb.id));
        await _commit(() => _embeddingRepo.deleteBySourceId(lb.id));
      }
    }

    await _commit(() => _lorebookRepo.putAll(parsed));

    await _rebuildLorebookActivationsPrefs(parsed);
  }

  /// Reads all lorebooks from the DB and rewrites the `lorebookActivations`
  /// SharedPreferences key from their activationScope / activationTargetId
  /// fields. Called after a lorebook pull to eliminate stale prefs that would
  /// otherwise show phantom character/chat connections in the UI.
  Future<void> _rebuildLorebookActivationsPrefs(List<Lorebook> all) async {
    final charMap = <String, List<String>>{};
    final chatMap = <String, List<String>>{};
    for (final lb in all) {
      final targetId = lb.activationTargetId;
      if (targetId == null) continue;
      if (lb.activationScope == 'character') {
        charMap.putIfAbsent(targetId, () => []).add(lb.id);
      } else if (lb.activationScope == 'chat') {
        chatMap.putIfAbsent(targetId, () => []).add(lb.id);
      }
    }
    final activations = LorebookActivations(character: charMap, chat: chatMap);
    await _commit(() => _saveLorebookActivations(activations));
  }

  /// Applies cloud api_presets while preserving local API keys and embedding
  /// keys only when the destination route and protocol still match. Cloud
  /// payloads strip keys (empty string) when includeApiKeys=false; preserving
  /// local credentials across a changed endpoint/protocol would allow a
  /// keyless cloud update to reroute local secrets to a different host.
  Future<void> _applyApiConfigs(Map<String, dynamic> data) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }

    final existing = await _read(_apiRepo.getAll);
    final localById = {for (final a in existing) a.id: a};

    final cloudIds = <String>{};
    for (final item in items) {
      final cloudConfig = ApiConfig.fromJson(item);
      cloudIds.add(cloudConfig.id);

      final local = localById[cloudConfig.id];
      final llmRouteMatches =
          local != null &&
          BackupSecretRoutes.sameLlm(
            _routeRow(cloudConfig),
            _routeRow(local),
            BackupSecrets.isSecretField,
          );
      final embeddingRouteMatches =
          local != null &&
          _embeddingRouteMatches(cloudConfig, local, llmRouteMatches);

      final merged = cloudConfig.copyWith(
        apiKey: cloudConfig.apiKey.isNotEmpty
            ? cloudConfig.apiKey
            : (llmRouteMatches ? local.apiKey : ''),
        embeddingApiKey: cloudConfig.embeddingApiKey.isNotEmpty
            ? cloudConfig.embeddingApiKey
            : (embeddingRouteMatches ? local.embeddingApiKey : ''),
        endpoint: llmRouteMatches
            ? BackupSecretUrls.refill(
                cloudConfig.endpoint,
                local.endpoint,
                BackupSecrets.isSecretField,
              )
            : (local != null && cloudConfig.apiKey.isEmpty
                  ? BackupSecretUrls.strip(
                      cloudConfig.endpoint,
                      BackupSecrets.isSecretField,
                    )
                  : cloudConfig.endpoint),
        embeddingEndpoint:
            embeddingRouteMatches && !cloudConfig.embeddingUseSame
            ? BackupSecretUrls.refill(
                cloudConfig.embeddingEndpoint,
                local.embeddingEndpoint,
                BackupSecrets.isSecretField,
              )
            : (local != null && cloudConfig.embeddingApiKey.isEmpty
                  ? BackupSecretUrls.strip(
                      cloudConfig.embeddingEndpoint,
                      BackupSecrets.isSecretField,
                    )
                  : cloudConfig.embeddingEndpoint),
        extraRequestParameters: _mergeExtraRequestParameters(
          cloudConfig,
          local,
          llmRouteMatches: llmRouteMatches,
        ),
      );
      await _commit(() => _apiRepo.put(merged));
    }

    // Delete local configs that no longer exist in cloud.
    for (final local in existing) {
      if (!cloudIds.contains(local.id)) {
        await _commit(() => _apiRepo.delete(local.id));
      }
    }
  }

  static Map<String, dynamic> _routeRow(ApiConfig config) => {
    'endpoint': config.endpoint,
    'embedding_endpoint': config.embeddingEndpoint,
    'protocol': config.protocol,
    'model': config.model,
    'stream': config.stream,
    'use_responses_api': config.useResponsesApi,
    'mode': config.mode,
    'embedding_use_same': config.embeddingUseSame,
    'embedding_llm_preset_id': config.embeddingLlmPresetId,
  };

  static bool _embeddingRouteMatches(
    ApiConfig cloudConfig,
    ApiConfig local,
    bool llmRouteMatches,
  ) {
    if (cloudConfig.embeddingUseSame && local.embeddingUseSame) {
      return llmRouteMatches &&
          cloudConfig.embeddingLlmPresetId.trim() ==
              local.embeddingLlmPresetId.trim();
    }
    if (!cloudConfig.embeddingUseSame &&
        !local.embeddingUseSame &&
        cloudConfig.embeddingEndpoint.trim().isNotEmpty &&
        local.embeddingEndpoint.trim().isNotEmpty &&
        EndpointNormalizer.parse(cloudConfig.embeddingEndpoint).isValid &&
        EndpointNormalizer.parse(local.embeddingEndpoint).isValid) {
      return BackupSecretRoutes.same(
        EndpointNormalizer.persistedEmbeddingEndpoint(
          cloudConfig.embeddingEndpoint,
        ),
        EndpointNormalizer.persistedEmbeddingEndpoint(local.embeddingEndpoint),
        BackupSecrets.isSecretField,
      );
    }
    return false;
  }

  static List<ExtraRequestParameter> _mergeExtraRequestParameters(
    ApiConfig cloudConfig,
    ApiConfig? local, {
    required bool llmRouteMatches,
  }) {
    if (cloudConfig.extraRequestParameters.isEmpty) {
      return cloudConfig.extraRequestParameters;
    }
    final cloudRaw = cloudConfig.extraRequestParameters
        .map((p) => p.toJson())
        .toList(growable: false);
    final Object? transformed;
    if (llmRouteMatches && local != null) {
      final localRaw = local.extraRequestParameters
          .map((p) => p.toJson())
          .toList(growable: false);
      transformed = BackupSecretRuntime.refillParameters(
        cloudRaw,
        localRaw,
        BackupSecrets.isSecretField,
      );
    } else if (local != null && cloudConfig.apiKey.isEmpty) {
      transformed = BackupSecretRuntime.stripParameters(
        cloudRaw,
        BackupSecrets.isSecretField,
      );
    } else {
      return cloudConfig.extraRequestParameters;
    }
    if (transformed is! List) return cloudConfig.extraRequestParameters;
    final stripNested = !llmRouteMatches && cloudConfig.apiKey.isEmpty;
    return transformed
        .whereType<Map<dynamic, dynamic>>()
        .map((item) {
          final param = ExtraRequestParameter.fromJson(
            Map<String, dynamic>.from(item),
          );
          return stripNested
              ? param.copyWith(value: _stripNestedSecretJson(param.value))
              : param;
        })
        .toList(growable: false);
  }

  static String _stripNestedSecretJson(String raw) {
    final trimmed = raw.trimLeft();
    if (!trimmed.startsWith('{') && !trimmed.startsWith('[')) return raw;
    try {
      final decoded = jsonDecode(raw);
      return jsonEncode(_stripJsonNode(decoded));
    } on FormatException {
      return raw;
    }
  }

  static Object? _stripJsonNode(Object? node) {
    if (node is Map) {
      return {
        for (final entry in node.entries)
          entry.key:
              entry.key is String &&
                  BackupSecrets.isSecretField(entry.key as String)
              ? (entry.value is String ? '' : null)
              : _stripJsonNode(entry.value),
      };
    }
    if (node is List) {
      return node.map(_stripJsonNode).toList(growable: false);
    }
    return node;
  }

  Future<void> _applyUiThemes(Map<String, dynamic> data) async {
    final List<Map<String, dynamic>> items;
    if (data['__singleton'] == true) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else if (data.containsKey('items')) {
      items = (data['items'] as List).cast<Map<String, dynamic>>();
    } else {
      items = [data];
    }
    final presets = items.map((j) => themePresetFromStoredJson(j)).toList();
    await _commit(() => _themePresetRepo.putAll(presets));
  }

  Future<void> _deleteLocalEntity(String type, String id) async {
    _checkCurrent();
    try {
      switch (type) {
        case 'character':
          await _commit(() async {
            await _characterDeletionStore.deleteCharacters({id});
          });
          break;
        case 'persona':
          await _commit(() => _personaRepo.delete(id));
          break;
        case 'chat':
          await _commit(() async {
            await _sessionDeletionStore.deleteSession(id);
          });
          break;
        case 'memory_book':
          await _commit(() => _memoryBookRepo.deleteBySessionId(id));
          break;
        case 'lorebooks':
          final all = await _read(_lorebookRepo.getAll);
          for (final lb in all) {
            await _commit(() => _lorebookRepo.delete(lb.id));
            await _commit(() => _embeddingRepo.deleteBySourceId(lb.id));
          }
          break;
        case 'api_presets':
          final apis = await _read(_apiRepo.getAll);
          for (final a in apis) {
            await _commit(() => _apiRepo.delete(a.id));
          }
          break;
        case 'theme_presets':
          final presets = await _read(_presetRepo.getAll);
          for (final p in presets) {
            await _commit(() => _presetRepo.delete(p.id));
          }
          break;
        case 'ui_themes':
          await _commit(() => _themePresetRepo.putAll([]));
          break;
        case 'local_storage':
          await _deleteLocalStorage();
          break;
        case 'extension_preset':
          await _commit(() => _extensionPresetRepo.delete(id));
          break;
        case 'info_block':
          // id == sessionId for info_block entries
          await _commit(() => _infoBlockStore.deleteBySessionId(id));
          break;
        case 'tracker_snapshot':
          await _commit(() => _trackerSnapshotStore.deleteBySessionId(id));
          break;
        case 'tracker_value':
          await _commit(() => _trackerValueStore.deleteBySessionId(id));
          break;
        case 'studio_config':
          await _commit(() => _studioConfigStore.delete(id));
          break;
        case 'studio_preset':
          if (_studioPresetStore != null) {
            await _commit(() => _studioPresetStore.delete(id));
          }
          break;
        case 'chat_summary':
          if (_chatSummaryStore != null) {
            await _commit(() => _chatSummaryStore.deleteBySessionId(id));
          }
          break;
        case 'memory_graph':
          if (_memoryGraphStore != null) {
            await _commit(() => _memoryGraphStore.deleteBySessionId(id));
          }
          break;
        case 'memory_event_registry':
          if (_memoryEventRegistryStore != null) {
            await _commit(
              () => _memoryEventRegistryStore.deleteBySessionId(id),
            );
          }
          break;
        case 'character_knowledge':
          if (_characterKnowledgeStore != null) {
            await _commit(() => _characterKnowledgeStore.deleteBySessionId(id));
          }
          break;
        case 'session_lorebook_overlays':
          if (_sessionLorebookOverlayStore != null) {
            await _commit(
              () => _sessionLorebookOverlayStore.deleteBySessionId(id),
            );
          }
          break;
        case 'reconciliation_state':
          if (_reconciliationStateStore != null) {
            await _commit(
              () => _reconciliationStateStore.deleteBySessionId(id),
            );
          }
          break;
        // Rewrite history has no independent tombstones. The owning chat's
        // deletion cascade removes it; a stale aggregate must never erase it.
        case 'rewrite_job_history':
          break;
        // extensions_settings has no meaningful "delete" — it's always present.
      }
    } catch (_) {
      _checkCurrent();
    }
  }

  Future<void> _mergeCloudReconciliationState(
    SyncManifest? cloudManifest,
    SyncManifest previousManifest,
  ) async {
    final store = _reconciliationStateStore;
    if (store == null || cloudManifest == null) return;
    for (final entry in cloudManifest.entries.values) {
      if (entry.type != 'reconciliation_state' || entry.deleted) continue;
      final previouslyAccepted = previousManifest.entries[entry.key];
      if (!previousManifest.needsReconciliationRestore(entry.key) &&
          previouslyAccepted != null &&
          !previouslyAccepted.deleted &&
          previouslyAccepted.hash == entry.hash &&
          (await _hasReconciliationState(entry.id) ||
              previousManifest.acceptedLocalHashes[entry.key] == '') &&
          !await _read(() => _manifestBuilder.isDeleted('chat', entry.id))) {
        continue;
      }
      if (await _read(() => _manifestBuilder.isDeleted(entry.type, entry.id)) ||
          await _read(() => _manifestBuilder.isDeleted('chat', entry.id))) {
        continue;
      }
      if (await _read(() => _chatRepo.getById(entry.id)) == null) {
        final chatEntry = cloudManifest.entries[entryKey('chat', entry.id)];
        if (chatEntry == null || chatEntry.deleted) {
          throw StateError(
            'Reconciliation state has no owning cloud chat: ${entry.id}',
          );
        }
        final chatData = await SyncSerialization.readRequiredCloudEntity(
          _adapter,
          chatEntry,
        );
        await _commit(() => _chatRepo.put(ChatSession.fromJson(chatData)));
      }
      await _mergeReconciliationEntry(entry);
    }
  }

  Future<bool> _hasReconciliationState(String sessionId) async {
    final store = _reconciliationStateStore;
    if (store is SyncPagedReconciliationStateStore) {
      return _read(() => store.hasBySessionId(sessionId));
    }
    return await _read(() async => store?.getBySessionId(sessionId)) != null;
  }

  Future<void> _mergeReconciliationEntry(
    SyncManifestEntry entry, {
    void Function(String)? onProgress,
  }) async {
    final store = _reconciliationStateStore;
    if (store == null) return;
    if (store is SyncPagedReconciliationStateStore) {
      await ReconciliationPageTransport(
        checkActive: _captureActiveGuard(),
        onProgress: onProgress,
        pageCache: _reconciliationPageCache,
      ).withDownloadedSource(
        _adapter,
        entry,
        (source) => _commit(() async {
          await store.mergeFromSource(entry.id, source);
        }),
      );
    } else {
      final data = await SyncSerialization.readRequiredCloudEntity(
        _adapter,
        entry,
      );
      await _commit(() async {
        await store.mergeBySessionId(entry.id, data);
      });
    }
  }

  void _verifyRewriteHistoryHash(
    SyncManifestEntry entry,
    Map<String, dynamic> data,
  ) {
    if (SyncSerialization.computeSyncHash(data) != entry.hash) {
      throw StateError('Rewrite history cloud hash mismatch: ${entry.key}');
    }
  }

  void _verifyMergePayloadHash(
    SyncManifestEntry entry,
    Map<String, dynamic> data,
  ) {
    if (SyncSerialization.computeSyncHash(data) != entry.hash) {
      throw StateError('Merge-only cloud hash mismatch: ${entry.key}');
    }
  }

  Future<void> _mergeCloudRewriteJobHistory(SyncManifest? cloudManifest) async {
    final store = _rewriteJobHistoryStore;
    if (store == null || cloudManifest == null) return;
    final localSessions = (await _read(
      _chatRepo.getAllSessionMetadata,
    )).map((session) => session.sessionId).toSet();
    for (final entry in cloudManifest.entries.values) {
      if (entry.type != 'rewrite_job_history' || entry.deleted) continue;
      if (await _read(() => _manifestBuilder.isDeleted('chat', entry.id)))
        continue;
      final chatEntry = cloudManifest.entries[entryKey('chat', entry.id)];
      if (chatEntry == null || chatEntry.deleted) {
        continue;
      }
      // A push must not pull back a session that this device deliberately
      // deleted. The ordinary pull phase decides whether a cloud chat is
      // reintroduced; history only follows an already present local chat.
      if (!localSessions.contains(entry.id)) continue;
      final local = await _read(() => store.getBySessionId(entry.id));
      if (local != null &&
          SyncSerialization.computeSyncHash(local) == entry.hash) {
        continue;
      }
      final cloudData = await SyncSerialization.readRequiredCloudEntity(
        _adapter,
        entry,
      );
      _verifyRewriteHistoryHash(entry, cloudData);
      await _commit(() async {
        await store.mergeBySessionId(entry.id, cloudData);
      });
    }
  }

  Future<void> _mergeCloudMemoryEventRegistry(
    SyncManifest? cloudManifest,
    SyncManifest previousManifest,
  ) async {
    final store = _memoryEventRegistryStore;
    if (store == null || cloudManifest == null) return;
    final localSessions = (await _read(
      _chatRepo.getAllSessionMetadata,
    )).map((session) => session.sessionId).toSet();
    for (final entry in cloudManifest.entries.values) {
      if (entry.type != 'memory_event_registry') continue;
      if (entry.deleted) {
        final local = await _read(() => store.getBySessionId(entry.id));
        if (local == null) continue;
        final previous = previousManifest.entries[entry.key];
        if (previous?.deleted == true) {
          // Facts accepted after this device observed the tombstone start a new
          // generation and may intentionally replace it.
          continue;
        }
        final localHash = SyncSerialization.computeSyncHash(local);
        if (previous != null &&
            !previous.deleted &&
            previous.hash == localHash) {
          // This is an unchanged stale copy. Remove it before manifest creation
          // so the durable cloud tombstone cannot be overwritten on push-first.
          await _commit(() => store.deleteBySessionId(entry.id));
          continue;
        }
        // Local facts changed without first observing the remote clear. Neither
        // side can be discarded safely; the pull path must resolve the deletion.
        throw const SyncPullRequiredBeforePush(
          'Pull required before push: memory event registry was cleared remotely',
        );
      }
      if (!localSessions.contains(entry.id) ||
          await _read(() => _manifestBuilder.isDeleted('chat', entry.id)) ||
          await _read(
            () => _manifestBuilder.isDeleted('memory_event_registry', entry.id),
          )) {
        continue;
      }
      final chatEntry = cloudManifest.entries[entryKey('chat', entry.id)];
      if (chatEntry == null || chatEntry.deleted) continue;
      final local = await _read(() => store.getBySessionId(entry.id));
      if (local != null &&
          SyncSerialization.computeSyncHash(local) == entry.hash) {
        continue;
      }
      final cloudData = await SyncSerialization.readRequiredCloudEntity(
        _adapter,
        entry,
      );
      _verifyMergePayloadHash(entry, cloudData);
      await _commit(() async {
        await store.mergeBySessionId(entry.id, cloudData);
      });
    }
  }

  Future<Map<String, dynamic>?> _readLocalStorage() async {
    final prefs = await _read(SharedPreferences.getInstance);
    final pipelineSettings = prefs.getString(
      SyncSerialization.pipelineSettingsKey,
    );
    final activeStudioPresetId = prefs.getString(
      SyncSerialization.activeStudioPresetKey,
    );
    final globalRegexScripts = prefs.getString(
      SyncSerialization.globalRegexScriptsKey,
    );
    final studioRegexScripts = prefs.getString(
      SyncSerialization.studioRegexScriptsKey,
    );
    final appSettings = AppSettingsPreferences.encode(
      AppSettingsPreferences.read(prefs),
    );
    return SyncSerialization.localStoragePayload(
      pipelineSettings: pipelineSettings,
      activeStudioPresetId: activeStudioPresetId,
      globalRegexScripts: globalRegexScripts,
      studioRegexScripts: studioRegexScripts,
      appSettings: appSettings,
      chatLayout: SyncSerialization.readChatLayout(prefs),
    );
  }

  Future<void> _applyLocalStorage(
    Map<String, dynamic> data,
  ) => SavedPreferencesWrites.run(data.keys, () async {
    final original = await _read(TrackedSharedPreferences.getInstance);
    final prefs = _SyncWorkflowPreferences(original, _checkCurrent, _commit);
    final pipelineSettings = data[SyncSerialization.pipelineSettingsKey];
    if (pipelineSettings is String) {
      if (pipelineSettings.isEmpty) {
        await prefs.remove(SyncSerialization.pipelineSettingsKey);
      } else {
        await prefs.setString(
          SyncSerialization.pipelineSettingsKey,
          pipelineSettings,
        );
      }
    }
    final activeStudioPresetId = data[SyncSerialization.activeStudioPresetKey];
    if (activeStudioPresetId is String) {
      if (activeStudioPresetId.isEmpty) {
        await prefs.remove(SyncSerialization.activeStudioPresetKey);
      } else {
        await prefs.setString(
          SyncSerialization.activeStudioPresetKey,
          activeStudioPresetId,
        );
      }
    }
    await _applyLocalStorageString(
      prefs,
      data,
      SyncSerialization.globalRegexScriptsKey,
    );
    await _applyLocalStorageString(
      prefs,
      data,
      SyncSerialization.studioRegexScriptsKey,
    );
    final rawAppSettings = data[SyncSerialization.appSettingsKey];
    if (rawAppSettings is Map) {
      await AppSettingsPreferences.applyPartial(
        prefs,
        Map<String, dynamic>.from(rawAppSettings),
      );
    }
    final layout = data[SyncSerialization.chatLayoutKey];
    if (layout is Map<String, dynamic>) {
      await SyncSerialization.applyChatLayout(prefs, layout);
    }
  });

  Future<void> _applyLocalStorageString(
    SharedPreferences prefs,
    Map<String, dynamic> data,
    String key,
  ) => SavedPreferencesWrites.run([key], () async {
    _checkCurrent();
    final value = data[key];
    if (value is! String) return;
    if (value.isEmpty) {
      await prefs.remove(key);
    } else {
      await prefs.setString(key, value);
    }
  });

  Future<void> _deleteLocalStorage() => SavedPreferencesWrites.run(
    [
      SyncSerialization.pipelineSettingsKey,
      SyncSerialization.activeStudioPresetKey,
      SyncSerialization.globalRegexScriptsKey,
      SyncSerialization.studioRegexScriptsKey,
    ],
    () async {
      final original = await _read(TrackedSharedPreferences.getInstance);
      final prefs = _SyncWorkflowPreferences(original, _checkCurrent, _commit);
      await prefs.remove(SyncSerialization.pipelineSettingsKey);
      await prefs.remove(SyncSerialization.activeStudioPresetKey);
      await prefs.remove(SyncSerialization.globalRegexScriptsKey);
      await prefs.remove(SyncSerialization.studioRegexScriptsKey);
      await AppSettingsPreferences.removeAll(prefs);
      await SyncSerialization.applyChatLayout(prefs, const {});
    },
  );
}

/// Already acknowledged local callbacks are facts, not a rollback promise.
final class SyncWorkflowRetired implements CloudOAuthRetiredCommit {
  const SyncWorkflowRetired(this.committedLocalWrites);
  final int committedLocalWrites;
  @override
  String toString() =>
      'Cloud sync workflow retired ($committedLocalWrites local writes settled)';
}

/// Only the original sync preference callbacks, including multi-field helpers.
/// No private-key custody, whole-store operation, or replacement lookup exists.
final class _SyncWorkflowPreferences implements SharedPreferences {
  _SyncWorkflowPreferences(this._original, this._check, this._commit);
  final SharedPreferences _original;
  final void Function() _check;
  final Future<void> Function(Future<void> Function()) _commit;
  Future<bool> _write(String key, Future<bool> Function() action) async {
    if (!AppSettingsPreferences.keys.contains(key) &&
        !AppSettingsPreferences.legacyKeys.contains(key) &&
        !SyncSerialization.chatLayoutPrefKeys.contains(key) &&
        !const {
          SyncSerialization.pipelineSettingsKey,
          SyncSerialization.activeStudioPresetKey,
          SyncSerialization.globalRegexScriptsKey,
          SyncSerialization.studioRegexScriptsKey,
        }.contains(key)) {
      throw StateError('Unexpected cloud preference write');
    }
    await _commit(() async {
      _check();
      if (!await action())
        throw StateError('Cloud preference write not acknowledged');
    });
    return true;
  }

  @override
  Object? get(String key) {
    _check();
    return _original.get(key);
  }

  @override
  bool? getBool(String key) {
    _check();
    return _original.getBool(key);
  }

  @override
  int? getInt(String key) {
    _check();
    return _original.getInt(key);
  }

  @override
  double? getDouble(String key) {
    _check();
    return _original.getDouble(key);
  }

  @override
  String? getString(String key) {
    _check();
    return _original.getString(key);
  }

  @override
  List<String>? getStringList(String key) {
    _check();
    return _original.getStringList(key);
  }

  @override
  bool containsKey(String key) {
    _check();
    return _original.containsKey(key);
  }

  @override
  Set<String> getKeys() {
    _check();
    return _original.getKeys();
  }

  @override
  Future<bool> setBool(String key, bool value) =>
      _write(key, () => _original.setBool(key, value));
  @override
  Future<bool> setInt(String key, int value) =>
      _write(key, () => _original.setInt(key, value));
  @override
  Future<bool> setDouble(String key, double value) =>
      _write(key, () => _original.setDouble(key, value));
  @override
  Future<bool> setString(String key, String value) =>
      _write(key, () => _original.setString(key, value));
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _write(key, () => _original.setStringList(key, value));
  @override
  Future<bool> remove(String key) => _write(key, () => _original.remove(key));
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('Unsupported cloud preference operation');
}
