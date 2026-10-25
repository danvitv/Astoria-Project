import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/db_provider.dart';
import '../../../core/state/character_folder_provider.dart';
import '../../../core/state/preset_folder_provider.dart';
import '../../../core/state/character_provider.dart';
import '../../chat/chat_session_service.dart';
import '../../chat/state/chat_native_owner_registry.dart';
import '../../chat/state/chat_session_write_queue.dart';
import '../../chat/state/agent_ops_jobs_provider.dart';
import '../../chat/generating_sessions_provider.dart';
import '../../memory/state/memory_active_drafts_provider.dart';
import '../../memory/state/memory_draft_jobs_provider.dart';
import '../../chat/services/collector_view_service.dart';
import '../../chat/services/reconciler_view_service.dart';
import '../../chat/services/prompt_capture_view_service.dart';
import '../../chat/services/current_ledger_injection_preview_service.dart';
import '../../chat_history/chat_history_provider.dart';
import '../../presets/preset_list_provider.dart';
import '../../extensions/providers/info_blocks_provider.dart';
import '../services/app_control/support_app_repair_runtime.dart';
import '../models/support_app_action.dart';
import '../services/app_control/native/support_native_session_maintenance_owner.dart';

/// Constructor-only native owner. It never reads/builds a target ChatNotifier.
final supportAppNativeRepairPortProvider = Provider<SupportAppNativeRepairPort>(
  (ref) {
    final native = ref.watch(nativeProviderRuntimeProvider);
    final owners = ref.watch(chatNativeOwnerRegistryProvider);
    var alive = true;
    ref.onDispose(() => alive = false);
    final port = SupportAppNativeRepairPort(
      ref,
      owners,
      () => alive && ref.mounted && native != null && native.isCurrent,
      maintenance: native == null
          ? null
          : SupportNativeSessionMaintenanceOwners(
              db: ref.watch(appDbProvider),
              chats: ref.watch(chatRepoProvider),
              owners: owners,
              original: () => alive && ref.mounted && native.isCurrent,
              captureJobInventory: (_) => _captureNativeJobInventory(ref),
            ),
    );
    ref.onDispose(() => port.maintenance?.dispose());
    return port;
  },
);

/// Read ONLY actual already-loaded process-local native job inventories. Absent
/// providers are not warmed. A new owner/state, loading/error or unknown busy
/// key retires the exact captured inventory; no status is guessed from JSON.
bool Function()? _captureNativeJobInventory(Ref ref) {
  try {
    final generating = ref.exists(generatingSessionsProvider)
        ? ref.read(generatingSessionsProvider)
        : null;
    final activeDrafts = ref.exists(memoryActiveDraftsProvider)
        ? ref.read(memoryActiveDraftsProvider)
        : null;
    final drafts = ref.exists(memoryDraftJobsProvider)
        ? ref.read(memoryDraftJobsProvider)
        : null;
    final agentOps = ref.exists(agentOpsJobsProvider)
        ? ref.read(agentOpsJobsProvider)
        : null;
    if (generating?.isNotEmpty == true ||
        activeDrafts?.isNotEmpty == true ||
        drafts?.jobs.isNotEmpty == true ||
        agentOps?.isNotEmpty == true)
      return null;
    return () {
      if (!ref.mounted) return false;
      try {
        return ref.exists(generatingSessionsProvider) == (generating != null) &&
            (!ref.exists(generatingSessionsProvider) ||
                identical(ref.read(generatingSessionsProvider), generating)) &&
            ref.exists(memoryActiveDraftsProvider) == (activeDrafts != null) &&
            (!ref.exists(memoryActiveDraftsProvider) ||
                identical(
                  ref.read(memoryActiveDraftsProvider),
                  activeDrafts,
                )) &&
            ref.exists(memoryDraftJobsProvider) == (drafts != null) &&
            (!ref.exists(memoryDraftJobsProvider) ||
                identical(ref.read(memoryDraftJobsProvider), drafts)) &&
            ref.exists(agentOpsJobsProvider) == (agentOps != null) &&
            (!ref.exists(agentOpsJobsProvider) ||
                identical(ref.read(agentOpsJobsProvider), agentOps));
      } catch (_) {
        return false;
      }
    };
  } catch (_) {
    return null;
  }
}

