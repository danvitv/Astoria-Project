import '../../../shared/theme/theme_provider.dart';
import '../services/support_theme_action_service.dart';

/// Transient native receipts only, never reconstructed from journal/card IDs.
/// DB lifetime owns retention; the delivered service checks exact theme/custody
/// and session compatibility again before a fresh separately approved Undo.
final class SupportThemeOriginalHandles {
  final _applied =
      <String, ({ThemeNotifier theme, SupportThemeApplied handle})>{};
  final _admissions = <String, Object>{};
  bool _alive = true;

  Object begin(String session, {required bool undo}) {
    final stamp = Object();
    if (_alive) {
      _admissions[session] = stamp;
      // A final confirmed Undo consumes the UI affordance, never restores it
      // from history after a refusal/conflict/uncertain outcome.
      if (undo) _applied.remove(session);
    }
    return stamp;
  }

  void accept(
    String session,
    ThemeNotifier theme,
    SupportThemeActionResult result,
    Object stamp,
  ) {
    if (!_alive || !identical(stamp, _admissions[session])) return;
    if (result.effect == SupportThemeEffect.undone) {
      _applied.remove(session);
    } else if (result.applied case final handle?) {
      _applied[session] = (theme: theme, handle: handle);
    }
  }

  SupportThemeApplied? forSession(String session, ThemeNotifier theme) {
    final entry = _applied[session];
    return _alive && entry != null && identical(entry.theme, theme)
        ? entry.handle
        : null;
  }

  void dispose() {
    _alive = false;
    _applied.clear();
    _admissions.clear();
  }
}
