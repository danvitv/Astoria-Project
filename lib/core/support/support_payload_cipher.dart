import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

import '../credentials/credential_slot.dart';
import '../credentials/credential_vault.dart';

part 'support_cipher_key_store.dart';
part 'support_cipher_envelope.dart';
part 'support_cipher_read_gate.dart';

enum SupportCipherFailure {
  vaultUnavailable,
  keyMissing,
  invalidKey,
  invalidContext,
  malformedEnvelope,
  authenticationFailed,
  inputTooLarge,
}

/// Deliberately omits underlying errors, keys, nonces, and plaintext payloads.
final class SupportCipherException implements Exception {
  const SupportCipherException(this.failure);

  final SupportCipherFailure failure;

  @override
  String toString() => 'SupportCipherException(${failure.name})';
}

/// Encrypts and decrypts support-assistant payloads at rest in SQLite using
/// `XChaCha20-Poly1305` AEAD with a per-installation 256-bit key stored in
/// [CredentialVault] and context-bound AAD.
final class SupportPayloadCipher {
  SupportPayloadCipher({
    required CredentialVault vault,
    Cipher? cipher,
    this.maxPlaintextBytes = 1024 * 1024,
    this.maxEnvelopeChars = 2 * 1024 * 1024,
    this.maxIdentifierBytes = 1024,
    // Keep the dependency private while preserving a public named argument.
    // ignore: prefer_initializing_formals
  }) : _keys = _SupportCipherKeyStore(vault),
       _cipher = cipher ?? Xchacha20.poly1305Aead(),
       _envelope = _SupportCipherEnvelope(maxPlaintextBytes, maxEnvelopeChars),
       _readOnly = null;

  /// Trusted read-only composition over the SAME installation-key owner.
  /// The gate wraps all original decrypt work, including vault/FIFO waits, and
  /// must race only this pure crypto future, never a SQL-owning reader callback.
  /// It is not a permission grant or a sandbox for arbitrary Dart callbacks.
  factory SupportPayloadCipher.readOnly({
    required SupportPayloadCipher delegate,
    required SupportCipherReadGate gate,
  }) => SupportPayloadCipher._readOnly(delegate, gate);

  SupportPayloadCipher._readOnly(
    SupportPayloadCipher delegate,
    SupportCipherReadGate gate,
  ) : _keys = delegate._keys,
      _cipher = delegate._cipher,
      _envelope = delegate._envelope,
      maxPlaintextBytes = delegate.maxPlaintextBytes,
      maxEnvelopeChars = delegate.maxEnvelopeChars,
      maxIdentifierBytes = delegate.maxIdentifierBytes,
      _readOnly = _SupportCipherReadDelegate(delegate, gate);

  static final CredentialSlot installKeySlot = CredentialSlot(
    domain: 'support.install_key',
    id: 'v1',
  );

  static const int envelopeVersion = 1;
  static const String algorithmName = 'XChaCha20-Poly1305';
  static const int _keyLengthBytes = 32;
  static const int _nonceLengthBytes = 24;
  static const int _macLengthBytes = 16;

  final _SupportCipherKeyStore _keys;
  final Cipher _cipher;
  final _SupportCipherEnvelope _envelope;
  final _SupportCipherReadDelegate? _readOnly;
  final int maxPlaintextBytes;
  final int maxEnvelopeChars;
  final int maxIdentifierBytes;

  /// Recovery preflight even when the selected DB has zero encrypted rows.
  /// Resolves the SAME key owner read-only and destroys all temporary key data.
  Future<void> requireExistingInstallationKey() async {
    final readOnly = _readOnly;
    if (readOnly != null) {
      await readOnly.run(() async {
        await readOnly.delegate.requireExistingInstallationKey();
        return '';
      });
      return;
    }
    final key = await _keys.resolve(createIfAbsent: false);
    key.destroy();
  }

