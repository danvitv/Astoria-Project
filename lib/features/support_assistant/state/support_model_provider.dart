import 'dart:async';

import 'package:dio/dio.dart';
import 'package:dio/io.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/state/connection_revision_provider.dart';
import '../../../core/state/credential_vault_provider.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/db/repositories/support_text_context_repo.dart';
import '../../../core/llm/transport/native_provider_transport.dart';
import '../../../core/llm/transport/native_tool_transport.dart';
import '../services/support_model_service.dart';
import 'support_model_dependencies.dart';
import 'support_model_ui_bridge.dart';
import 'support_native_provider.dart';
import 'support_app_control_provider.dart';

export 'support_model_ui_bridge.dart';

/// Native private adapter seam. No shared Dio/interceptors/logger/capture/hooks.
/// Constructed only by actual once-approved dispatch; no startup/model probing.
final supportModelPrivateAdapterFactoryProvider =
    Provider<HttpClientAdapter Function()>(
      (ref) =>
          () => IOHttpClientAdapter(),
    );

final supportModelUiBridgeProvider = Provider<SupportModelUiBridge>((ref) {
  final db = ref.watch(appDbProvider);
  final cipher = ref.watch(supportPayloadCipherProvider);
  final api = ref.watch(apiConfigRepoProvider);
  final native = ref.watch(nativeProviderRuntimeProvider);
  final revisions = ref.watch(connectionRevisionRegistryProvider);
  final redaction = ref.watch(secretRedactionCoordinatorProvider);
  final snapshot = ref.watch(secretRedactorProvider);
  final runtime = ref.watch(supportNativeRuntimeProvider);
  // Controller replacement must retire this issuer even on the same runtime.
  ref.watch(supportNativeConsentControllerProvider);
  final workspace = ref.watch(supportModelWorkspaceBindingProvider);
  final custody = ref.watch(supportModelDatabaseCustodyProvider);
  final adapterFactory = ref.watch(supportModelPrivateAdapterFactoryProvider);
  // Native tools cannot fall back to a saved row key. Legacy text-only fixture
  // compositions need not construct any additional application capability graph.
  var alive = true;
  bool current() =>
      alive &&
      custody.alive &&
      (native?.isCurrent ?? true) &&
      identical(snapshot, redaction.redactor);
  late final SupportModelUiBridge bridge;
  final service = SupportModelService(
    db: db,
    writeCipher: cipher,
    apiRepo: api,
    revisions: revisions,
    redaction: redaction,
    runtime: runtime,
    adapterFactory: adapterFactory,
    isOwnerCurrent: current,
    writes: custody,
    // Resolve ONCE only after this original native saved source was prepared.
    // Legacy text-only fixtures never evaluate the application action graph.
    appActionsFactory: native == null
        ? null
        : () {
            if (!current() || !ref.mounted) {
              throw StateError('Original model owner retired.');
            }
            return ref.read(supportAppActionRegistryProvider);
          },
    toolTransport: native == null
        ? null
        : NativeToolTransport(
            credentials: native.credentials,
            authIssuer: native.auth,
            mutations: native.mutations,
            routes: native.routes,
            currentRedactor: () => redaction.redactor,
            adapterFactory: adapterFactory,
          ),
    nativeSources: native?.sources,
    nativeMetadata: native?.credentialReader,
    nativeDispatcher: native == null
        ? null
        : (inner) => NativeProviderPrivateTextDispatcher(
            credentials: native.credentials,
            authIssuer: native.auth,
            mutations: native.mutations,
            routes: native.routes,
            privateTextTransport: inner,
          ),
    // AppDatabase's stock single background NativeDatabase, no pool/reconnect or
    // busy-handler setup. Emission/preparation initialize it before preview; the
    // FIFO callbacks await outside transactions. Unknown injected owners must
    // not use this native composition contract.
    admissionContract:
        SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
    onMessage: (message) => bridge.onMessage(message),
    onPhase: (phase) => bridge.onPhase(phase),
  );
  bridge = SupportModelUiBridge(
    service: service,
    runtime: runtime,
    workspace: workspace,
    isOwnerCurrent: current,
  );
  custody.retain(service);
  ref.onDispose(() {
    alive = false;
    bridge.dispose();
    unawaited(bridge.drained.then((_) => custody.release(service)));
  });
  return bridge;
});

/// Only safe run presentation. No tool authority or raw transport/config state.
class SupportModelRunViewNotifier extends Notifier<SupportModelRunView> {
  Object? _owner;
  @override
  SupportModelRunView build() {
    final bridge = ref.watch(supportModelUiBridgeProvider);
    final owner = Object();
    _owner = owner;
    var active = true, queued = false;
    final stop = bridge.listen(() {
      if (!active || queued) return;
      queued = true;
      // Runtime/provider/workspace retirement can occur during another build.
      // Coalesce presentation only; cancellation itself is always synchronous.
      scheduleMicrotask(() {
        queued = false;
        if (active && identical(_owner, owner) && ref.mounted) {
          state = bridge.view;
        }
      });
    });
    ref.onDispose(() {
      active = false;
      stop();
    });
    return bridge.view;
  }
}

final supportModelRunViewProvider =
    NotifierProvider<SupportModelRunViewNotifier, SupportModelRunView>(
      SupportModelRunViewNotifier.new,
    );
