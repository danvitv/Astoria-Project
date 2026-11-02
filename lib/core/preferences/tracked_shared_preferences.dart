import 'package:shared_preferences/shared_preferences.dart';
// Capture the actual legacy plugin producer, not a fresh lookup after reading.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'saved_preferences_owner.dart';

/// API-compatible legacy facade; reads never reload/normalize or call setters.
/// Only the original plugin instance is retained. Do not claim unknown raw
/// instances, external processes or raw-plugin bypasses as covered writers.
final class TrackedSharedPreferences implements SharedPreferences {
  TrackedSharedPreferences._(this.delegate, this.store);
  final SharedPreferences delegate;
  final SavedPreferencesStore store;
  static SharedPreferences wrap(SharedPreferences value) =>
      value is TrackedSharedPreferences
      ? value
      : TrackedSharedPreferences._(
          value,
          SavedPreferencesOwner.process.attach(value),
        );
  static Future<SharedPreferences> getInstance() async {
    final backend = SharedPreferencesStorePlatform.instance;
    final actual = await SharedPreferences.getInstance();
    return TrackedSharedPreferences._(
      actual,
      SavedPreferencesOwner.process.attach(
        actual,
        trustedPlugin: true,
        backendCurrent: () =>
            identical(backend, SharedPreferencesStorePlatform.instance),
      ),
    );
  }

  Future<bool> _write(String key, Future<bool> Function() write) {
    Future<bool> perform() async {
      var acknowledged = false;
      try {
        return acknowledged = await write();
      } finally {
        store.owner.acknowledge(store, key, acknowledged);
      }
    }

    return SavedPreferencesWrites.run(
      [key],
      () => key == PrivatePreferenceKeys.chubApiKey
          ? SavedPreferencesWrites.serializeChub(perform)
          : key == PrivatePreferenceKeys.saucepanToken
          ? SavedPreferencesWrites.serializeSaucepan(perform)
          : PrivatePreferenceKeys.datacatAccountKeys.contains(key)
          ? SavedPreferencesWrites.serializeDatacat(perform)
          : key == PrivatePreferenceKeys.datacatAnonymousToken
          ? SavedPreferencesWrites.serializeDatacatAnonymous(perform)
          : PrivatePreferenceKeys.imageRoutmyKeys.contains(key)
          ? SavedPreferencesWrites.serializeImageRoutmy(perform)
          : key == PrivatePreferenceKeys.cloudOAuthDocument
          ? SavedPreferencesWrites.serializeCloudOAuth(perform)
          : key == 'pipelineSettings'
          ? SavedPreferencesWrites.serializeMemoryCustomApi(perform)
          : perform(),
    );
  }

  /// Exact native single-key string write/removal. Compare before cache publication;
  /// never route a saved read projection through this API. False/throw can persist.
  Future<({bool started, bool accepted, SavedPreferencesLease? receipt})>
  compareAndSetString({
    required String key,
    required String? expectedRaw,
    required String? value,
    required SavedPreferencesLease expected,
    required bool Function() isCurrent,
  }) async {
    // Private credential keys have their own physical FIFOs; do not widen this
    // saved-JSON writer into a private credential mutation surface.
    if (key == PrivatePreferenceKeys.chubApiKey ||
        key == PrivatePreferenceKeys.saucepanToken ||
        key == PrivatePreferenceKeys.datacatAnonymousToken ||
        key == PrivatePreferenceKeys.cloudOAuthDocument ||
        PrivatePreferenceKeys.imageRoutmyKeys.contains(key) ||
        PrivatePreferenceKeys.datacatAccountKeys.contains(key)) {
      return (started: false, accepted: false, receipt: null);
    }
    if (!isCurrent() || !expected.current || getString(key) != expectedRaw) {
      return (started: false, accepted: false, receipt: null);
    }
    final admission = store.owner.beginConditional(expected, store, key);
    if (admission == null) {
      return (started: false, accepted: false, receipt: null);
    }
    Future<({bool started, bool accepted, SavedPreferencesLease? receipt})>
    perform() async {
      var accepted = false, started = false;
      SavedPreferencesLease? receipt;
      try {
        if (isCurrent() && admission.current && getString(key) == expectedRaw) {
          started = true;
          accepted = value == null
              ? await delegate.remove(key)
              : await delegate.setString(key, value);
        }
      } catch (_) {
        // Keep the original producer's ambiguous outcome; never expose exception.
      } finally {
        receipt = admission.finish(accepted);
      }
      if (!started) return (started: false, accepted: false, receipt: null);
      return (started: true, accepted: accepted, receipt: receipt);
    }

    // Retain the ORIGINAL synchronous CAS admission while waiting in the mixed
    // document's physical FIFO. Do not reacquire a lease or re-enter the facade.
    return key == 'pipelineSettings'
        ? SavedPreferencesWrites.serializeMemoryCustomApi(perform)
        : perform();
  }

