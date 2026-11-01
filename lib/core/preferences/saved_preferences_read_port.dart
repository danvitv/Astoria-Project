import 'package:shared_preferences/shared_preferences.dart';

import 'saved_preferences_owner.dart';
import 'tracked_shared_preferences.dart';

/// A retained actual producer/future, not a notifier's unloaded defaults and
/// not a callback that looks up a fresh provider after an await.
final class SavedPreferencesReadPort {
  SavedPreferencesReadPort({
    required Future<SharedPreferences> original,
    required bool Function() producerCurrent,
    SharedPreferences? loaded,
  }) : _original = original,
       _producerCurrent = producerCurrent,
       _loaded = loaded;
  final Future<SharedPreferences> _original;
  final bool Function() _producerCurrent;
  final SharedPreferences? _loaded;

  SavedPreferencesLease capture(String family) =>
      SavedPreferencesOwner.process.capture(
        SavedPreferencesKeys.families[family]!,
        store: _loaded is TrackedSharedPreferences
            ? _loaded.store
            : SavedPreferencesOwner.process.originalStore,
      );

  Future<Map<String, Object?>> read(
    String family,
    SavedPreferencesLease lease,
  ) async {
    void check() {
      if (!_producerCurrent() || !lease.current) {
        lease.retire();
        throw const SavedPreferencesUnavailable();
      }
    }

    check();
    final prefs = _loaded ?? await _original;
    check();
    // Do not silently certify an injected/raw/unknown backend.
    if (prefs is! TrackedSharedPreferences ||
        !lease.bindOriginalStore(prefs.store)) {
      lease.retire();
      throw const SavedPreferencesUnavailable();
    }
    final result = <String, Object?>{};
    for (final key in SavedPreferencesKeys.families[family]!) {
      check();
      final value = prefs.get(key);
      if (value is List<String>) {
        result[key] = List<String>.unmodifiable(value);
      } else {
        result[key] = value;
      }
    }
    check();
    return Map.unmodifiable(result);
  }

  bool isCurrent(SavedPreferencesLease lease) {
    if (!_producerCurrent()) lease.retire();
    return lease.current;
  }
}

final class SavedPreferencesUnavailable implements Exception {
  const SavedPreferencesUnavailable();
  @override
  String toString() => 'Saved preferences unavailable.';
}