  Future<String> encrypt({
    required String plaintext,
    required String table,
    required String rowId,
    required String field,
    String? sessionId,
  }) async {
    if (_readOnly != null) {
      throw const SupportCipherException(SupportCipherFailure.invalidContext);
    }
    final aad = _buildAad(
      table: table,
      rowId: rowId,
      field: field,
      sessionId: sessionId,
    );
    // Count UTF-8 bytes without allocating an unbounded encoding first.
    final byteLength = _boundedUtf8Length(plaintext, maxPlaintextBytes);
    final expectedEnvelopeLength = 108 + 4 * ((byteLength + 2) ~/ 3);
    if (maxEnvelopeChars < expectedEnvelopeLength) {
      throw const SupportCipherException(SupportCipherFailure.inputTooLarge);
    }
    final clearBytes = utf8.encode(plaintext);
    SecretKeyData? secretKey;
    try {
      secretKey = await _keys.resolve(createIfAbsent: true);
      final nonce = _cipher.newNonce();
      if (nonce.length != _nonceLengthBytes) {
        throw const SupportCipherException(
          SupportCipherFailure.malformedEnvelope,
        );
      }
      final secretBox = await _cipher.encrypt(
        clearBytes,
        secretKey: secretKey,
        nonce: nonce,
        aad: aad,
      );
      if (secretBox.mac.bytes.length != _macLengthBytes) {
        throw const SupportCipherException(
          SupportCipherFailure.malformedEnvelope,
        );
      }
      final envelope = jsonEncode(<String, Object>{
        'v': envelopeVersion,
        'alg': algorithmName,
        'n': base64UrlEncode(secretBox.nonce),
        'c': base64UrlEncode(secretBox.cipherText),
        't': base64UrlEncode(secretBox.mac.bytes),
      });
      if (envelope.length > maxEnvelopeChars) {
        throw const SupportCipherException(SupportCipherFailure.inputTooLarge);
      }
      return envelope;
    } on SupportCipherException {
      rethrow;
    } catch (_) {
      throw const SupportCipherException(
        SupportCipherFailure.malformedEnvelope,
      );
    } finally {
      secretKey?.destroy();
      clearBytes.fillRange(0, clearBytes.length, 0);
    }
  }

  Future<String> decrypt({
    required String envelopeText,
    required String table,
    required String rowId,
    required String field,
    String? sessionId,
  }) async {
    final readOnly = _readOnly;
    if (readOnly != null) {
      return readOnly.run(
        () => readOnly.delegate.decrypt(
          envelopeText: envelopeText,
          table: table,
          rowId: rowId,
          field: field,
          sessionId: sessionId,
        ),
      );
    }
    final aad = _buildAad(
      table: table,
      rowId: rowId,
      field: field,
      sessionId: sessionId,
    );
    final parsed = _envelope.parse(envelopeText);
    final secretKey = await _keys.resolve(createIfAbsent: false);
    List<int>? clearBytes;
    try {
      clearBytes = await _cipher.decrypt(
        SecretBox(parsed.cipherText, nonce: parsed.nonce, mac: Mac(parsed.mac)),
        secretKey: secretKey,
        aad: aad,
      );
      return utf8.decode(clearBytes);
    } on SecretBoxAuthenticationError {
      throw const SupportCipherException(
        SupportCipherFailure.authenticationFailed,
      );
    } on FormatException {
      throw const SupportCipherException(
        SupportCipherFailure.malformedEnvelope,
      );
    } on SupportCipherException {
      rethrow;
    } catch (_) {
      throw const SupportCipherException(
        SupportCipherFailure.authenticationFailed,
      );
    } finally {
      secretKey.destroy();
      clearBytes?.fillRange(0, clearBytes.length, 0);
    }
  }

  List<int> _buildAad({
    required String table,
    required String rowId,
    required String field,
    String? sessionId,
  }) {
    for (final identifier in [table, rowId, field, ?sessionId]) {
      if (identifier.length > maxIdentifierBytes) {
        throw const SupportCipherException(SupportCipherFailure.invalidContext);
      }
      try {
        _boundedUtf8Length(identifier, maxIdentifierBytes);
      } on SupportCipherException {
        throw const SupportCipherException(SupportCipherFailure.invalidContext);
      }
    }
    if (table.trim().isEmpty ||
        rowId.trim().isEmpty ||
        field.trim().isEmpty ||
        table.contains('|') ||
        rowId.contains('|') ||
        field.contains('|') ||
        (sessionId != null && sessionId.contains('|'))) {
      throw const SupportCipherException(SupportCipherFailure.invalidContext);
    }
    return utf8.encode(
      'astoria.support.v1|$table|$rowId|${sessionId ?? ""}|$field',
    );
  }
}

/// Matches Dart's UTF-8 replacement behavior for unpaired surrogates.
int _boundedUtf8Length(String text, int limit) {
  if (limit < 0 || text.length > limit) {
    throw const SupportCipherException(SupportCipherFailure.inputTooLarge);
  }
  var bytes = 0;
  for (var i = 0; i < text.length; i++) {
    final unit = text.codeUnitAt(i);
    if (unit < 0x80) {
      bytes++;
    } else if (unit < 0x800) {
      bytes += 2;
    } else if (unit >= 0xd800 &&
        unit <= 0xdbff &&
        i + 1 < text.length &&
        text.codeUnitAt(i + 1) >= 0xdc00 &&
        text.codeUnitAt(i + 1) <= 0xdfff) {
      bytes += 4;
      i++;
    } else {
      bytes += 3;
    }
    if (bytes > limit) {
      throw const SupportCipherException(SupportCipherFailure.inputTooLarge);
    }
  }
  return bytes;
}
