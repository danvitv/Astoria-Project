import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:dio/dio.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../../credentials/fake_credential_storage.dart';

/// Synthetic fake storage, ONE real vault/key owner and real XChaCha AEAD.
/// No plugin calls, application/default DB, environment or native startup.
final class ReadOnlyCipherFixture {
  ReadOnlyCipherFixture({
    int maxPlaintextBytes = 1024 * 1024,
    int maxEnvelopeChars = 2 * 1024 * 1024,
    int maxIdentifierBytes = 1024,
  }) {
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_read_only_cipher',
    );
    owner = SupportPayloadCipher(
      vault: vault,
      cipher: primitive,
      maxPlaintextBytes: maxPlaintextBytes,
      maxEnvelopeChars: maxEnvelopeChars,
      maxIdentifierBytes: maxIdentifierBytes,
    );
  }

  static const text = 'SYNTHETIC_READ_ONLY_BODY_9c31 🐈';
  final storage = FakeCredentialStorage();
  final primitive = ReadOnlyControlledCipher();
  late final CredentialVault vault;
  late final SupportPayloadCipher owner;
  late String envelope;

  Future<void> seed() async {
    envelope = await encrypt(owner);
    observe();
  }

  void observe() {
    storage.operations.clear();
    storage.reads = 0;
    primitive.decryptAads.clear();
    primitive.nonceCalls = 0;
    primitive.encryptCalls = 0;
  }

  Future<String> encrypt(
    SupportPayloadCipher cipher, {
    String plaintext = text,
  }) => cipher.encrypt(
    plaintext: plaintext,
    table: 'support_messages',
    rowId: 'history',
    sessionId: 'session',
    field: 'body_ciphertext',
  );

  Future<String> decrypt(
    SupportPayloadCipher cipher, {
    String? envelopeText,
    String table = 'support_messages',
    String rowId = 'history',
    String? sessionId = 'session',
    String field = 'body_ciphertext',
  }) => cipher.decrypt(
    envelopeText: envelopeText ?? envelope,
    table: table,
    rowId: rowId,
    sessionId: sessionId,
    field: field,
  );
}

/// Counts primitive entry without retaining keys/plaintext or raw error causes.
final class ReadOnlyControlledCipher implements Cipher {
  final Cipher _delegate = Xchacha20.poly1305Aead();
  final decryptAads = <String>[];
  int nonceCalls = 0;
  int encryptCalls = 0;
  Future<void> Function(String aad)? beforeDecrypt;
  @override
  List<int> newNonce() {
    nonceCalls++;
    return _delegate.newNonce();
  }

  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) {
    encryptCalls++;
    return _delegate.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }

  @override
  Future<List<int>> decrypt(
    SecretBox secretBox, {
    required SecretKey secretKey,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    final context = utf8.decode(aad);
    decryptAads.add(context);
    await beforeDecrypt?.call(context);
    return _delegate.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class ReadPause {
  final entered = Completer<void>();
  final resume = Completer<void>();
  Future<void> hold() async {
    if (!entered.isCompleted) entered.complete();
    await resume.future;
  }

  void release() {
    if (!resume.isCompleted) resume.complete();
  }
}

/// Test-only native-style policy. 25ms is a MANUAL fixture budget, not a
/// production/plugin claim. Only pure decrypt is raced, never H/SQL callbacks.
final class CipherReadBudget {
  CipherReadBudget(this.token, this.clock);
  final CancelToken token;
  final ManualReadDeadline clock;
  int calls = 0;
  int settledCount = 0;
  Completer<void>? _settled;
  Future<void> get settled => _settled!.future;

  Future<String> call(Future<String> Function() decryptPure) async {
    calls++;
    if (token.isCancelled || clock.expired) _refuse();
    final deadline = Completer<String>();
    final timer = clock.schedule(const Duration(milliseconds: 25), () {
      deadline.completeError(_failure);
    });
    final settled = Completer<void>();
    _settled = settled;
    final pure = decryptPure();
    unawaited(
      pure.then<void>(
        (_) {
          settledCount++;
          settled.complete();
        },
        onError: (Object _, StackTrace _) {
          settledCount++;
          settled.complete();
        },
      ),
    );
    try {
      final text = await Future.any<String>([
        pure,
        token.whenCancel.then<String>((_) => _refuse()),
        deadline.future,
      ]);
      if (token.isCancelled || clock.expired) _refuse();
      return text;
    } finally {
      timer.cancel();
    }
  }

  static const _failure = SupportCipherException(
    SupportCipherFailure.invalidContext,
  );
  static Never _refuse() => throw _failure;
}

final class ManualReadDeadline {
  bool expired = false;
  _ReadTimer? _timer;
  Timer schedule(Duration budget, void Function() expire) {
    if (budget != const Duration(milliseconds: 25)) {
      throw StateError('Unexpected synthetic read budget');
    }
    return _timer = _ReadTimer(expire);
  }

  void expire() {
    expired = true;
    _timer?.expire();
  }
}

final class _ReadTimer implements Timer {
  _ReadTimer(this._expire);
  final void Function() _expire;
  bool _active = true;
  void expire() {
    if (!_active) return;
    _active = false;
    _expire();
  }

  @override
  void cancel() => _active = false;
  @override
  bool get isActive => _active;
  @override
  int get tick => 0;
}

final class UnprintableReadError implements Exception {
  const UnprintableReadError();
  @override
  String toString() =>
      throw StateError('Raw read error must never be formatted');
}
