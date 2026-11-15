import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/painting.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/character_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/chat_session_ops_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/lorebook_provider.dart';
import '../../../core/state/lorebook_embedding_provider.dart';
import '../../../core/state/global_regex_provider.dart';
import '../../../core/state/shared_prefs_provider.dart';
import '../../../core/state/studio_regex_provider.dart';
import '../../../core/utils/error_format.dart';
import '../../../shared/theme/theme_provider.dart';
import '../../personas/persona_list_provider.dart';
import '../../presets/preset_list_provider.dart';
import '../../settings/api_list_provider.dart';
import '../../settings/app_settings_provider.dart';
import '../../card_rewrite/card_rewriter_recovery_view_service.dart';
import '../../chat/chat_provider.dart';
import '../../chat/chat_session_service.dart';
import '../../chat/services/collector_view_service.dart';
import '../../chat/services/reconciler_view_service.dart';
import '../../chat_history/chat_history_provider.dart';
import '../sync_provider.dart';
import '../sync_models.dart';
import 'sync_engine.dart';
import 'sync_queue.dart';
import 'sync_service.dart';
import 'sync_conflict.dart';
import '../../chat/composer_pins_provider.dart';
import '../../chat/hidden_composer_actions_provider.dart';
import '../../chat/composer_empty_action_provider.dart';
import '../../chat/quick_replies_provider.dart';
import '../../chat/state/magic_drawer_stats_cache.dart';

/// Controller for cloud sync operations, separating business logic from UI.
class SyncController {
  final WidgetRef _ref;
  final bool Function() isMounted;

  bool _isConnecting = false;
  bool _isConnectingGdrive = false;
  bool _isDisconnecting = false;
  bool _isWiping = false;
  bool _isResolvingConflicts = false;
  Map<String, dynamic>? _syncResult;
  bool _syncIncludeApiKeys = false;
  String? _gdriveFolderId;

  SyncController(this._ref, {required this.isMounted});

  bool _ownsService(SyncService service) =>
      isMounted() && identical(_ref.read(syncServiceProvider).value, service);

  bool get isConnecting => _isConnecting;
  bool get isConnectingGdrive => _isConnectingGdrive;
  bool get isDisconnecting => _isDisconnecting;
  bool get isWiping => _isWiping;
  bool get isResolvingConflicts => _isResolvingConflicts;
  Map<String, dynamic>? get syncResult => _syncResult;
  bool get syncIncludeApiKeys => _syncIncludeApiKeys;
  String? get gdriveFolderId => _gdriveFolderId;

