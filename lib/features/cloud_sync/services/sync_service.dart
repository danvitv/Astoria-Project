import 'dart:convert';
import 'dart:async';

// ignore_for_file: prefer_initializing_formals

import 'package:shared_preferences/shared_preferences.dart';

import '../../../core/credentials/cloud_oauth_mobile_metadata.dart';
import '../../../core/credentials/cloud_oauth_credential_owner.dart';
import '../../../core/credentials/credential_vault.dart';
import '../../../core/credentials/secret_redaction_coordinator.dart';
import '../../../core/preferences/tracked_shared_preferences.dart';

import '../../../core/services/generation_notification_service.dart';
import '../../../core/models/lorebook.dart';
import '../../../core/application/session_deletion_store.dart';
import '../../../core/application/character_deletion_store.dart';
import '../sync_repo_interfaces.dart';
import 'dropbox/dropbox_adapter.dart';
import 'dropbox/dropbox_auth.dart';
import 'gdrive/gdrive_adapter.dart';
import 'gdrive/gdrive_auth.dart';
import 'sync_conflict.dart';
import 'sync_engine.dart';
import 'sync_conflict_diagnostics.dart';
import 'sync_conflict_diagnostics_download.dart';
import 'sync_manifest.dart';
import 'reconciliation_page_cache.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';

export 'sync_conflict_diagnostics_report.dart';

class SyncService {
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
  final SyncMemoryEventRegistryStore? _memoryEventRegistryStore;
  final SyncCharacterKnowledgeStore? _characterKnowledgeStore;
  final SyncSessionLorebookOverlayStore? _sessionLorebookOverlayStore;
  final SyncReconciliationStateStore? _reconciliationStateStore;
  final SyncRewriteJobHistoryStore? _rewriteJobHistoryStore;
  final SessionDeletionStore _sessionDeletionStore;
  final CharacterDeletionStore _characterDeletionStore;
  final Future<void> Function(LorebookActivations) _saveLorebookActivations;
  final Future<void> Function(Set<String>)? _reconcilePulledSessions;
  final Future<String> Function(String)? _diagnosticDownload;
  // Trusted constructor seam; production defaults to the actual provider below.
  final CloudAdapter Function(SyncProvider)? _selectAdapter;
  final ReconciliationPageCache? _reconciliationPageCache;

  SyncProvider _provider = SyncProvider.dropbox;
  SyncStatus _status = SyncStatus.idle;
  String? _lastError;
  int? _lastSyncTime;
  final List<SyncConflict> _conflicts = [];
  final List<String> _resolvedAsCloud = [];
  bool _resolvedAsLocal = false;
  Map<String, dynamic>? _accountInfo;
  bool _autoSyncEnabled = false;
  int _autoSyncMessageCount = 5;
  int _messageCounter = 0;
  bool _operationInProgress = false;
  bool _isDiagnosingConflicts = false;

  final DropboxAuth _dropboxAuth;
  final GDriveAuth _gdriveAuth;
  final Future<SharedPreferences>? _originalPreferences;
  final SecretRedactionCoordinator _redaction;
  bool _disposed = false;
  int _workflowEpoch = 0;
  final Object _workflowKey = Object();
  bool Function()? _publicationGuard;
  List<bool Function()>? _publicationClauses;
  final Map<SyncProvider, String> _storageWarnings = {};
  String? _metadataWarning;
  String? _disconnectWarning;
  int _acknowledgedPreferenceWrites = 0;

  Future<void> _writePreference(Future<bool> Function() original) async {
    _checkWorkflow();
    if (!await original())
      throw StateError('Cloud preference write not acknowledged');
    _acknowledgedPreferenceWrites++;
    try {
      _checkWorkflow();
    } catch (_) {
      throw SyncWorkflowRetired(_acknowledgedPreferenceWrites);
    }
  }

