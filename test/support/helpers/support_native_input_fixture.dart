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

/// Declared-schema-only memory SQLite, real XChaCha AEAD, one fake vault owner.
/// No App, production seeds/migrations, provider, environment, file or network.
final class NativeInputFixture {
  NativeInputFixture() {
    db = _NativeInputDatabase(NativeDatabase.memory().interceptWith(sql));
    cipher = SupportPayloadCipher(
      vault: CredentialVault(storage: storage, buildChannel: 'synthetic_input'),
      cipher: primitive,
    );
    repo = SupportRepo(db, cipher);
  }

  static const maxTime = 9007199254740991;
  static const sessionId = 'synthetic-input-session';
  static const foreignId = 'synthetic-foreign-session';
  static const oldId = 'synthetic-unselected-old';
  static const input = SupportMessage(
    id: 'z-synthetic-user',
    sessionId: sessionId,
    role: 'user',
    body: 'SYNTHETIC_SANITIZED_INPUT_CANARY',
    runId: 'synthetic-run',
    status: 'complete',
    createdAt: 3,
  );
  static const reply = SupportMessage(
    id: 'a-synthetic-reply',
    sessionId: sessionId,
    role: 'assistant',
    body: '',
    runId: 'synthetic-run',
    status: 'preparing',
    createdAt: 0,
  );
  static const provenance = '{"synthetic":"SYNTHETIC_ORIGIN_CANARY"}';
  final storage = FakeCredentialStorage();
  final primitive = NativeInputCipher();
  final sql = NativeInputSql();
  late final AppDatabase db;
  late final SupportPayloadCipher cipher;
  late SupportRepo repo;
  bool current = true;
  bool isCurrent() => current;

  Future<void> seed() async {
    for (final id in [sessionId, foreignId]) {
      await repo.createSession(
        SupportSession(
          id: id,
          title: 'SYNTHETIC_PARENT_TITLE_CANARY',
          createdAt: 1,
          updatedAt: 7,
          pinned: true,
          mode: 'synthetic-retained-mode',
          activeApiConfigId: 'synthetic-retained-api',
          activeModelId: 'synthetic-retained-model',
        ),
      );
    }
    await repo.putMessage(
      SupportMessage(
        id: oldId,
        sessionId: sessionId,
        role: 'assistant',
        body: 'SYNTHETIC_UNSELECTED_BODY_CANARY',
        cardsJson: '["SYNTHETIC_UNSELECTED_CARD_CANARY"]',
        createdAt: 10,
      ),
    );
    await repo.putMessage(
      SupportMessage(
        id: 'synthetic-foreign-body',
        sessionId: foreignId,
        role: 'user',
        body: 'SYNTHETIC_FOREIGN_BODY_CANARY',
        createdAt: maxTime,
      ),
    );
    await repo.putContextBlock(
      const SupportContextBlock(
        id: 'synthetic-retained-context',
        sessionId: sessionId,
        startMessageId: oldId,
        endMessageId: oldId,
        summary: 'SYNTHETIC_UNSELECTED_SUMMARY_CANARY',
        protectedFactsJson: '["SYNTHETIC_UNSELECTED_FACT_CANARY"]',
        createdAt: 9,
      ),
    );
    await repo.recordMutation(
      const SupportMutationRecord(
        id: 'synthetic-retained-mutation',
        sessionId: sessionId,
        domain: 'synthetic',
        targetId: 'synthetic-target',
        beforeJson: '{"synthetic":0}',
        afterJson: '{"synthetic":1}',
        createdAt: 9,
      ),
    );
    await repo.recordReport(
      const SupportReportRecord(
        id: 'synthetic-retained-report',
        sessionId: sessionId,
        fileHash: 'synthetic-hash',
        createdAt: 9,
      ),
    );
  }

  Future<SupportMessage?> append([SupportMessage? message]) =>
      repo.appendCurrentUser(message: message ?? input, isCurrent: isCurrent);

  Future<SupportReplyReservation?> reserve(
    SupportMessage user, {
    SupportMessage? candidate,
  }) => repo.reserveOrderedReply(
    message: candidate ?? reply,
    originatingUser: user,
    provenanceJson: provenance,
    isCurrent: isCurrent,
  );

  Future<SupportMessageRow?> row(String id) => (db.select(
    db.supportMessages,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<SupportSessionRow?> parentRow() => (db.select(
    db.supportSessions,
  )..where((t) => t.id.equals(sessionId))).getSingleOrNull();

  /// All declared tables/raw ciphertext and ordering, outside boundary spies.
  Future<String> snapshot() async {
    final result = <String, Object?>{};
    for (final table in db.allTables) {
      final rows = await db
          .customSelect(
            'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
          )
          .get();
      result[table.actualTableName] = rows.map((r) => r.data).toList();
    }
    return jsonEncode(result);
  }

  void observe() {
    sql.observations.clear();
    sql.writes.clear();
    primitive.decryptAads.clear();
    primitive.encryptAads.clear();
    storage.operations.clear();
  }

  void clearHooks() {
    sql.afterSelect = null;
    sql.afterWrite = null;
    primitive.beforeDecrypt = null;
    primitive.afterEncrypt = null;
    storage.beforeRead = null;
    storage.readError = null;
  }

  Future<void> close() => db.close();
}

final class _NativeInputDatabase extends AppDatabase {
  _NativeInputDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final class NativeInputCipher implements Cipher {
  final delegate = Xchacha20.poly1305Aead();
  final decryptAads = <String>[];
  final encryptAads = <String>[];
  Future<void> Function(String aad)? beforeDecrypt, afterEncrypt;
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
    final context = utf8.decode(aad);
    encryptAads.add(context);
    final result = await delegate.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
    await afterEncrypt?.call(context);
    return result;
  }

  @override
  Future<List<int>> decrypt(
    SecretBox box, {
    required SecretKey secretKey,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    final context = utf8.decode(aad);
    decryptAads.add(context);
    await beforeDecrypt?.call(context);
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

typedef NativeInputObservation = ({
  String statement,
  List<Object?> args,
  List<Map<String, Object?>> rows,
});

/// Hooks after actual SQL and BEFORE its awaited result returns. These are
/// provisional SQL/read faults, deliberately NOT physical COMMIT-fault probes.
final class NativeInputSql extends QueryInterceptor {
  final observations = <NativeInputObservation>[];
  final writes = <String>[];
  Future<void> Function(String statement, List<Object?> args)? afterSelect;
  Future<void> Function(String statement)? afterWrite;
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    observations.add((statement: statement, args: List.of(args), rows: rows));
    await afterSelect?.call(statement, args);
    return rows;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runInsert(executor, statement, args);
    writes.add(statement);
    await afterWrite?.call(statement);
    return result;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runUpdate(executor, statement, args);
    writes.add(statement);
    await afterWrite?.call(statement);
    return result;
  }
}
