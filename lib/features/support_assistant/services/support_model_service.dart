// Public native injection names intentionally initialize PRIVATE dependencies.
// ignore_for_file: prefer_initializing_formals

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../../core/credentials/connection_revision_registry.dart';
import '../../../core/credentials/native_provider_credentials.dart';
import '../../../core/credentials/secret_redaction_coordinator.dart';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/db/app_db.dart';
import '../../../core/db/repositories/api_config_repo.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../../../core/db/repositories/support_text_context_repo.dart';
import '../../../core/db/repositories/support_source_text_repo.dart';
import '../../../core/llm/transport/chat_transport_request.dart';
import '../../../core/llm/native_saved_connection_source.dart';
import '../../../core/llm/transport/native_provider_transport.dart';
import '../../../core/llm/transport/private_text_transport.dart';
import '../../../core/llm/transport/native_tool_transport.dart';
import '../../../core/models/api_config.dart';
import '../../../core/models/support_models.dart';
import '../../../core/models/support_text_context.dart';
import '../../../core/support/support_payload_cipher.dart';
import '../../../core/utils/id_generator.dart';
import '../models/support_model_provenance.dart';
import '../models/support_model_view.dart';
import '../models/support_model_tool_activity.dart';
import '../models/support_model_tool_ui_ports.dart';
import '../models/support_app_action_context.dart';
import '../models/support_app_action.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_provenance.dart';
import '../models/support_permission_scope.dart';
import '../models/support_recipient_resolution.dart';
import '../models/support_workspace_models.dart';
import 'support_authorization_service.dart';
import 'support_model_native_provenance_validator.dart';
import 'support_model_provenance_codec.dart';
import 'support_native_runtime.dart';
import 'support_permission_codec.dart';
import 'support_recipient_projection.dart';
import 'support_workspace_settings_codec.dart';
import 'support_context_policy.dart';
import 'app_control/support_app_action_registry.dart';
import 'app_control/backup/support_backup_file_host.dart';
import 'app_control/backup/support_database_backup_adapter.dart';
import 'support_model_tool_payloads.dart';
import 'support_model_tool_outcome.dart';

export '../models/support_model_view.dart';
export '../models/support_model_tool_ui_ports.dart';
export '../models/support_model_tool_activity.dart';

part 'support_model_native_intent.dart';
part 'support_model_read_service.dart';
part 'support_model_configuration_service.dart';
part 'support_model_context_service.dart';
part 'support_model_direct_conversation.dart';
part 'support_model_run_service.dart';
part 'support_model_compaction_service.dart';
part 'support_model_compacted_recipe.dart';
part 'support_model_tool_loop.dart';
part 'support_model_reply_regeneration.dart';
part 'support_model_unanswered_retry.dart';
part 'support_model_source_tool_run.dart';
part 'support_model_tool_activity.dart';

/// Native-only write scheduling seam; NEVER expose this service/scheduler to
/// tools. HTTP and user-controlled preview are never enqueued here.
abstract interface class SupportModelWriteScheduler {
  Future<T> enqueue<T>(Future<T> Function() write);
}

final class SupportModelWriteQueue implements SupportModelWriteScheduler {
  Future<void> _tail = Future<void>.value();
  @override
  Future<T> enqueue<T>(Future<T> Function() write) {
    final result = _tail.then((_) => write());
    _tail = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }
}

