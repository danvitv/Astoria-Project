part of 'support_model_ui_bridge.dart';

/// Joins the actual original emission/admission futures. No queue around preview
/// or HTTP. No Ref, alternate service lookup or automatic configured-model reply.
final class _ModelUiSubmission {
  const _ModelUiSubmission(this.service, this.onPhase);
  final SupportModelService service;
  final void Function(SupportModelPhase) onPhase;

  Future<SupportModelRunResult> run(SupportModelUiSend send) async {
    try {
      final emission = await service.emitInput(
        controller: send._emitter._controller,
        uiLifetime: send._emitter._uiLifetime,
        draftRevision: send._draftRevision,
        text: send._text,
        isEmitterCurrent: () => send._publicationCurrent && !send._stopped,
        isDraftCurrent: send._isDraftCurrent,
      );
      if (emission.intent == null) {
        return SupportModelRunResult(
          accepted: false,
          saved: false,
          reason: emission.reason,
        );
      }
      // ORIGINAL service. A provider rebuild after await never rebinds this text.
      final submission = service.beginSend(emission.intent!);
      unawaited(
        submission.accepted.then((accepted) {
          send._accepted = accepted;
          if (!send._acceptance.isCompleted) {
            send._acceptance.complete(accepted);
          }
          if (send._publicationCurrent) onPhase(SupportModelPhase.preparing);
        }),
      );
      final prepared = await submission.prepared;
      final current = send._publicationCurrent && !send._stopped;
      send._preview = current ? prepared.preview : null;
      send._preparation.complete(
        SupportModelUiPreparation(
          preview: send._preview,
          reason: current ? prepared.reason : SupportModelRefusal.stale,
        ),
      );
      if (!current && prepared.preview != null) {
        service.cancelPreview(prepared.preview!);
      }
      if (current && send._preview != null) onPhase(SupportModelPhase.preview);
      return await submission.finished;
    } catch (_) {
      service.stop();
      return SupportModelRunResult(
        accepted: send._accepted,
        saved: false,
        reason: SupportModelRefusal.unavailable,
      );
    }
  }
}
