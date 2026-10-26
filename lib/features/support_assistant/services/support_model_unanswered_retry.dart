part of 'support_model_service.dart';

extension SupportModelNativeRetry on SupportModelService {
  /// Explicit retry of the displayed last native USER, without another append.
  /// The original emitter predicate and duplicate latch are captured before ANY
  /// await. Uses current profile, the actual own prefix and existing ROOT checks.
  SupportModelSubmission beginRetry({
    required Object controller,
    required Object uiLifetime,
    required bool Function() isEmitterCurrent,
    required SupportModelMessage selectedUser,
    required List<SupportModelConversationMessage> visibleConversation,
    SupportModelToolUiPorts? toolUi,
  }) {
    if (_active != null || _regenerationPending || _emissions.isNotEmpty) {
      return _rejectedSubmission(SupportModelRefusal.busy);
    }
    try {
      if (!_ownerCurrent || !isEmitterCurrent()) {
        return _rejectedSubmission(SupportModelRefusal.stale);
      }
      if (selectedUser.text.length > 8192 ||
          selectedUser.text.trim().isEmpty ||
          visibleConversation.length > 100000 ||
          visibleConversation.any(
            (m) =>
                !const ['user', 'assistant'].contains(m.role) ||
                m.id.length > 128 ||
                m.text.length > 65536,
          )) {
        return _rejectedSubmission(SupportModelRefusal.unsafe);
      }
      if (selectedUser.role != 'user' ||
          selectedUser.status != 'complete' ||
          selectedUser.sessionId != _runtime.sessionId ||
          visibleConversation.isEmpty ||
          visibleConversation.last.id != selectedUser.id ||
          visibleConversation.last.role != 'user' ||
          visibleConversation.last.text != selectedUser.text) {
        return _rejectedSubmission(SupportModelRefusal.stale);
      }
    } catch (_) {
      return _rejectedSubmission(SupportModelRefusal.stale);
    }
    final accepted = Completer<bool>();
    final prepared = Completer<SupportModelPreparation>();
    final finished = Completer<SupportModelRunResult>();
    _regenerationPending = true;
    unawaited(
      _emitUnansweredRetry(
        controller,
        uiLifetime,
        isEmitterCurrent,
        selectedUser,
        List.unmodifiable(visibleConversation),
        toolUi,
        accepted,
        prepared,
        finished,
      ),
    );
    return SupportModelSubmission._(
      accepted.future,
      prepared.future,
      finished.future,
    );
  }

  Future<void> _emitUnansweredRetry(
    Object controller,
    Object uiLifetime,
    bool Function() isEmitterCurrent,
    SupportModelMessage selected,
    List<SupportModelConversationMessage> visible,
    SupportModelToolUiPorts? toolUi,
    Completer<bool> accepted,
    Completer<SupportModelPreparation> prepared,
    Completer<SupportModelRunResult> finished,
  ) async {
    _ModelReadOperation? emission;
    var pendingReleased = false;
    var failure = SupportModelRefusal.unavailable;
    try {
      final r = _runtime;
      r.checkConfiguration();
      final id = r.sessionId,
          epoch = r.epoch,
          owner = r.writeOwner,
          lifetime = r.lifetime,
          revision = _revisions.revision;
      bool current() =>
          _ownerCurrent &&
          isEmitterCurrent() &&
          r.alive &&
          r.sessionId == id &&
          r.epoch == epoch &&
          r.writeOwner == owner &&
          r.lifetime == lifetime &&
          r.pending == 0 &&
          r.settingsPending == 0 &&
          _revisions.isStable &&
          _revisions.revision == revision &&
          r.configurationStable();
      emission = _ModelReadOperation(this, current);
      _emissions.add(emission);
      emission.check();
      final config = await _ModelConfiguration.read(
        emission,
        id,
        prime: true,
        directConversation: true,
      );
      emission.check();
      final reader = emission.reader;
      final original = await emission.checked(
        () => reader.readUnansweredUser(
          expectedUser: SupportMessage(
            id: selected.id,
            sessionId: id,
            role: 'user',
            body: selected.text,
            runId: selected.runId,
            status: selected.status,
            createdAt: selected.createdAt,
          ),
          isCurrent: emission!.current,
        ),
      );
      if (original == null) _refuse(SupportModelRefusal.stale);
      final user = original.message;
      if (_safeText(_redaction.redactor, user.body, 8192) != user.body) {
        _refuse(SupportModelRefusal.unsafe);
      }
      final binding = _ModelBinding(
        this,
        config,
        controller,
        uiLifetime,
        0,
        isEmitterCurrent,
        () => true,
        visible.take(visible.length - 1).toList(),
        toolUi: toolUi,
      );
      if (!binding.current()) _refuse(SupportModelRefusal.stale);
      final run = _ModelRun(
        this,
        binding,
        user.body,
        user.id,
        _newId(),
        _newId(),
        unanswered: original,
        regenerationUser: user,
      );
      _active = run;
      emission.close();
      _emissions.remove(emission);
      emission = null;
      _regenerationPending = false;
      pendingReleased = true;
      run.phase(SupportModelPhase.preparing);
      unawaited(run.prepare());
      unawaited(run.acceptance.future.then(accepted.complete));
      unawaited(run.preparation.future.then(prepared.complete));
      finished.complete(await run.completion.future);
      return;
    } on _ModelRefused catch (error) {
      failure = error.reason;
    } catch (_) {
      failure = emission != null && emission.reason != SupportModelRefusal.none
          ? emission.reason
          : SupportModelRefusal.unavailable;
    } finally {
      emission?.close();
      if (emission != null) _emissions.remove(emission);
      if (!pendingReleased) _regenerationPending = false;
    }
    if (!accepted.isCompleted) accepted.complete(false);
    if (!prepared.isCompleted) {
      prepared.complete(SupportModelPreparation._(null, failure));
    }
    if (!finished.isCompleted) {
      finished.complete(
        SupportModelRunResult(accepted: false, saved: false, reason: failure),
      );
    }
  }
}
