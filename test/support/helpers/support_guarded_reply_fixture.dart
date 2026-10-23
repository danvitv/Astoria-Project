import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../../credentials/fake_credential_storage.dart';

/// Real memory SQLite and AEAD; only fake vault/synthetic rows. No app startup.
final class GuardedReplyFixture {
  GuardedReplyFixture() {
    db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(sql));
    cipher = SupportPayloadCipher(
      vault: CredentialVault(storage: storage, buildChannel: 'dev'),
      cipher: primitive,
    );
    repo = SupportRepo(db, cipher);
  }

  static const message = SupportMessage(
    id: 'synthetic-reply',
    sessionId: 'synthetic-original-session',
    role: 'assistant',
    body: '',
    runId: 'synthetic-run',
    status: 'preparing',
    createdAt: 4,
  );
  static const provenanceJson = '{"selected":["SYNTHETIC_PROVENANCE_CANARY"]}';
  static const contextId = 'support.reply_provenance:synthetic-reply';
  final storage = FakeCredentialStorage();
  final primitive = GuardedReplyCipher();
  final sql = GuardedReplySql();
  late final AppDatabase db;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  bool current = true;
  bool isCurrent() => current;

  Future<void> seed() async {
    for (final id in [message.sessionId, 'synthetic-other-session']) {
      await repo.createSession(
        SupportSession(
          id: id,
          title: 'SYNTHETIC_PARENT_CANARY',
          createdAt: 1,
          updatedAt: 1,
        ),
      );
    }
    await repo.appendMessage(
      SupportMessage(
        id: 'synthetic-other-message',
        sessionId: message.sessionId,
        role: 'user',
        body: 'SYNTHETIC_OTHER_BODY_CANARY',
        cardsJson: '[]',
        createdAt: 2,
      ),
    );
    await repo.putContextBlock(
      SupportContextBlock(
        id: 'synthetic-other-context',
        sessionId: message.sessionId,
        startMessageId: 'synthetic-other-message',
        endMessageId: 'synthetic-other-message',
        summary: 'SYNTHETIC_OTHER_CONTEXT_CANARY',
        createdAt: 3,
      ),
    );
  }

  Future<SupportReplyReservation?> reserve({
    SupportMessage? candidate,
    String? provenance,
  }) => repo.reserveReply(
    message: candidate ?? message,
    provenanceJson: provenance ?? provenanceJson,
    isCurrent: isCurrent,
  );

  Future<SupportMessage?> settle(
    SupportReplyReservation expected, {
    String status = 'complete',
    String? body = 'SYNTHETIC_REPLY_CANARY',
  }) => repo.settleReply(
    expected: expected,
    status: status,
    body: body,
    isCurrent: isCurrent,
  );

  Future<Map<String, List<Object>>> rows() async => {
    'messages': await db.select(db.supportMessages).get(),
    'context': await db.select(db.supportContextBlocks).get(),
    'sessions': await db.select(db.supportSessions).get(),
  };
  Future<SupportMessageRow?> replyRow() => (db.select(
    db.supportMessages,
  )..where((t) => t.id.equals(message.id))).getSingleOrNull();
  Future<SupportContextBlockRow?> provenanceRow() => (db.select(
    db.supportContextBlocks,
  )..where((t) => t.id.equals(contextId))).getSingleOrNull();
  Future<void> close() => db.close();
}

final class GuardedReplyCipher implements Cipher {
  final delegate = Xchacha20.poly1305Aead();
  Future<void> Function(String aad)? afterEncrypt, beforeDecrypt;
  @override
  List<int> newNonce() => delegate.newNonce();
  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    final box = await delegate.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
    await afterEncrypt?.call(utf8.decode(aad));
    return box;
  }

  @override
  Future<List<int>> decrypt(
    SecretBox box, {
    required SecretKey secretKey,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    await beforeDecrypt?.call(utf8.decode(aad));
    return delegate.decrypt(
      box,
      secretKey: secretKey,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Hooks run after actual SQL, before its Future returns to the repository.
final class GuardedReplySql extends QueryInterceptor {
  Future<void> Function(String sql)? afterWrite, afterSelect;
  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final count = await super.runInsert(executor, statement, args);
    await afterWrite?.call(statement);
    return count;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final count = await super.runUpdate(executor, statement, args);
    await afterWrite?.call(statement);
    return count;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    await afterSelect?.call(statement);
    return rows;
  }
}