/// Inject one source-audited stable initialized DB/registry/coordinator owner.
/// No Ref/global/default DB/vault/transport lookup. This is a native issuer, not
/// a public model tool port. Parent UI must bind the ACTUALLY emitted composer
/// controller/lifetime/draft revision through isEmitterCurrent, not reconstruct
/// a replacement after awaits. Call dispose explicitly on screen/provider exit.
final class SupportModelService {
  SupportModelService({
    required AppDatabase db,
    required SupportPayloadCipher writeCipher,
    required ApiConfigRepo apiRepo,
    required ConnectionRevisionRegistry revisions,
    required SecretRedactionCoordinator redaction,
    required SupportNativeRuntime runtime,
    required HttpClientAdapter Function() adapterFactory,
    required bool Function() isOwnerCurrent,
    required SupportModelWriteScheduler writes,
    NativeSavedConnectionSourceResolver? nativeSources,
    NativeProviderCredentialMetadataReader? nativeMetadata,
    NativeProviderPrivateTextDispatcher Function(PrivateTextTransport)?
    nativeDispatcher,
    SupportTextAdmissionContract? admissionContract,
    NativeToolTransport? toolTransport,
    SupportAppActionRegistry? appActions,
    SupportSourceTextRepo? sourceRepo,
    Future<String> Function()? activeStudioPresetId,
    SupportAppActionRegistry Function()? appActionsFactory,
    SupportAppActionRegistry Function(SupportDatabaseBackupAdapter)?
    appActionsWithBackupFactory,
    String Function()? newId,
    int Function()? now,
    Timer Function(Duration, void Function()) scheduleTimer = Timer.new,
    Duration readDeadline = const Duration(seconds: 5),
    Duration deadline = PrivateTextLimits.deadline,
    void Function(SupportModelMessage)? onMessage,
    void Function(SupportModelPhase)? onPhase,
    void Function(String runId, String sessionId, SupportModelToolActivity)?
    onToolActivity,
  }) : _db = db,
       _writeCipher = writeCipher,
       _apiRepo = apiRepo,
       _revisions = revisions,
       _redaction = redaction,
       _runtime = runtime,
       _adapterFactory = adapterFactory,
       _isOwnerCurrent = isOwnerCurrent,
       _writes = writes,
       _nativeSources = nativeSources,
       _nativeMetadata = nativeMetadata,
       _nativeDispatcher = nativeDispatcher,
       _admissionContract = admissionContract,
       _toolTransport = toolTransport,
       _appActions = appActions,
       _sourceRepo = sourceRepo,
       _activeStudioPresetId = activeStudioPresetId,
       _appActionsFactory = appActionsFactory,
       _appActionsWithBackupFactory = appActionsWithBackupFactory,
       _newId = newId ?? generateId,
       _now = now ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch),
       _scheduleTimer = scheduleTimer,
       _readDeadline = readDeadline,
       _deadline = deadline,
       _onMessage = onMessage,
       _onPhase = onPhase,
       _onToolActivity = onToolActivity,
       _writer = SupportRepo(db, writeCipher) {
    if (readDeadline <= Duration.zero ||
        readDeadline > const Duration(seconds: 5) ||
        deadline <= Duration.zero ||
        deadline > PrivateTextLimits.deadline) {
      throw ArgumentError('Invalid support model budget.');
    }
    _unlistenRuntime = runtime.listen(_observe);
    _unlistenRegistry = revisions.subscribe(_observe);
    redaction.addListener(_observeRedactor);
  }
  final AppDatabase _db;
  final SupportPayloadCipher _writeCipher;
  final ApiConfigRepo _apiRepo;
  final ConnectionRevisionRegistry _revisions;
  final SecretRedactionCoordinator _redaction;
  final SupportNativeRuntime _runtime;
  final HttpClientAdapter Function() _adapterFactory;
  final bool Function() _isOwnerCurrent;
  final SupportModelWriteScheduler _writes;
  final NativeSavedConnectionSourceResolver? _nativeSources;
  final NativeProviderCredentialMetadataReader? _nativeMetadata;
  final NativeProviderPrivateTextDispatcher Function(PrivateTextTransport)?
  _nativeDispatcher;
  final SupportTextAdmissionContract? _admissionContract;
  final NativeToolTransport? _toolTransport;
  final SupportAppActionRegistry? _appActions;
  final SupportSourceTextRepo? _sourceRepo;
  final Future<String> Function()? _activeStudioPresetId;
  final SupportAppActionRegistry Function()? _appActionsFactory;
  final SupportAppActionRegistry Function(SupportDatabaseBackupAdapter)?
  _appActionsWithBackupFactory;
  final String Function() _newId;
  final int Function() _now;
  final Timer Function(Duration, void Function()) _scheduleTimer;
  final Duration _readDeadline, _deadline;
  final void Function(SupportModelMessage)? _onMessage;
  final void Function(SupportModelPhase)? _onPhase;
  final void Function(String, String, SupportModelToolActivity)?
  _onToolActivity;
  final SupportRepo _writer;
  late final void Function() _unlistenRuntime, _unlistenRegistry;
  final _emissions = <_ModelReadOperation>{};
  _ModelRun? _active;
  bool _regenerationPending = false;
  ProviderTokenUsage? _lastUsage;
  String? _usageSession;
  int? _usageRevision;
  bool _alive = true;

  void _observeRedactor(SecretRedactor _) => _observe();
  void _observe() {
    final run = _active;
    if (run != null && !run.current()) run.cancel(SupportModelRefusal.stale);
    for (final operation in List.of(_emissions)) {
      if (!operation.current()) operation.cancel(SupportModelRefusal.stale);
    }
  }

  bool get _ownerCurrent {
    try {
      return _alive && _isOwnerCurrent();
    } catch (_) {
      return false;
    }
  }

  /// Stop also works while SSE/crypto is quiet. Settlement custody is separate.
  void stop() {
    _active?.cancel(SupportModelRefusal.cancelled);
    for (final operation in List.of(_emissions)) {
      operation.cancel(SupportModelRefusal.cancelled);
    }
  }

  void invalidateMessage(String sessionId, String messageId) {
    final run = _active;
    if (run == null || !run.references(sessionId, messageId)) return;
    if (run.sessionId == sessionId &&
        (run.userId == messageId || run.replyId == messageId)) {
      run.settlementValid = false;
    }
    run.cancel(SupportModelRefusal.stale);
  }

  void invalidateSession(String sessionId) {
    final run = _active;
    if (run == null) return;
    if (run.sessionId == sessionId) run.settlementValid = false;
    if (run.sessionId == sessionId ||
        run.binding.policy.scope?.gameSessionId == sessionId) {
      run.cancel(SupportModelRefusal.stale);
    }
  }

  /// GAME domain only. IDs may equal our SUPPORT session/user/reply IDs: a game
  /// mutation cancels the original request but NEVER revokes its DB settlement.
  /// No history reads or late provider/runtime-owner lookup is performed here.
  void invalidateGameSource({
    required String sessionId,
    Set<String>? messageIds,
  }) {
    final ids = messageIds == null ? null : Set<String>.of(messageIds);
    bool affects(SupportPermissionScope? scope) =>
        scope != null &&
        scope.gameSessionId == sessionId &&
        scope.hasGameHistory &&
        (scope.gameHistoryExtent == SupportHistoryExtent.wholeSession ||
            ids == null ||
            scope.gameHistory!.messageIds.any(ids.contains));
    final run = _active;
    if (run != null && affects(run.binding.policy.scope)) {
      run.cancel(SupportModelRefusal.stale);
    }
    // Emissions have no accepted run yet. An unchanged original native scope
    // is their source; changed epochs already fail their retained predicates.
    if (affects(_runtime.snapshot.preferences?.scope)) {
      for (final operation in List.of(_emissions)) {
        operation.cancel(SupportModelRefusal.stale);
      }
    }
  }

  /// Use ONLY for actual original DB/data-owner replacement, not selection-away.
  void revokeSettlementOwner() {
    _active?.settlementValid = false;
    stop();
  }

  void dispose() {
    if (!_alive) return;
    _alive = false;
    _unlistenRuntime();
    _unlistenRegistry();
    _redaction.removeListener(_observeRedactor);
    for (final operation in List.of(_emissions)) {
      operation.cancel(SupportModelRefusal.stale);
    }
    _active?.history.revokeAdmissionOwner();
    _active?.cancel(SupportModelRefusal.stale);
  }

  @override
  String toString() => 'SupportModelService';
}
