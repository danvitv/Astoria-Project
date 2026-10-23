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
    this.operation = SupportThemeOperation.selection,
  });
  final SupportThemeRecoveryState state;
  final SupportThemeOperation operation;
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
      active: operation == SupportThemeOperation.mode ? false : value.active,
      policy: b.service.redaction.redactor,
    );
  }
}

extension SupportThemeRecoveryRead on SupportThemeActionService {
  Future<SupportThemeRecovery> recover(
    SupportThemeIntent intent,
    String operationId, {
    SupportThemeOperation operation = SupportThemeOperation.selection,
  }) async {
    final b = intent._binding;
    final codec = SupportThemeActionService._codecFor(operation);
    final unavailable = SupportThemeRecovery._(
      SupportThemeRecoveryState.unavailable,
      null,
      null,
      null,
      operation: operation,
    );
    if (!_current(b) ||
        !SupportThemeActionService._codec.identifier(operationId, b.redactor)) {
      return unavailable;
    }
    final originalJob = custody._jobs[operationId];
    if (originalJob != null) {
      return originalJob.sessionId != b.sessionId ||
              originalJob.operation != operation
          ? unavailable
          : SupportThemeRecovery._(
              SupportThemeRecoveryState.liveJob,
              null,
              null,
              null,
              operation: operation,
            );
    }
    try {
      if (!await _fresh(b) || !_current(b)) return unavailable;
      final row = await custody.repo.readCurrentMutation(
        id: operationId,
        sessionId: b.sessionId,
        domain: codec.domainValue,
        targetId: codec.targetValue,
        isCurrent: () => _current(b),
      );
      if (!_current(b)) return unavailable;
      final retainedJob = custody._jobs[operationId];
      if (retainedJob != null) {
        return retainedJob.sessionId != b.sessionId ||
                retainedJob.operation != operation
            ? unavailable
            : SupportThemeRecovery._(
                SupportThemeRecoveryState.liveJob,
                null,
                null,
                null,
                operation: operation,
              );
      }
      if (row == null) return unavailable;
      final before = codec.decode(
        encoded: row.record.beforeJson,
        sessionId: b.sessionId,
        policy: redaction.redactor,
      );
      final after = codec.decode(
        encoded: row.record.afterJson,
        sessionId: b.sessionId,
        policy: redaction.redactor,
      );
      if (before == null || after == null || !_current(b)) return unavailable;
      // Mode evidence describes ONE preset with only its bounded mode changed.
      // It still cannot restore the native full-content/revision precondition.
      if (operation == SupportThemeOperation.mode &&
          (before.id != after.id ||
              before.name != after.name ||
              before.accent != after.accent)) {
        return unavailable;
      }
      return SupportThemeRecovery._(
        row.status.unresolved
            ? SupportThemeRecoveryState.uncertain
            : SupportThemeRecoveryState.history,
        b,
        before,
        after,
        status: row.status,
        operation: operation,
      );
    } catch (_) {
      return unavailable;
    }
  }
}
