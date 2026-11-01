import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sodium/sodium.dart';

import 'package:glaze_flutter/core/support_report/support_report_crypto.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:glaze_flutter/core/support_report/support_report_private_key_store.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';
import 'arguments.dart';

Future<void> runSupportReportCli(List<String> args) async {
  try {
    final command = SupportReportCliArguments.parse(args);
    if (!Platform.isWindows) {
      throw const SupportReportException(
        SupportReportFailure.unsupportedPlatform,
      );
    }
    final sodium =
        await SodiumInit.init(); // Native hooks in dart run/build executable.
    final store = SupportReportPrivateKeyStore(sodium);
    if (command.command == 'keygen') {
      final keys = sodium.crypto.box.keyPair();
      try {
        final recipient = SupportReportRecipient(
          keyId: command.options['--key-id']!,
          publicKey: keys.publicKey,
        );
        // Refuse overwrite for BOTH files; do not touch existing custody.
        final publicFile = File(command.options['--public']!);
        if (await publicFile.exists()) {
          throw const SupportReportException(
            SupportReportFailure.protectedKeyUnavailable,
          );
        }
        store.create(command.options['--private']!, recipient, keys.secretKey);
        store.createDescriptor(command.options['--public']!, recipient);
        stdout.writeln(
          'Protected private key and public descriptor created. Keep the private file on this Windows account and machine.',
        );
      } finally {
        keys.secretKey.dispose();
      }
    } else {
      final descriptor = await _readBounded(
        File(command.options['--public']!),
        1024,
      );
      final recipient = SupportReportRecipient.parse(utf8.decode(descriptor));
      if (recipient == null) {
        throw const SupportReportException(
          SupportReportFailure.recipientMissing,
        );
      }
      final packet = await _readBounded(
        File(command.options['--input']!),
        SupportReportCrypto.maxPacketBytes,
      );
      final privateKey = store.load(command.options['--private']!, recipient);
      try {
        final json = SupportReportCrypto(
          sodium,
        ).decrypt(packet: packet, recipient: recipient, privateKey: privateKey);
        // Authenticated and bounded BEFORE any output. No plaintext temp or ZIP.
        stdout.writeln(json);
      } finally {
        privateKey.dispose();
      }
    }
  } on SupportReportException catch (e) {
    stderr.writeln('Support report CLI refused: ${e.failure.name}.');
    exitCode = 2;
  } catch (_) {
    stderr.writeln('Support report CLI refused: unavailable.');
    exitCode = 2;
  }
}

Future<Uint8List> _readBounded(File file, int maximum) async {
  final handle = await file.open();
  try {
    final length = await handle.length();
    if (length < 1 || length > maximum) {
      throw const SupportReportException(SupportReportFailure.tooLarge);
    }
    final bytes = await handle.read(maximum + 1);
    if (bytes.length != length || bytes.length > maximum) {
      throw const SupportReportException(SupportReportFailure.invalidPacket);
    }
    return bytes;
  } finally {
    await handle.close();
  }
}
