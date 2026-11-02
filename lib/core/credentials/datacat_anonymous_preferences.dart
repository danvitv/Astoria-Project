import '../preferences/saved_preferences_owner.dart';
import 'credential_vault.dart';

/// Native anonymous custody only, never a saved application-data family.
abstract final class DatacatAnonymousPreferences {
  static const token = PrivatePreferenceKeys.datacatAnonymousToken;
  static const device = 'gz_dc_device';

  /// The parent composition registers this CENTRAL physical family tail. There
  /// is deliberately no second helper-local queue and no untracked fallback.
  static Future<T> serialize<T>(Future<T> Function() operation) =>
      SavedPreferencesWrites.serializeDatacatAnonymous(operation);

  static SavedPreferencesLease? capture(Iterable<String> keys) {
    final selected = keys.toSet();
    if (!selected.every(PrivatePreferenceKeys.tracked.contains)) return null;
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture(
      selected,
      store: store?.current == true ? store : null,
    );
  }

  static void check(SavedPreferencesLease? lease, bool Function() current) {
    try {
      if (lease != null && current() && lease.current) return;
    } catch (_) {
      // Native guard failures never expose arbitrary captured causes.
    }
    throw const CredentialVaultAdmissionDenied();
  }
}
