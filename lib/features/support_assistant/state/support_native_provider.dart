import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../../core/db/repositories/support_consent_selection_repo.dart';
import '../../../core/models/support_consent_selection.dart';
import '../../../core/state/connection_revision_provider.dart';
import '../../../core/state/chat_source_mutation_provider.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../models/support_native_view.dart';
import '../services/support_connection_metadata_service.dart';
import '../services/support_native_consent_controller.dart';
import '../services/support_native_runtime.dart';
import '../services/support_game_source_observer.dart';
import '../services/support_permission_store.dart';
import '../services/support_recipient_resolver.dart';
import 'support_workspace_dependencies.dart';
import 'support_model_dependencies.dart';

final supportPermissionStoreProvider = Provider(
  (ref) => SupportPermissionStore(ref.watch(supportRepoProvider)),
);
final supportConsentSelectionRepoProvider = Provider(
  (ref) => SupportConsentSelectionRepo(
    db: ref.watch(appDbProvider),
    supportRepo: ref.watch(supportRepoProvider),
    currentRedactor: () => ref.read(secretRedactorProvider),
  ),
);

/// Shared runtime for actual offline send and later native controls. No UI startup.
final supportNativeRuntimeProvider = Provider<SupportNativeRuntime>((ref) {
  final store = ref.watch(supportSessionStoreProvider);
  final permissions = ref.watch(supportPermissionStoreProvider);
  final api = ref.watch(apiConfigRepoProvider);
  final revisions = ref.watch(connectionRevisionRegistryProvider);
  final sources = ref.watch(chatSourceMutationRegistryProvider);
  final writes = ref.watch(supportModelDurableWritesProvider);
  SupportGameSourceObserver? sourceObserver;
  late final SupportNativeRuntime runtime;
  final resolver = SupportRecipientResolver(
    apiRepo: api,
    readSettings: store.readableSettingsFor,
    currentContext: () => runtime.recipientContext,
    revisions: revisions,
    redactor: () => ref.read(secretRedactorProvider),
  );
  final metadata = SupportConnectionMetadataService(
    api,
    () => ref.read(secretRedactorProvider),
  );
  runtime = SupportNativeRuntime(
    permissions: permissions,
    resolveRecipient: resolver.resolve,
    loadSelectedConnection: (id, current) => metadata.loadSelected(
      id,
      resolver,
      store.readableSettingsFor,
      isCurrent: current,
    ),
    configurationRevision: () => revisions.revision,
    configurationStable: () => revisions.isStable,
    gameSourceCheckpoint: () => sourceObserver?.reconcile(),
    gameSourceStable: () => sourceObserver?.isStable ?? true,
  );
  sourceObserver = SupportGameSourceObserver(
    registry: sources,
    runtime: runtime,
    invalidateGameSource: writes.invalidateGameSource,
  );
  final stop = revisions.subscribe(runtime.invalidateConfiguration);
  // subscribe has no initial event. Sample before exposing this native owner.
  runtime.checkConfiguration();
  ref.onDispose(() {
    sourceObserver?.dispose();
    stop();
    runtime.dispose();
  });
  return runtime;
});
final supportNativeConsentControllerProvider = Provider((ref) {
  final selectors = ref.watch(supportConsentSelectionRepoProvider);
  final runtime = ref.watch(supportNativeRuntimeProvider);
  final controller = SupportNativeConsentController(
    runtime: runtime,
    readMessages: (source, id, offset) =>
        source == SupportConsentSelectionSource.roleplay
        ? selectors.listRoleplayMessages(sessionId: id, offset: offset)
        : selectors.listSupportMessages(sessionId: id, offset: offset),
  );
  final stop = runtime.listenGameSourceRetirement(
    controller.invalidateDisplayedIntents,
  );
  ref.onDispose(() {
    stop();
    controller.invalidateDisplayedIntents();
  });
  return controller;
});

class SupportNativeViewNotifier extends Notifier<SupportNativeView> {
  Object? _owner;
  @override
  SupportNativeView build() {
    final controller = ref.watch(supportNativeConsentControllerProvider);
    final owner = Object();
    _owner = owner;
    var active = true, ready = false;
    final stop = controller.runtime.listen(() {
      if (active && ready && identical(_owner, owner) && ref.mounted) {
        state = controller.view;
      }
    });
    ref.onDispose(() {
      active = false;
      if (identical(_owner, owner)) _owner = null;
      stop();
    });
    final initial = controller.view;
    ready = true;
    return initial;
  }
}

final supportNativeViewProvider =
    NotifierProvider<SupportNativeViewNotifier, SupportNativeView>(
      SupportNativeViewNotifier.new,
    );
