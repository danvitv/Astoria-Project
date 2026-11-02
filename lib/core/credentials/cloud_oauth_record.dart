import 'dart:convert';

import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

enum CloudOAuthProvider { dropbox, gdrive }

/// Trusted native custody only. Never pass this record to diagnostic/model state.
final class CloudOAuthPair {
  const CloudOAuthPair({
    required this.accessToken,
    required this.refreshToken,
    this.expiresAt,
    this.accountId,
    this.uid,
    this.folderId,
  });

  final String accessToken, refreshToken;
  final int? expiresAt;
  final String? accountId, uid, folderId;

  bool get expired =>
      expiresAt != null && DateTime.now().millisecondsSinceEpoch >= expiresAt!;

  CloudOAuthPair withFolder(String? folder) => CloudOAuthPair(
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt,
    accountId: accountId,
    uid: uid,
    folderId: folder,
  );

  CloudOAuthPair withAccount(String account) => CloudOAuthPair(
    accessToken: accessToken,
    refreshToken: refreshToken,
    expiresAt: expiresAt,
    accountId: account,
    uid: uid,
    folderId: folderId,
  );

  String encode(CloudOAuthProvider provider) => jsonEncode({
    'version': 1,
    'provider': provider.name,
    'access_token': accessToken,
    'refresh_token': refreshToken,
    'expires_at': expiresAt,
    'account_id': accountId,
    'uid': uid,
    'folderId': folderId,
  });

  @override
  String toString() => 'CloudOAuthPair';
}

void registerCloudOAuthAliases(
  Object? value,
  SecretRedactionCoordinator redaction, [
  int depth = 0,
]) {
  if (depth > 12) return;
  if (value is Map) {
    for (final entry in value.entries) {
      final key = entry.key.toString().toLowerCase().replaceAll('_', '');
      if (const {
            'accesstoken',
            'refreshtoken',
            'token',
            'code',
            'authorizationcode',
            'clientsecret',
            'codeverifier',
          }.contains(key) &&
          entry.value is String) {
        redaction.registerSecret(entry.value as String);
      }
      registerCloudOAuthAliases(entry.value, redaction, depth + 1);
    }
  } else if (value is List) {
    for (final item in value) {
      registerCloudOAuthAliases(item, redaction, depth + 1);
    }
  }
}

CloudOAuthPair decodeCloudOAuthPair(
  Object? value,
  CloudOAuthProvider provider,
  SecretRedactionCoordinator redaction, {
  bool legacy = false,
}) {
  registerCloudOAuthAliases(value, redaction);
  if (value is! Map ||
      (!legacy &&
          (value['version'] != 1 || value['provider'] != provider.name))) {
    throw const CredentialVaultException(
      CredentialVaultFailure.verificationFailed,
    );
  }
  final access = value['access_token'], refresh = value['refresh_token'];
  final expiry = value['expires_at'];
  final folder = value['folderId'];
  if (provider == CloudOAuthProvider.gdrive &&
      folder != null &&
      (folder is! String || !RegExp(r'^[A-Za-z0-9_-]+$').hasMatch(folder))) {
    throw const CredentialVaultException(
      CredentialVaultFailure.verificationFailed,
    );
  }
  for (final key in ['account_id', 'uid', 'folderId']) {
    final binding = value[key];
    if (binding != null &&
        (binding is! String ||
            binding.isEmpty ||
            binding.length > 1024 ||
            binding.contains(RegExp(r'[\r\n\x00]')))) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
  }
  if (access is! String ||
      access.isEmpty ||
      refresh is! String ||
      refresh.isEmpty ||
      access.length > 32768 ||
      refresh.length > 32768 ||
      access.contains(RegExp(r'[\r\n\x00]')) ||
      refresh.contains(RegExp(r'[\r\n\x00]')) ||
      (expiry != null && (expiry is! int || expiry < 0))) {
    throw const CredentialVaultException(
      CredentialVaultFailure.verificationFailed,
    );
  }
  return CloudOAuthPair(
    accessToken: access,
    refreshToken: refresh,
    expiresAt: expiry as int?,
    accountId: value['account_id'] as String?,
    uid: value['uid'] as String?,
    folderId: value['folderId'] as String?,
  );
}
