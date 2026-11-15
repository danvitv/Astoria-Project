import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import '../../settings/app_settings_provider.dart';
import 'sync_serialization.dart';
import 'sync_character_hash.dart';
import 'sync_engine.dart' show SyncWorkflowRetired;
import '../sync_models.dart';
import '../sync_repo_interfaces.dart';
import '../../../core/application/sync_reconciliation_source.dart';
import '../../../core/utils/time_helpers.dart';

class SyncManifestBuilder implements SyncManifestProvider {
  final SyncCharacterStore _characterRepo;
  final SyncChatStore _chatRepo;
  final SyncPersonaStore _personaRepo;
  final SyncPresetStore _presetRepo;
  final SyncApiConfigStore _apiRepo;
  final SyncMemoryBookStore _memoryBookRepo;
  final SyncLorebookStore _lorebookRepo;
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
  final SyncMemoryEventRegistryStore? _memoryEventRegistryStore;
  final SyncCharacterKnowledgeStore? _characterKnowledgeStore;
  final SyncSessionLorebookOverlayStore? _sessionLorebookOverlayStore;
  final SyncReconciliationStateStore? _reconciliationStateStore;
  final SyncRewriteJobHistoryStore? _rewriteJobHistoryStore;
  final SyncImageStore? _imageStore;
  final void Function()? _checkOriginal;
  int _acknowledgedWrites = 0;
  void _check() {
    try {
      _checkOriginal?.call();
    } catch (_) {
      throw SyncWorkflowRetired(_acknowledgedWrites);
    }
  }

  Future<T> _read<T>(Future<T> Function() action) async {
    _check();
    final value = await action();
    _check();
    return value;
  }

  Future<void> _write(Future<bool> Function() action) async {
    _check();
    if (!await action()) {
      throw StateError('Cloud manifest write not acknowledged');
    }
    _acknowledgedWrites++;
    _check();
  }

  static const _manifestKey = 'gz_sync_manifest_v2';
  static const _deviceIdKey = 'gz_sync_device_id';
  static const _deletedKey = 'gz_sync_deleted_entries';

  SyncManifestBuilder({
    required this._characterRepo,
    required this._chatRepo,
    required this._personaRepo,
    required this._presetRepo,
    required this._apiRepo,
    required this._memoryBookRepo,
    required this._lorebookRepo,
    required this._themePresetRepo,
    required this._extensionPresetRepo,
    required this._extensionsSettingsStore,
    required this._infoBlockStore,
    required this._trackerSnapshotStore,
    required this._trackerValueStore,
    required this._studioConfigStore,
    this._studioPresetStore,
    this._chatSummaryStore,
    this._characterFolderStore,
    this._memoryGraphStore,
    this._memoryEventRegistryStore,
    this._characterKnowledgeStore,
    this._sessionLorebookOverlayStore,
    this._reconciliationStateStore,
    this._rewriteJobHistoryStore,
    this._imageStore,
    void Function()? checkCurrent,
  }) : _checkOriginal = checkCurrent;

  @override
  Future<String> getDeviceId() async {
    final prefs = await _read(SharedPreferences.getInstance);
    var id = prefs.getString(_deviceIdKey);
    if (id == null) {
      id =
          '${DateTime.now().millisecondsSinceEpoch}_${Random().nextInt(999999)}';
      await _write(() => prefs.setString(_deviceIdKey, id!));
    }
    return id;
  }

