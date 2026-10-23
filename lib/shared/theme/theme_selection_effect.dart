part of 'theme_selection.dart';

/// Completion observation is separate from admission/publication authority.
/// Once invoked, a backend Future may complete even if the native view retires.
Future<ThemeSelectionResult> _runThemeSelectionEffect({
  required ThemeSelectionStore store,
  required Object owner,
  required int revision,
  required ThemePreset before,
  required ThemePreset after,
  required _ThemeModeSnapshots? mode,
  required bool Function() isCurrent,
  required void Function(ThemePreset, List<ThemePreset>?) publish,
}) async {
  var acceptance = ThemeSelectionWriteAcceptance.unknown;
  try {
    final accepted = await (mode == null
        ? store.setActiveChecked(after.id)
        : (store as ThemeModeStore).saveAllChecked(mode.after));
    acceptance = accepted
        ? ThemeSelectionWriteAcceptance.accepted
        : ThemeSelectionWriteAcceptance.rejected;
  } catch (_) {
    // A throw does not prove absence of effect. Observe, never retry.
  }
  var current = isCurrent();
  ThemeSelectionFreshObservation observed;
  try {
    // Original journal custody survives cancellation. This fresh read is only
    // observation; it neither reauthorizes a write nor paints a replacement view.
    final fresh = await store.readSelectionFresh();
    current = isCurrent();
    final contentMatches =
        fresh.installed(before.id) == before &&
        fresh.installed(after.id) == after;
    observed = mode != null
        ? mode.observe(fresh)
        : !contentMatches
        ? ThemeSelectionFreshObservation.other
        : fresh.activeId == after.id
        ? ThemeSelectionFreshObservation.after
        : fresh.activeId == before.id
        ? ThemeSelectionFreshObservation.before
        : ThemeSelectionFreshObservation.other;
  } catch (_) {
    current = isCurrent();
    observed = ThemeSelectionFreshObservation.unavailable;
  }
  final applied =
      acceptance == ThemeSelectionWriteAcceptance.accepted &&
      observed == ThemeSelectionFreshObservation.after;
  if (applied && current) {
    try {
      publish(after, mode?.after);
      current = isCurrent(); // synchronous listeners can admit newer work too
    } catch (_) {
      // A publication/listener failure cannot erase the observed external effect
      // or turn private listener text into a public domain error/retry signal.
      current = false;
    }
  }
  final code = acceptance == ThemeSelectionWriteAcceptance.unknown
      ? ThemeSelectionCode.writeThrew
      : acceptance == ThemeSelectionWriteAcceptance.rejected
      ? ThemeSelectionCode.writeRejected
      : observed == ThemeSelectionFreshObservation.unavailable
      ? ThemeSelectionCode.verificationFailed
      : applied
      ? ThemeSelectionCode.applied
      : ThemeSelectionCode.verificationConflict;
  return ThemeSelectionResult(
    code,
    effectStarted: true,
    writeAcceptance: acceptance,
    freshObserved: observed,
    ownerCurrent: current,
    receipt: applied
        ? ThemeSelectionReceipt._(owner, revision, before, after, mode)
        : null,
  );
}
