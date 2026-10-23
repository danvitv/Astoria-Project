import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../models/support_workspace_models.dart';
import '../services/support_native_runtime.dart';
import '../services/support_workspace_send_service.dart';
import '../services/support_workspace_store.dart';
import 'support_workspace_lifecycle.dart';
import 'support_workspace_state.dart';
import 'support_workspace_topic_coordinator.dart';
import 'support_workspace_dependencies.dart';
import 'support_native_provider.dart';
import 'support_model_dependencies.dart';
import 'support_model_workspace_binding.dart';
import 'support_model_write_custody.dart';
import 'support_model_workspace_attachment.dart';

export '../models/support_workspace_models.dart';
export 'support_workspace_state.dart';
export 'support_workspace_dependencies.dart';

part 'support_workspace_settings_intent.dart';

/// Serial durable writes; each build and selection own their completions.
class SupportWorkspaceNotifier extends Notifier<SupportWorkspaceState> {
  int _epoch = 0, _selection = 0;
  late SupportWorkspaceLifecycle _owner;
  SupportNativeRuntime? _native;
  late SupportModelWorkspaceBinding _modelWorkspace;
  late SupportModelDurableWrites _writes;
  late final _topics = SupportWorkspaceTopicCoordinator(
    capture: () => SupportWorkspaceSendContext(
      _owner,
      _selection,
      state.activeSessionId,
      ready:
          !state.isLoading &&
          !state.isBusy &&
          !_modelWorkspace.busy &&
          (state.activeSessionId.isEmpty ||
              (state.settingsAvailable &&
                  state.activeSession?.isLocked != true)),
    ),
    isCurrent: (context) =>
        _current(context.owner) && context.selection == _selection,
    enqueue: _enqueue,
    reload: _reload,
    inspectConnection: (id, current) =>
        _native!.inspectSelectedConnection(id, current),
    invalidateNative: () => _native?.invalidateLease(),
    selectCreatedSession: (id) {
      _native!.selectSession(id);
      state = state.copyWith(activeSessionId: id);
    },
    publish: _publishDurable,
    publishHandledTopic: (topic) =>
        state = state.copyWith(lastHandledTopic: topic),
  );

  @override
  SupportWorkspaceState build() {
    _native?.selectSession('', force: true);
    final native = ref.watch(supportNativeRuntimeProvider);
    _native = native;
    native.selectSession('', force: true);
    _writes = ref.watch(supportModelDurableWritesProvider);
    final owner = _owner = SupportWorkspaceLifecycle(
      ++_epoch,
      ref.watch(supportSessionStoreProvider),
    );
    final modelWorkspace = _modelWorkspace = ref.watch(
      supportModelWorkspaceBindingProvider,
    );
    final attachment = SupportModelWorkspaceAttachment(
      native: native,
      readState: () => state,
      readSelection: () => _selection,
      isOwnerCurrent: () => _current(owner),
      isWritePending: () => owner.sending || owner.pending > 0,
      publish: (message) => _publishDurable(owner, message),
    );
    final binding = modelWorkspace.attach(
      capture: attachment.capture,
      resumeLocal: () {
        if (_current(owner)) _topics.resume();
      },
    );
    _selection++;
    ref.onDispose(() {
      native.invalidateBindings();
      owner.alive = false;
      modelWorkspace.detach(binding);
    });
    unawaited(
      Future<void>.microtask(() async {
        if (_current(owner)) {
          await _enqueue(owner, () => _reload(owner, readPolicy: true));
        }
      }),
    );
    return SupportWorkspaceState(lastHandledTopic: _topics.handledTopic);
  }

  bool _current(SupportWorkspaceLifecycle owner) =>
      ref.mounted &&
      owner.alive &&
      owner.epoch == _epoch &&
      identical(owner, _owner);

