import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:glaze_flutter/core/support_report/support_report_crypto.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:glaze_flutter/core/support_report/support_report_json.dart';
import 'package:glaze_flutter/core/support_report/support_report_private_key_store.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';

/// SYNTHETIC ONLY. Parent executes this native test; no operator keys involved.
void main() {
  test(
    'DPAPI CurrentUser protected synthetic key roundtrip, overwrite and wrong entropy refusal',
    () async {
      final sodium = await SodiumInit.init();
      final keys = sodium.crypto.box.keyPair();
      final dir = await Directory.systemTemp.createTemp(
        'astoria-synthetic-report-key-',
      );
      final path = '${dir.path}${Platform.pathSeparator}synthetic.key';
      final recipient = SupportReportRecipient(
        keyId: 'synthetic-only',
        publicKey: keys.publicKey,
      );
      final store = SupportReportPrivateKeyStore(sodium);
      try {
        if (!Platform.isWindows) {
          expect(
            () => store.create(path, recipient, keys.secretKey),
            throwsA(isA<SupportReportException>()),
          );
          return;
        }
        store.create(path, recipient, keys.secretKey);
        expect(
          () => store.create(path, recipient, keys.secretKey),
          throwsA(isA<SupportReportException>()),
        );
        final stored = await File(path).readAsBytes();
        expect(stored.length, greaterThan(32));
        final containsRawKey = keys.secretKey.runUnlockedSync((private) {
          for (
            var start = 0;
            start + private.length <= stored.length;
            start++
          ) {
            var equal = true;
            for (var i = 0; i < private.length; i++) {
              if (stored[start + i] != private[i]) {
                equal = false;
                break;
              }
            }
            if (equal) return true;
          }
          return false;
        });
        expect(containsRawKey, isFalse); // failure cannot print private bytes
        final loaded = store.load(path, recipient);
        try {
          const id = '1234567890abcdef1234567890abcdef';
          final payload = SupportReportJson.canonical({
            'version': 1,
            'reportId': id,
            'createdDay': 20000,
            'blocks': <Object?>[],
            'omissions': <Object?>[],
          });
          final crypto = SupportReportCrypto(sodium);
          final packet = crypto.encrypt(
            payloadJson: payload,
            recipient: recipient,
            reportId: id,
            createdDay: 20000,
          );
          expect(
            crypto.decrypt(
              packet: packet,
              recipient: recipient,
              privateKey: loaded,
            ),
            payload,
          );
        } finally {
          loaded.dispose();
        }
        final wrong = SupportReportRecipient(
          keyId: 'synthetic-wrong',
          publicKey: keys.publicKey,
        );
        expect(
          () => store.load(path, wrong),
          throwsA(isA<SupportReportException>()),
        );
        final tampered = Uint8List.fromList(stored);
        tampered[tampered.length - 1] ^= 1;
        await File(path).writeAsBytes(tampered, flush: true);
        expect(
          () => store.load(path, recipient),
          throwsA(isA<SupportReportException>()),
        );
      } finally {
        keys.secretKey.dispose();
        await dir.delete(
          recursive: true,
        ); // Only this test-created synthetic directory.
      }
    },
  );
}
