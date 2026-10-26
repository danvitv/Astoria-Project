import 'dart:async';

import '../models/support_workspace_models.dart';
import '../services/support_model_service.dart';
import '../services/support_native_runtime.dart';
import 'support_model_run_view.dart';
import 'support_model_workspace_binding.dart';

export 'support_model_run_view.dart';
export '../services/support_model_service.dart'
    show SupportModelPreview, SupportModelApproval, SupportModelRunResult;

part 'support_model_ui_send.dart';
part 'support_model_ui_submission.dart';

/// Native owning UI bridge, NOT a tool port. Constructor-injected; no WidgetRef,
/// late provider lookups, ordinary transport/capture or context-reader escape.
final class SupportModelUiBridge {
  SupportModelUiBridge({
    required SupportModelService service,
    required SupportNativeRuntime runtime,
    required SupportModelWorkspaceBinding workspace,
    required bool Function() isOwnerCurrent,
    // Public injection names deliberately initialize private native dependencies.
    // ignore: prefer_initializing_formals
  }) : _service = service,
       _runtime = runtime,
       _workspace = workspace,
       // ignore: prefer_initializing_formals
       _isOwnerCurrent = isOwnerCurrent {
    _submission = _ModelUiSubmission(service, onPhase);
    if (workspace.busy) {
      _view = const SupportModelRunView(
        phase: SupportModelPhase.settling,
        busy: true,
      );
    }
    _stopRuntime = runtime.listen(_observe);
    _stopWorkspace = workspace.listen(_observe);
  }
  final SupportModelService _service;
  final SupportNativeRuntime _runtime;
  final SupportModelWorkspaceBinding _workspace;
  late final _ModelUiSubmission _submission;
  final bool Function() _isOwnerCurrent;
  late final void Function() _stopRuntime, _stopWorkspace;
  final _listeners = <void Function()>{};
  final _drained = Completer<void>();
  SupportModelUiSend? _active;
  bool _alive = true;
  SupportModelRunView _view = const SupportModelRunView();
  int? _usageEpoch, _usageRevision;
  SupportModelRunView get view => _view;
  Future<void> get drained => _drained.future;

  bool get _current {
    try {
      return _alive && _isOwnerCurrent();
    } catch (_) {
      return false;
    }
  }

  /// Bind the ACTUALLY displayed issuer/controller/lifetime synchronously. The
  /// callback must remain about those originals, never read a replacement issuer.
  SupportModelUiEmitter bindEmitter({
    required Object controller,
    required Object uiLifetime,
    required bool Function() isEmitterCurrent,
    List<SupportModelConversationMessage> visibleConversation = const [],
    SupportModelToolUiPorts? toolUi,
  }) {
    final runtime = _runtime,
        epoch = runtime.epoch,
        owner = runtime.writeOwner,
        lifetime = runtime.lifetime,
        revision = runtime.configurationRevision();
    bool runtimeCurrent() =>
        runtime.alive &&
        runtime.epoch == epoch &&
        runtime.writeOwner == owner &&
        runtime.lifetime == lifetime &&
        runtime.configurationRevision() == revision &&
        runtime.configurationStable();
    return SupportModelUiEmitter._(
      this,
      controller,
      uiLifetime,
      isEmitterCurrent,
      _workspace.capture(),
      runtimeCurrent,
      List.unmodifiable(visibleConversation),
      toolUi,
    );
  }

