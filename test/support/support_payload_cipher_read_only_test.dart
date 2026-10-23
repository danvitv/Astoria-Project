import 'dart:async' show unawaited;
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import 'helpers/read_only_cipher_fixture.dart';

Matcher _failure(SupportCipherFailure failure) => throwsA(
  isA<SupportCipherException>().having(
    (e) => e.failure,
    'fixed failure',
    failure,
  ),
);

void main() {
  test(
    'same owner/config; unchanged real envelope/AAD/empty roundtrip',
    () async {
      final f = ReadOnlyCipherFixture(
        maxPlaintextBytes: 4096,
        maxEnvelopeChars: 8192,
        maxIdentifierBytes: 128,
      );
      await f.seed();
      var calls = 0;
      final read = SupportPayloadCipher.readOnly(
        delegate: f.owner,
        gate: (pure) {
          calls++;
          return pure();
        },
      );
      expect(read.maxPlaintextBytes, 4096);
      expect(read.maxEnvelopeChars, 8192);
      expect(read.maxIdentifierBytes, 128);
      final before = Map<String, String>.from(f.storage.values);
      expect(await f.decrypt(read), ReadOnlyCipherFixture.text);
      expect(calls, 1);
      expect(f.storage.operations, ['read']);
      expect(f.storage.values, before);
      final envelope = jsonDecode(f.envelope) as Map<String, dynamic>;
      expect(envelope.keys.toSet(), {'v', 'alg', 'n', 'c', 't'});
      expect(envelope['v'], 1);
      expect(envelope['alg'], 'XChaCha20-Poly1305');
      expect(base64Url.decode(envelope['n'] as String), hasLength(24));
      expect(base64Url.decode(envelope['t'] as String), hasLength(16));
      for (final wrong in [
        () => f.decrypt(read, table: 'support_sessions'),
        () => f.decrypt(read, rowId: 'wrong'),
        () => f.decrypt(read, sessionId: 'wrong'),
        () => f.decrypt(read, sessionId: null),
        () => f.decrypt(read, field: 'cards_ciphertext'),
      ]) {
        await expectLater(
          wrong(),
          _failure(SupportCipherFailure.authenticationFailed),
        );
      }
      final empty = await f.encrypt(f.owner, plaintext: '');
      expect(await f.decrypt(read, envelopeText: empty), '');
      expect(await f.decrypt(f.owner), ReadOnlyCipherFixture.text);
      expect(f.storage.values, before);
    },
  );

  for (final initialized in [false, true]) {
    test(
      'read-only encrypt rejects before gate/context/size/storage/nonce; existing key $initialized',
      () async {
        final f = ReadOnlyCipherFixture();
        if (initialized) await f.seed();
        final before = Map<String, String>.from(f.storage.values);
        final read = SupportPayloadCipher.readOnly(
          delegate: f.owner,
          gate: (_) => throw StateError('Encrypt must not enter read gate'),
        );
        f.storage.readError = const UnprintableReadError();
        f.storage.writeError = const UnprintableReadError();
        for (final invalid in [false, true]) {
          await expectLater(
            read.encrypt(
              plaintext: invalid ? 'x' * (1024 * 1024 + 1) : 'SYNTHETIC_CANARY',
              table: invalid ? 'bad|table' : 'support_messages',
              rowId: invalid ? '' : 'history',
              field: 'body_ciphertext',
            ),
            _failure(SupportCipherFailure.invalidContext),
          );
        }
        expect(f.storage.operations, isEmpty);
        expect(f.storage.values, before);
        expect(f.primitive.decryptAads, isEmpty);
        expect(f.primitive.nonceCalls, 0);
        expect(f.primitive.encryptCalls, 0);
      },
    );
  }

  test(
    'gate denial encloses even invalid AAD/envelope; preserves safe failure',
    () async {
      final f = ReadOnlyCipherFixture();
      final read = SupportPayloadCipher.readOnly(
        delegate: f.owner,
        gate: (_) async => throw const SupportCipherException(
          SupportCipherFailure.vaultUnavailable,
        ),
      );
      await expectLater(
        read.decrypt(envelopeText: 'not-json', table: '', rowId: '', field: ''),
        _failure(SupportCipherFailure.vaultUnavailable),
      );
      expect(f.storage.operations, isEmpty);
      expect(f.primitive.decryptAads, isEmpty);
      expect(
        const SupportCipherException(
          SupportCipherFailure.invalidContext,
        ).toString(),
        'SupportCipherException(invalidContext)',
      );
    },
  );

  test(
    'successful escaped thunk cannot run later; separate concurrent reads remain independent',
    () async {
      final f = ReadOnlyCipherFixture();
      await f.seed();
      final thunks = <Future<String> Function()>[];
      final read = SupportPayloadCipher.readOnly(
        delegate: f.owner,
        gate: (pure) {
          thunks.add(pure);
          return pure();
        },
      );
      expect(
        await Future.wait(List.generate(4, (_) => f.decrypt(read))),
        List.filled(4, ReadOnlyCipherFixture.text),
      );
      expect(f.storage.operations, List.filled(4, 'read'));
      for (final thunk in thunks) {
        await expectLater(
          thunk(),
          _failure(SupportCipherFailure.invalidContext),
        );
      }
      expect(f.storage.operations, List.filled(4, 'read'));
    },
  );

  test(
    'malformed/oversize/context/tamper preserve original safe failures',
    () async {
      final f = ReadOnlyCipherFixture(
        maxPlaintextBytes: 4096,
        maxEnvelopeChars: 8192,
      );
      await f.seed();
      final read = SupportPayloadCipher.readOnly(
        delegate: f.owner,
        gate: (p) => p(),
      );
      for (final text in [
        'not-json',
        '{}',
        f.envelope.replaceFirst('"v":1', '"v":2'),
      ]) {
        await expectLater(
          f.decrypt(read, envelopeText: text),
          _failure(SupportCipherFailure.malformedEnvelope),
        );
      }
      await expectLater(
        f.decrypt(read, envelopeText: 'x' * 8193),
        _failure(SupportCipherFailure.inputTooLarge),
      );
      await expectLater(
        f.decrypt(read, rowId: 'bad|id'),
        _failure(SupportCipherFailure.invalidContext),
      );
      expect(f.storage.operations, isEmpty);
      for (final field in ['n', 'c', 't']) {
        final map = jsonDecode(f.envelope) as Map<String, dynamic>;
        final original = map[field] as String;
        map[field] =
            '${original[0] == 'A' ? 'B' : 'A'}${original.substring(1)}';
        await expectLater(
          f.decrypt(read, envelopeText: jsonEncode(map)),
          _failure(SupportCipherFailure.authenticationFailed),
        );
      }
    },
  );

  test(
    'fresh key loss/corruption/wrong key/restore; no decrypt caching/writes',
    () async {
      final f = ReadOnlyCipherFixture();
      await f.seed();
      final key = f.storage.values.keys.single;
      final original = f.storage.values[key]!; // Synthetic fixture only.
      final read = SupportPayloadCipher.readOnly(
        delegate: f.owner,
        gate: (p) => p(),
      );
      expect(await f.decrypt(read), ReadOnlyCipherFixture.text);
      f.storage.values.remove(key);
      await expectLater(
        f.decrypt(read),
        _failure(SupportCipherFailure.keyMissing),
      );
      await expectLater(
        f.decrypt(f.owner),
        _failure(SupportCipherFailure.keyMissing),
      );
      f.storage.values[key] = 'bad';
      await expectLater(
        f.decrypt(read),
        _failure(SupportCipherFailure.invalidKey),
      );
      f.storage.values[key] = base64UrlEncode(List<int>.filled(32, 37));
      await expectLater(
        f.decrypt(read),
        _failure(SupportCipherFailure.authenticationFailed),
      );
      f.storage.values[key] = original;
      f.storage.readError = const UnprintableReadError();
      await expectLater(
        f.decrypt(read),
        _failure(SupportCipherFailure.vaultUnavailable),
      );
      f.storage.readError = null;
      expect(await f.decrypt(read), ReadOnlyCipherFixture.text);
      expect(await f.decrypt(f.owner), ReadOnlyCipherFixture.text);
      expect(f.storage.operations.every((op) => op == 'read'), true);
      expect(f.storage.values[key], original);
    },
  );

  for (final kind in [
    'zero',
    'forged-before',
    'forged-after',
    'double',
    'raw-sync',
    'raw-async',
  ]) {
    test(
      'gate misuse fails safely: $kind; escaped thunk never starts later',
      () async {
        final f = ReadOnlyCipherFixture();
        await f.seed();
        late Future<String> Function() escaped;
        Future<String>? secondAttempt;
        final read = SupportPayloadCipher.readOnly(
          delegate: f.owner,
          gate: kind == 'raw-sync'
              ? (pure) {
                  escaped = pure;
                  throw const UnprintableReadError();
                }
              : (pure) async {
                  escaped = pure;
                  switch (kind) {
                    case 'zero':
                      throw const SupportCipherException(
                        SupportCipherFailure.vaultUnavailable,
                      );
                    case 'forged-before':
                      return 'SYNTHETIC_FORGED_PLAINTEXT';
                    case 'forged-after':
                      await pure();
                      return 'SYNTHETIC_FORGED_PLAINTEXT';
                    case 'double':
                      final actual = await pure();
                      secondAttempt = pure();
                      await secondAttempt!.then<void>(
                        (_) {},
                        onError: (Object _, StackTrace _) {},
                      );
                      return actual; // Caught misuse still poisons this read.
                    case 'raw-sync':
                      throw const UnprintableReadError();
                    default:
                      await Future<void>.value();
                      throw const UnprintableReadError();
                  }
                },
        );
        await expectLater(
          f.decrypt(read),
          _failure(
            kind == 'zero'
                ? SupportCipherFailure.vaultUnavailable
                : SupportCipherFailure.invalidContext,
          ),
        );
        if (secondAttempt != null) {
          await expectLater(
            secondAttempt!,
            _failure(SupportCipherFailure.invalidContext),
          );
        }
        final operations = List<String>.from(f.storage.operations);
        await expectLater(
          escaped(),
          _failure(SupportCipherFailure.invalidContext),
        );
        expect(f.storage.operations, operations);
        expect(
          f.storage.reads,
          ['forged-after', 'double'].contains(kind) ? 1 : 0,
        );
      },
    );
  }

  test(
    'one-shot even while pending; no plaintext returned after early gate exit',
    () async {
      final f = ReadOnlyCipherFixture();
      await f.seed();
      final pause = ReadPause();
      addTearDown(pause.release);
      f.storage.beforeRead = pause.hold;
      late Future<String> pendingPure;
      late Future<String> secondAttempt;
      late Future<String> Function() escaped;
      final read = SupportPayloadCipher.readOnly(
        delegate: f.owner,
        gate: (pure) async {
          escaped = pure;
          pendingPure = pure();
          await pause.entered.future;
          secondAttempt = pure();
          return 'SYNTHETIC_FORGED_EARLY';
        },
      );
      await expectLater(
        f.decrypt(read),
        _failure(SupportCipherFailure.invalidContext),
      );
      await expectLater(
        secondAttempt,
        _failure(SupportCipherFailure.invalidContext),
      );
      pause.release();
      await expectLater(
        pendingPure,
        _failure(SupportCipherFailure.invalidContext),
      );
      await expectLater(
        escaped(),
        _failure(SupportCipherFailure.invalidContext),
      );
      expect(f.storage.operations, ['read']);
      expect(f.primitive.decryptAads, hasLength(1));
    },
  );

  test(
    'abandoned raw-storage late error is handled by bridge itself; FIFO remains usable',
    () async {
      final f = ReadOnlyCipherFixture();
      await f.seed();
      final pause = ReadPause();
      addTearDown(pause.release);
      var first = true;
      f.storage.beforeRead = () async {
        if (!first) return;
        first = false;
        await pause.hold();
        throw const UnprintableReadError();
      };
      final read = SupportPayloadCipher.readOnly(
        delegate: f.owner,
        gate: (pure) async {
          // Intentionally abandoned: unawaited adds NO fixture error handler.
          unawaited(pure());
          await pause.entered.future;
          throw const SupportCipherException(
            SupportCipherFailure.invalidContext,
          );
        },
      );
      await expectLater(
        f.decrypt(read),
        _failure(SupportCipherFailure.invalidContext),
      );
      pause.release();
      // Same key-store FIFO orders this after the late failed storage resolution.
      expect(await f.decrypt(f.owner), ReadOnlyCipherFixture.text);
      expect(f.storage.operations, ['read', 'read']);
    },
  );

  for (final deadline in [false, true]) {
    test(
      'cancel/expiry BEFORE start: $deadline; zero vault/primitive access',
      () async {
        final f = ReadOnlyCipherFixture();
        await f.seed();
        final token = CancelToken();
        final clock = ManualReadDeadline();
        if (deadline) {
          clock.expire();
        } else {
          token.cancel();
        }
        final budget = CipherReadBudget(token, clock);
        final read = SupportPayloadCipher.readOnly(
          delegate: f.owner,
          gate: budget.call,
        );
        await expectLater(
          f.decrypt(read),
          _failure(SupportCipherFailure.invalidContext),
        );
        expect(f.storage.operations, isEmpty);
        expect(f.primitive.decryptAads, isEmpty);
      },
    );

    test(
      'cancel/expiry while gate queued BEFORE thunk invocation: $deadline',
      () async {
        final f = ReadOnlyCipherFixture();
        await f.seed();
        final pause = ReadPause();
        addTearDown(pause.release);
        final token = CancelToken();
        final clock = ManualReadDeadline();
        final budget = CipherReadBudget(token, clock);
        final read = SupportPayloadCipher.readOnly(
          delegate: f.owner,
          gate: (pure) async {
            await pause.hold();
            return budget.call(
              pure,
            ); // Rechecks BEFORE starting any original work.
          },
        );
        final pending = f.decrypt(read);
        final refusal = expectLater(
          pending,
          _failure(SupportCipherFailure.invalidContext),
        );
        await pause.entered.future;
        if (deadline) {
          clock.expire();
        } else {
          token.cancel();
        }
        pause.release();
        await refusal;
        expect(f.storage.operations, isEmpty);
        expect(f.primitive.decryptAads, isEmpty);
      },
    );

    for (final boundary in ['storage', 'primitive']) {
      for (final lateError in [false, true]) {
        test(
          'cancel/expiry DURING $boundary: $deadline; late error $lateError',
          () async {
            final f = ReadOnlyCipherFixture();
            await f.seed();
            final before = Map<String, String>.from(f.storage.values);
            final pause = ReadPause();
            addTearDown(pause.release);
            if (boundary == 'storage') {
              f.storage.beforeRead = pause.hold;
            } else {
              f.primitive.beforeDecrypt = (_) async {
                await pause.hold();
                if (lateError) throw const UnprintableReadError();
              };
            }
            final token = CancelToken();
            final clock = ManualReadDeadline();
            final budget = CipherReadBudget(token, clock);
            final read = SupportPayloadCipher.readOnly(
              delegate: f.owner,
              gate: budget.call,
            );
            final pending = f.decrypt(read);
            final refusal = expectLater(
              pending,
              _failure(SupportCipherFailure.invalidContext),
            );
            await pause.entered.future;
            expect(
              f.primitive.decryptAads,
              hasLength(boundary == 'storage' ? 0 : 1),
            );
            if (deadline) {
              clock.expire();
            } else {
              token.cancel();
            }
            await refusal; // Does NOT wait for raw storage/primitive release.
            expect(budget.settledCount, 0);
            if (boundary == 'storage' && lateError) {
              f.storage.readError = const UnprintableReadError();
            }
            pause.release();
            await budget.settled;
            expect(budget.settledCount, 1);
            expect(f.storage.values, before);
            expect(f.storage.operations, ['read']);
            f.storage.beforeRead = null;
            f.storage.readError = null;
            f.primitive.beforeDecrypt = null;
            expect(await f.decrypt(f.owner), ReadOnlyCipherFixture.text);
          },
        );
      }
    }
  }

  for (final deadline in [false, true]) {
    for (final queue in ['key-store', 'vault']) {
      test(
        'same existing $queue FIFO survives canceled/expired queued read $deadline; no queue removal',
        () async {
          final f = ReadOnlyCipherFixture();
          await f.seed();
          final pause = ReadPause();
          addTearDown(pause.release);
          f.storage.beforeRead = pause.hold;
          final Future<Object?> predecessor = queue == 'key-store'
              ? f.decrypt(f.owner)
              : f.vault.metadata(SupportPayloadCipher.installKeySlot);
          await pause.entered.future;
          final token = CancelToken();
          final clock = ManualReadDeadline();
          final budget = CipherReadBudget(token, clock);
          final read = SupportPayloadCipher.readOnly(
            delegate: f.owner,
            gate: budget.call,
          );
          final pending = f.decrypt(read);
          final refusal = expectLater(
            pending,
            _failure(SupportCipherFailure.invalidContext),
          );
          // Gate has invoked the pure thunk; resolve is now behind the SAME owner.
          await Future<void>.value();
          expect(f.storage.reads, 1);
          if (deadline) {
            clock.expire();
          } else {
            token.cancel();
          }
          await refusal;
          expect(budget.settledCount, 0);
          expect(f.storage.reads, 1);
          pause.release();
          await predecessor;
          await budget.settled;
          expect(
            f.storage.reads,
            2,
          ); // Late admitted pure queue item still runs.
          expect(f.storage.operations, ['read', 'read']);
          f.storage.beforeRead = null;
          expect(await f.decrypt(f.owner), ReadOnlyCipherFixture.text);
        },
      );
    }
  }
}
