part of 'support_theme_action_service.dart';

/// Metadata is queried FIRST. Only then retain two actual guarded encrypted
/// expectations for the newest watermark and page boundary. Private custody
/// here is observation-only and never exposed as reservation/effect authority.
extension _ThemeHistoryBoundary on SupportThemeActionService {
  Future<SupportMutationReservation?> _historyBoundaryRead(
    _ThemeBinding b,
    String id,
  ) async {
    if (!_current(b) ||
        !SupportThemeActionService._codec.identifier(id, b.redactor) ||
        custody._jobs.containsKey(id)) {
      return null;
    }
    try {
      final row = await custody.repo.readCurrentMutation(
        id: id,
        sessionId: b.sessionId,
        domain: SupportThemeEvidenceCodec.domain,
        targetId: SupportThemeEvidenceCodec.target,
        isCurrent: () => _current(b) && !custody._jobs.containsKey(id),
      );
      return _current(b) && !custody._jobs.containsKey(id) ? row : null;
    } catch (_) {
      return null;
    }
  }

  Future<bool> _historyCursorCurrent(
    _ThemeBinding b,
    SupportThemeHistoryCursor cursor,
  ) async {
    final newest = cursor._newest, boundary = cursor._boundary;
    if (!_current(b) || newest == null || boundary == null) return false;
    final latest = await _historyBoundaryRead(b, newest.record.id);
    if (!_current(b) ||
        latest == null ||
        !custody.repo.sameMutationHistoryObservation(newest, latest)) {
      return false;
    }
    final edge = await _historyBoundaryRead(b, boundary.record.id);
    return _current(b) &&
        edge != null &&
        custody.repo.sameMutationHistoryObservation(boundary, edge);
  }

  Future<SupportThemeHistoryCursor?> _historyContinuation(
    _ThemeBinding b,
    SupportMutationHistoryPage native,
    SupportThemeHistoryCursor? previous,
  ) async {
    final next = native.nextCursor;
    if (!_current(b) || next == null) return null;
    final newest =
        previous?._newest ??
        await _historyBoundaryRead(b, native.entries.first.id);
    if (!_current(b)) return null;
    final boundary = await _historyBoundaryRead(b, native.entries.last.id);
    if (!_current(b)) return null;
    // A malformed/locked boundary remains explicit: a continuation is offered
    // but its next read will be unavailable, never falsely mark history exhausted.
    return SupportThemeHistoryCursor._(b, next, newest, boundary);
  }
}
