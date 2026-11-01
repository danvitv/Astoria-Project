import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:glaze_flutter/core/support_report/support_report_crypto.dart';
import 'package:glaze_flutter/core/support_report/support_report_json.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';

/// Parent-run native subprocess evidence: the pure Dart native-asset CLI bundle.
/// All files and keys are synthetic, generated within THIS owned Temp fixture.
void main() {
  test(
    'standalone synthetic CLI keygen/decode emits no private console material',
    () async {
      if (!Platform.isWindows) return;
      final approvedTemp = Directory('${Directory.systemTemp.path}/opencode');
      final temp = approvedTemp.existsSync()
          ? approvedTemp
          : Directory.systemTemp;
      final dir = await temp.createTemp('astoria-synthetic-report-cli-');
      final buildDir = await temp.createTemp('astoria-synthetic-cli-build-');
      final privatePath = '${dir.path}${Platform.pathSeparator}private.key';
      final publicPath = '${dir.path}${Platform.pathSeparator}recipient.json';
      final packetPath = '${dir.path}${Platform.pathSeparator}report.astrpt';
      try {
        // SDK/compiler output is separate, BEFORE generating any synthetic key.
        // Program stdout/stderr assertions below remain exact and unfiltered.
        final build = await Process.run('dart', [
          'build',
          'cli',
          '--target',
          'bin/support_report_cli.dart',
          '--output',
          buildDir.path,
        ], runInShell: true);
        expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');
        final binaries = await Directory(
          '${buildDir.path}/bundle/bin',
        ).list().toList();
        final executable = binaries.whereType<File>().singleWhere(
          (file) => file.path.endsWith('.exe'),
        );
        Future<ProcessResult> cli(List<String> args) =>
            Process.run(executable.path, args);
        final created = await cli([
          'keygen',
          '--private',
          privatePath,
          '--public',
          publicPath,
          '--key-id',
          'synthetic-cli-only',
        ]);
        expect(created.exitCode, 0);
        expect(
          (created.stdout as String).trim(),
          'Protected private key and public descriptor created. Keep the private file on this Windows account and machine.',
        );
        expect(created.stderr, isEmpty);
        final descriptor = await File(publicPath).readAsString();
        expect(jsonDecode(descriptor), isNot(contains('privateKey')));
        final recipient = SupportReportRecipient.parse(descriptor)!;
        final sodium = await SodiumInit.init();
        const id = 'abcdef0123456789abcdef0123456789';
        final json = SupportReportJson.canonical({
          'version': 1,
          'reportId': id,
          'createdDay': 20001,
          'blocks': <Object?>[
            {
              'id': 'environment',
              'title': 'Synthetic fact',
              'personal': false,
              'dependencies': <String>[],
              'content': 'synthetic-visible-only',
            },
          ],
          'omissions': <Object?>[],
        });
        final packet = SupportReportCrypto(sodium).encrypt(
          payloadJson: json,
          recipient: recipient,
          reportId: id,
          createdDay: 20001,
        );
        await File(packetPath).writeAsBytes(packet, flush: true);
        final decoded = await cli([
          'decode',
          '--private',
          privatePath,
          '--public',
          publicPath,
          '--input',
          packetPath,
        ]);
        expect(decoded.exitCode, 0);
        expect((decoded.stdout as String).trim(), json);
        expect(decoded.stderr, isEmpty);
        final damaged = Uint8List.fromList(packet);
        damaged[damaged.length - 1] ^= 1;
        await File(packetPath).writeAsBytes(damaged, flush: true);
        final refused = await cli([
          'decode',
          '--private',
          privatePath,
          '--public',
          publicPath,
          '--input',
          packetPath,
        ]);
        expect(refused.exitCode, 2);
        expect(refused.stdout, isEmpty);
        expect(
          (refused.stderr as String).trim(),
          'Support report CLI refused: authenticationFailed.',
        );
        expect(
          (await dir.list().toList()).length,
          3,
        ); // no decoded JSON, ZIP or temp plaintext artifact
      } finally {
        await dir.delete(recursive: true);
        await buildDir.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 3)),
  );
}