  Future<void> loadIncludeApiKeys() async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    final raw = prefs.get('gz_sync_include_api_keys');
    _syncIncludeApiKeys = raw is bool ? raw : false;
  }

  Future<void> setIncludeApiKeys(bool val) async {
    final prefs = await _ref.read(sharedPreferencesProvider.future);
    if (prefs.get('gz_sync_include_api_keys') is! bool) {
      await prefs.remove('gz_sync_include_api_keys');
    }
    await prefs.setBool('gz_sync_include_api_keys', val);
    _syncIncludeApiKeys = val;
  }

  Future<void> resolveFolderIdIfNeeded() async {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null &&
        service.provider == SyncProvider.gdrive &&
        service.isConnected()) {
      if (service.gdriveFolderId != null) {
        _gdriveFolderId = service.gdriveFolderId;
      } else {
        final pending = service.resolveGDriveFolderId();
        final issued = service.capturePublicationGuard();
        final folder = await pending;
        if (_ownsService(service) && issued() && service.isConnected())
          _gdriveFolderId = folder;
      }
    }
  }

  void initStateFromService() {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null) {
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _ref.read(syncConnectedProvider.notifier).state = service.isConnected();
      _ref.read(syncProviderProvider.notifier).state = service.provider;
      _ref.read(syncAutoEnabledProvider.notifier).state =
          service.autoSyncEnabled;
    }
  }

  /// Returns error message or null on success.
  Future<String?> connectDropbox() async {
    _isConnecting = true;
    try {
      final service = await _ref.read(syncServiceProvider.future);
      if (!_ownsService(service)) return 'Cloud sync owner retired';
      final pending = service.connectDropbox();
      final issued = service.capturePublicationGuard();
      await pending;
      if (!_ownsService(service) || !issued())
        return 'Cloud sync owner retired';
      _ref.read(syncConnectedProvider.notifier).state = service.isConnected();
      _ref.read(syncProviderProvider.notifier).state = SyncProvider.dropbox;
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _ref.read(syncLastErrorProvider.notifier).state = service.warning;
      await resolveFolderIdIfNeeded();
      return null;
    } catch (_) {
      return 'Dropbox connection failed';
    } finally {
      _isConnecting = false;
    }
  }

  Future<String?> connectGDrive() async {
    _isConnectingGdrive = true;
    try {
      final service = await _ref.read(syncServiceProvider.future);
      if (!_ownsService(service)) return 'Cloud sync owner retired';
      final pending = service.connectGDrive();
      final issued = service.capturePublicationGuard();
      await pending;
      if (!_ownsService(service) || !issued())
        return 'Cloud sync owner retired';
      _ref.read(syncConnectedProvider.notifier).state = service.isConnected();
      _ref.read(syncProviderProvider.notifier).state = SyncProvider.gdrive;
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _ref.read(syncLastErrorProvider.notifier).state = service.warning;
      await resolveFolderIdIfNeeded();
      return null;
    } catch (_) {
      return 'Google Drive connection failed';
    } finally {
      _isConnectingGdrive = false;
    }
  }

  Future<String?> disconnect() async {
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;

    _isDisconnecting = true;
    bool Function()? issued;
    bool current() => _ownsService(service) && (issued?.call() ?? true);
    try {
      final pending = service.disconnect();
      issued = service.capturePublicationGuard();
      await pending;
      if (!current()) return 'Cloud sync owner retired';
      _ref.read(syncConnectedProvider.notifier).state = false;
      _ref.read(syncProviderProvider.notifier).state = SyncProvider.dropbox;
      _ref.read(syncStatusProvider.notifier).state = service.status;
      _ref.read(syncLastErrorProvider.notifier).state = service.warning;
      _syncResult = null;
      _gdriveFolderId = null;
      return service.warning;
    } catch (_) {
      // Verified local tombstone remains truth even when remote/metadata fails.
      if (current()) {
        _ref.read(syncConnectedProvider.notifier).state = service.isConnected();
      }
      return 'Disconnect failed';
    } finally {
      _isDisconnecting = false;
    }
  }

  /// Returns a result map or throws.
  Future<Map<String, dynamic>?> wipeCloudData({
    required void Function(SyncProgress p) onProgress,
    required String providerLabel,
  }) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);

    _isWiping = true;
    _syncResult = null;
    statusNotifier.state = SyncStatus.syncing;
    bool Function()? issued;
    bool current() => _ownsService(service) && (issued?.call() ?? true);
    try {
      final pending = service.wipeCloudData(
        onProgress: (progress) {
          if (current()) onProgress(progress);
        },
      );
      issued = service.capturePublicationGuard();
      await pending;
      if (!current()) return null;
      statusNotifier.state = service.status;
      _syncResult = {'type': 'wipe', 'total': 'all'};
      return _syncResult;
    } catch (e) {
      if (!current()) rethrow;
      statusNotifier.state = SyncStatus.error;
      rethrow;
    } finally {
      _isWiping = false;
      if (current()) {
        progressNotifier.state = null;
        statusNotifier.state = service.status;
      }
    }
  }

  Future<String?> doSync(String mode) async {
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final lastErrorNotifier = _ref.read(syncLastErrorProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);
    final conflictsNotifier = _ref.read(syncConflictsProvider.notifier);

    statusNotifier.state = SyncStatus.syncing;
    lastErrorNotifier.state = null;
    _syncResult = null;

    int itemsCount = 0;
    SyncService? service;
    bool Function()? issued;
    bool current() =>
        service != null && _ownsService(service) && (issued?.call() ?? true);
    final originalProducer = _ref.read(syncServiceProvider.future);
    final originalService = _ref.read(syncServiceProvider).value;
    try {
      service = await originalProducer;
      if (!current() ||
          (originalService != null && !identical(originalService, service))) {
        return 'Cloud sync owner retired';
      }
      final owned = service;
      void progress(SyncProgress p) {
        if (!current()) return;
        progressNotifier.state = p;
        itemsCount = p.total;
      }

      late Future<void> pending;
      switch (mode) {
        case 'push':
          pending = owned.fullPushWithConflictPreflight(
            includeApiKeys: _syncIncludeApiKeys,
            onProgress: progress,
          );
          break;
        case 'pull':
          pending = owned.fullPull(onProgress: progress);
          break;
        case 'full':
          pending = owned.fullSync(
            includeApiKeys: _syncIncludeApiKeys,
            onProgress: progress,
          );
          break;
        default:
          return null;
      }
      issued = owned
          .capturePublicationGuard(); // Exact synchronously started workflow.
      await pending;
      if (!current()) return 'Cloud sync owner retired';
      if (mode != 'push' || owned.status == SyncStatus.conflict)
        await refreshDataProvidersAfterPull(isCurrent: current);
      if (!current()) return 'Cloud sync owner retired';
      _syncResult = owned.conflicts.isNotEmpty
          ? {
              'type': 'pull',
              'pulled': itemsCount,
              'conflictsCount': owned.conflicts.length,
            }
          : mode == 'push'
          ? {'type': 'push', 'pushed': itemsCount}
          : mode == 'pull'
          ? {
              'type': 'pull',
              'pulled': itemsCount,
              'conflictsCount': owned.conflicts.length,
            }
          : {'type': 'full'};
      statusNotifier.state = owned.status;
      conflictsNotifier.state = List.of(owned.conflicts);
      if (mode == 'full') return 'sync_full_done'.tr();
      if (owned.conflicts.isNotEmpty) {
        return 'Sync requires resolving ${owned.conflicts.length} conflicts';
      }
      return '${mode == 'push' ? 'Push' : 'Pull'} completed ($itemsCount items)';
    } catch (e) {
      if (!current()) return 'Cloud sync owner retired';
      final message = _formatSyncError(e);
      lastErrorNotifier.state = message;
      statusNotifier.state = service!.status;
      conflictsNotifier.state = List.of(service.conflicts);
      return 'Sync failed: $message';
    } finally {
      if (current()) progressNotifier.state = null;
    }
  }

  Future<String?> resolveConflict(SyncConflict conflict, String choice) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;
    final conflictsNotifier = _ref.read(syncConflictsProvider.notifier);
    final errorNotifier = _ref.read(syncLastErrorProvider.notifier);
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);

    // Optimistically remove from UI immediately — the user should not wait
    // for a manifest-rewrite before seeing the conflict row disappear.
    final optimistic = _ref
        .read(syncConflictsProvider)
        .where((c) => c.key != conflict.key)
        .toList();
    conflictsNotifier.state = optimistic;
    statusNotifier.state = SyncStatus.syncing;
    bool Function()? issued;
    bool current() => _ownsService(service) && (issued?.call() ?? true);
    try {
      final pending = service.resolveConflict(conflict, choice);
      issued = service.capturePublicationGuard();
      await pending;
      if (!current()) return 'Cloud sync owner retired';
      // Sync provider state with service truth (in case of partial failure).
      conflictsNotifier.state = List.from(service.conflicts);

      if (service.conflicts.isEmpty) {
        return await _applyPendingPullAndFinalize(
          service,
          setStatus: (value) => statusNotifier.state = value,
          setProgress: (value) => progressNotifier.state = value,
          setError: (value) => errorNotifier.state = value,
        );
      }
      statusNotifier.state = SyncStatus.conflict;
      return null;
    } catch (e) {
      if (!current()) return 'Cloud sync owner retired';
      // Roll back optimistic removal on error.
      conflictsNotifier.state = List.from(service.conflicts);
      final message = _formatSyncError(e);
      errorNotifier.state = message;
      statusNotifier.state = service.status;
      return 'Could not resolve conflict: $message';
    }
  }

  Future<String?> resolveAllConflicts(String choice) async {
    if (_isResolvingConflicts) return null;
    final service = _ref.read(syncServiceProvider).value;
    if (service == null) return null;
    final conflictsNotifier = _ref.read(syncConflictsProvider.notifier);
    final errorNotifier = _ref.read(syncLastErrorProvider.notifier);
    final statusNotifier = _ref.read(syncStatusProvider.notifier);
    final progressNotifier = _ref.read(syncProgressProvider.notifier);
    _isResolvingConflicts = true;
    // Optimistically clear all conflict rows immediately.
    conflictsNotifier.state = [];
    statusNotifier.state = SyncStatus.syncing;
    bool Function()? issued;
    bool current() => _ownsService(service) && (issued?.call() ?? true);
    try {
      final pending = service.resolveAllConflictsAndApply(
        choice,
        onProgress: (value) {
          if (current()) progressNotifier.state = value;
        },
      );
      issued = service.capturePublicationGuard();
      await pending;
      if (!current()) return 'Cloud sync owner retired';
      conflictsNotifier.state = List.from(service.conflicts);
      if (isMounted()) await refreshDataProvidersAfterPull(isCurrent: current);
      if (!current()) return 'Cloud sync owner retired';
      return 'Sync complete';
    } catch (e) {
      if (!current()) return 'Cloud sync owner retired';
      final message = _formatSyncError(e);
      errorNotifier.state = message;
      conflictsNotifier.state = List.from(service.conflicts);
      statusNotifier.state = service.status;
      return 'Could not resolve conflicts: $message';
    } finally {
      _isResolvingConflicts = false;
      if (current()) {
        statusNotifier.state = service.status;
        progressNotifier.state = null;
      }
    }
  }

  /// Called after all conflicts are resolved. Applies the pending pull,
  /// shows progress, invalidates data providers, and returns a toast message.
  Future<String?> _applyPendingPullAndFinalize(
    SyncService service, {
    required void Function(SyncStatus value) setStatus,
    required void Function(SyncProgress? value) setProgress,
    required void Function(String? value) setError,
  }) async {
    bool Function()? issued;
    bool current() => _ownsService(service) && (issued?.call() ?? true);
    setStatus(SyncStatus.syncing);
    try {
      final pending = service.applyPendingPullAfterResolve(
        onProgress: (p) {
          if (current()) setProgress(p);
        },
      );
      issued = service.capturePublicationGuard();
      await pending;
      if (!current()) return 'Cloud sync owner retired';
      await refreshDataProvidersAfterPull(isCurrent: current);
      if (!current()) return 'Cloud sync owner retired';
      return 'Sync complete';
    } catch (e) {
      if (!current()) return 'Cloud sync owner retired';
      final message = _formatSyncError(e);
      setError(message);
      return 'Sync failed: $message';
    } finally {
      if (current()) {
        setStatus(service.status);
        setProgress(null);
      }
    }
  }

  String _formatSyncError(Object error) {
    if (error is! SyncQueueAggregateError || error.errors.isEmpty) {
      return formatError(error);
    }
    final first = formatError(error.errors.first);
    final remaining = error.errors.length - 1;
    return remaining == 0 ? first : '$first (+$remaining more errors)';
  }

  Future<void> refreshDataProvidersAfterPull({
    bool Function()? isCurrent,
  }) async {
    void check() {
      if (!isMounted() || isCurrent?.call() == false)
        throw StateError('Cloud sync owner retired');
    }

    check();
    // Pull writes use the original cached preferences delegate. Reload would
    // retire that very credential admission before the dependent publications.
    _ref.invalidate(appSettingsProvider);
    await _ref.read(appSettingsProvider.future);
    check();
    await _ref.read(pipelineSettingsProvider.notifier).load();
    check();

    // Evict all cached avatar images so that Image.file widgets re-read the
    // updated files from disk immediately (without a full app restart).
    _evictAvatarImageCache();

    // Chat sessions are replaced directly in the database during pull. Drop
    // both in-memory layers before rebuilding providers so ownership changes
    // (for example a Card Rewriter variant fork) become visible immediately.
    ChatSessionService.clearCache();
    _ref.invalidate(chatProvider, asReload: true);
    _ref.invalidate(reconcilerViewProvider, asReload: true);
    _ref.invalidate(collectorViewProvider, asReload: true);
    _ref.invalidate(cardRewriterRecoveryViewsProvider, asReload: true);

    _ref.invalidate(charactersProvider);
    _ref.invalidate(personaListProvider);
    _ref.invalidate(apiListProvider);
    _ref.invalidate(lorebooksProvider);
    _ref.invalidate(chatSessionOpsProvider);
    _ref.invalidate(chatHistoryProvider);
    _ref.invalidate(activeStudioPresetProvider);
    _ref.invalidate(studioPresetProvider);
    // Both preset libraries are read once and cached — neither is a Drift
    // stream — and the pull writes straight through their repositories. Without
    // these two the Presets screen kept showing the list it had read at
    // startup: a preset synced from another device was invisible until the app
    // was restarted, and so was a cover image, whose file the pull drops next
    // to the path the preset already points at.
    _ref.invalidate(presetListProvider);
    _ref.invalidate(studioPresetListProvider);
    _ref.invalidate(globalRegexProvider);
    _ref.invalidate(studioRegexProvider);
    _ref.invalidate(composerPinsProvider);
    _ref.invalidate(hiddenComposerActionsProvider);
    _ref.invalidate(composerEmptyActionProvider);
    _ref.invalidate(quickRepliesProvider);
    _ref.invalidate(magicDrawerLayoutCacheProvider);
    unawaited(_ref.read(sessionLorebookEmbeddingWorkerProvider).drain());
    await _ref.read(themeProvider.notifier).reload();
    check();

    // Bump the version counter so widgets that watch avatarVersionProvider
    // (chat_header, character_list) rebuild and pick up the new paths.
    bumpAvatarVersion(_ref);
  }

  void _evictAvatarImageCache() {
    try {
      // Collect avatar paths from characters currently in the provider.
      final chars = _ref.read(charactersProvider).value ?? [];
      for (final c in chars) {
        if (c.avatarPath != null && c.avatarPath!.isNotEmpty) {
          FileImage(File(c.avatarPath!)).evict();
        }
      }
      // Also clear live images (includes images whose path hasn't changed but
      // whose bytes on disk have been replaced by the sync pull).
      PaintingBinding.instance.imageCache.clearLiveImages();
    } catch (_) {}
  }

  Future<void> setAutoSync(bool val) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null) {
      final pending = service.setAutoSync(
        val,
        messageCount: service.autoSyncMessageCount,
      );
      final issued = service.capturePublicationGuard();
      await pending;
      if (!_ownsService(service) || !issued()) return;
      _ref.read(syncAutoEnabledProvider.notifier).state = val;
    }
  }

  Future<void> updateAutoSyncThreshold(int count) async {
    final service = _ref.read(syncServiceProvider).value;
    if (service != null) {
      await service.setAutoSync(service.autoSyncEnabled, messageCount: count);
    }
  }
}