  /// [cloudManifest] — when pulling, used to avoid bumping updatedAt to now for
  /// entities that only differ from a stale local manifest but match cloud.
  @override
  Future<SyncManifest> buildLocalManifest({
    SyncManifest? cloudManifest,
    bool applyAcceptedHashes = true,
  }) async {
    final deviceId = await getDeviceId();
    final now = DateTime.now().millisecondsSinceEpoch;
    final entries = <String, SyncManifestEntry>{};

    final previous = await readLocalManifest();
    final characterAcceptedHashes = <String, String>{};

    final characters = await _read(_characterRepo.getAll);
    for (final c in characters) {
      final json = c.toJson();
      final size = SyncCharacterHash.avatarSize(json, _imageStore);
      final hash = SyncCharacterHash.compute(json, size);
      final legacyHash = SyncCharacterHash.compute(json, size, legacy: true);
      final key = entryKey('character', c.id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      final acceptedHash = previous.acceptedLocalHashes[key];
      // Legacy Character.toJson() contains GalleryEntry objects, which the old
      // normalizer skipped. A nonempty gallery needs payload-level proof.
      final legacyBaseline = c.gallery.isNotEmpty
          ? null
          : cloudEntry != null &&
                !cloudEntry.deleted &&
                cloudEntry.hash == legacyHash
          ? cloudEntry
          : prevEntry != null &&
                !prevEntry.deleted &&
                (prevEntry.hash == legacyHash || acceptedHash == legacyHash)
          ? prevEntry
          : null;
      if (legacyBaseline != null) {
        updatedAt = legacyBaseline.updatedAt;
        if (applyAcceptedHashes) {
          entries[key] = legacyBaseline;
          characterAcceptedHashes[key] = hash;
          continue;
        }
      } else if (hash != prevEntry?.hash &&
          hash != cloudEntry?.hash &&
          hash != acceptedHash) {
        updatedAt = max(
          updatedAt,
          SyncCharacterHash.timestampMillis(c.updatedAt),
        );
      }

      entries[key] = SyncManifestEntry(
        type: 'character',
        id: c.id,
        path: cloudPath('character', c.id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final personas = await _read(_personaRepo.getAll);
    for (final p in personas) {
      final json = p.toJson();
      final hash = SyncSerialization.computeSyncHash(_normalizeForHash(json));
      final key = entryKey('persona', p.id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'persona',
        id: p.id,
        path: cloudPath('persona', p.id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final extensionPresets = await _read(_extensionPresetRepo.getAll);
    for (final ep in extensionPresets) {
      final json = ep.toJson();
      final hash = SyncSerialization.computeSyncHash(json);
      final key = entryKey('extension_preset', ep.id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'extension_preset',
        id: ep.id,
        path: cloudPath('extension_preset', ep.id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final sessions = await _read(_chatRepo.getAllSessionMetadata);
    for (final s in sessions) {
      final hash = SyncSerialization.computeChatMetadataHash(s);
      final key = entryKey('chat', s.sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      final entityUpdatedAt = timestampSecondsToMilliseconds(s.updatedAt);
      if (entityUpdatedAt > updatedAt) updatedAt = entityUpdatedAt;

      entries[key] = SyncManifestEntry(
        type: 'chat',
        id: s.sessionId,
        path: cloudPath('chat', s.sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final memoryBooks = await _read(_memoryBookRepo.getAll);
    for (final mb in memoryBooks) {
      final json = mb.toJson();
      final hash = SyncSerialization.computeMemoryBookHash(json);
      final key = entryKey('memory_book', mb.sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      if (mb.updatedAt > updatedAt) updatedAt = mb.updatedAt;

      entries[key] = SyncManifestEntry(
        type: 'memory_book',
        id: mb.sessionId,
        path: cloudPath('memory_book', mb.sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final infoBlockSessionIds = await _read(_infoBlockStore.getAllSessionIds);
    for (final sessionId in infoBlockSessionIds) {
      final blocks = await _read(
        () => _infoBlockStore.getBySessionId(sessionId),
      );
      if (blocks.isEmpty) continue;
      final hash = SyncSerialization.computeSyncHash(
        SyncSerialization.infoBlocksPayload(blocks),
      );
      final key = entryKey('info_block', sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'info_block',
        id: sessionId,
        path: cloudPath('info_block', sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final chatSessionIds = sessions.map((session) => session.sessionId).toSet();
    final trackerSnapshotSessionIds = {
      ...chatSessionIds,
      ...await _read(_trackerSnapshotStore.getAllSessionIds),
    };
    for (final sessionId in trackerSnapshotSessionIds) {
      final snapshots = await _read(
        () => _trackerSnapshotStore.getBySessionId(sessionId),
      );
      final payload = {'__trackerSnapshots': true, 'items': snapshots};
      final hash = SyncSerialization.computeSyncHash(payload);
      final key = entryKey('tracker_snapshot', sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'tracker_snapshot',
        id: sessionId,
        path: cloudPath('tracker_snapshot', sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final trackerValueSessionIds = {
      ...chatSessionIds,
      ...await _read(_trackerValueStore.getAllSessionIds),
    };
    for (final sessionId in trackerValueSessionIds) {
      final trackers = await _read(
        () => _trackerValueStore.getBySessionId(sessionId),
      );
      final payload = {'__trackerValues': true, 'items': trackers};
      final hash = SyncSerialization.computeSyncHash(payload);
      final key = entryKey('tracker_value', sessionId);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: 'tracker_value',
        id: sessionId,
        path: cloudPath('tracker_value', sessionId),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    final studioConfigs = await _read(_studioConfigStore.getAll);
    for (final config in studioConfigs) {
      final id = config.sessionId;
      final json = config.toJson();
      final hash = SyncSerialization.computeStudioConfigHash(json);
      final key = entryKey('studio_config', id);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      var updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );
      if (config.updatedAt > updatedAt) updatedAt = config.updatedAt;

      entries[key] = SyncManifestEntry(
        type: 'studio_config',
        id: id,
        path: cloudPath('studio_config', id),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    if (_studioPresetStore != null) {
      final studioPresets = await _read(_studioPresetStore.getAll);
      for (final preset in studioPresets) {
        final json = preset.toJson();
        final hash = SyncSerialization.computeSyncHash(json);
        final key = entryKey('studio_preset', preset.id);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        var updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );
        if (preset.updatedAt > updatedAt) updatedAt = preset.updatedAt;

        entries[key] = SyncManifestEntry(
          type: 'studio_preset',
          id: preset.id,
          path: cloudPath('studio_preset', preset.id),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    // Chat summaries — per-session, like tracker_value.
    if (_chatSummaryStore != null) {
      final summarySessionIds = await _read(_chatSummaryStore.getAllSessionIds);
      for (final sessionId in summarySessionIds) {
        final summary = await _read(
          () => _chatSummaryStore.getBySessionId(sessionId),
        );
        if (summary == null) continue;
        final hash = SyncSerialization.computeSyncHash(summary);
        final key = entryKey('chat_summary', sessionId);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );

        entries[key] = SyncManifestEntry(
          type: 'chat_summary',
          id: sessionId,
          path: cloudPath('chat_summary', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    // Memory graph — per-session, packs 5 tables into one JSON.
    if (_memoryGraphStore != null) {
      final graphSessionIds = await _read(_memoryGraphStore.getAllSessionIds);
      for (final sessionId in graphSessionIds) {
        final graph = await _read(
          () => _memoryGraphStore.getBySessionId(sessionId),
        );
        if (graph == null) continue;
        final hash = SyncSerialization.computeSyncHash(graph);
        final key = entryKey('memory_graph', sessionId);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );

        entries[key] = SyncManifestEntry(
          type: 'memory_graph',
          id: sessionId,
          path: cloudPath('memory_graph', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    if (_memoryEventRegistryStore != null) {
      final store = _memoryEventRegistryStore;
      final sessionIds = await _read(store.getAllSessionIds);
      for (final sessionId in sessionIds) {
        if (!chatSessionIds.contains(sessionId) ||
            await isDeleted('chat', sessionId)) {
          continue;
        }
        final registry = await _read(() => store.getBySessionId(sessionId));
        if (registry == null) continue;
        final hash = SyncSerialization.computeSyncHash(registry);
        final key = entryKey('memory_event_registry', sessionId);
        entries[key] = SyncManifestEntry(
          type: 'memory_event_registry',
          id: sessionId,
          path: cloudPath('memory_event_registry', sessionId),
          updatedAt: _resolveUpdatedAt(
            hash: hash,
            prevEntry: previous.entries[key],
            cloudEntry: cloudManifest?.entries[key],
            now: now,
          ),
          hash: hash,
        );
      }
    }

    if (_characterKnowledgeStore != null) {
      final sessionIds = await _read(_characterKnowledgeStore.getAllSessionIds);
      for (final sessionId in sessionIds) {
        final knowledge = await _read(
          () => _characterKnowledgeStore.getBySessionId(sessionId),
        );
        if (knowledge == null) continue;
        final hash = SyncSerialization.computeSyncHash(knowledge);
        final key = entryKey('character_knowledge', sessionId);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );
        entries[key] = SyncManifestEntry(
          type: 'character_knowledge',
          id: sessionId,
          path: cloudPath('character_knowledge', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
    }

    if (_sessionLorebookOverlayStore != null) {
      final sessionIds = await _read(
        _sessionLorebookOverlayStore.getAllSessionIds,
      );
      for (final sessionId in sessionIds) {
        final overlays = await _read(
          () => _sessionLorebookOverlayStore.getBySessionId(sessionId),
        );
        if (overlays == null) continue;
        final hash = SyncSerialization.computeSyncHash(overlays);
        final key = entryKey('session_lorebook_overlays', sessionId);
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: previous.entries[key],
          cloudEntry: cloudManifest?.entries[key],
          now: now,
        );
        entries[key] = SyncManifestEntry(
          type: 'session_lorebook_overlays',
          id: sessionId,
          path: cloudPath('session_lorebook_overlays', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
      final chatSessionIds = sessions
          .map((session) => session.sessionId)
          .toSet();
      for (final previousEntry in previous.entries.values) {
        if (previousEntry.type != 'session_lorebook_overlays' ||
            entries.containsKey(previousEntry.key) ||
            !chatSessionIds.contains(previousEntry.id)) {
          continue;
        }
        final cloudEntry = cloudManifest?.entries[previousEntry.key];
        if (cloudEntry == null ||
            cloudEntry.deleted ||
            cloudEntry.hash != previousEntry.hash ||
            !previous.acceptedLocalHashes.containsKey(previousEntry.key) ||
            await isDeleted(previousEntry.type, previousEntry.id) ||
            await isDeleted('chat', previousEntry.id)) {
          continue;
        }
        // An accepted empty aggregate has no local rows to rebuild from.
        entries[previousEntry.key] = cloudEntry;
      }
    }

    if (_reconciliationStateStore != null) {
      final store = _reconciliationStateStore;
      final sessionIds = await _read(store.getAllSessionIds);
      for (final sessionId in sessionIds) {
        final String? hash;
        if (store is SyncPagedReconciliationStateStore) {
          hash = (await _read(
            () => store.fingerprintBySessionId(sessionId),
          ))?.hash;
        } else {
          final state = await _read(() => store.getBySessionId(sessionId));
          hash = state == null
              ? null
              : SyncSerialization.computeSyncHash(state);
        }
        if (hash == null) continue;
        final key = entryKey('reconciliation_state', sessionId);
        final prevEntry = previous.entries[key];
        final cloudEntry = cloudManifest?.entries[key];
        final updatedAt = _resolveUpdatedAt(
          hash: hash,
          prevEntry: prevEntry,
          cloudEntry: cloudEntry,
          now: now,
        );
        entries[key] = SyncManifestEntry(
          type: 'reconciliation_state',
          id: sessionId,
          path: cloudPath('reconciliation_state', sessionId),
          updatedAt: updatedAt,
          hash: hash,
        );
      }
      final chatSessionIds = sessions
          .map((session) => session.sessionId)
          .toSet();
      for (final previousEntry in previous.entries.values) {
        if (previousEntry.type != 'reconciliation_state' ||
            entries.containsKey(previousEntry.key) ||
            !chatSessionIds.contains(previousEntry.id)) {
          continue;
        }
        final cloudEntry = cloudManifest?.entries[previousEntry.key];
        if (cloudEntry == null ||
            cloudEntry.deleted ||
            cloudEntry.hash != previousEntry.hash ||
            !previous.acceptedLocalHashes.containsKey(previousEntry.key) ||
            await isDeleted(previousEntry.type, previousEntry.id) ||
            await isDeleted('chat', previousEntry.id)) {
          continue;
        }
        // A cloud state may normalize to no durable runs (for example, stale
        // legacy anchors). Keep its accepted manifest marker so it is not
        // downloaded and rejected again on every pull.
        entries[previousEntry.key] = cloudEntry;
      }
    }

    if (_rewriteJobHistoryStore != null) {
      final sessionIds = await _read(_rewriteJobHistoryStore.getAllSessionIds);
      for (final sessionId in sessionIds) {
        if (!chatSessionIds.contains(sessionId) ||
            await isDeleted('chat', sessionId)) {
          continue;
        }
        final history = await _read(
          () => _rewriteJobHistoryStore.getBySessionId(sessionId),
        );
        if (history == null) continue;
        final hash = SyncSerialization.computeSyncHash(history);
        final key = entryKey('rewrite_job_history', sessionId);
        entries[key] = SyncManifestEntry(
          type: 'rewrite_job_history',
          id: sessionId,
          path: cloudPath('rewrite_job_history', sessionId),
          updatedAt: _resolveUpdatedAt(
            hash: hash,
            prevEntry: previous.entries[key],
            cloudEntry: cloudManifest?.entries[key],
            now: now,
          ),
          hash: hash,
        );
      }
    }

    await _addSingletons(entries, previous, now, cloudManifest);
    await _addDeletedEntries(entries, now);

    final trackerSnapshotRestoreHashes = <String, String>{};
    for (final pending in previous.trackerSnapshotRestoreHashes.entries) {
      final snapshot = entries[pending.key];
      final chat = snapshot == null
          ? null
          : entries[entryKey('chat', snapshot.id)];
      if (snapshot == null ||
          snapshot.type != 'tracker_snapshot' ||
          snapshot.deleted ||
          snapshot.hash != pending.value ||
          chat == null ||
          chat.deleted ||
          await isDeleted('chat', snapshot.id) ||
          await isDeleted(snapshot.type, snapshot.id)) {
        continue;
      }
      trackerSnapshotRestoreHashes[pending.key] = pending.value;
    }

    final acceptedLocalHashes = <String, String>{...characterAcceptedHashes};
    if (applyAcceptedHashes) {
      for (final accepted in previous.acceptedLocalHashes.entries) {
        if (previous.needsReconciliationRestore(accepted.key)) continue;
        final entry = entries[accepted.key];
        final previousEntry = previous.entries[accepted.key];
        if (entry == null ||
            previousEntry == null ||
            entry.hash != accepted.value) {
          continue;
        }
        entries[accepted.key] = previousEntry;
        acceptedLocalHashes[accepted.key] = accepted.value;
      }
    }

    return SyncManifest(
      version: SyncManifest.currentVersion,
      deviceId: deviceId,
      createdAt: previous.createdAt,
      lastSync: previous.lastSync,
      entries: entries,
      acceptedLocalHashes: acceptedLocalHashes,
      trackerSnapshotRestoreHashes: trackerSnapshotRestoreHashes,
    );
  }

  /// Decides manifest updatedAt without spurious "now" bumps on hash drift.
  static int _resolveUpdatedAt({
    required String hash,
    required SyncManifestEntry? prevEntry,
    required SyncManifestEntry? cloudEntry,
    required int now,
  }) {
    if (prevEntry != null && hash == prevEntry.hash) {
      return prevEntry.updatedAt;
    }
    if (cloudEntry != null && hash == cloudEntry.hash) {
      return cloudEntry.updatedAt;
    }
    if (prevEntry != null &&
        cloudEntry != null &&
        prevEntry.hash == cloudEntry.hash) {
      // Was aligned with cloud; local DB changed → treat as local edit.
      return now;
    }
    // No previous manifest entry — entity was never synced from this device.
    // Don't claim "now" (would always beat cloud); let entity-level updatedAt
    // (c.updatedAt, s.updatedAt) override if the entity was genuinely edited.
    return prevEntry?.updatedAt ?? 0;
  }

  /// Returns the size of the avatar file in bytes, or 0 if the file doesn't
  /// exist or avatarPath is null. The size is platform-neutral (same bytes on
  /// Android and Windows for the same image), unlike the path itself.
  int _avatarFileSize(String? avatarPath) {
    if (avatarPath == null || avatarPath.isEmpty) return 0;
    final store = _imageStore;
    if (store == null) return 0;
    try {
      final absPath = store.absolutePath(avatarPath);
      if (absPath == null) return 0;
      final file = File(absPath);
      if (!file.existsSync()) return 0;
      return file.lengthSync();
    } catch (_) {
      return 0;
    }
  }

  /// Remove device-specific fields from entity JSON before hashing so that
  /// the same logical entity produces the same hash on every device.
  /// avatarPath is replaced by _avatarFileSize (platform-neutral) so that
  /// a missing or changed avatar binary triggers a re-push without causing
  /// Android↔Windows false-conflicts from differing absolute paths.
  /// Gallery paths are device-local, but ids, labels and order must be hashed
  /// so a gallery edit gets pushed even when character text is unchanged.
  Map<String, dynamic> _normalizeForHash(Map<String, dynamic> json) {
    final out = Map<String, dynamic>.from(json);
    final avatarPath = out['avatarPath'] as String?;
    out.remove('avatarPath');
    final gallery = out.remove('gallery') as List?;
    if (gallery != null && gallery.isNotEmpty) {
      out['_gallery'] = [
        for (final raw in gallery)
          if (raw is Map<String, dynamic>)
            {
              'id': raw['id'],
              'label': raw['label'],
              'createdAt': raw['createdAt'],
            },
      ];
    }
    // Include avatar file size so that uploading/deleting the avatar binary
    // changes the hash and triggers a re-push, even when the JSON is unchanged.
    // Using file size (not path) keeps hashes consistent across platforms.
    final avatarSize = _avatarFileSize(avatarPath);
    if (avatarSize > 0) {
      out['_avatarFileSize'] = avatarSize;
    }
    return out;
  }

  Future<void> _addSingletons(
    Map<String, SyncManifestEntry> entries,
    SyncManifest previous,
    int now,
    SyncManifest? cloudManifest,
  ) async {
    final singletons = <String, dynamic>{};

    final lorebooks = await _read(_lorebookRepo.getAll)
      ..sort((a, b) => a.id.compareTo(b.id));
    singletons['lorebooks'] = lorebooks.map((l) => l.toJson()).toList();

    final apiConfigs = await _read(_apiRepo.getAll);
    singletons['api_presets'] = apiConfigs
        .map((a) => a.copyWith(apiKey: '', embeddingApiKey: '').toJson())
        .toList();

    final presets = await _read(_presetRepo.getAll);
    singletons['theme_presets'] = presets.map((p) => p.toJson()).toList();

    final uiThemes = await _read(_themePresetRepo.getAll);
    singletons['ui_themes'] = uiThemes.map((t) => t.toJson()).toList();

    for (final entry in singletons.entries) {
      final type = entry.key;
      final items = entry.value as List;
      final hash = SyncSerialization.computeSyncHash(entry.value);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = items.isEmpty
          ? 0
          : _resolveUpdatedAt(
              hash: hash,
              prevEntry: prevEntry,
              cloudEntry: cloudEntry,
              now: now,
            );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    // extensions_settings is a Map singleton (not a list), handled separately.
    {
      const type = 'extensions_settings';
      final settings = await _read(_extensionsSettingsStore.get);
      final settingsJson = settings.toJson();
      final hash = SyncSerialization.computeSyncHash(settingsJson);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

    // Character folders — singleton (all folders + members in one JSON).
    if (_characterFolderStore != null) {
      const type = 'character_folders';
      final data = await _read(_characterFolderStore.getAll);
      final hash = SyncSerialization.computeSyncHash(data);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }

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
    {
      const type = 'local_storage';
      final payload = SyncSerialization.localStoragePayload(
        pipelineSettings: pipelineSettings,
        activeStudioPresetId: activeStudioPresetId,
        globalRegexScripts: globalRegexScripts,
        studioRegexScripts: studioRegexScripts,
        appSettings: appSettings,
        chatLayout: SyncSerialization.readChatLayout(prefs),
      );
      final hash = SyncSerialization.computeSyncHash(payload);
      final key = entryKey(type, type);
      final prevEntry = previous.entries[key];
      final cloudEntry = cloudManifest?.entries[key];
      final updatedAt = _resolveUpdatedAt(
        hash: hash,
        prevEntry: prevEntry,
        cloudEntry: cloudEntry,
        now: now,
      );

      entries[key] = SyncManifestEntry(
        type: type,
        id: type,
        path: cloudPath(type, type),
        updatedAt: updatedAt,
        hash: hash,
      );
    }
  }

  Future<void> _addDeletedEntries(
    Map<String, SyncManifestEntry> entries,
    int now,
  ) async {
    final prefs = await _read(SharedPreferences.getInstance);
    final raw = prefs.getString(_deletedKey);
    if (raw == null) return;

    final deleted = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    for (final d in deleted) {
      final type = d['type'] as String;
      final id = d['id'] as String;
      final key = entryKey(type, id);
      if (!entries.containsKey(key)) {
        entries[key] = SyncManifestEntry(
          type: type,
          id: id,
          path: cloudPath(type, id),
          updatedAt: now,
          hash: '',
          deleted: true,
        );
      }
    }
  }

  @override
  Future<SyncManifest> readLocalManifest() async {
    final prefs = await _read(SharedPreferences.getInstance);
    final raw = prefs.getString(_manifestKey);
    if (raw == null) return const SyncManifest(deviceId: '', createdAt: 0);
    try {
      return SyncManifest.fromJson(jsonDecode(raw) as Map<String, dynamic>);
    } catch (_) {
      return const SyncManifest(deviceId: '', createdAt: 0);
    }
  }

  @override
  Future<void> writeLocalManifest(SyncManifest manifest) async {
    final prefs = await _read(SharedPreferences.getInstance);
    await _write(
      () => prefs.setString(_manifestKey, jsonEncode(manifest.toJson())),
    );
  }

  Future<void> markDeleted(String type, String id) async {
    final prefs = await _read(SharedPreferences.getInstance);
    final raw = prefs.getString(_deletedKey);
    final deleted = raw != null
        ? (jsonDecode(raw) as List).cast<Map<String, dynamic>>().toList()
        : <Map<String, dynamic>>[];
    deleted.add({'type': type, 'id': id});
    await _write(() => prefs.setString(_deletedKey, jsonEncode(deleted)));
  }

  @override
  Future<void> clearLocalManifest() async {
    final prefs = await _read(SharedPreferences.getInstance);
    await _write(() => prefs.remove(_manifestKey));
    await _write(() => prefs.remove(_deletedKey));
  }

  @override
  Future<void> clearDeleted() async {
    final prefs = await _read(SharedPreferences.getInstance);
    await _write(() => prefs.remove(_deletedKey));
  }

  @override
  Future<bool> isDeleted(String type, String id) async {
    final prefs = await _read(SharedPreferences.getInstance);
    final raw = prefs.getString(_deletedKey);
    if (raw == null) return false;
    final deleted = (jsonDecode(raw) as List).cast<Map<String, dynamic>>();
    return deleted.any((row) => row['type'] == type && row['id'] == id);
  }
}
