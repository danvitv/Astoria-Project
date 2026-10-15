part of 'support_payload_cipher.dart';

/// Serializes installation-key initialization without caching key material.
final class _SupportCipherKeyStore {
  _SupportCipherKeyStore(this.vault);
  final CredentialVault vault;
  Future<void> _queue = Future<void>.value();

  Future<SecretKeyData> resolve({required bool createIfAbsent}) {
    final result = _queue.then((_) => _resolve(createIfAbsent));
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  Future<SecretKeyData> _resolve(bool createIfAbsent) async {
    Uint8List? decoded;
    try {
      final slot = SupportPayloadCipher.installKeySlot;
      if (createIfAbsent && !(await vault.metadata(slot)).configured) {
        final candidate = SecretKeyData.random(
          length: SupportPayloadCipher._keyLengthBytes,
        );
        try {
          await vault.importIfAbsent(slot, base64UrlEncode(candidate.bytes));
        } finally {
          candidate.destroy();
        }
      }
      await vault.useSecret(slot, (secret) async {
        decoded = _decode(secret);
      });
      if (decoded == null ||
          decoded!.length != SupportPayloadCipher._keyLengthBytes) {
        throw const SupportCipherException(SupportCipherFailure.invalidKey);
      }
      return SecretKeyData(
        Uint8List.fromList(decoded!),
        overwriteWhenDestroyed: true,
      );
    } on SupportCipherException {
      rethrow;
    } on CredentialVaultException catch (e) {
      throw SupportCipherException(switch (e.failure) {
        CredentialVaultFailure.missing => SupportCipherFailure.keyMissing,
        CredentialVaultFailure.storageUnavailable ||
        CredentialVaultFailure.verificationFailed =>
          SupportCipherFailure.vaultUnavailable,
      });
    } catch (_) {
      throw const SupportCipherException(SupportCipherFailure.vaultUnavailable);
    } finally {
      decoded?.fillRange(0, decoded!.length, 0);
    }
  }

  static Uint8List? _decode(String raw) {
    // A 32-byte key is 43 unpadded or 44 padded chars. Bound before trim/decode.
    if (raw.length > 128) return null;
    final trimmed = raw.trim();
    if (trimmed.length != 43 && trimmed.length != 44) return null;
    try {
      final bytes = base64Url.decode(base64Url.normalize(trimmed));
      final canonical = base64UrlEncode(bytes);
      if (trimmed != canonical && trimmed != canonical.replaceAll('=', '')) {
        bytes.fillRange(0, bytes.length, 0);
        return null;
      }
      return bytes;
    } catch (_) {
      return null;
    }
  }
}