  void Function() listen(void Function() listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  void _publish(SupportModelRunView next) {
    if (!_current) return;
    _view = next;
    for (final listener in List.of(_listeners)) {
      if (!_listeners.contains(listener)) continue;
      try {
        listener();
      } catch (_) {
        /* Presentation cannot own a native run. */
      }
    }
  }

  void _observe() {
    final send = _active;
    if (send == null) {
      if (_view.sessionId != null &&
          (_view.sessionId != _runtime.sessionId ||
              _usageEpoch != _runtime.epoch ||
              _usageRevision != _runtime.configurationRevision())) {
        _publish(const SupportModelRunView());
      }
      if (_view.busy != _workspace.busy) {
        _publish(
          SupportModelRunView(
            phase: _workspace.busy ? SupportModelPhase.settling : null,
            busy: _workspace.busy,
          ),
        );
      }
      return;
    }
    if (send._publicationCurrent) return;
    _service.stop();
    // Retired session/lifetime cannot publish old preview/body/status to a new UI.
    _publish(
      const SupportModelRunView(phase: SupportModelPhase.settling, busy: true),
    );
  }

  SupportModelUiSend _send(
    SupportModelUiEmitter emitter,
    String text,
    int draftRevision,
    bool Function() isDraftCurrent, {
    bool compact = false,
    SupportModelMessage? regeneration,
  }) {
    final capture = emitter._workspaceCapture;
    final ready = _workspace
        .capture(); // Readiness ONLY, never a new target owner.
    final send = SupportModelUiSend._(
      this,
      emitter,
      capture,
      text,
      draftRevision,
      isDraftCurrent,
      emitter._runtimeCurrent,
      compact: compact,
      regeneration: regeneration,
    );
    if (!_current || !emitter._current || capture == null || !capture.current) {
      send._completeRefusal(SupportModelRefusal.stale);
    } else if (_active != null || _workspace.busy) {
      send._completeRefusal(SupportModelRefusal.busy);
    } else if (ready?.current != true ||
        ready?.ready != true ||
        ready?.sessionId != capture.sessionId) {
      send._completeRefusal(SupportModelRefusal.unavailable);
    } else {
      _active =
          send; // Claim BEFORE emitInput's first await, including draft ABA.
      if (!_workspace.claim(send)) {
        _active = null;
        send._completeRefusal(SupportModelRefusal.busy);
      } else {
        onPhase(SupportModelPhase.preparing);
        unawaited(_submit(send));
      }
    }
    return send;
  }

  Future<void> _submit(SupportModelUiSend send) async {
    final result = await _submission.run(send);
    send._projectStoppedResult(result);
    send._complete(result);
    if (identical(_active, send)) _active = null;
    _workspace.release(send);
    if (_current && _active == null) {
      _usageEpoch = _runtime.epoch;
      _usageRevision = _runtime.configurationRevision();
      _publish(
        send._publicationCurrent
            ? SupportModelRunView(
                phase: SupportModelPhase.settled,
                reason: result.reason,
                accepted: result.accepted,
                saved: result.saved,
                status: result.outcome?.status,
                dispatch:
                    result.outcome?.dispatch ?? PrivateTextDispatch.notAdmitted,
                transportReason:
                    result.outcome?.reason ?? PrivateTextReason.none,
                runId: send._runId,
                sessionId: send._capture?.sessionId,
                usage: result.outcome?.usage,
                compacted: result.compacted,
                isCompaction: send._compact,
              )
            : const SupportModelRunView(),
      );
    }
    if (!_alive && !_drained.isCompleted) _drained.complete();
  }

  /// Service observers contain sanitized durable rows only. No raw deltas/cards.
  void onMessage(SupportModelMessage message) {
    final send = _active;
    if (send == null || !send._publicationCurrent) return;
    send._runId = message.runId;
    if (message.role == 'assistant') send._reply ??= message;
    send._capture!.publish(
      SupportMessageItem(
        id: message.id,
        sessionId: message.sessionId,
        runId: message.runId,
        status: message.status,
        role: SupportMessageRole.values.firstWhere(
          (r) => r.name == message.role,
        ),
        body: message.text,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          message.createdAt,
          isUtc: true,
        ),
      ),
    );
  }

  void onPhase(SupportModelPhase phase) {
    final send = _active;
    if (send == null || !send._publicationCurrent) return;
    _publish(
      SupportModelRunView(
        phase: phase,
        busy: true,
        accepted: send._accepted,
        preview: phase == SupportModelPhase.preview ? send._preview : null,
        runId: send._runId,
        sessionId: send._capture?.sessionId,
        isCompaction: send._compact,
      ),
    );
  }

  void _stop(SupportModelUiSend send) {
    if (!identical(_active, send)) return;
    send._stopped = true;
    _service.stop();
    _publish(
      SupportModelRunView(
        phase: SupportModelPhase.settling,
        reason: SupportModelRefusal.cancelled,
        busy: true,
        accepted: send._accepted,
        runId: send._runId,
        sessionId: send._capture?.sessionId,
      ),
    );
  }

  void dispose() {
    if (!_alive) return;
    _alive = false;
    _stopRuntime();
    _stopWorkspace();
    _listeners.clear();
    _service.dispose(); // Network/admission only; original settlement survives.
    if (_active == null && !_drained.isCompleted) _drained.complete();
  }

  @override
  String toString() => 'SupportModelUiBridge';
}
