import 'dart:async';

import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import '../theme_selection_test_store.dart';

/// Riverpod disposes the actual notifier. Fixture cleanup releases every owned
/// debounce without double-disposing it or leaving delayed work outside guards.
final class ThemeProviderTheme {
  ThemeProviderTheme(ThemeSelectionBacking backing)
    : store = ThemeSelectionTestStore(backing) {
    notifier = ThemeNotifier(
      storage: store,
      delay: (_) {
        final pending = Completer<void>();
        _delays.add(pending);
        return pending.future;
      },
    );
  }
  final ThemeSelectionTestStore store;
  late final ThemeNotifier notifier;
  final _delays = <Completer<void>>[];
  bool providerDisposed = false;

  void releaseDelays() {
    for (final delay in _delays) {
      if (!delay.isCompleted) delay.complete();
    }
  }
}
