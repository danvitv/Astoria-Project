part of 'support_theme_action_service.dart';

enum SupportThemeHistoryAvailability { available, unavailable }

/// Native observation continuation, bound to ONE original emitted S intent.
final class SupportThemeHistoryCursor {
  const SupportThemeHistoryCursor._(
    this._binding,
    this._native,
    this._newest,
    this._boundary,
  );
  final _ThemeBinding _binding;
  final SupportMutationHistoryCursor _native;
  final SupportMutationReservation? _newest, _boundary;
}

/// IDs and evidence stay private until a current-policy projection is requested.
/// Neither this page nor its continuation can produce approval/receipt/Undo.
final class SupportThemeHistoryPage {
  SupportThemeHistoryPage._(
    this._binding,
    this._native,
    Iterable<_ThemeHistoryEntry> entries, [
    this._continuation,
  ]) : _entries = List.unmodifiable(entries);
  final _ThemeBinding _binding;
  final SupportMutationHistoryPage? _native;
  final List<_ThemeHistoryEntry> _entries;
  final SupportThemeHistoryCursor? _continuation;
}

typedef _ThemeHistoryEntry = ({String id, SupportThemeRecovery recovery});

/// Safe immutable render snapshot. Rebuild via intent.history(page) on EVERY
/// render; do not retain this DTO as authorization or a raw-label fallback.
final class SupportThemeHistoryView {
  SupportThemeHistoryView._(
    this.availability,
    Iterable<SupportThemeHistoryEntryView> entries,
    this.nextCursor,
  ) : entries = List.unmodifiable(entries);
  final SupportThemeHistoryAvailability availability;
  final List<SupportThemeHistoryEntryView> entries;
  final SupportThemeHistoryCursor? nextCursor;
}

final class SupportThemeHistoryEntryView {
  const SupportThemeHistoryEntryView._(
    this.state,
    this.operationId,
    this.status,
    this.before,
    this.after,
  );
  final SupportThemeRecoveryState state;
  final String? operationId;
  final SupportMutationStatus? status;

  /// Historical labels deliberately have active=false: not current theme proof.
  final SupportThemeValue? before, after;
}
