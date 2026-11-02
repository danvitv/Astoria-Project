import '../preferences/saved_preferences_owner.dart';
import 'credential_vault.dart';

/// Private original cloud document, never an application/model data family.
abstract final class CloudOAuthPreferences {
  static const tokens = 'gz_sync_tokens';

  // Parent composition owns the sixth physical tail and facade registration.
  static Future<T> serialize<T>(Future<T> Function() operation) =>
      SavedPreferencesWrites.serializeCloudOAuth(operation);

  static SavedPreferencesLease? capture({bool document = true}) {
    if (!PrivatePreferenceKeys.tracked.contains(tokens)) return null;
    final owner = SavedPreferencesOwner.process;
    final store = owner.originalStore;
    return owner.capture(
      document ? [tokens] : const [],
      store: store?.current == true ? store : null,
    );
  }

  static void check(SavedPreferencesLease? lease, bool Function() current) {
    if (lease == null || !lease.current || !current()) {
      throw const CredentialVaultAdmissionDenied();
    }
  }
}
