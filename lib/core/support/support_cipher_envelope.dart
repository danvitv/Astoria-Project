part of 'support_payload_cipher.dart';

/// Bounded, strict wire parsing before any vault access.
final class _SupportCipherEnvelope {
  _SupportCipherEnvelope(this.maxBytes, this.maxChars);
  final int maxBytes;
  final int maxChars;
  _ParsedEnvelope parse(String text) {
    if (text.length > maxChars || maxChars < 0) {
      throw const SupportCipherException(SupportCipherFailure.inputTooLarge);
    }
    try {
      final decoded = jsonDecode(text);
      if (decoded is! Map || decoded.length != 5 ||
          decoded.keys.any((key) => !const ['v', 'alg', 'n', 'c', 't'].contains(key)) ||
          decoded['v'] is! int || decoded['v'] != SupportPayloadCipher.envelopeVersion ||
          decoded['alg'] != SupportPayloadCipher.algorithmName) {
        throw const FormatException();
      }
      final n = decoded['n'];
      final c = decoded['c'];
      final t = decoded['t'];
      if (n is! String || c is! String || t is! String || n.length != 32 || t.length != 24 ||
          maxBytes < 0 || c.length > 4 * ((maxBytes + 2) ~/ 3)) {
        throw const FormatException();
      }
      final nonce = _decode(n);
      final ciphertext = _decode(c);
      final mac = _decode(t);
      if (nonce.length != 24 || mac.length != 16 || ciphertext.length > maxBytes) {
        throw const FormatException();
      }
      return _ParsedEnvelope(nonce: nonce, cipherText: ciphertext, mac: mac);
    } catch (_) {
      throw const SupportCipherException(SupportCipherFailure.malformedEnvelope);
    }
  }
  static Uint8List _decode(String text) {
    final bytes = base64Url.decode(text);
    if (base64UrlEncode(bytes) != text) throw const FormatException();
    return bytes;
  }
}

final class _ParsedEnvelope {
  const _ParsedEnvelope({required this.nonce, required this.cipherText, required this.mac});
  final Uint8List nonce;
  final Uint8List cipherText;
  final Uint8List mac;
}