  Future<bool> _enqueue(
    SupportWorkspaceLifecycle owner,
    Future<void> Function() work, {
    bool Function()? ownsError,
  }) {
    if (!_current(owner)) return Future.value(false);
    owner.pending++;
    final result = Completer<bool>();
    owner.tail = owner.tail.then((_) async {
      var success = false;
      if (_current(owner)) {
        state = state.copyWith(isBusy: true, clearError: true);
        try {
          await work();
          success = _current(owner);
        } catch (error) {
          if (_current(owner) && ownsError?.call() != false) {
            state = state.copyWith(
              error: error is SupportReplyUnavailable
                  ? 'Сообщение сохранено, но ответ помощника не удалось сохранить. Не отправляй сообщение повторно; попробуй обновить историю.'
                  : 'Не удалось прочитать или сохранить историю помощника. Проверь доступ к защищённому хранилищу.',
            );
          }
        }
      }
      owner.pending--;
      if (_current(owner)) {
        state = state.copyWith(isBusy: owner.pending > 0, isLoading: false);
        if (success) _topics.resume();
      }
      result.complete(success);
    });
    return result.future;
  }

  Future<void> _reload(
    SupportWorkspaceLifecycle owner, {
    bool readPolicy = false,
  }) async {
    final native = _native!;
    final publicationStamp = _writes.publicationStamp;
    final SupportWorkspaceSnapshot snapshot;
    try {
      snapshot = await owner.store.load();
    } catch (_) {
      if (_current(owner)) {
        state = state.copyWith(
          settingsAvailability: SupportSettingsAvailability.unavailable,
        );
      }
      rethrow;
    }
    if (!_current(owner)) return;
    if (!identical(publicationStamp, _writes.publicationStamp)) {
      // A concurrent native durable transition outlived this display read. Never
      // repaint its older snapshot over an accepted/terminal row. Local reload
      // retries on its own tail, NOT the model's bounded durable-write FIFO.
      unawaited(refresh());
      return;
    }
    final active = snapshot.sessions.any((s) => s.id == state.activeSessionId)
        ? state.activeSessionId
        : snapshot.sessions.firstOrNull?.id ?? '';
    final changedSession = native.sessionId != active;
    native.selectSession(active);
    // Hydrate a newly bound session, not every message/settings repaint. A
    // redundant refresh would retire another already-admitted local operation.
    if (active.isNotEmpty && (readPolicy || changedSession)) {
      await native.refresh(resolve: false);
      if (!_current(owner)) return;
      if (!identical(publicationStamp, _writes.publicationStamp)) {
        unawaited(refresh());
        return;
      }
    }
    state = state.copyWith(
      sessions: snapshot.sessions,
      messagesBySession: snapshot.messages,
      activeSessionId: active,
      settings: snapshot.settings[active] ?? const SupportAssistantSettings(),
      settingsBySession: snapshot.settings,
      settingsAvailabilityBySession: snapshot.settingsAvailability,
      settingsAvailability:
          snapshot.settingsAvailability[active] ??
          (active.isEmpty
              ? SupportSettingsAvailability.available
              : SupportSettingsAvailability.unavailable),
      isLoading: false,
    );
  }

  Future<bool> refresh() {
    final owner = _owner;
    return _enqueue(owner, () => _reload(owner, readPolicy: true));
  }

  void setSessionSearchQuery(String query) {
    state = state.copyWith(sessionSearchQuery: query);
  }

  Future<String?> createNewSession({String? title}) async {
    _native!.invalidateBindings();
    final owner = _owner, selection = ++_selection;
    String? id;
    await _enqueue(owner, () async {
      final created = await owner.store.create(title);
      if (!_current(owner)) return;
      id = created;
      if (_selection == selection) {
        _native!.selectSession(created);
        state = state.copyWith(activeSessionId: id);
      }
      await _reload(owner, readPolicy: true);
    });
    return _current(owner) ? id : null;
  }

  void selectSession(String sessionId) {
    if (!state.sessions.any((s) => s.id == sessionId)) return;
    _native!.selectSession(sessionId, force: true);
    _selection++;
    state = state.copyWith(
      activeSessionId: sessionId,
      settings:
          state.settingsBySession[sessionId] ??
          const SupportAssistantSettings(),
      settingsAvailability:
          state.settingsAvailabilityBySession[sessionId] ??
          SupportSettingsAvailability.unavailable,
    );
    unawaited(refresh());
  }

