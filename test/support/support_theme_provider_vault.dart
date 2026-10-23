import 'package:glaze_flutter/core/credentials/credential_storage.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../credentials/fake_credential_storage.dart';

/// Fake backing with ONE declared installation-key slot, not permission to
/// resolve synthetic API/model/account credentials or delete installation keys.
final class ThemeProviderVaultStorage implements CredentialStorage {
  ThemeProviderVaultStorage(this.backing, this.block);
  final FakeCredentialStorage backing;
  final Never Function(String) block;
  static final _allowed =
      'app.astoria.credentials.v1.theme_provider_test.'
      '${SupportPayloadCipher.installKeySlot.storageSuffix}';
  void _check(String key) {
    if (key != _allowed) block('non-installation credential slot');
  }

  @override
  Future<String?> read(String key) {
    _check(key);
    return backing.read(key);
  }

  @override
  Future<void> write(String key, String value) {
    _check(key);
    return backing.write(key, value);
  }

  @override
  Future<void> delete(String key) => block('credential deletion');
}
