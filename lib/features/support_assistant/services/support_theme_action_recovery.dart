part of 'support_theme_action_service.dart';

/// Observation only. No restored receipt, approval, full-content/ABA proof,
/// status settlement or automatic replay exists on the recovery API.
final class SupportThemeRecovery {
  const SupportThemeRecovery._(
    this.state,
    this._binding,
    this._before,
    this._after, {
    this.status,
  });
  final SupportThemeRecoveryState state;
  final SupportMutationStatus? status;
  final _ThemeBinding? _binding;
  final SupportThemeValue? _before, _after;
  SupportThemeValue? get before => _project(_before);
  SupportThemeValue? get after => _project(_after);
  SupportThemeValue? _project(SupportThemeValue? value) {
    final b = _binding;
    if (b == null || value == null || !b.service._displayCurrent(b)) {
      return null;
    }
    return SupportThemeActionService._codec.project(
      id: value.id,
      name: value.name,
      mode: value.mode,
      accent: value.accent,
      active: value.active,
      policy: b.service.redaction.redactor,
    );
  }
}

extension SupportThemeRecoveryRead on SupportThemeActionService {
  Future<SupportThemeRecovery> recover(
    SupportThemeIntent intent,
    String operationId,
  ) async {
    final b = intent._binding;
    const unavailable = SupportThemeRecovery._(
      SupportThemeRecoveryState.unavailable,
      null,
      null,
      null,
    );
    if (!_current(b) ||
        !SupportThemeActionService._codec.identifier(operationId, b.redactor)) {
      return unavailable;
    }
    final originalJob = custody._jobs[operationId];
    if (originalJob != null) {
      return originalJob.sessionId != b.sessionId
          ? unavailable
          : const SupportThemeRecovery._(
              SupportThemeRecoveryState.liveJob,
              null,
              null,
              null,
            );
    }
    try {
      if (!await _fresh(b) || !_current(b)) return unavailable;
      final row = await custody.repo.readCurrentMutation(
        id: operationId,
        sessionId: b.sessionId,
        domain: SupportThemeEvidenceCodec.domain,
        targetId: SupportThemeEvidenceCodec.target,
        isCurrent: () => _current(b),
      );
      if (!_current(b)) return unavailable;
      final retainedJob = custody._jobs[operationId];
      if (retainedJob != null) {
        return retainedJob.sessionId != b.sessionId
            ? unavailable
            : const SupportThemeRecovery._(
                SupportThemeRecoveryState.liveJob,
                null,
                null,
                null,
              );
      }
      if (row == null) return unavailable;
      final before = SupportThemeActionService._codec.decode(
        encoded: row.record.beforeJson,
        sessionId: b.sessionId,
        policy: redaction.redactor,
      );
      final after = SupportThemeActionService._codec.decode(
        encoded: row.record.afterJson,
        sessionId: b.sessionId,
        policy: redaction.redactor,
      );
      if (before == null || after == null || !_current(b)) return unavailable;
      return SupportThemeRecovery._(
        row.status.unresolved
            ? SupportThemeRecoveryState.uncertain
            : SupportThemeRecoveryState.history,
        b,
        before,
        after,
        status: row.status,
      );
    } catch (_) {
      return unavailable;
    }
  }
}
