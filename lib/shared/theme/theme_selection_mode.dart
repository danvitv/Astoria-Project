part of 'theme_selection.dart';

/// Exact immutable ordered native snapshots. Nothing here is display/journal
/// data. Same-ID before/after must be distinguished by full contents, not ID.
class _ThemeModeSnapshots {
  _ThemeModeSnapshots._(this.activeId, this.before, this.after);

  factory _ThemeModeSnapshots.propose(
    ThemeSelectionStoredState stored,
    String mode,
  ) => _ThemeModeSnapshots._(
    stored.activeId,
    List.unmodifiable(stored.presets),
    List.unmodifiable(
      stored.presets.map(
        (preset) => preset.id == stored.activeId
            ? preset.copyWith(themeMode: mode)
            : preset,
      ),
    ),
  );

  final String activeId;
  final List<ThemePreset> before;
  final List<ThemePreset> after;

  _ThemeModeSnapshots get reversed =>
      _ThemeModeSnapshots._(activeId, after, before);

  bool matchesBefore(ThemeSelectionStoredState stored) =>
      _matches(stored, before);

  ThemeSelectionFreshObservation observe(ThemeSelectionStoredState stored) =>
      _matches(stored, after)
      ? ThemeSelectionFreshObservation.after
      : _matches(stored, before)
      ? ThemeSelectionFreshObservation.before
      : ThemeSelectionFreshObservation.other;

  bool _matches(ThemeSelectionStoredState stored, List<ThemePreset> expected) {
    if (stored.activeId != activeId ||
        stored.presets.length != expected.length) {
      return false;
    }
    for (var i = 0; i < expected.length; ++i) {
      if (stored.presets[i] != expected[i]) return false;
    }
    return true;
  }
}
