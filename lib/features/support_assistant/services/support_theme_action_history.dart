part of 'support_theme_action_service.dart';

extension SupportThemeHistoryRead on SupportThemeActionService {
  Future<SupportThemeHistoryPage> discoverHistory(
    SupportThemeIntent intent, {
    SupportThemeHistoryCursor? cursor,
    SupportThemeOperation operation = SupportThemeOperation.selection,
  }) async {
    final b = intent._binding;
    SupportThemeHistoryPage unavailable() =>
        SupportThemeHistoryPage._(b, operation, null, const []);
    if (!_current(b) ||
        (cursor != null &&
            (!identical(cursor._binding, b) ||
                cursor.operation != operation))) {
      return unavailable();
    }
    try {
      final codec = SupportThemeActionService._codecFor(operation);
      if (!await _fresh(b) || !_current(b)) return unavailable();
      final native = await custody.repo.discoverMutationHistory(
        sessionId: b.sessionId,
        domain: codec.domainValue,
        targetId: codec.targetValue,
        isCurrent: () => _current(b),
        cursor: cursor?._native,
      );
      if (!_current(b) || native == null) return unavailable();
      // Exact cursor evidence is checked ONLY AFTER exact bounded metadata.
      if (cursor != null) {
        final valid = await _historyCursorCurrent(b, cursor);
        if (!_current(b) || !valid) return unavailable();
      }
      final entries = <_ThemeHistoryEntry>[];
      for (final row in native.entries) {
        if (!_current(b)) return unavailable();
        // Existing exact guarded recovery retains shared live-job exclusion and
        // strict versioned evidence validation. No generic decrypted loader.
        final recovery = await recover(intent, row.id, operation: operation);
        if (!_current(b)) return unavailable();
        entries.add((id: row.id, recovery: recovery));
      }
      if (!_current(b)) return unavailable();
      final continuation = await _historyContinuation(
        b,
        native,
        cursor,
        operation,
      );
      if (!_current(b)) return unavailable();
      if (continuation != null &&
          continuation._newest != null &&
          continuation._boundary != null) {
        final valid = await _historyCursorCurrent(b, continuation);
        if (!_current(b) || !valid) return unavailable();
      }
      if (cursor != null) {
        final valid = await _historyCursorCurrent(b, cursor);
        if (!_current(b) || !valid) return unavailable();
      }
      final valid = await custody.repo.validateMutationHistory(
        page: native,
        isCurrent: () => _current(b),
      );
      if (!_current(b) || !valid) return unavailable();
      return SupportThemeHistoryPage._(
        b,
        operation,
        native,
        entries,
        continuation,
      );
    } catch (_) {
      return unavailable();
    }
  }

  SupportThemeHistoryView projectHistory(
    SupportThemeIntent intent,
    SupportThemeHistoryPage page,
  ) {
    SupportThemeHistoryView unavailable() => SupportThemeHistoryView._(
      SupportThemeHistoryAvailability.unavailable,
      const [],
      null,
      operation: page.operation,
    );
    final b = intent._binding;
    if (!identical(page._binding, b) ||
        !_historyDisplayCurrent(b) ||
        page._native == null) {
      return unavailable();
    }
    final policy = redaction.redactor;
    final entries = <SupportThemeHistoryEntryView>[];
    for (final entry in page._entries) {
      if (!_historyDisplayCurrent(b)) return unavailable();
      final safeId = SupportThemeActionService._codec.identifier(
        entry.id,
        policy,
      );
      if (!safeId) {
        entries.add(
          SupportThemeHistoryEntryView._(
            SupportThemeRecoveryState.unavailable,
            null,
            null,
            null,
            null,
            operation: page.operation,
          ),
        );
        continue;
      }
      // Recheck CURRENT shared jobs, including work started after discovery.
      final job = custody._jobs[entry.id];
      if (job != null) {
        entries.add(
          SupportThemeHistoryEntryView._(
            job.sessionId == b.sessionId && job.operation == page.operation
                ? SupportThemeRecoveryState.liveJob
                : SupportThemeRecoveryState.unavailable,
            job.sessionId == b.sessionId && job.operation == page.operation
                ? entry.id
                : null,
            null,
            null,
            null,
            operation: page.operation,
          ),
        );
        continue;
      }
      final recovery = entry.recovery;
      SupportThemeValue? historical(SupportThemeValue? value) => value == null
          ? null
          : SupportThemeActionService._codec.project(
              id: value.id,
              name: value.name,
              mode: value.mode,
              accent: value.accent,
              active: false,
              policy: policy,
            );
      final before = historical(recovery.before),
          after = historical(recovery.after);
      final readable =
          before != null &&
          after != null &&
          (recovery.state == SupportThemeRecoveryState.history ||
              recovery.state == SupportThemeRecoveryState.uncertain);
      entries.add(
        SupportThemeHistoryEntryView._(
          readable ? recovery.state : SupportThemeRecoveryState.unavailable,
          entry.id,
          readable ? recovery.status : null,
          readable ? before : null,
          readable ? after : null,
          operation: page.operation,
        ),
      );
    }
    if (!_historyDisplayCurrent(b) || !identical(policy, redaction.redactor)) {
      return unavailable();
    }
    final cursor = _current(b) ? page._continuation : null;
    if (!_historyDisplayCurrent(b) || !identical(policy, redaction.redactor)) {
      return unavailable();
    }
    // The final owner predicates may be reentrant. Check jobs after those
    // callbacks as well, with no further callback/await before publication.
    for (var i = 0; i < entries.length; i++) {
      final job = custody._jobs[page._entries[i].id];
      if (job != null && entries[i].operationId != null) {
        entries[i] = SupportThemeHistoryEntryView._(
          job.sessionId == b.sessionId && job.operation == page.operation
              ? SupportThemeRecoveryState.liveJob
              : SupportThemeRecoveryState.unavailable,
          job.sessionId == b.sessionId && job.operation == page.operation
              ? entries[i].operationId
              : null,
          null,
          null,
          null,
          operation: page.operation,
        );
      }
    }
    return SupportThemeHistoryView._(
      SupportThemeHistoryAvailability.available,
      entries,
      cursor,
      operation: page.operation,
    );
  }

  bool _historyDisplayCurrent(_ThemeBinding b) =>
      _displayCurrent(b) && custody._current();
}
