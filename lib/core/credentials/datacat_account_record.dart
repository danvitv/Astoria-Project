import 'dart:convert';

import 'credential_vault.dart';
import 'datacat_account_preferences.dart';
import 'secret_redaction_coordinator.dart';

/// The only retained/published account value. No credential or device binding.
final class DatacatCredentialAccount {
  const DatacatCredentialAccount({
    this.authenticated = false,
    this.displayName,
    this.scopes = const [],
    this.unavailable = false,
  });
  final bool authenticated, unavailable;
  final String? displayName;
  final List<String> scopes;
}

/// Trusted storage codec only. Original token/device bytes are inseparable.
/// Metadata travels with the pair, not a possibly conflicting backup document.
String encodeDatacatAccount(
  String token,
  String device, {
  String? name,
  List<String> scopes = const [],
}) => jsonEncode({
  'version': 1,
  'token': token,
  'device': device,
  'name': name,
  'scopes': scopes,
});

Future<T> useDatacatAccount<T>(
  String envelope, {
  required String expectedDevice,
  required SecretRedactionCoordinator redaction,
  required Future<T> Function(String token, DatacatCredentialAccount account)
  consume,
}) async {
  final dynamic data;
  try {
    data = jsonDecode(envelope);
  } catch (_) {
    throw const CredentialVaultException(CredentialVaultFailure.verificationFailed);
  }
  if (data is! Map || data['version'] != 1 || data['token'] is! String) {
    throw const CredentialVaultException(CredentialVaultFailure.verificationFailed);
  }
  final token = data['token'] as String;
  redaction.registerSecret(token);
  if (data['device'] != expectedDevice ||
      !DatacatAccountPreferences.validDevice(expectedDevice)) {
    // Never adopt the protected binding into preferences, or rebind its token.
    throw const CredentialVaultException(CredentialVaultFailure.verificationFailed);
  }
  final rawName = data['name'];
  final rawScopes = data['scopes'];
  if ((rawName != null && rawName is! String) ||
      rawScopes is! List || rawScopes.any((s) => s is! String)) {
    throw const CredentialVaultException(CredentialVaultFailure.verificationFailed);
  }
  final account = DatacatCredentialAccount(
    authenticated: token.isNotEmpty,
    displayName: rawName is String ? redaction.redactor.redactText(rawName) : null,
    scopes: List.unmodifiable(rawScopes.cast<String>().map(
      redaction.redactor.redactText,
    )),
  );
  return consume(token, account);
}
