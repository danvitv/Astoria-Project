part of 'support_model_service.dart';

/// These opaque native objects are NEVER restored/decoded from rows or JSON.
/// Only this issuer can create them; data leases and old rows cannot substitute.
final class SupportModelInputIntent {
  SupportModelInputIntent._(this._issuer, this._binding, this._text);
  final SupportModelService _issuer;
  final _ModelBinding _binding;
  final String _text;
  bool _used = false;
  @override
  String toString() => 'SupportModelInputIntent';
}

final class SupportModelInputEmission {
  const SupportModelInputEmission._(this.intent, this.reason);
  final SupportModelInputIntent? intent;
  final SupportModelRefusal reason;
  @override
  String toString() => 'SupportModelInputEmission';
}

final class SupportModelPreview {
  SupportModelPreview._(
    this._issuer,
    this._run,
    this.recipient,
    Iterable<SupportModelPreviewText> messages,
    this.supportMessages,
    this.gameMessages,
  ) : messages = List.unmodifiable(messages);
  final SupportModelService _issuer;
  final _ModelRun _run;
  final SupportResolvedRecipient recipient;
  final List<SupportModelPreviewText> messages;
  final int supportMessages, gameMessages;
  String get sessionId => _run.sessionId;
  String get runId => _run.runId;
  String get userMessageId => _run.userId;
  String get replyMessageId => _run.replyId;
  bool get isCurrent => _run.current() && identical(_run.preview, this);
  @override
  String toString() => 'SupportModelPreview';
}

final class SupportModelApproval {
  SupportModelApproval._(this._preview);
  final SupportModelPreview _preview;
  bool _used = false;
  @override
  String toString() => 'SupportModelApproval';
}

final class SupportModelPreparation {
  const SupportModelPreparation._(this.preview, this.reason);
  final SupportModelPreview? preview;
  final SupportModelRefusal reason;
  @override
  String toString() => 'SupportModelPreparation';
}

final class SupportModelSubmission {
  const SupportModelSubmission._(this.accepted, this.prepared, this.finished);

  /// Completes immediately after durable append, NOT after preview/HTTP.
  final Future<bool> accepted;
  final Future<SupportModelPreparation> prepared;
  final Future<SupportModelRunResult> finished;
  @override
  String toString() => 'SupportModelSubmission';
}

extension SupportModelNativeInput on SupportModelService {
  /// Called by native emitted composer ownership, NOT topic/import/restore/tool
  /// dispatch. Secret priming may rebuild the parent provider: old owner DENIES.
  /// Draft ABA checks apply until durable append; new drafts after acceptance do
  /// not revoke the submitted immutable text. Emitter lifetime always applies.
  Future<SupportModelInputEmission> emitInput({
    required Object controller,
    required Object uiLifetime,
    required int draftRevision,
    required String text,
    required bool Function() isEmitterCurrent,
    required bool Function() isDraftCurrent,
  }) async {
    _ModelReadOperation? operation;
    try {
      if (_active != null) {
        _refuse(SupportModelRefusal.busy);
      }
      if (text.length > 8192) _refuse(SupportModelRefusal.tooLarge);
      if (draftRevision < 0 || text.trim().isEmpty) {
        _refuse(SupportModelRefusal.unsafe);
      }
      final r = _runtime;
      r.checkConfiguration();
      final id = r.sessionId,
          owner = r.writeOwner,
          lifetime = r.lifetime,
          epoch = r.epoch,
          revision = _revisions.revision;
      var preparingInput = true;
      bool current() =>
          _ownerCurrent &&
          isEmitterCurrent() &&
          (!preparingInput || isDraftCurrent()) &&
          r.alive &&
          r.sessionId == id &&
          r.writeOwner == owner &&
          r.lifetime == lifetime &&
          r.epoch == epoch &&
          r.pending == 0 &&
          r.settingsPending == 0 &&
          _revisions.isStable &&
          _revisions.revision == revision &&
          r.configurationStable();
      operation = _ModelReadOperation(this, current);
      _emissions.add(operation);
      operation.check();
      final configuration = await _ModelConfiguration.read(
        operation,
        id,
        prime: true,
      );
      operation.check();
      // The saved source retains this original operation, including Stop and
      // epoch/revision custody. Draft custody transfers to the intent binding;
      // after durable append a new composer draft does not revoke this input.
      preparingInput = false;
      final safe = _safeText(_redaction.redactor, text.trim(), 8192);
      if (safe.isEmpty) {
        _refuse(SupportModelRefusal.unsafe);
      }
      final binding = _ModelBinding(
        this,
        configuration,
        controller,
        uiLifetime,
        draftRevision,
        isEmitterCurrent,
        isDraftCurrent,
      );
      if (!binding.current(draft: true)) _refuse(SupportModelRefusal.stale);
      return SupportModelInputEmission._(
        SupportModelInputIntent._(this, binding, safe),
        SupportModelRefusal.none,
      );
    } on _ModelRefused catch (error) {
      return SupportModelInputEmission._(null, error.reason);
    } catch (_) {
      return SupportModelInputEmission._(
        null,
        operation != null && operation.reason != SupportModelRefusal.none
            ? operation.reason
            : SupportModelRefusal.unavailable,
      );
    } finally {
      if (operation != null) {
        operation.close();
        _emissions.remove(operation);
      }
    }
  }

