import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../preferences/saved_preferences_owner.dart';
import '../preferences/tracked_shared_preferences.dart';
import 'cloud_oauth_preferences.dart';
import 'cloud_oauth_record.dart';
import 'cloud_oauth_credential_owner.dart';
import 'credential_vault.dart';
import 'secret_redaction_coordinator.dart';

/// Only Google's pre-existing native_connected/folder metadata, not SDK custody.
/// A token-bearing backup cannot be normalized/re-emitted as a metadata save.
Future<CloudOAuthMobileMetadataOutcome> saveCloudOAuthMobileMetadata({
  required Future<SharedPreferences> originalPreferences,
  required bool connected,
  required String? folderId,
  required SecretRedactionCoordinator redaction,
  required bool Function() isCurrent,
}) {
  final lease = CloudOAuthPreferences.capture(); // Before queue/acquisition.
  return CloudOAuthPreferences.serialize(() async {
    void check() => CloudOAuthPreferences.check(lease, isCurrent);
    check();
    final prefs = await originalPreferences;
    check();
    if (prefs is! TrackedSharedPreferences ||
        !lease!.bindOriginalStore(prefs.store)) {
      throw const CredentialVaultAdmissionDenied();
    }
    final raw = prefs.getString(CloudOAuthPreferences.tokens);
    final decoded = raw == null ? <String, dynamic>{} : jsonDecode(raw);
    registerCloudOAuthAliases(decoded, redaction);
    if (decoded is! Map<String, dynamic>) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    // Explicit cleanup authorization is absent. Fail closed rather than copying
    // sibling/plaintext pairs or destroying them while saving native metadata.
    if (_containsOAuthMaterial(decoded)) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    final existing = decoded['gdrive'];
    if (existing != null && existing is! Map<String, dynamic>) {
      throw const CredentialVaultException(
        CredentialVaultFailure.verificationFailed,
      );
    }
    final metadata = <String, dynamic>{
      if (existing is Map<String, dynamic>) ...existing,
      'native_connected': connected,
      'folderId': folderId,
    };
    final next = jsonEncode({...decoded, 'gdrive': metadata});
    if (next == raw)
      return const CloudOAuthMobileMetadataOutcome._(
        acknowledged: false,
        retired: false,
      );
    check();
    final admitted = prefs.store.owner.beginConditional(
      lease,
      prefs.store,
      CloudOAuthPreferences.tokens,
    );
    if (admitted == null) throw const CredentialVaultAdmissionDenied();
    var accepted = false;
    var invoked = false;
    var failed = false;
    var retained = false;
    SavedPreferencesLease? receipt;
    try {
      if (!isCurrent() ||
          !admitted.current ||
          prefs.getString(CloudOAuthPreferences.tokens) != raw) {
        throw const CredentialVaultAdmissionDenied();
      }
      // Already owns the sixth physical FIFO. Calling the facade here would
      // re-enter the same tail; retain this EXACT delegate and settle its ack.
      invoked = true;
      accepted = await prefs.delegate.setString(
        CloudOAuthPreferences.tokens,
        next,
      );
    } catch (_) {
      if (!invoked) {
        if (!isCurrent() || !admitted.current)
          throw const CredentialVaultAdmissionDenied();
        throw const CredentialVaultException(
          CredentialVaultFailure.storageUnavailable,
        );
      }
      failed = true;
    } finally {
      retained = admitted.current;
      receipt = admitted.finish(accepted);
    }
    // The exact original plugin's true ack survives later retirement. It is a
    // storage fact only, not permission to publish or bind the new JSON owner.
    if (accepted)
      return CloudOAuthMobileMetadataOutcome._(
        acknowledged: true,
        retired: !isCurrent() || receipt?.current != true,
      );
    if (!isCurrent() || !retained) {
      throw CloudOAuthMobileMetadataCommitUnknown._(
        acknowledged: failed ? null : false,
      );
    }
    throw CredentialVaultException(
      failed
          ? CredentialVaultFailure.storageUnavailable
          : CredentialVaultFailure.verificationFailed,
    );
  }).catchError((Object error) {
    if (error is CloudOAuthRetiredCommit ||
        error is CredentialVaultException ||
        error is CredentialVaultAdmissionDenied)
      throw error;
    throw const CredentialVaultException(
      CredentialVaultFailure.storageUnavailable,
    );
  });
}

final class CloudOAuthMobileMetadataOutcome {
  const CloudOAuthMobileMetadataOutcome._({
    required this.acknowledged,
    required this.retired,
  });
  final bool acknowledged;
  final bool retired;
  bool get committedButRetired => acknowledged && retired;
  void requireCurrent(bool Function() original) {
    if (!retired && original()) return;
    if (acknowledged) throw CloudOAuthMobileMetadataCommittedButRetired._(this);
    throw const CredentialVaultAdmissionDenied();
  }

  @override
  String toString() => committedButRetired
      ? 'Cloud metadata acknowledged; operation retired'
      : 'Cloud metadata outcome';
}

final class CloudOAuthMobileMetadataCommittedButRetired
    implements CloudOAuthRetiredCommit {
  const CloudOAuthMobileMetadataCommittedButRetired._(this.receipt);
  final CloudOAuthMobileMetadataOutcome receipt;
  @override
  String toString() => 'Cloud metadata acknowledged; operation retired';
}

/// The original plugin setter was invoked but did not acknowledge success.
/// A false acknowledgement or thrown failure cannot prove no durable effect.
final class CloudOAuthMobileMetadataCommitUnknown
    implements CloudOAuthRetiredCommit {
  const CloudOAuthMobileMetadataCommitUnknown._({required this.acknowledged});
  final bool? acknowledged;
  bool get writeInvoked => true;
  bool? get committed => null;
  @override
  String toString() =>
      'Cloud metadata setter invoked; commit unknown; operation retired';
}

bool _containsOAuthMaterial(Object? value, [int depth = 0]) {
  if (depth > 12) return true;
  if (value is Map) {
    return value.entries.any((e) {
      final key = e.key.toString().toLowerCase().replaceAll('_', '');
      return const {
            'accesstoken',
            'refreshtoken',
            'token',
            'code',
            'authorizationcode',
            'clientsecret',
            'codeverifier',
          }.contains(key) ||
          _containsOAuthMaterial(e.value, depth + 1);
    });
  }
  if (value is List)
    return value.any((e) => _containsOAuthMaterial(e, depth + 1));
  return false;
}