final class SupportAppNativeRepairPort
    implements SupportAppRepairNativePort, SupportAppRepairQueueResolutionPort {
  SupportAppNativeRepairPort(
    this.ref,
    this.owners,
    this.original, {
    this.maintenance,
  });
  final Ref ref;
  final ChatNativeOwnerRegistry owners;
  final bool Function() original;
  final SupportNativeSessionMaintenanceOwners? maintenance;

  /// Read fence only: retain already-loaded job inventories without warming a
  /// controller/provider, manufacturing a queue, or admitting a source effect.
  bool Function()? captureAnalysisReadGuard() {
    if (!isCurrent) return null;
    final jobs = _captureNativeJobInventory(ref);
    return jobs == null ? null : () => isCurrent && jobs();
  }

  @override
  bool get isCurrent => original() && owners.isCurrent;
  @override
  ChatSessionWriteQueue? existingQueue(String id) => isCurrent
      ? owners.existing(id)?.queue ?? maintenance?.existing(id)?.queue
      : null;
  @override
  bool requiresMaintenanceOwner(String id) =>
      isCurrent && owners.existing(id) == null;
  @override
  bool isMaintenanceQueue(String id, ChatSessionWriteQueue queue) =>
      maintenance?.claimForQueue(id, queue) != null;
  @override
  ChatSessionWriteQueue? resolveRepairQueue(
    String id,
    SupportAppActionContext context,
  ) {
    if (!isCurrent) return null;
    return owners.existing(id)?.queue ??
        maintenance?.resolve(id, context)?.queue;
  }

  @override
  bool retainsRepairQueue(String id, ChatSessionWriteQueue queue) =>
      isCurrent &&
      (identical(owners.existing(id)?.queue, queue) ||
          maintenance?.claimForQueue(id, queue) != null);
  @override
  Future<bool> validateRepairQueue(
    String id,
    ChatSessionWriteQueue queue,
  ) async {
    if (!isCurrent) return false;
    if (identical(owners.existing(id)?.queue, queue)) return true;
    // The newly reserved original claim is not yet proven; existing() deliberately
    // cannot return it to other domain/session-memory effects.
    final claim = maintenance?.claimForQueue(id, queue);
    return claim != null && await claim.validateQueuedSource();
  }

  @override
  void repairQueueStarted(String id, ChatSessionWriteQueue queue) =>
      maintenance?.queuedStarted(id, queue);
  @override
  void repairQueueSettled(String id, ChatSessionWriteQueue queue) =>
      maintenance?.queuedSettled(id, queue);
  @override
  bool invalidateLatestSession(String id) {
    if (!isCurrent) return false;
    final owner = owners.existing(id);
    final character =
        owner?.characterId ?? maintenance?.existing(id)?.characterId;
    if (character == null) return false;
    ChatSessionService.clearCache(charId: character);
    ref.invalidate(chatHistoryProvider);
    ref.invalidate(collectorViewProvider(id));
    ref.invalidate(reconcilerViewProvider(id));
    ref.invalidate(promptCaptureViewsProvider(id));
    ref.invalidate(currentLedgerInjectionPreviewProvider);
    // Actual awaited native refresh follows in the composed terminal scope.
    return false;
  }

  Future<bool> refreshSession(String id, bool Function() current) async {
    if (!isCurrent || !current()) return false;
    final provider = infoBlocksProvider(id);
    final notifier = ref.exists(provider) ? ref.read(provider.notifier) : null;
    if (notifier == null) return true; // No existing InfoBlock view to refresh.
    return notifier.refreshNativeLatest(() => isCurrent && current());
  }

  @override
  bool invalidateLatestDatabaseRepair() {
    if (!isCurrent) return false;
    ChatSessionService.clearCache();
    ref.invalidate(charactersProvider);
    ref.invalidate(characterFoldersProvider);
    ref.invalidate(folderMembershipsProvider);
    ref.invalidate(presetFoldersProvider);
    ref.invalidate(presetFolderMembershipsProvider);
    ref.invalidate(presetListProvider);
    ref.invalidate(presetsListProvider);
    ref.invalidate(studioPresetListProvider);
    return true;
  }
}
