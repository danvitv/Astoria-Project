import 'dart:convert';
import 'dart:typed_data';

import 'support_report_error.dart';
import 'support_report_json.dart';

final class SupportReportRecipient {
  SupportReportRecipient({required this.keyId, required Uint8List publicKey})
    : _publicKey = Uint8List.fromList(publicKey) {
    if (!validKeyId(keyId) ||
        _publicKey.length != 32 ||
        _publicKey.every((b) => b == 0)) {
      throw const SupportReportException(SupportReportFailure.invalidRecipient);
    }
  }
  final String keyId;
  final Uint8List _publicKey;
  Uint8List get publicKey => Uint8List.fromList(_publicKey);
  static bool validKeyId(String value) =>
      RegExp(r'^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$').hasMatch(value);

  static SupportReportRecipient? parse(String text) {
    try {
      final map = SupportReportJson.decode(text, limit: 1024);
      if (map is! Map<String, dynamic> ||
          map.length != 3 ||
          !map.keys.toSet().containsAll(['version', 'keyId', 'publicKey']) ||
          map['version'] is! int ||
          map['version'] != 1) {
        throw const SupportReportException(
          SupportReportFailure.invalidRecipient,
        );
      }
      if (map['keyId'] == null && map['publicKey'] == null) return null;
      final id = map['keyId'], key = map['publicKey'];
      if (id is! String || key is! String || key.length != 44) {
        throw const SupportReportException(
          SupportReportFailure.invalidRecipient,
        );
      }
      final bytes = base64Decode(key);
      if (base64Encode(bytes) != key) {
        throw const SupportReportException(
          SupportReportFailure.invalidRecipient,
        );
      }
      return SupportReportRecipient(keyId: id, publicKey: bytes);
    } catch (_) {
      throw const SupportReportException(SupportReportFailure.invalidRecipient);
    }
  }

  String get descriptorJson => SupportReportJson.canonical({
    'version': 1,
    'keyId': keyId,
    'publicKey': base64Encode(_publicKey),
  });
  bool sameAs(SupportReportRecipient? other) =>
      other != null && descriptorJson == other.descriptorJson;
  @override
  String toString() => 'SupportReportRecipient';
}