  SupportModelSubmission beginSend(SupportModelInputIntent intent) {
    try {
      if (_active != null) _refuse(SupportModelRefusal.busy);
      if (!identical(intent._issuer, this) ||
          intent._used ||
          !intent._binding.current(draft: true)) {
        _refuse(SupportModelRefusal.stale);
      }
      intent._used = true;
      final run = _ModelRun(
        this,
        intent._binding,
        intent._text,
        _newId(),
        _newId(),
        _newId(),
      );
      _active = run; // Claim synchronously BEFORE any admission await.
      run.phase(SupportModelPhase.preparing);
      unawaited(run.prepare()); // Own handler returns only safe results.
      return SupportModelSubmission._(
        run.acceptance.future,
        run.preparation.future,
        run.completion.future,
      );
    } on _ModelRefused catch (error) {
      return _rejectedSubmission(error.reason);
    } catch (_) {
      return _rejectedSubmission(SupportModelRefusal.unavailable);
    }
  }

  SupportModelApproval? approve(SupportModelPreview preview) {
    if (!identical(preview._issuer, this) ||
        !preview.isCurrent ||
        preview._run.approvalIssued ||
        preview._run.running) {
      return null;
    }
    preview._run.approvalIssued = true;
    return SupportModelApproval._(preview);
  }

  Future<SupportModelRunResult> dispatch(SupportModelApproval approval) {
    final preview = approval._preview;
    if (!identical(preview._issuer, this)) {
      return Future.value(
        const SupportModelRunResult(
          accepted: false,
          saved: false,
          reason: SupportModelRefusal.stale,
        ),
      );
    }
    if (approval._used || !preview.isCurrent || preview._run.running) {
      // Repeated/stale callbacks observe the ORIGINAL once result, never claim a
      // committed user wasn't accepted and never allocate/replay a new request.
      if (!preview._run.running && !preview._run._settling) {
        preview._run.cancel(SupportModelRefusal.stale);
      }
      return preview._run.completion.future;
    }
    approval._used = true;
    preview._run.running = true;
    unawaited(preview._run.generate());
    return preview._run.completion.future;
  }

  void cancelPreview(SupportModelPreview preview) {
    if (identical(preview._issuer, this) && identical(_active, preview._run)) {
      preview._run.cancel(SupportModelRefusal.cancelled);
    }
  }
}

SupportModelSubmission _rejectedSubmission(SupportModelRefusal reason) =>
    SupportModelSubmission._(
      Future.value(false),
      Future.value(SupportModelPreparation._(null, reason)),
      Future.value(
        SupportModelRunResult(accepted: false, saved: false, reason: reason),
      ),
    );