  Future<bool> renameSession(String id, String title) {
    return _editSession((store, current) async {
      if (current()) await store.rename(id, title);
    });
  }

  Future<bool> togglePinSession(String id) =>
      _editSession((store, current) => store.togglePin(id, isCurrent: current));

  Future<bool> deleteSession(String id) {
    final owner = _owner;
    final native = _native!, writes = _writes;
    final activeTarget = id == state.activeSessionId;
    writes.invalidateSession(id);
    if (activeTarget) {
      native.invalidateBindings();
      if (_current(owner)) _selection++;
    }
    var deleted = false, unavailable = false;
    return _enqueue(owner, () async {
      try {
        deleted = await owner.store.deleteSessionIfMutationsSettled(
          id,
          isCurrent: () => _current(owner),
        );
      } catch (_) {
        unavailable = true;
        rethrow;
      }
      if (!deleted || !_current(owner)) return;
      await _reload(owner);
    }).then((_) {
      if (unavailable) {
        throw StateError('Support session deletion outcome unavailable.');
      }
      // Display reload/ownership may fail after the protected transaction has
      // returned true. Neither failure changes the original committed fact.
      return deleted;
    });
  }

  Future<bool> _editSession(
    Future<void> Function(SupportWorkspaceStore, bool Function()) edit,
  ) {
    final owner = _owner;
    return _enqueue(owner, () async {
      await edit(owner.store, () => _current(owner));
      if (!_current(owner)) return;
      await _reload(owner);
    });
  }

  SupportWorkspaceSettingsIntent? captureSettingsIntent({
    bool Function()? isOriginalUiCurrent,
  }) {
    final native = _native;
    if (native == null ||
        state.activeSessionId.isEmpty ||
        state.isLoading ||
        !state.settingsAvailable) {
      return null;
    }
    final owner = _owner, selection = _selection;
    final session = state.activeSessionId, lifetime = native.lifetime;
    bool original() =>
        _current(owner) &&
        selection == _selection &&
        identical(native, _native) &&
        native.alive &&
        native.lifetime == lifetime &&
        native.sessionId == session &&
        state.activeSessionId == session;
    final intent = SupportWorkspaceSettingsIntent._(
      this,
      () => original() && (isOriginalUiCurrent?.call() ?? true) && original(),
    );
    return intent.isCurrent ? intent : null;
  }

  bool _ownsSettingsIntent(SupportWorkspaceSettingsIntent intent) =>
      identical(intent._notifier, this) && intent.isCurrent;

  Future<bool> _settings(
    SupportAssistantSettings Function(SupportAssistantSettings) change, {
    SupportWorkspaceSettingsIntent? intent,
  }) {
    final id = state.activeSessionId;
    if (id.isEmpty ||
        state.isLoading ||
        !state.settingsAvailable ||
        (intent != null && !_ownsSettingsIntent(intent))) {
      return Future.value(false);
    }
    return _editPreferences(
      (store, current) => store.changeSettings(id, change, isCurrent: current),
      isOriginalUiCurrent: intent == null
          ? null
          : () => _ownsSettingsIntent(intent),
    );
  }

  Future<bool> _editPreferences(
    Future<void> Function(SupportWorkspaceStore, bool Function()) edit, {
    bool Function()? isOriginalUiCurrent,
  }) {
    final native = _native!;
    final settleNative = native.beginSettingsChange();
    final owner = _owner, selection = _selection;
    final nativeOwner = native.writeOwner, id = state.activeSessionId;
    bool current() =>
        _current(owner) &&
        selection == _selection &&
        (isOriginalUiCurrent?.call() ?? true) &&
        _current(owner) &&
        selection == _selection;
    return _enqueue(
      owner,
      () async {
        if (!current()) return;
        try {
          await edit(owner.store, current);
        } finally {
          // Separate transactions: failures never restore old native authority.
          if (current() && native.owns(id, nativeOwner)) {
            try {
              await native.permissions.selectRecipientFromNative(
                id,
                null,
                isCurrent: () => current() && native.owns(id, nativeOwner),
              );
            } catch (_) {
              /* Native authority remains denied even on clear failure. */
            }
          }
        }
        if (!_current(owner)) return;
        await _reload(owner, readPolicy: true);
      },
      ownsError: current,
    ).then((success) => success && current()).whenComplete(settleNative);
  }

