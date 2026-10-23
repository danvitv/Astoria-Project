import 'package:flutter/foundation.dart';

/// Bounded point-in-time preview, not a live domain observation or authority.
/// Constructing values never issues native action authority. Retained UI must
/// reproject its opaque native handle and refresh after ordinary theme changes.
@immutable
final class SupportThemeValue {
  const SupportThemeValue({
    required this.id,
    required this.name,
    required this.mode,
    required this.accent,
    required this.active,
  });
  final String id, name, mode, accent;
  final bool active;
}

enum SupportThemeActionKind { apply, undo }

@immutable
final class SupportThemePreview {
  const SupportThemePreview({
    required this.kind,
    required this.before,
    required this.after,
  });
  final SupportThemeActionKind kind;
  final SupportThemeValue before, after;
}

/// Domain truth and journal-save truth deliberately remain separate.
enum SupportThemeEffect { refused, noEffect, applied, undone, uncertain }

enum SupportThemeJournalSave { notReserved, settled, unresolved }

enum SupportThemeRecoveryState { unavailable, liveJob, uncertain, history }
