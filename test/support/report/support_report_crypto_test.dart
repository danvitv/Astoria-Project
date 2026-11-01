import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:glaze_flutter/core/support_report/support_report_crypto.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:glaze_flutter/core/support_report/support_report_json.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';

void main() {
  late Sodium sodium;
  late KeyPair keys;
  late SupportReportRecipient recipient;
  late SupportReportCrypto crypto;
  const reportId = '00112233445566778899aabbccddeeff';
  const day = 20750;
  late String payload;
  setUp(() async {
    sodium = await SodiumInit.init();
    keys = sodium.crypto.box.keyPair();
    recipient = SupportReportRecipient(
      keyId: 'synthetic-test',
      publicKey: keys.publicKey,
    );
    crypto = SupportReportCrypto(sodium);
    payload = SupportReportJson.canonical({
      'version': 1,
      'reportId': reportId,
      'createdDay': day,
      'blocks': [
        {
          'id': 'environment',
          'title': 'Synthetic fact',
          'personal': false,
          'dependencies': <String>[],
          'content': 'synthetic-only',
        },
      ],
      'omissions': ['bounded'],
    });
  });
  tearDown(() => keys.secretKey.dispose());

  Uint8List encrypt() => crypto.encrypt(
    payloadJson: payload,
    recipient: recipient,
    reportId: reportId,
    createdDay: day,
  );
  String decrypt(Uint8List packet) => crypto.decrypt(
    packet: packet,
    recipient: recipient,
    privateKey: keys.secretKey,
  );
  test(
    'real sealed key and AEAD decode equals exact displayed canonical payload',
    () {
      final first = encrypt(), second = encrypt();
      expect(decrypt(first), payload);
      expect(first, isNot(orderedEquals(second)));
      expect(
        utf8.decode(first, allowMalformed: true),
        isNot(contains('synthetic-only')),
      );
    },
  );
  test(
    'every immutable header field is authenticated or strictly rejected',
    () {
      final packet = encrypt();
      final length = ByteData.sublistView(packet).getUint32(8, Endian.big);
      final header =
          jsonDecode(utf8.decode(packet.sublist(16, 16 + length)))
              as Map<String, dynamic>;
      for (final entry in <String, Object>{
        'version': 2,
        'algorithm': 'hostile',
        'keyId': 'other-key',
        'reportId': '11112233445566778899aabbccddeeff',
        'createdDay': day + 1,
        'nonce': base64Encode(Uint8List(24)),
        'sealedKey': base64Encode(Uint8List(80)),
      }.entries) {
        final edited = SupportReportJson.canonical({
          ...header,
          entry.key: entry.value,
        });
        final bytes = Uint8List.fromList([
          ...packet.sublist(0, 16),
          ...utf8.encode(edited),
          ...packet.sublist(16 + length),
        ]);
        ByteData.sublistView(
          bytes,
        ).setUint32(8, utf8.encode(edited).length, Endian.big);
        expect(
          () => decrypt(bytes),
          throwsA(isA<SupportReportException>()),
          reason: entry.key,
        );
      }
    },
  );
  test(
    'ciphertext, tag, prefix, wrong recipient and wrong private key fail closed',
    () {
      final original = encrypt();
      for (final at in [0, 8, 12, original.length - 17, original.length - 1]) {
        final changed = Uint8List.fromList(original);
        changed[at] ^= 1;
        expect(() => decrypt(changed), throwsA(isA<SupportReportException>()));
      }
      final wrong = sodium.crypto.box.keyPair();
      try {
        expect(
          () => crypto.decrypt(
            packet: original,
            recipient: recipient,
            privateKey: wrong.secretKey,
          ),
          throwsA(isA<SupportReportException>()),
        );
      } finally {
        wrong.secretKey.dispose();
      }
    },
  );
  test(
    'low order public key, appended bytes and packet limits refuse finite errors',
    () {
      final low = SupportReportRecipient(
        keyId: 'synthetic-low-order',
        publicKey: Uint8List(32)..[0] = 1,
      );
      expect(
        () => crypto.encrypt(
          payloadJson: payload,
          recipient: low,
          reportId: reportId,
          createdDay: day,
        ),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => decrypt(Uint8List.fromList([...encrypt(), 0])),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => decrypt(Uint8List(SupportReportCrypto.maxPacketBytes + 1)),
        throwsA(isA<SupportReportException>()),
      );
    },
  );
  test(
    'payload depth and duplicate JSON keys are rejected before encryption',
    () {
      expect(
        () => SupportReportJson.decode('{"a":1,"\\u0061":2}'),
        throwsA(isA<SupportReportException>()),
      );
      final deep =
          '${List.filled(18, '[').join()}0${List.filled(18, ']').join()}';
      expect(
        () => SupportReportJson.decode(deep),
        throwsA(isA<SupportReportException>()),
      );
      expect(
        () => SupportReportJson.decode('{"canary-secret":NaN}'),
        throwsA(isA<SupportReportException>()),
      );
    },
  );
  test('unconfigured recipient does not fabricate a public key', () {
    expect(
      SupportReportRecipient.parse(
        '{"version":1,"keyId":null,"publicKey":null}',
      ),
      isNull,
    );
    expect(
      () => SupportReportRecipient.parse(
        '{"version":1,"keyId":"a","publicKey":null}',
      ),
      throwsA(isA<SupportReportException>()),
    );
  });
}
