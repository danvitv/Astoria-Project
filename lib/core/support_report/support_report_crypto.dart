import 'dart:convert';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'support_report_error.dart';
import 'support_report_json.dart';
import 'support_report_payload.dart';
import 'support_report_recipient.dart';

/// Real libsodium sealed random symmetric key + XChaCha20-Poly1305 IETF.
/// Fixed binary header, including sealed key, is authenticated as AEAD AD.
final class SupportReportCrypto {
  SupportReportCrypto(this.sodium);
  final Sodium sodium;
  static const prefixBytes = 16;
  static const maxHeaderBytes = 1024;
  static const maxPacketBytes =
      SupportReportJson.maxBytes + maxHeaderBytes + 32;
  static const _magic = [65, 83, 84, 82, 80, 84, 49, 0]; // ASTRPT1\0

  /// Strict bounded framing/header check for native save composition. This does
  /// NOT authenticate the encrypted payload; only decrypt can make that claim.
  bool isWellFormedPacket(Uint8List packet) {
    try {
      _parse(packet);
      return true;
    } catch (_) {
      return false;
    }
  }

  Uint8List encrypt({
    required String payloadJson,
    required SupportReportRecipient recipient,
    required String reportId,
    required int createdDay,
  }) {
    if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(reportId) ||
        createdDay < 0 ||
        createdDay > 1000000) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    SupportReportPayload.validate(
      payloadJson,
      reportId: reportId,
      createdDay: createdDay,
    );
    final plain = Uint8List.fromList(utf8.encode(payloadJson));
    SecureKey? key;
    try {
      final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
      key = aead.keygen();
      final nonce = sodium.randombytes.buf(24);
      final sealed = key.runUnlockedSync(
        (bytes) => sodium.crypto.box.seal(
          message: bytes,
          publicKey: recipient.publicKey,
        ),
      );
      final header = Uint8List.fromList(
        utf8.encode(
          SupportReportJson.canonical({
            'version': 1,
            'algorithm': 'sealedbox-xchacha20poly1305-ietf',
            'keyId': recipient.keyId,
            'reportId': reportId,
            'createdDay': createdDay,
            'nonce': base64Encode(nonce),
            'sealedKey': base64Encode(sealed),
          }),
        ),
      );
      final prefix = _prefix(header.length, plain.length + 16);
      final ad = Uint8List.fromList([...prefix, ...header]);
      final cipher = aead.encrypt(
        message: plain,
        nonce: nonce,
        key: key,
        additionalData: ad,
      );
      return Uint8List.fromList([...ad, ...cipher]);
    } on SupportReportException {
      rethrow;
    } catch (_) {
      throw const SupportReportException(
        SupportReportFailure.authenticationFailed,
      );
    } finally {
      key?.dispose();
      plain.fillRange(0, plain.length, 0);
    }
  }

  /// No decoded payload/header is returned until BOTH sealed-key opening and
  /// whole-header AEAD authentication succeed. No plaintext file is involved.
  String decrypt({
    required Uint8List packet,
    required SupportReportRecipient recipient,
    required SecureKey privateKey,
  }) {
    Uint8List? opened, plain;
    SecureKey? key;
    try {
      final (ad, cipher, header) = _parse(packet);
      if (header['keyId'] != recipient.keyId) {
        throw const SupportReportException(
          SupportReportFailure.authenticationFailed,
        );
      }
      opened = sodium.crypto.box.sealOpen(
        cipherText: _bytes(header['sealedKey'], 80),
        publicKey: recipient.publicKey,
        secretKey: privateKey,
      );
      if (opened.length != 32) {
        throw const SupportReportException(
          SupportReportFailure.authenticationFailed,
        );
      }
      key = sodium.secureCopy(opened);
      opened.fillRange(0, opened.length, 0);
      plain = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: cipher,
        nonce: _bytes(header['nonce'], 24),
        key: key,
        additionalData: ad,
      );
      final text = utf8.decode(plain);
      SupportReportPayload.validate(
        text,
        reportId: header['reportId'] as String,
        createdDay: header['createdDay'] as int,
      );
      return text;
    } on SupportReportException {
      rethrow;
    } catch (_) {
      throw const SupportReportException(
        SupportReportFailure.authenticationFailed,
      );
    } finally {
      key?.dispose();
      opened?.fillRange(0, opened.length, 0);
      plain?.fillRange(0, plain.length, 0);
    }
  }

  (Uint8List, Uint8List, Map<String, dynamic>) _parse(Uint8List packet) {
    if (packet.length > maxPacketBytes) {
      throw const SupportReportException(SupportReportFailure.tooLarge);
    }
    if (packet.length < prefixBytes ||
        !_magic.asMap().entries.every((e) => packet[e.key] == e.value)) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    final data = ByteData.sublistView(packet);
    final headerLength = data.getUint32(8, Endian.big);
    final cipherLength = data.getUint32(12, Endian.big);
    if (headerLength < 1 ||
        headerLength > maxHeaderBytes ||
        cipherLength < 16 ||
        cipherLength > SupportReportJson.maxBytes + 16 ||
        packet.length != prefixBytes + headerLength + cipherLength) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    final offset = prefixBytes + headerLength;
    final text = utf8.decode(packet.sublist(prefixBytes, offset));
    final map = SupportReportJson.decode(text, limit: maxHeaderBytes);
    if (map is! Map<String, dynamic> ||
        map.length != 7 ||
        !map.keys.toSet().containsAll([
          'version',
          'algorithm',
          'keyId',
          'reportId',
          'createdDay',
          'nonce',
          'sealedKey',
        ]) ||
        map['version'] is! int ||
        map['version'] != 1 ||
        map['algorithm'] != 'sealedbox-xchacha20poly1305-ietf' ||
        map['keyId'] is! String ||
        !SupportReportRecipient.validKeyId(map['keyId'] as String) ||
        map['reportId'] is! String ||
        !RegExp(r'^[a-f0-9]{32}$').hasMatch(map['reportId'] as String) ||
        map['createdDay'] is! int ||
        (map['createdDay'] as int) < 0 ||
        (map['createdDay'] as int) > 1000000 ||
        SupportReportJson.canonical(map) != text) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    _bytes(map['nonce'], 24);
    _bytes(map['sealedKey'], 80);
    return (
      Uint8List.sublistView(packet, 0, offset),
      Uint8List.sublistView(packet, offset),
      map,
    );
  }

  Uint8List _bytes(Object? value, int length) {
    if (value is! String || value.length != ((length + 2) ~/ 3) * 4) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    final bytes = base64Decode(value);
    if (bytes.length != length || base64Encode(bytes) != value) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    return bytes;
  }

  Uint8List _prefix(int header, int cipher) {
    final bytes = Uint8List(prefixBytes)..setRange(0, 8, _magic);
    ByteData.sublistView(bytes)
      ..setUint32(8, header, Endian.big)
      ..setUint32(12, cipher, Endian.big);
    return bytes;
  }
}
