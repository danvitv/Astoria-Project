import '../preferences/saved_preferences_owner.dart';
import 'credential_vault.dart';

/// Private native registration seam, never a saved application-data family.
/// The tracked facade must route physical writes/clear/reload through this FIFO.
abstract final class DatacatAccountPreferences {
  static const token = 'gz_dc_user_token';
  static const device = 'gz_dc_device';
  static const name = 'gz_dc_user_name';
  static const scopes = 'gz_dc_scopes';
  static const keys = PrivatePreferenceKeys.datacatAccountKeys;

  static Future<T> serialize<T>(Future<T> Function() operation) =>
      SavedPreferencesWrites.serializeDatacat(operation);

  /// Fail closed until composition registers the exact keys; capture() cannot
  /// otherwise certify them. No runtime registration or untracked read shortcut.
  static SavedPreferencesLease? capture(Iterable<String> keys) {
    if (!DatacatAccountPreferences.keys.every(
      PrivatePreferenceKeys.tracked.contains,
    )) {
      return null;
    }
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture(keys, store: store?.current == true ? store : null);
  }

  static void check(SavedPreferencesLease? lease, bool Function() current) {
    if (lease == null || !current() || !lease.current) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  static bool validDevice(String value) =>
      value.length >= 16 &&
      value.length <= 160 &&
      RegExp(r'^[A-Za-z0-9._:-]+$').hasMatch(value);
}