  Future<bool> recoverSettings({
    required String sessionId,
    required bool confirmed,
  }) {
    if (!confirmed ||
        sessionId != state.activeSessionId ||
        state.isLoading ||
        state.isBusy ||
        state.settingsAvailability != SupportSettingsAvailability.corrupt) {
      return Future.value(false);
    }
    return _editPreferences(
      (store, current) =>
          store.recoverSettings(sessionId, confirmed: true, isCurrent: current),
    );
  }

  Future<bool> setMode(
    SupportAssistantMode mode, {
    SupportWorkspaceSettingsIntent? intent,
  }) => _settings((s) => s.copyWith(mode: mode), intent: intent);
  Future<bool> selectConnection(
    String? id, {
    String? defaultModelId,
    SupportWorkspaceSettingsIntent? intent,
  }) => _settings(
    (s) => s.copyWith(
      apiConfigId: id,
      clearApiConfigId: id == null,
      modelId: defaultModelId,
      clearModelId: defaultModelId == null,
    ),
    intent: intent,
  );
  Future<bool> selectModel(
    String? id, {
    SupportWorkspaceSettingsIntent? intent,
  }) => _settings(
    (s) => s.copyWith(modelId: id, clearModelId: id == null || id.isEmpty),
    intent: intent,
  );
  Future<bool> setTemperature(
    double value, {
    SupportWorkspaceSettingsIntent? intent,
  }) => _settings(
    (s) => s.copyWith(temperature: value.isFinite ? value.clamp(0, 2) : 0.35),
    intent: intent,
  );
  Future<bool> setMaxTokens(
    int value, {
    SupportWorkspaceSettingsIntent? intent,
  }) => _settings(
    (s) => s.copyWith(maxTokens: value.clamp(256, 16384)),
    intent: intent,
  );
  Future<bool> setReasoningEffort(
    SupportReasoningEffort effort, {
    SupportWorkspaceSettingsIntent? intent,
  }) => _settings((s) => s.copyWith(reasoningEffort: effort), intent: intent);
  Future<bool> setDcpCompression(
    bool enabled, {
    SupportWorkspaceSettingsIntent? intent,
  }) => _settings(
    (s) => s.copyWith(dcpCompressionEnabled: enabled),
    intent: intent,
  );

  Future<bool> deleteMessage(String messageId) {
    final id = state.activeSessionId;
    _writes.invalidateMessage(id, messageId);
    return _editSession(
      (store, current) =>
          store.deleteMessage(id, messageId, isCurrent: current),
    );
  }

  void _publishDurable(
    SupportWorkspaceLifecycle owner,
    SupportMessageItem message,
  ) {
    if (!_current(owner)) return;
    state = state.copyWith(
      messagesBySession: SupportModelWorkspaceAttachment.mergeDurable(
        state.messagesBySession,
        message,
      ),
    );
  }

  /// Legacy string-only callback is LOCAL help only; it can NEVER authorize HTTP.
  /// Actual model UI uses supportModelUiBridgeProvider's emitted owning handle.
  Future<bool> sendUserMessage(String text) => sendLocalHelp(text);
  Future<bool> sendLocalHelp(String text) => _topics.send(text: text);
  Future<bool> triggerQuickAction(String topic) => _topics.send(topic: topic);
  void applyInitialTopic(String? topic) => _topics.applyInitialTopic(topic);
  // No executor/exporter exists in this phase.
  Future<bool> applyMutationPlan(String planId) async => false;
  Future<bool> rollbackMutation(String journalId) async => false;
}

final supportWorkspaceProvider =
    NotifierProvider<SupportWorkspaceNotifier, SupportWorkspaceState>(
      SupportWorkspaceNotifier.new,
    );