  String? get warning =>
      _disconnectWarning ??
      (_provider == SyncProvider.gdrive ? _metadataWarning : null) ??
      _storageWarnings[_provider];
  Map<SyncProvider, String> get storageWarnings =>
      Map.unmodifiable(_storageWarnings);

  bool Function() capturePublicationGuard() {
    final epoch = _workflowEpoch;
    final issued = _publicationClauses;
    // Retain this workflow's actual admission object. Later genuine clauses
    // may be added to it; a later workflow never replaces this captured object.
    return () =>
        !_disposed &&
        epoch == _workflowEpoch &&
        (issued?.every((guard) => guard()) ?? true);
  }

  void _checkWorkflow() {
    final guard = Zone.current[_workflowKey] as bool Function()?;
    if (_disposed ||
        guard?.call() == false ||
        _publicationGuard?.call() == false) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  Future<T> _workflow<T>(Future<T> Function() action, {bool oauth = false}) {
    final inherited = Zone.current[_workflowKey] as bool Function()?;
    final protected = _provider == SyncProvider.dropbox
        ? _dropboxAuth.hasWorkflowOwner
        : _gdriveAuth.hasWorkflowOwner;
    if (inherited != null) {
      _checkWorkflow();
      if (!oauth || !protected) return action();
      Future<T> child() {
        final credential = _provider == SyncProvider.dropbox
            ? _dropboxAuth.requests.guard
            : _gdriveAuth.requests.guard;
        bool owned() => inherited() && credential();
        _publicationGuard = owned;
        _publicationClauses!.add(owned);
        return runZoned(() async {
          _checkWorkflow();
          final result = await action();
          _checkWorkflow();
          return result;
        }, zoneValues: {_workflowKey: owned});
      }

      return _provider == SyncProvider.dropbox
          ? _dropboxAuth.requests.run(child)
          : _gdriveAuth.requests.run(child);
    }
    final epoch = ++_workflowEpoch;
    _acknowledgedPreferenceWrites = 0;
    final provider = _provider;
    bool current() =>
        !_disposed &&
        epoch == _workflowEpoch &&
        (!oauth || provider == _provider);
    Future<T> run() => runZoned(() async {
      final credential = oauth && protected
          ? (provider == SyncProvider.dropbox
                ? _dropboxAuth.requests.guard
                : _gdriveAuth.requests.guard)
          : (() => true);
      bool owned() => current() && credential();
      _publicationGuard = owned;
      _publicationClauses = [owned];
      return runZoned(() async {
        _checkWorkflow();
        final value = await action();
        _checkWorkflow();
        return value;
      }, zoneValues: {_workflowKey: owned});
    });
    if (!oauth || !protected) return run();
    return provider == SyncProvider.dropbox
        ? _dropboxAuth.requests.run(run)
        : _gdriveAuth.requests.run(run);
  }

  SyncProvider get provider => _provider;
  SyncStatus get status => _status;
  String? get lastError => _lastError;
  int? get lastSyncTime => _lastSyncTime;
  List<SyncConflict> get conflicts => _conflicts;
  Map<String, dynamic>? get accountInfo => _accountInfo;
  bool get autoSyncEnabled => _autoSyncEnabled;
  int get autoSyncMessageCount => _autoSyncMessageCount;
  bool get isSyncing => _status == SyncStatus.syncing;
  bool get operationInProgress => _operationInProgress;
  bool get isDiagnosingConflicts => _isDiagnosingConflicts;
  bool get hasConflicts => _conflicts.isNotEmpty;

  String? get gdriveFolderId {
    if (_provider != SyncProvider.gdrive) return null;
    final adapter = _adapter;
    if (adapter is GDriveAdapter) {
      return adapter.glazeFolderId;
    }
    return null;
  }

  Future<String?> resolveGDriveFolderId() async {
    return _withAdapterOperation(_resolveGDriveFolderId);
  }

  Future<String?> _resolveGDriveFolderId() async {
    if (_provider != SyncProvider.gdrive) return null;
    final adapter = _adapter;
    if (adapter is GDriveAdapter) {
      final folder = await _workflow(adapter.getGlazeFolderId, oauth: true);
      _checkWorkflow();
      if (_gdriveAuth.usesNativeCustody) await _saveTokens();
      _checkWorkflow();
      return folder;
    }
    return null;
  }

  SyncService({
    required this._characterRepo,
    required this._chatRepo,
    required this._personaRepo,
    required this._presetRepo,
    required this._apiRepo,
    required this._memoryBookRepo,
    required this._lorebookRepo,
    required this._embeddingRepo,
    required this._imageStorage,
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
    required SessionDeletionStore sessionDeletionStore,
    required CharacterDeletionStore characterDeletionStore,
    required Future<void> Function(LorebookActivations) saveLorebookActivations,
    Future<void> Function(Set<String>)? reconcilePulledSessions,
    Future<String> Function(String)? diagnosticDownload,
    CloudAdapter Function(SyncProvider)? selectAdapter,
    ReconciliationPageCache? reconciliationPageCache,
    DropboxAuth? dropboxAuth,
    GDriveAuth? gdriveAuth,
    Future<SharedPreferences>? originalPreferences,
    SecretRedactionCoordinator? redaction,
  }) : _sessionDeletionStore = sessionDeletionStore,
       _characterDeletionStore = characterDeletionStore,
       _saveLorebookActivations = saveLorebookActivations,
       _reconcilePulledSessions = reconcilePulledSessions,
       _diagnosticDownload = diagnosticDownload,
       _selectAdapter = selectAdapter,
       _reconciliationPageCache = reconciliationPageCache,
       _dropboxAuth = dropboxAuth ?? DropboxAuth(),
       _gdriveAuth = gdriveAuth ?? GDriveAuth(),
       _originalPreferences = originalPreferences,
       _redaction = redaction ?? SecretRedactionCoordinator();

  CloudAdapter get _adapter {
    final selector = _selectAdapter;
    if (selector != null) return selector(_provider);
    switch (_provider) {
      case SyncProvider.dropbox:
        return DropboxAdapter(_dropboxAuth);
      case SyncProvider.gdrive:
        return GDriveAdapter(_gdriveAuth);
    }
  }

  SyncManifestBuilder get _manifestBuilder => SyncManifestBuilder(
    checkCurrent: _checkWorkflow,
    characterRepo: _characterRepo,
    chatRepo: _chatRepo,
    personaRepo: _personaRepo,
    presetRepo: _presetRepo,
    apiRepo: _apiRepo,
    memoryBookRepo: _memoryBookRepo,
    lorebookRepo: _lorebookRepo,
    themePresetRepo: _themePresetRepo,
    extensionPresetRepo: _extensionPresetRepo,
    extensionsSettingsStore: _extensionsSettingsStore,
    infoBlockStore: _infoBlockStore,
    trackerSnapshotStore: _trackerSnapshotStore,
    trackerValueStore: _trackerValueStore,
    studioConfigStore: _studioConfigStore,
    studioPresetStore: _studioPresetStore,
    chatSummaryStore: _chatSummaryStore,
    characterFolderStore: _characterFolderStore,
    memoryGraphStore: _memoryGraphStore,
    memoryEventRegistryStore: _memoryEventRegistryStore,
    characterKnowledgeStore: _characterKnowledgeStore,
    sessionLorebookOverlayStore: _sessionLorebookOverlayStore,
    reconciliationStateStore: _reconciliationStateStore,
    rewriteJobHistoryStore: _rewriteJobHistoryStore,
    imageStore: _imageStorage,
  );

  SyncEngine get _engine => SyncEngine(
    _adapter,
    _manifestBuilder,
    _characterRepo,
    _chatRepo,
    _personaRepo,
    _presetRepo,
    _apiRepo,
    _memoryBookRepo,
    _lorebookRepo,
    _embeddingRepo,
    _imageStorage,
    _themePresetRepo,
    _extensionPresetRepo,
    _extensionsSettingsStore,
    _infoBlockStore,
    _trackerSnapshotStore,
    _trackerValueStore,
    _studioConfigStore,
    _studioPresetStore,
    _chatSummaryStore,
    _characterFolderStore,
    _memoryGraphStore,
    _characterKnowledgeStore,
    _sessionDeletionStore,
    _characterDeletionStore,
    _saveLorebookActivations,
    _reconciliationStateStore,
    _sessionLorebookOverlayStore,
    _reconcilePulledSessions,
    300,
    const Duration(seconds: 2),
    _rewriteJobHistoryStore,
    _checkWorkflow,
    _reconciliationPageCache,
    _memoryEventRegistryStore,
  );

  Future<void> init() async {
    await _withAdapterOperation(_init);
  }

  Future<void> _init() async {
    final prefs =
        await (_originalPreferences ?? TrackedSharedPreferences.getInstance());
    _checkWorkflow();
    final providerStr = prefs.getString('gz_sync_provider');
    if (providerStr == 'gdrive') _provider = SyncProvider.gdrive;
    _autoSyncEnabled = prefs.getBool('gz_sync_auto') ?? false;
    _autoSyncMessageCount = prefs.getInt('gz_sync_auto_count') ?? 5;
    _lastSyncTime = prefs.getInt('gz_sync_last');

    if (_gdriveAuth.usesNativeCustody) {
      try {
        final tokensRaw = prefs.getString('gz_sync_tokens');
        if (tokensRaw != null) {
          final tokens = jsonDecode(tokensRaw) as Map<String, dynamic>;
          _gdriveAuth.loadTokens(tokens);
        }
      } catch (_) {
        _metadataWarning =
            'Google Drive metadata unavailable; reconnect explicitly';
      }
    }

    if (_dropboxAuth.hasWorkflowOwner || _gdriveAuth.hasWorkflowOwner) {
      for (final provider in SyncProvider.values) {
        try {
          if (provider == SyncProvider.dropbox) {
            await _dropboxAuth.restoreTokens();
          } else {
            await _gdriveAuth.restoreTokens();
          }
          _checkWorkflow();
          _storageWarnings.remove(provider);
        } catch (_) {
          _checkWorkflow();
          _storageWarnings[provider] = provider == SyncProvider.dropbox
              ? 'Dropbox protected credentials unavailable; reconnect explicitly'
              : 'Google Drive protected credentials unavailable; reconnect explicitly';
        }
      }
    }

    await _gdriveAuth.restoreNativeSession();
    _checkWorkflow();

    if (!_storageWarnings.containsKey(_provider)) {
      try {
        await _workflow(() async {
          final info = await _adapter.getAccountInfo();
          _checkWorkflow();
          _accountInfo = info;
        }, oauth: true);
      } catch (_) {
        _checkWorkflow();
      }
    }
  }

  Future<void> setProvider(SyncProvider p) async {
    await _withAdapterOperation(() => _setProvider(p));
  }

  Future<void> _setProvider(SyncProvider p) async {
    _provider = p;
    final prefs = await SharedPreferences.getInstance();
    _checkWorkflow();
    await _writePreference(() => prefs.setString('gz_sync_provider', p.name));
    _checkWorkflow();
    await _workflow(() async {
      final info = await _adapter.getAccountInfo();
      _checkWorkflow();
      _accountInfo = info;
    }, oauth: true);
  }

  Future<void> fullPush({
    void Function(SyncProgress)? onProgress,
    bool? includeApiKeys,
  }) async {
    if (_operationInProgress) {
      throw StateError('Sync operation already in progress');
    }
    _operationInProgress = true;
    try {
      await _withSyncForeground(() async {
        _status = SyncStatus.syncing;
        _lastError = null;

        try {
          final engine = _engine;
          await engine.pushEntities(
            onProgress: onProgress ?? (_) {},
            includeApiKeys: includeApiKeys,
          );
          _checkWorkflow();
          _lastSyncTime = DateTime.now().millisecondsSinceEpoch;
          final prefs = await SharedPreferences.getInstance();
          _checkWorkflow();
          await _writePreference(
            () => prefs.setInt('gz_sync_last', _lastSyncTime!),
          );
          _checkWorkflow();
          _status = SyncStatus.idle;
        } catch (e) {
          if (e is CloudOAuthRetiredCommit) rethrow;
          _checkWorkflow();
          _lastError = e.toString();
          _status = SyncStatus.error;
          rethrow;
        }
      });
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> fullPull({void Function(SyncProgress)? onProgress}) async {
    if (_operationInProgress) {
      throw StateError('Sync operation already in progress');
    }
    _operationInProgress = true;
    try {
      await _withSyncForeground(() async {
        _status = SyncStatus.syncing;
        _lastError = null;
        _conflicts.clear();
        _resolvedAsCloud.clear();
        _resolvedAsLocal = false;

        try {
          final engine = _engine;
          await engine.pullEntities(
            onProgress: onProgress ?? (_) {},
            onConflict: (c) {
              _checkWorkflow();
              if (_conflicts.every((existing) => existing.key != c.key)) {
                _conflicts.add(c);
              }
            },
          );
          _checkWorkflow();
          if (_conflicts.isNotEmpty) {
            _status = SyncStatus.conflict;
          } else {
            _lastSyncTime = DateTime.now().millisecondsSinceEpoch;
            final prefs = await SharedPreferences.getInstance();
            _checkWorkflow();
            await _writePreference(
              () => prefs.setInt('gz_sync_last', _lastSyncTime!),
            );
            _checkWorkflow();
            _status = SyncStatus.idle;
          }
        } catch (e) {
          if (e is CloudOAuthRetiredCommit) rethrow;
          _checkWorkflow();
          _lastError = e.toString();
          _status = SyncStatus.error;
          rethrow;
        }
      });
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> fullSync({
    void Function(SyncProgress)? onProgress,
    bool? includeApiKeys,
  }) async {
    if (_operationInProgress)
      throw StateError('Sync operation already in progress');
    await _workflow(() async {
      await fullPush(onProgress: onProgress, includeApiKeys: includeApiKeys);
      _checkWorkflow();
      if (_status != SyncStatus.error) await fullPull(onProgress: onProgress);
    }, oauth: true);
  }

  Future<void> wipeCloudData({void Function(SyncProgress)? onProgress}) async {
    await _withAdapterOperation(() => _wipeCloudData(onProgress: onProgress));
  }

  Future<void> _wipeCloudData({void Function(SyncProgress)? onProgress}) async {
    if (_status == SyncStatus.syncing) return;
    await _withSyncForeground(() async {
      _status = SyncStatus.syncing;
      _lastError = null;

      try {
        final engine = _engine;
        await engine.wipeCloudData(onProgress: onProgress ?? (_) {});
        _checkWorkflow();
        await _manifestBuilder.clearLocalManifest();
        _checkWorkflow();
        _conflicts.clear();
        _resolvedAsCloud.clear();
        _status = SyncStatus.idle;
      } catch (e) {
        if (e is CloudOAuthRetiredCommit) rethrow;
        _checkWorkflow();
        _lastError = e.toString();
        _status = SyncStatus.error;
        rethrow;
      }
    });
  }

  Future<void> resolveAllConflicts(String choice) async {
    _rejectDuringDiagnosis();
    if (_conflicts.isEmpty) return;
    final conflicts = List<SyncConflict>.from(_conflicts);
    try {
      if (choice == 'cloud') {
        _resolvedAsCloud.addAll(
          conflicts
              .map((conflict) => conflict.key)
              .where((key) => !_resolvedAsCloud.contains(key)),
        );
      } else {
        _resolvedAsLocal = true;
      }
      _conflicts.clear();
    } catch (e) {
      _lastError = e.toString();
      _status = SyncStatus.error;
      rethrow;
    }
  }

  Future<void> resolveAllConflictsAndApply(
    String choice, {
    required void Function(SyncProgress) onProgress,
  }) async {
    if (_operationInProgress) {
      throw StateError('Sync operation already in progress');
    }
    _operationInProgress = true;
    try {
      await _withSyncForeground(() async {
        _status = SyncStatus.syncing;
        _lastError = null;
        final conflicts = List<SyncConflict>.from(_conflicts);
        if (choice == 'cloud') {
          _resolvedAsCloud.addAll(
            conflicts
                .map((conflict) => conflict.key)
                .where((key) => !_resolvedAsCloud.contains(key)),
          );
        } else {
          _resolvedAsLocal = true;
        }
        _conflicts.clear();

        try {
          await _engine.applyPendingPull(
            onProgress: onProgress,
            resolvedAsCloud: _resolvedAsCloud.isNotEmpty
                ? List.from(_resolvedAsCloud)
                : null,
            pushLocalChanges: _resolvedAsLocal,
          );
          _checkWorkflow();
          _resolvedAsCloud.clear();
          _resolvedAsLocal = false;
          _lastSyncTime = DateTime.now().millisecondsSinceEpoch;
          final prefs = await SharedPreferences.getInstance();
          _checkWorkflow();
          await _writePreference(
            () => prefs.setInt('gz_sync_last', _lastSyncTime!),
          );
          _checkWorkflow();
          _status = SyncStatus.idle;
        } catch (e) {
          if (e is CloudOAuthRetiredCommit) rethrow;
          _checkWorkflow();
          _lastError = e.toString();
          _status = SyncStatus.error;
          rethrow;
        }
      });
    } finally {
      _operationInProgress = false;
    }
  }

  /// Records the conflict resolution choice (updates manifest, tracks
  /// cloud-resolved keys). Does NOT trigger a pull — call [applyPendingPull]
  /// once all conflicts have been resolved.
  Future<void> resolveConflict(SyncConflict conflict, String choice) async {
    if (_operationInProgress) {
      throw StateError('Sync operation already in progress');
    }
    _operationInProgress = true;
    bool Function()? issued;
    try {
      final pending = _workflow(
        () => _engine.resolveConflict(conflict, choice),
        oauth: true,
      );
      issued = capturePublicationGuard();
      await pending;
      if (!issued()) throw const CredentialVaultAdmissionDenied();
      if (choice == 'cloud') {
        _resolvedAsCloud.add(conflict.key);
      } else {
        _resolvedAsLocal = true;
      }
      _conflicts.removeWhere((c) => c.key == conflict.key);
    } catch (e) {
      if (e is CloudOAuthRetiredCommit) rethrow;
      if (_disposed || issued?.call() == false) rethrow;
      _lastError = e.toString();
      _status = SyncStatus.error;
      rethrow;
    } finally {
      _operationInProgress = false;
    }
  }

  /// Applies the pending pull after all conflicts have been resolved.
  /// Should be called by the controller once [conflicts] is empty.
  Future<void> applyPendingPullAfterResolve({
    required void Function(SyncProgress) onProgress,
  }) async {
    if (_operationInProgress) {
      throw StateError('Sync operation already in progress');
    }
    _operationInProgress = true;
    try {
      await _withSyncForeground(() async {
        try {
          _status = SyncStatus.syncing;
          await _engine.applyPendingPull(
            onProgress: onProgress,
            resolvedAsCloud: _resolvedAsCloud.isNotEmpty
                ? List.from(_resolvedAsCloud)
                : null,
            pushLocalChanges: _resolvedAsLocal,
          );
          _checkWorkflow();
          _resolvedAsCloud.clear();
          _resolvedAsLocal = false;
          _lastSyncTime = DateTime.now().millisecondsSinceEpoch;
          final prefs = await SharedPreferences.getInstance();
          _checkWorkflow();
          await _writePreference(
            () => prefs.setInt('gz_sync_last', _lastSyncTime!),
          );
          _checkWorkflow();
          _status = SyncStatus.idle;
        } catch (e) {
          if (e is CloudOAuthRetiredCommit) rethrow;
          _checkWorkflow();
          _lastError = e.toString();
          _status = SyncStatus.error;
          rethrow;
        }
      });
    } finally {
      _operationInProgress = false;
    }
  }

  Future<void> _withSyncForeground(Future<void> Function() action) async {
    await _workflow(() async {
      await GenerationNotificationService.instance.onSyncStarted();
      try {
        _checkWorkflow();
        await action();
        _checkWorkflow();
      } finally {
        await GenerationNotificationService.instance.onSyncFinished();
      }
    }, oauth: true);
  }

  Future<void> connectDropbox() async {
    await _withAdapterOperation(_connectDropbox);
  }

  Future<void> _connectDropbox() async {
    final pending = _dropboxAuth.connect();
    final credential = _dropboxAuth.captureConnectionGuard();
    final lifecycle = _publicationGuard!;
    _publicationGuard = () => lifecycle() && credential();
    _publicationClauses!.add(credential);
    await pending;
    _checkWorkflow();
    if (!credential()) throw const CredentialVaultAdmissionDenied();
    _storageWarnings.remove(SyncProvider.dropbox);
    _disconnectWarning = null;
    final info = await _adapter.getAccountInfo();
    _checkWorkflow();
    _accountInfo = info;
  }

  Future<void> connectGDrive() async {
    await _withAdapterOperation(_connectGDrive);
  }

  Future<void> _connectGDrive() async {
    final pending = _gdriveAuth.connect();
    final credential = _gdriveAuth.captureConnectionGuard();
    final lifecycle = _publicationGuard!;
    _publicationGuard = () => lifecycle() && credential();
    _publicationClauses!.add(credential);
    await pending;
    _checkWorkflow();
    if (!credential()) throw const CredentialVaultAdmissionDenied();
    _storageWarnings.remove(SyncProvider.gdrive);
    _disconnectWarning = null;
    await _saveTokens();
    _checkWorkflow();
    final info = await _adapter.getAccountInfo();
    _checkWorkflow();
    _accountInfo = info;
  }

  Future<void> disconnect() async {
    await _withAdapterOperation(_disconnect);
  }

  Future<void> _disconnect() async {
    late Future<CloudOAuthDisconnectOutcome> pending;
    switch (_provider) {
      case SyncProvider.dropbox:
        pending = _dropboxAuth.disconnect();
        break;
      case SyncProvider.gdrive:
        pending = _gdriveAuth.disconnect();
        break;
    }
    final credential = _provider == SyncProvider.dropbox
        ? _dropboxAuth.requests.captureGuard()
        : _gdriveAuth.requests.captureGuard();
    final lifecycle = _publicationGuard!;
    _publicationGuard = () => lifecycle() && credential();
    _publicationClauses!.add(credential);
    final result = await pending;
    _checkWorkflow();
    _disconnectWarning = result.warning;
    _accountInfo = null;
    _conflicts.clear();
    _resolvedAsCloud.clear();
    _lastSyncTime = null;
    _status = SyncStatus.idle;
    await _manifestBuilder.clearLocalManifest();
    _checkWorkflow();
    if (_provider == SyncProvider.gdrive) await _saveTokens();
  }

  Future<void> setAutoSync(bool enabled, {int messageCount = 5}) async {
    await _withAdapterOperation(() => _setAutoSync(enabled, messageCount));
  }

  Future<void> _setAutoSync(bool enabled, int messageCount) async {
    _autoSyncEnabled = enabled;
    _autoSyncMessageCount = messageCount;
    final prefs = await SharedPreferences.getInstance();
    _checkWorkflow();
    await _writePreference(() => prefs.setBool('gz_sync_auto', enabled));
    _checkWorkflow();
    await _writePreference(
      () => prefs.setInt('gz_sync_auto_count', messageCount),
    );
    _checkWorkflow();
  }

  Future<void> incrementMessageCounter() async {
    if (_isDiagnosingConflicts) return;
    if (!_autoSyncEnabled) return;
    _messageCounter++;
    if (_messageCounter >= _autoSyncMessageCount) {
      _messageCounter = 0;
      await fullPush();
    }
  }

  Future<bool> tryAutoPush() async {
    if (_operationInProgress || hasConflicts || !isConnected()) return false;
    await fullPush();
    return true;
  }

  bool isConnected() {
    switch (_provider) {
      case SyncProvider.dropbox:
        return _dropboxAuth.isConnected;
      case SyncProvider.gdrive:
        return _gdriveAuth.isConnected;
    }
  }

  Future<T> _withAdapterOperation<T>(Future<T> Function() action) async {
    if (_disposed) throw StateError('Cloud sync owner retired');
    if (_operationInProgress) {
      throw StateError('Sync operation already in progress');
    }
    _operationInProgress = true;
    try {
      return await _workflow(action);
    } finally {
      _operationInProgress = false;
    }
  }

  void _rejectDuringDiagnosis() {
    if (_isDiagnosingConflicts) {
      throw StateError('Sync diagnostic operation already in progress');
    }
  }

  /// No DB/manifest/preferences writes. Only the selected read-only capability
  /// is allowed; unsupported adapters are refused before any local reads.
  Future<SyncConflictDiagnosticReport> diagnoseConflicts(
    List<SyncConflict> conflicts,
  ) async {
    if (_operationInProgress) {
      throw StateError('Sync operation already in progress');
    }
    _operationInProgress = true;
    _isDiagnosingConflicts = true;
    try {
      return await _workflow(() async {
        final downloader = SyncConflictDiagnosticDownload(_adapter);
        if (!downloader.supported) {
          return await SyncConflictDiagnostics(
            readLocal: (_, _) => throw const SyncDiagnosticAdapterUnsupported(),
            download: downloader.download,
            adapterSupported: false,
          ).diagnose(conflicts);
        }
        return await _engine.diagnoseConflicts(
          conflicts,
          diagnosticDownload: _diagnosticDownload ?? downloader.download,
        );
      }, oauth: true);
    } catch (_) {
      return SyncConflictDiagnosticReport(
        status: SyncDiagnosticStatus.unavailable,
      );
    } finally {
      _isDiagnosingConflicts = false;
      _operationInProgress = false;
    }
  }

  Future<void> _saveTokens() async {
    // Each persisted OAuth owner already verified its atomic secure record.
    // Mobile Google retains the SDK and its original metadata-only semantics.
    if (!_gdriveAuth.usesNativeCustody) return;
    _checkWorkflow();
    final original = capturePublicationGuard();
    try {
      final result = await saveCloudOAuthMobileMetadata(
        originalPreferences:
            _originalPreferences ?? TrackedSharedPreferences.getInstance(),
        connected: _gdriveAuth.isConnected,
        folderId: _gdriveAuth.folderId,
        redaction: _redaction,
        isCurrent: original,
      );
      result.requireCurrent(original);
      _checkWorkflow();
      _metadataWarning = null;
    } catch (error) {
      if (error is CloudOAuthRetiredCommit) rethrow;
      _checkWorkflow();
      // SDK success is independent of a refused legacy-document metadata save.
      _metadataWarning =
          'Google Drive connected state retained; metadata could not be saved';
    }
  }

  void dispose() {
    _disposed = true;
    _dropboxAuth.dispose();
    _gdriveAuth.dispose();
  }
}