  /// Native, exact retirement of ONLY the Chub legacy key. Caller must retain
  /// the original store/value/revision and separately verify the vault copy.
  /// Shared key ordering prevents a later backup setter from being erased by a
  /// delayed remove. No clear(), reload(), replacement store or generic delete.
  Future<bool> retireChubApiKey({
    required String expectedRaw,
    required SavedPreferencesLease expected,
    required bool Function() isCurrent,
  }) => SavedPreferencesWrites.serializeChub(() async {
    const key = PrivatePreferenceKeys.chubApiKey;
    if (!isCurrent() || !expected.current || getString(key) != expectedRaw) {
      return false;
    }
    final admission = store.owner.beginConditional(expected, store, key);
    if (admission == null) return false;
    var accepted = false;
    SavedPreferencesLease? receipt;
    try {
      if (isCurrent() && admission.current && getString(key) == expectedRaw) {
        accepted = await delegate.remove(key);
      }
    } catch (_) {
      // An ambiguous native failure quarantines the original store; no retry.
    } finally {
      receipt = admission.finish(accepted);
    }
    return accepted &&
        isCurrent() &&
        receipt?.current == true &&
        !containsKey(key);
  });

  @override
  Object? get(String key) => delegate.get(key);
  @override
  Set<String> getKeys() => delegate.getKeys();
  @override
  bool containsKey(String key) => delegate.containsKey(key);
  @override
  bool? getBool(String key) => delegate.getBool(key);
  @override
  int? getInt(String key) => delegate.getInt(key);
  @override
  double? getDouble(String key) => delegate.getDouble(key);
  @override
  String? getString(String key) => delegate.getString(key);
  @override
  List<String>? getStringList(String key) => delegate.getStringList(key);
  @override
  Future<bool> setBool(String key, bool value) =>
      _write(key, () => delegate.setBool(key, value));
  @override
  Future<bool> setInt(String key, int value) =>
      _write(key, () => delegate.setInt(key, value));
  @override
  Future<bool> setDouble(String key, double value) =>
      _write(key, () => delegate.setDouble(key, value));
  @override
  Future<bool> setString(String key, String value) =>
      _write(key, () => delegate.setString(key, value));
  @override
  Future<bool> setStringList(String key, List<String> value) =>
      _write(key, () => delegate.setStringList(key, value));
  @override
  Future<bool> remove(String key) => _write(key, () => delegate.remove(key));
  @override
  Future<bool> clear() => SavedPreferencesWrites.run(
    PrivatePreferenceKeys.tracked,
    () => SavedPreferencesWrites.serializePrivateSources(() async {
      var acknowledged = false;
      try {
        return acknowledged = await delegate.clear();
      } finally {
        for (final key in PrivatePreferenceKeys.tracked) {
          store.owner.acknowledge(store, key, acknowledged);
        }
      }
    }),
  );
  @override
  Future<void> reload() {
    final preexisting = store.owner.pendingKeys;
    return SavedPreferencesWrites.run(
      PrivatePreferenceKeys.tracked,
      () => SavedPreferencesWrites.serializePrivateSources(() async {
        // Legacy reload replaces its whole cache AFTER getAll completes. An
        // overlapping accepted setter may already have persisted a newer value;
        // reloading an older captured map must not certify that cache as saved.
        final before = store.owner
            .capture(PrivatePreferenceKeys.tracked)
            .revisions;
        var completed = false;
        try {
          await delegate.reload();
          completed = true;
        } finally {
          final after = store.owner
              .capture(PrivatePreferenceKeys.tracked)
              .revisions;
          for (final key in PrivatePreferenceKeys.tracked) {
            if (!completed ||
                !store.current ||
                preexisting.contains(key) ||
                before[key] != after[key]) {
              store.owner.acknowledge(store, key, false);
            }
          }
        }
      }),
    );
  }

  @override
  // ignore: deprecated_member_use
  Future<bool> commit() => delegate.commit();
}
