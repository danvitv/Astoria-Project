part of 'support_model_ui_bridge.dart';

/// Owning displayed emitter; retiring this handle can stop only its original send.
/// UI should retire on unmount/controller/issuer replacement, not draft edits.
final class SupportModelUiEmitter {
  SupportModelUiEmitter._(
    this._bridge,
    this._controller,
    this._uiLifetime,
    this._isEmitterCurrent,
    this._workspaceCapture,
    this._runtimeCurrent,
    this._visibleConversation,
    this._toolUi,
  );
  final SupportModelUiBridge _bridge;
  final Object _controller, _uiLifetime;
  final bool Function() _isEmitterCurrent;
  final SupportModelWorkspaceCapture? _workspaceCapture;
  final bool Function() _runtimeCurrent;
  final List<SupportModelConversationMessage> _visibleConversation;
  final SupportModelToolUiPorts? _toolUi;
  bool _retired = false;
  SupportModelUiSend? _lastSend;
  bool get isCurrent => _current;

  bool get _current {
    try {
      return !_retired &&
          _bridge._current &&
          _isEmitterCurrent() &&
          _workspaceCapture?.current == true &&
          _runtimeCurrent();
    } catch (_) {
      return false;
    }
  }

  /// Revision is monotonic for EVERY draft edit (including A→B→A). The predicate
  /// checks that exact emitted revision/controller until durable acceptance.
  SupportModelUiSend send({
    required String text,
    required int draftRevision,
    required bool Function() isDraftCurrent,
  }) {
    final send = _bridge._send(this, text, draftRevision, isDraftCurrent);
    if (identical(_bridge._active, send)) _lastSend = send;
    return send;
  }

  SupportModelUiSend compact() {
    final send = _bridge._send(this, '', 0, () => true, compact: true);
    if (identical(_bridge._active, send)) _lastSend = send;
    return send;
  }

  void retire() {
    if (_retired) return;
    _retired = true;
    _lastSend?.stop();
  }

  @override
  String toString() => 'SupportModelUiEmitter';
}

/// Synchronously returned at actual Send; accepted is durable append, NOT model
/// success. Prepared/finished are independent. Keep this original through awaits.
final class SupportModelUiSend {
  SupportModelUiSend._(
    this._bridge,
    this._emitter,
    this._capture,
    this._text,
    this._draftRevision,
    this._isDraftCurrent,
    this._runtimeCurrent, {
    this._compact = false,
  });
  final SupportModelUiBridge _bridge;
  final SupportModelUiEmitter _emitter;
  final SupportModelWorkspaceCapture? _capture;
  final String _text;
  final int _draftRevision;
  final bool Function() _isDraftCurrent;
  final bool Function() _runtimeCurrent;
  final bool _compact;
  final _acceptance = Completer<bool>();
  final _preparation = Completer<SupportModelUiPreparation>();
  final _completion = Completer<SupportModelRunResult>();
  SupportModelPreview? _preview;
  SupportModelApproval? _approval;
  SupportModelMessage? _reply;
  String? _runId;
  bool _accepted = false, _stopped = false, _dispatched = false;

  Future<bool> get accepted => _acceptance.future;
  Future<SupportModelUiPreparation> get prepared => _preparation.future;
  Future<SupportModelRunResult> get finished => _completion.future;

  bool get _publicationCurrent {
    try {
      return _bridge._current &&
          _emitter._current &&
          _capture?.current == true &&
          _runtimeCurrent();
    } catch (_) {
      return false;
    }
  }

  bool get isCurrent =>
      !_stopped && identical(_bridge._active, this) && _publicationCurrent;

  /// Explicit CURRENT native confirmation. A bool returned by a sheet is not
  /// authority. No approval serializer or context loader is exported by this API.
  SupportModelApproval? approve(SupportModelPreview preview) {
    if (!isCurrent || !identical(preview, _preview)) return null;
    final approval = _bridge._service.approve(preview);
    if (approval != null) _approval = approval;
    return approval;
  }

  Future<SupportModelRunResult> dispatch(SupportModelApproval approval) {
    if (_dispatched && identical(approval, _approval)) return finished;
    if (!isCurrent || !identical(approval, _approval)) {
      return Future.value(
        SupportModelRunResult(
          accepted: _accepted,
          saved: false,
          reason: SupportModelRefusal.stale,
        ),
      );
    }
    _dispatched = true;
    // Original service + original once approval; never look up a provider here.
    unawaited(_bridge._service.dispatch(approval));
    return finished;
  }

  void cancelPreview(SupportModelPreview preview) {
    if (!identical(_bridge._active, this) || !identical(preview, _preview)) {
      return;
    }
    _bridge._service.cancelPreview(preview);
    stop();
  }

  /// Also works before emission/admission/preview and while HTTP is quiet. An old
  /// retained Stop cannot touch any later request, even on the same issuer.
  void stop() => _bridge._stop(this);

  void _projectStoppedResult(SupportModelRunResult result) {
    // Stop closes the service's emitter predicate, not durable display custody.
    // Join ONLY its original saved return before finished releases this claim.
    if (!_stopped ||
        !identical(_bridge._active, this) ||
        !_publicationCurrent ||
        !result.accepted ||
        !result.saved) {
      return;
    }
    final message = result.message, reply = _reply;
    if (message == null ||
        reply == null ||
        message.id != reply.id ||
        message.sessionId != _capture?.sessionId ||
        message.sessionId != reply.sessionId ||
        message.runId != _runId ||
        message.runId != reply.runId ||
        message.role != 'assistant' ||
        message.createdAt != reply.createdAt ||
        !const {
          'complete',
          'limited',
          'stopped',
          'error',
        }.contains(message.status)) {
      return;
    }
    try {
      _bridge.onMessage(message);
    } catch (_) {
      /* Presentation cannot prevent original completion or claim release. */
    }
  }

  void _completeRefusal(SupportModelRefusal reason) => _complete(
    SupportModelRunResult(accepted: false, saved: false, reason: reason),
  );

  void _complete(SupportModelRunResult result) {
    if (!_acceptance.isCompleted) _acceptance.complete(result.accepted);
    if (!_preparation.isCompleted) {
      _preparation.complete(SupportModelUiPreparation(reason: result.reason));
    }
    if (!_completion.isCompleted) _completion.complete(result);
  }

  @override
  String toString() => 'SupportModelUiSend';
}
