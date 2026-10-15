import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../credentials/fake_credential_storage.dart';

void main() {
  late FakeCredentialStorage storage;
  late CredentialVault vault;
  late SupportPayloadCipher cipher;

  setUp(() {
    storage = FakeCredentialStorage();
    vault = CredentialVault(storage: storage, buildChannel: 'dev');
    cipher = SupportPayloadCipher(vault: vault);
  });

  String flipSingleChar(String input, {int index = 0}) {
    final targetIndex = index.clamp(0, input.length - 1);
    final original = input[targetIndex];
    final replacement = original == 'A' ? 'B' : 'A';
    return input.replaceRange(targetIndex, targetIndex + 1, replacement);
  }

  test('round-trips plaintext and produces v1 XChaCha20-Poly1305 envelope', () async {
    const plaintext = 'Support message with Unicode 🐈‍⬛ and secret sk-test';
    final envelope = await cipher.encrypt(
      plaintext: plaintext,
      table: 'support_messages',
      rowId: 'msg-1',
      sessionId: 'sess-1',
      field: 'body_ciphertext',
    );

    expect(envelope, isNot(contains(plaintext)));
    expect(envelope, isNot(contains('sk-test')));

    final decodedJson = jsonDecode(envelope) as Map<String, dynamic>;
    expect(decodedJson['v'], 1);
    expect(decodedJson['alg'], 'XChaCha20-Poly1305');
    expect(base64Url.decode(decodedJson['n'] as String), hasLength(24));
    expect(base64Url.decode(decodedJson['t'] as String), hasLength(16));

    final decrypted = await cipher.decrypt(
      envelopeText: envelope,
      table: 'support_messages',
      rowId: 'msg-1',
      sessionId: 'sess-1',
      field: 'body_ciphertext',
    );
    expect(decrypted, plaintext);

    // Also verify empty string round-trip.
    final emptyEnvelope = await cipher.encrypt(
      plaintext: '',
      table: 'support_messages',
      rowId: 'msg-1',
      sessionId: 'sess-1',
      field: 'cards_ciphertext',
    );
    final decryptedEmpty = await cipher.decrypt(
      envelopeText: emptyEnvelope,
      table: 'support_messages',
      rowId: 'msg-1',
      sessionId: 'sess-1',
      field: 'cards_ciphertext',
    );
    expect(decryptedEmpty, '');
  });

  test('generates distinct random 24-byte nonces and serializes concurrent first-time init', () async {
    final envelopes = await Future.wait(
      List.generate(
        8,
        (i) => cipher.encrypt(
          plaintext: 'same-plaintext',
          table: 'support_messages',
          rowId: 'msg-concurrent',
          sessionId: 'sess-1',
          field: 'body_ciphertext',
        ),
      ),
    );

    final nonces = <String>{};
    for (final env in envelopes) {
      final map = jsonDecode(env) as Map<String, dynamic>;
      nonces.add(map['n'] as String);
      final roundTrip = await cipher.decrypt(
        envelopeText: env,
        table: 'support_messages',
        rowId: 'msg-concurrent',
        sessionId: 'sess-1',
        field: 'body_ciphertext',
      );
      expect(roundTrip, 'same-plaintext');
    }
    expect(nonces, hasLength(8));

    // Only one install key write occurred across all 8 concurrent first-time calls.
    final writeCount = storage.operations.where((op) => op == 'write').length;
    expect(writeCount, 1);
  });

  test('rejects AAD mismatches across table, rowId, sessionId, and field', () async {
    final envelope = await cipher.encrypt(
      plaintext: 'bound payload',
      table: 'support_messages',
      rowId: 'msg-10',
      sessionId: 'sess-10',
      field: 'body_ciphertext',
    );

    await expectLater(
      cipher.decrypt(
        envelopeText: envelope,
        table: 'support_sessions',
        rowId: 'msg-10',
        sessionId: 'sess-10',
        field: 'body_ciphertext',
      ),
      throwsA(isA<SupportCipherException>()),
    );

    await expectLater(
      cipher.decrypt(
        envelopeText: envelope,
        table: 'support_messages',
        rowId: 'msg-11',
        sessionId: 'sess-10',
        field: 'body_ciphertext',
      ),
      throwsA(isA<SupportCipherException>()),
    );

    await expectLater(
      cipher.decrypt(
        envelopeText: envelope,
        table: 'support_messages',
        rowId: 'msg-10',
        sessionId: 'sess-11',
        field: 'body_ciphertext',
      ),
      throwsA(isA<SupportCipherException>()),
    );

    await expectLater(
      cipher.decrypt(
        envelopeText: envelope,
        table: 'support_messages',
        rowId: 'msg-10',
        sessionId: null,
        field: 'body_ciphertext',
      ),
      throwsA(isA<SupportCipherException>()),
    );

    await expectLater(
      cipher.decrypt(
        envelopeText: envelope,
        table: 'support_messages',
        rowId: 'msg-10',
        sessionId: 'sess-10',
        field: 'cards_ciphertext',
      ),
      throwsA(isA<SupportCipherException>()),
    );
  });

  test('rejects tampered nonce, ciphertext, and mac', () async {
    final envelope = await cipher.encrypt(
      plaintext: 'sensitive diagnostic payload',
      table: 'support_mutation_journal',
      rowId: 'mut-1',
      sessionId: 'sess-1',
      field: 'before_ciphertext',
    );
    final map = jsonDecode(envelope) as Map<String, dynamic>;

    for (final key in ['n', 'c', 't']) {
      final tampered = Map<String, dynamic>.from(map);
      tampered[key] = flipSingleChar(map[key] as String, index: 2);
      await expectLater(
        cipher.decrypt(
          envelopeText: jsonEncode(tampered),
          table: 'support_mutation_journal',
          rowId: 'mut-1',
          sessionId: 'sess-1',
          field: 'before_ciphertext',
        ),
        throwsA(isA<SupportCipherException>()),
        reason: 'Tampered $key must throw SupportCipherException',
      );
    }
  });

  test('fails closed on wrong install key', () async {
    final envelope = await cipher.encrypt(
      plaintext: 'locked with original key',
      table: 'support_sessions',
      rowId: 'sess-1',
      sessionId: 'sess-1',
      field: 'title_ciphertext',
    );

    // Replace install key with a different 32-byte key.
    final wrongKey = base64UrlEncode(SecretKeyData.random(length: 32).bytes);
    await vault.store(SupportPayloadCipher.installKeySlot, wrongKey);

    await expectLater(
      cipher.decrypt(
        envelopeText: envelope,
        table: 'support_sessions',
        rowId: 'sess-1',
        sessionId: 'sess-1',
        field: 'title_ciphertext',
      ),
      throwsA(
        isA<SupportCipherException>().having(
          (e) => e.failure,
          'failure',
          SupportCipherFailure.authenticationFailed,
        ),
      ),
    );
  });

  test('fails closed without overwriting slot when vault is unavailable or key is corrupted', () async {
    final envelope = await cipher.encrypt(
      plaintext: 'durable secret text',
      table: 'support_sessions',
      rowId: 'sess-1',
      sessionId: 'sess-1',
      field: 'title_ciphertext',
    );
    final slotKey = storage.values.keys.single;
    final originalKey = storage.values[slotKey]!;

    // 1. Vault read unavailable -> fails closed and never writes/overwrites.
    storage.readError = StateError('keystore locked');
    final writesBefore = storage.operations.where((op) => op == 'write').length;
    await expectLater(
      cipher.encrypt(
        plaintext: 'should fail',
        table: 'support_sessions',
        rowId: 'sess-2',
        sessionId: 'sess-2',
        field: 'title_ciphertext',
      ),
      throwsA(
        isA<SupportCipherException>().having(
          (e) => e.failure,
          'failure',
          SupportCipherFailure.vaultUnavailable,
        ),
      ),
    );
    expect(storage.operations.where((op) => op == 'write').length, writesBefore);
    expect(storage.values[slotKey], originalKey);

    // Restore read availability -> original ciphertext still decrypts.
    storage.readError = null;
    expect(
      await cipher.decrypt(
        envelopeText: envelope,
        table: 'support_sessions',
        rowId: 'sess-1',
        sessionId: 'sess-1',
        field: 'title_ciphertext',
      ),
      'durable secret text',
    );

    // 2. Corrupted stored key -> fails closed and never overwrites the slot.
    storage.values[slotKey] = 'corrupted-short-key';
    final writesBeforeCorrupt =
        storage.operations.where((op) => op == 'write').length;
    await expectLater(
      cipher.encrypt(
        plaintext: 'should fail on corrupt key',
        table: 'support_sessions',
        rowId: 'sess-3',
        sessionId: 'sess-3',
        field: 'title_ciphertext',
      ),
      throwsA(
        isA<SupportCipherException>().having(
          (e) => e.failure,
          'failure',
          SupportCipherFailure.invalidKey,
        ),
      ),
    );
    expect(
      storage.operations.where((op) => op == 'write').length,
      writesBeforeCorrupt,
    );
    expect(storage.values[slotKey], 'corrupted-short-key');
  });
}
