import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'cloud_oauth_preferences.dart';
import 'cloud_oauth_record.dart';
import 'cloud_oauth_credential_owner.dart' show CloudOAuthRetiredCommit;
import 'credential_slot.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Retains the exact pre-await document producer/revisions. No cleanup API.
final class CloudOAuthLegacySource {
  CloudOAuthLegacySource(this._original)
    : _lease = CloudOAuthPreferences.capture();

  final Future<SharedPreferences> _original;
  final SavedPreferencesLease? _lease;

  Future<void> importIfAbsent({
    required CredentialVault vault,
    required CredentialSlot slot,
    required CloudOAuthProvider provider,
    required SecretRedactionCoordinator redaction,
    required bool Function() isCurrent,
  }) => CloudOAuthPreferences.serialize(() async {
    void check() => CloudOAuthPreferences.check(_lease, isCurrent);
    check();
    final prefs = await _original;
    check();
    if (prefs is! TrackedSharedPreferences ||
        !_lease!.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    final raw = prefs.getString(CloudOAuthPreferences.tokens);
    if (raw == null) return;
    final document = jsonDecode(raw);
    registerCloudOAuthAliases(document, redaction);
    if (document is! Map) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    final value = document[provider.name];
    if (value == null) return;
    // Native mobile custody never enters this source: composition creates no
    // mobile Google owner. A copied native-connected marker is not a desktop pair.
    if (value is Map &&
        value['native_connected'] == true &&
        !value.containsKey('access_token') &&
        !value.containsKey('refresh_token'))
      return;
    final envelope = decodeCloudOAuthPair(
      value,
      provider,
      redaction,
      legacy: true,
    ).encode(provider);
    check();
    final native = await vault.importIfAbsentGuarded(
      slot,
      envelope,
      isCurrent: () => isCurrent() && _lease.current,
    );
    if (!isCurrent() || !_lease.current) {
      throw CloudOAuthImportSettledButRetired._(
        CloudOAuthImportReceipt._(configured: native.configured),
      );
    }
  });
}

/// The existing vault import API verifies its result but does not distinguish
/// an invoked absent-slot write from an already-present protected record. Keep
/// that uncertainty explicit; neither result grants this retired legacy owner.
final class CloudOAuthImportReceipt {
  const CloudOAuthImportReceipt._({required this.configured});
  final bool configured;
  bool get nativeResultVerified => true;
  bool? get writeCommitted => null;
  @override
  String toString() => 'Cloud OAuth native import receipt';
}

final class CloudOAuthImportSettledButRetired
    implements CloudOAuthRetiredCommit {
  const CloudOAuthImportSettledButRetired._(this.receipt);
  final CloudOAuthImportReceipt receipt;
  @override
  String toString() => 'Cloud OAuth native import settled; operation retired';
}
