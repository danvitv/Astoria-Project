import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/support_report/support_report_save_port.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_report_platform_save.dart';

// Synthetic ciphertext framing only. These port tests inject a trusted validator;
// cryptographic correctness belongs to the real codec tests, not a fake here.
Uint8List _packet() => Uint8List.fromList([
  65,
  83,
  84,
  82,
  80,
  84,
  49,
  0,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  16,
  123,
  ...List.filled(16, 222),
]);

bool _valid(Uint8List bytes) => bytes.length == 33 && bytes[16] == 123;
bool _current() => true;

Future<SupportReportSaveDestination?> _choose(
  SupportReportPlatformSave port, {
  bool Function() current = _current,
}) => port.chooseDestination(
  fileName: 'untrusted-private-name.json',
  isCurrent: current,
);

class _ForeignDestination implements SupportReportSaveDestination {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel(SupportReportPlatformSave.channelName);
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  group('Windows admission', () {
    test('already-stale and unsupported selectors perform no I/O', () async {
      var selects = 0, writes = 0;
      for (final platform in [
        SupportReportSavePlatform.windows,
        SupportReportSavePlatform.unsupported,
      ]) {
        final port = SupportReportPlatformSave(
          platform: platform,
          validateCiphertext: _valid,
          windowsSelector: (_) async {
            selects++;
            return 'native-path';
          },
          windowsWriter: (_, _) {
            writes++;
          },
        );
        expect(
          await _choose(
            port,
            current: () => platform == SupportReportSavePlatform.unsupported,
          ),
          isNull,
        );
      }
      expect(selects, 0);
      expect(writes, 0);
    });

    test(
      'neutral path-only selector; frozen validated ciphertext; one-use result',
      () async {
        final bytes = _packet();
        final expected = bytes.toList();
        var writes = 0, validated = false;
        final port = SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          windowsSelector: (name) async {
            expect(name, SupportReportPlatformSave.neutralFileName);
            expect(writes, 0);
            return 'private-native-selection';
          },
          validateCiphertext: (frozen) {
            expect(frozen, expected);
            // Original caller memory can change, but cannot change this packet.
            bytes.fillRange(0, bytes.length, 0);
            expect(() => frozen[0] = 0, throwsUnsupportedError);
            validated = true;
            return true;
          },
          windowsWriter: (path, frozen) {
            expect(path, 'private-native-selection');
            expect(validated, isTrue);
            expect(frozen, expected);
            writes++;
          },
        );
        final destination = (await _choose(port))!;
        expect(writes, 0);
        final result = await port.commit(
          destination: destination,
          ciphertext: bytes,
          isCurrent: _current,
        );
        expect(result.status, SupportReportSaveStatus.saved);
        expect(result.fileName, SupportReportPlatformSave.neutralFileName);
        expect(result.reason, isNull);
        expect(writes, 1);
        final replay = await port.commit(
          destination: destination,
          ciphertext: _packet(),
          isCurrent: _current,
        );
        expect(replay.status, SupportReportSaveStatus.refused);
        expect(writes, 1);
      },
    );

    test(
      'foreign/untrusted issuer does not invoke validator or writer',
      () async {
        var writes = 0, validations = 0;
        SupportReportPlatformSave makePort() => SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          windowsSelector: (_) async => 'native-selection',
          validateCiphertext: (_) {
            validations++;
            return true;
          },
          windowsWriter: (_, _) {
            writes++;
          },
        );
        final first = makePort(), second = makePort();
        final destination = (await _choose(first))!;
        await _choose(second);
        for (final other in [destination, _ForeignDestination()]) {
          final result = await second.commit(
            destination: other,
            ciphertext: _packet(),
            isCurrent: _current,
          );
          expect(result.status, SupportReportSaveStatus.refused);
        }
        expect(writes, 0);
        expect(validations, 0);
        // A foreign refusal did not consume the legitimate issuer's destination.
        expect(
          (await first.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          )).status,
          SupportReportSaveStatus.saved,
        );
      },
    );

    test(
      'cancel releases chooser promptly and drops late native path',
      () async {
        final picker = Completer<String?>(), invoked = Completer<void>();
        var writes = 0;
        final port = SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          validateCiphertext: _valid,
          windowsSelector: (_) {
            invoked.complete();
            return picker.future;
          },
          windowsWriter: (_, _) {
            writes++;
          },
        );
        final choice = _choose(port);
        await invoked.future;
        expect(
          await _choose(port),
          isNull,
        ); // Concurrent/superseded selector refused.
        await port.cancel();
        expect(await choice, isNull);
        picker.complete('late-private-path');
        expect(await _choose(port), isNull);
        expect(writes, 0);
      },
    );

    test(
      'source change across dialog rejects selection with no write',
      () async {
        final picker = Completer<String?>();
        var sourceCurrent = true, writes = 0;
        final port = SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          validateCiphertext: _valid,
          windowsSelector: (_) => picker.future,
          windowsWriter: (_, _) {
            writes++;
          },
        );
        final choice = _choose(port, current: () => sourceCurrent);
        sourceCurrent = false;
        picker.complete('native-path');
        expect(await choice, isNull);
        sourceCurrent = true; // A -> B -> A cannot revive a refused attempt.
        expect(await _choose(port), isNull);
        expect(writes, 0);
      },
    );

    for (final cause in [
      'cancel',
      'original',
      'commit',
      'throw',
      'validator',
    ]) {
      test('$cause before final admission cannot write or retry', () async {
        var original = true, commitCurrent = true, writes = 0;
        final port = SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          windowsSelector: (_) async => 'native-path',
          validateCiphertext: (_) {
            if (cause == 'validator') commitCurrent = false;
            return true;
          },
          windowsWriter: (_, _) {
            writes++;
          },
        );
        final destination = (await _choose(port, current: () => original))!;
        if (cause == 'cancel') await port.cancel();
        if (cause == 'original') original = false;
        if (cause == 'commit') commitCurrent = false;
        bool guard() {
          if (cause == 'throw') throw StateError('private details');
          return commitCurrent;
        }

        final result = await port.commit(
          destination: destination,
          ciphertext: _packet(),
          isCurrent: guard,
        );
        expect(result.status, SupportReportSaveStatus.canceled);
        original = commitCurrent = true;
        expect(
          (await port.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          )).status,
          SupportReportSaveStatus.refused,
        );
        expect(writes, 0);
      });
    }

    for (final invalid in ['empty', 'oversize', 'plaintext', 'exception']) {
      test('rejects $invalid before write and consumes destination', () async {
        var writes = 0, validations = 0;
        final port = SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          windowsSelector: (_) async => 'native-path',
          validateCiphertext: (bytes) {
            validations++;
            if (invalid == 'exception') {
              throw StateError('private validation detail');
            }
            return _valid(bytes);
          },
          windowsWriter: (_, _) {
            writes++;
          },
        );
        final destination = (await _choose(port))!;
        final bytes = switch (invalid) {
          'empty' => Uint8List(0),
          'oversize' => Uint8List(
            SupportReportPlatformSave.maxCiphertextBytes + 1,
          ),
          'plaintext' => Uint8List.fromList('private plaintext'.codeUnits),
          _ => _packet(),
        };
        final result = await port.commit(
          destination: destination,
          ciphertext: bytes,
          isCurrent: _current,
        );
        expect(result.status, SupportReportSaveStatus.refused);
        expect(result.reason, 'invalid_ciphertext');
        expect(writes, 0);
        expect(
          validations,
          invalid == 'empty' || invalid == 'oversize' ? 0 : 1,
        );
        expect(
          (await port.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          )).status,
          SupportReportSaveStatus.refused,
        );
      });
    }

    test(
      'actual temporary file contains only ciphertext, result excludes path',
      () async {
        // This suite never opens a real user file, database or Downloads folder.
        final approvedTemp = Directory(
          '${Platform.environment['LOCALAPPDATA']}\\Temp\\opencode',
        );
        final dir = approvedTemp.createTempSync('report-port-test-');
        final file = File(
          '${dir.path}${Platform.pathSeparator}ciphertext.astreport',
        );
        try {
          file.writeAsBytesSync([
            99,
            98,
          ]); // Only this test-owned overwrite fixture.
          final port = SupportReportPlatformSave(
            platform: SupportReportSavePlatform.windows,
            validateCiphertext: _valid,
            windowsSelector: (_) async => file.path,
          );
          final destination = (await _choose(port))!;
          expect(file.readAsBytesSync(), [99, 98]); // Picker did not truncate.
          final result = await port.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          );
          expect(result.status, SupportReportSaveStatus.saved);
          expect(file.readAsBytesSync(), _packet());
          expect(result.fileName, SupportReportPlatformSave.neutralFileName);
          expect(result.fileName, isNot(contains(dir.path)));
        } finally {
          if (file.existsSync()) file.deleteSync();
          dir.deleteSync();
        }
      },
      skip: !Platform.isWindows,
    );

    test(
      'post-admission outcome is truthful even when scope changes',
      () async {
        var current = true;
        final port = SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          validateCiphertext: _valid,
          windowsSelector: (_) async => 'native-path',
          windowsWriter: (_, _) {
            current = false;
          },
        );
        final destination = (await _choose(port, current: () => current))!;
        final result = await port.commit(
          destination: destination,
          ciphertext: _packet(),
          isCurrent: () => current,
        );
        expect(result.status, SupportReportSaveStatus.saved);
      },
    );

    test(
      'write failure exposes only finite incomplete code, never absence',
      () async {
        final port = SupportReportPlatformSave(
          platform: SupportReportSavePlatform.windows,
          validateCiphertext: _valid,
          windowsSelector: (_) async => 'private-native-path',
          windowsWriter: (_, _) => throw FileSystemException(
            'private exception',
            'private-native-path',
          ),
        );
        final destination = (await _choose(port))!;
        final result = await port.commit(
          destination: destination,
          ciphertext: _packet(),
          isCurrent: _current,
        );
        expect(result.status, SupportReportSaveStatus.failed);
        expect(result.reason, 'write_incomplete');
        expect(result.fileName, isNull);
      },
    );
  });

  group('Android opaque channel custody', () {
    final calls = <MethodCall>[];
    setUp(calls.clear);

    SupportReportPlatformSave makePort({
      bool Function(Uint8List) validator = _valid,
    }) => SupportReportPlatformSave(
      platform: SupportReportSavePlatform.android,
      androidChannel: channel,
      validateCiphertext: validator,
    );

    void fakeNative({
      Future<Object?> Function(MethodCall)? commit,
      Future<Object?> Function(MethodCall)? choose,
    }) {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        switch (call.method) {
          case 'beginRequest':
            expect(call.arguments, isNull);
            return {'status': 'ready', 'request': 'native-request'};
          case 'choose':
            expect(call.arguments, {
              'request': 'native-request',
              'neutralName': SupportReportPlatformSave.neutralFileName,
            });
            return choose == null
                ? {'status': 'selected', 'token': 'native-token'}
                : choose(call);
          case 'commit':
            final args = call.arguments as Map;
            expect(args.keys.toSet(), {
              'request',
              'token',
              'neutralName',
              'bytes',
            });
            expect(args['request'], 'native-request');
            expect(args['token'], 'native-token');
            expect(
              args['neutralName'],
              SupportReportPlatformSave.neutralFileName,
            );
            expect(args['bytes'], _packet());
            return commit == null
                ? {'status': 'saved', 'code': 'saved'}
                : commit(call);
          case 'cancel':
            expect(call.arguments, {'request': 'native-request'});
            return null;
          default:
            throw StateError('unexpected method');
        }
      });
    }

    test(
      'choose carries no bytes/URI; commit has only native-issued handles and ciphertext',
      () async {
        fakeNative();
        final bytes = _packet();
        final port = makePort(
          validator: (frozen) {
            bytes.fillRange(0, bytes.length, 0);
            return _valid(frozen);
          },
        );
        final destination = (await _choose(port))!;
        expect(calls.map((c) => c.method), ['beginRequest', 'choose']);
        final result = await port.commit(
          destination: destination,
          ciphertext: bytes,
          isCurrent: _current,
        );
        expect(result.status, SupportReportSaveStatus.saved);
        expect(result.fileName, SupportReportPlatformSave.neutralFileName);
        expect(calls.map((c) => c.method), [
          'beginRequest',
          'choose',
          'commit',
        ]);
      },
    );

    test(
      'source change after selector or during validator cannot send ciphertext',
      () async {
        for (final duringValidator in [false, true]) {
          calls.clear();
          fakeNative();
          var current = true;
          final port = makePort(
            validator: (_) {
              if (duringValidator) current = false;
              return true;
            },
          );
          final destination = (await _choose(port, current: () => current))!;
          if (!duringValidator) current = false;
          final result = await port.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: () => current,
          );
          expect(result.status, SupportReportSaveStatus.canceled);
          expect(calls.where((c) => c.method == 'commit'), isEmpty);
          expect(calls.last.method, 'cancel');
        }
      },
    );

    test(
      'invalid ciphertext cancels unused native document without sending payload',
      () async {
        fakeNative();
        final port = makePort(validator: (_) => false);
        final destination = (await _choose(port))!;
        final result = await port.commit(
          destination: destination,
          ciphertext: _packet(),
          isCurrent: _current,
        );
        expect(result.status, SupportReportSaveStatus.refused);
        expect(calls.where((c) => c.method == 'commit'), isEmpty);
        expect(calls.last.method, 'cancel');
      },
    );

    for (final selection in [
      {'status': 'canceled'},
      {'status': 'failed'},
      {'status': 'selected'},
      {'status': 'selected', 'token': ''},
    ]) {
      test(
        'canceled/failed/missing token selection fails closed: $selection',
        () async {
          fakeNative(choose: (_) async => selection);
          final port = makePort();
          expect(await _choose(port), isNull);
          // Allow the original observer's cleanup to complete via cancel's reply.
          await port.cancel();
          expect(calls.where((c) => c.method == 'commit'), isEmpty);
          expect(calls.last.method, 'cancel');
        },
      );
    }

    test(
      'foreign and replayed tokens cannot cause a second native write',
      () async {
        fakeNative();
        final first = makePort(), second = makePort();
        final destination = (await _choose(first))!;
        expect(
          (await second.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          )).status,
          SupportReportSaveStatus.refused,
        );
        expect(
          (await first.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          )).status,
          SupportReportSaveStatus.saved,
        );
        expect(
          (await first.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          )).status,
          SupportReportSaveStatus.refused,
        );
        expect(calls.where((c) => c.method == 'commit').length, 1);
      },
    );

    test(
      'cancel during pending selection is finite and invalidates request',
      () async {
        final pending = Completer<Object?>(), invoked = Completer<void>();
        fakeNative(
          choose: (_) {
            invoked.complete();
            return pending.future;
          },
        );
        final port = makePort();
        final choice = _choose(port);
        await invoked.future;
        await port.cancel();
        expect(await choice, isNull);
        expect(calls.last.method, 'cancel');
        pending.complete({'status': 'selected', 'token': 'late-token'});
        expect(await _choose(port), isNull);
        expect(calls.where((c) => c.method == 'commit'), isEmpty);
      },
    );

    test(
      'cancel before native-issued request returns cleans late issuer without choosing',
      () async {
        final begun = Completer<Object?>(), canceled = Completer<void>();
        messenger.setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'beginRequest') return begun.future;
          if (call.method == 'cancel') {
            expect(call.arguments, {'request': 'late-request'});
            canceled.complete();
            return null;
          }
          fail('canceled operation must not choose or commit');
        });
        final port = makePort();
        final choice = _choose(port);
        await port.cancel();
        expect(await choice, isNull);
        begun.complete({'status': 'ready', 'request': 'late-request'});
        await canceled.future;
        expect(calls.map((c) => c.method), ['beginRequest', 'cancel']);
      },
    );

    test(
      'admitted native saved reply stays saved after Dart cancel/scope change',
      () async {
        final writing = Completer<void>(), reply = Completer<Object?>();
        var current = true;
        fakeNative(
          commit: (_) {
            writing.complete();
            return reply.future;
          },
        );
        final port = makePort();
        final destination = (await _choose(port, current: () => current))!;
        final save = port.commit(
          destination: destination,
          ciphertext: _packet(),
          isCurrent: () => current,
        );
        await writing.future;
        current = false;
        await port.cancel();
        reply.complete({'status': 'saved', 'code': 'saved'});
        expect((await save).status, SupportReportSaveStatus.saved);
      },
    );

    for (final status in [
      'canceled',
      'refused',
      'failed',
      'unknown',
      'lost_reply',
    ]) {
      test(
        'finite $status outcomes do not expose native exception or URI',
        () async {
          fakeNative(
            commit: (_) async {
              if (status == 'lost_reply') {
                throw PlatformException(
                  code: 'private-uri',
                  message: 'private-content',
                );
              }
              return {'status': status, 'code': 'untrusted-provider-exception'};
            },
          );
          final port = makePort();
          final destination = (await _choose(port))!;
          final result = await port.commit(
            destination: destination,
            ciphertext: _packet(),
            isCurrent: _current,
          );
          expect(result.status, switch (status) {
            'canceled' => SupportReportSaveStatus.canceled,
            'refused' => SupportReportSaveStatus.refused,
            _ => SupportReportSaveStatus.failed,
          });
          expect(result.reason, isNot(contains('private')));
          expect(result.reason, isNot(contains('provider')));
          expect(result.fileName, isNull);
        },
      );
    }
  });
}
