import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../credentials/fake_credential_storage.dart';
import 'helpers/support_text_context_fixture.dart' show TextContextControlledCipher;

/// Tripwires start BEFORE graph/fixture evaluation and remain through close.
/// Allows only declared memory SQLite FFI, not a universal FFI/process sandbox.
void sessionTextTest(
  String name,
  Future<void> Function(SessionTextFixture f) body,
) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String kind) {
      attempts.add(kind);
      throw StateError('Outside declared synthetic session-text fixture');
    }

    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final previous = messenger.allMessagesHandler;
    messenger.allMessagesHandler = (channel, handler, message) =>
        block('native $channel');
    try {
      await HttpOverrides.runZoned(
        () => IOOverrides.runZoned(
          () async {
            final f = SessionTextFixture();
            try {
              await f.seed();
              await body(f);
            } finally {
              f.sql.observing = false;
              f.primitive.beforeDecrypt = null;
              await f.db.close();
              await messenger.platformMessagesFinished;
              expect(attempts, isEmpty);
            }
          },
          createFile: (_) => block('file/default database'),
          createDirectory: (_) => block('directory/default database'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HTTP'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

final class SessionMemoryDatabase extends AppDatabase {
  SessionMemoryDatabase(super.e) : super.forTesting();
  int _transactionId = 0;
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) => super.transaction(
    () => runZoned(action, zoneValues: {#sessionTextTransaction: ++_transactionId}),
    requireNew: requireNew,
  );
}

/// Actual returned SQL primitives and real AEAD AAD, not fabricated snapshots.
final class SessionTextFixture {
  SessionTextFixture() {
    db = SessionMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    cipher = SupportPayloadCipher(
      vault: CredentialVault(storage: storage, buildChannel: 'synthetic_session_text'),
      cipher: primitive,
    );
    repo = newRepo();
  }
  static const support = 'synthetic-own-support';
  static const game = 'synthetic-own-roleplay';
  static const current = 'current-user';
  static const run = 'synthetic-current-run';
  static const secret = 'SYNTHETIC_SESSION_SECRET_619f';
  static const excluded = 'SYNTHETIC_NON_BODY_PRIVATE_531c';
  static const hidden = 'SYNTHETIC_HIDDEN_BODY_e81a';
  static const input = 'SYNTHETIC_CURRENT_INPUT_e15b';
  static const reply = 'SYNTHETIC_CURRENT_REPLY_d58a';
  final sql = SessionTextSqlProbe();
  final storage = FakeCredentialStorage();
  final primitive = TextContextControlledCipher();
  SecretRedactor redactor = SecretRedactor(knownSecrets: [secret]);
  late final SessionMemoryDatabase db;
  late final SupportPayloadCipher cipher;
  late final SupportTextContextRepo repo;

  SupportTextContextRepo newRepo({SupportNativeProvenanceValidator? validator}) =>
      SupportTextContextRepo(
        db: db,
        cipher: cipher,
        currentRedactor: () => redactor,
        admissionContract:
            SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
        nativeProvenanceValidator: validator,
      );

  Future<String> encrypt(String body, String table, String row, String session, String field) =>
      cipher.encrypt(plaintext: body, table: table, rowId: row, sessionId: session, field: field);

  Future<void> supportSession(String session) async {
    final title = await encrypt('Synthetic $secret', 'support_sessions', session, session, 'title_ciphertext');
    await db.into(db.supportSessions).insert(SupportSessionsCompanion.insert(
      id: session,
      titleCiphertext: title,
      createdAt: const Value(1),
      activeApiConfigId: const Value(secret),
      activeModelId: const Value(excluded),
    ));
  }

  Future<void> message(String id, {
    String session = support,
    String body = 'Synthetic history',
    String role = 'user',
    String status = 'complete',
    int time = 2,
    String? runId,
  }) async {
    final envelope = await encrypt(body, 'support_messages', id, session, 'body_ciphertext');
    await db.into(db.supportMessages).insert(SupportMessagesCompanion.insert(
      id: id, sessionId: session, role: role, bodyCiphertext: envelope,
      cardsCiphertext: const Value('unreadable-private-card'),
      runId: Value(runId), status: Value(status), createdAt: Value(time),
    ));
  }

  static Map<String, Object?> gameMessage(String id, {
    String body = 'Synthetic game history', String role = 'assistant',
  }) => {
    'id': id, 'role': role, 'content': body, 'timestamp': 1,
    'swipeId': 1, 'agentSwipeId': 0,
    'swipes': [excluded, body],
    'agentSwipes': [{'content': body, 'reasoning': excluded}],
    'reasoning': excluded, 'rawPrompt': secret, 'provider': excluded,
    'worldState': excluded, 'variables': excluded, 'imagePath': excluded,
  };

  Future<void> replaceGame(List<Object?> messages) => replaceGameJson(jsonEncode(messages));
  Future<void> replaceGameJson(String json) async {
    await (db.update(db.chatSessions)..where((t) => t.sessionId.equals(game)))
        .write(ChatSessionsCompanion(messagesJson: Value(json)));
  }

  Future<void> seed() async {
    await db.customSelect('SELECT 1').getSingle();
    await db.customStatement('PRAGMA busy_timeout = 0');
    await supportSession(support);
    await supportSession('synthetic-foreign-support');
    await message('history-a', body: 'Synthetic first $secret', time: 2);
    await message('history-b', role: 'assistant', runId: 'synthetic-old-run', time: 3);
    await message('a-before-tie', body: 'Before native tuple', time: 10);
    await message(current, body: input, time: 10, runId: run);
    // COMPLETE intentionally: exclusion must be ordering, not pending status.
    await message('reserved-reply', role: 'assistant', body: reply, time: 10, runId: run);
    await message('foreign-history', session: 'synthetic-foreign-support', body: excluded);
    await db.into(db.characters).insert(CharactersCompanion.insert(
      charId: 'synthetic-character', name: 'Synthetic',
      description: const Value(excluded), variantGroupId: const Value('synthetic-group'),
      variantOrder: const Value(0),
    ));
    await db.into(db.chatSessions).insert(ChatSessionsCompanion.insert(
      sessionId: game, characterId: 'synthetic-character', sessionIndex: 0,
      messagesJson: jsonEncode([
        gameMessage('game-a', role: 'user', body: 'Synthetic first $secret'),
        gameMessage('hidden-game', body: hidden)..['isHidden'] = true,
        gameMessage('game-b'),
      ]),
      sessionVarsJson: const Value('{"private":"$excluded"}'),
      authorsNoteJson: const Value('{"private":"$secret"}'),
      draft: const Value(secret),
    ));
  }

  Future<SupportSessionHistoryBoundary> boundary({String session = support, String user = current, String runId = run}) =>
      repo.captureSupportSessionBoundary(sessionId: session, userMessageId: user, runId: runId);
  Future<SupportTextContextSnapshot> own(SupportSessionHistoryBoundary boundary, {String session = support}) =>
      repo.loadSupportSessionHistory(sessionId: session, currentInput: boundary);
  Future<SupportTextContextSnapshot> roleplay() =>
      repo.loadRoleplaySessionHistory(sessionId: game);
  Future<bool> admit(SupportTextContextSnapshot snapshot, void Function() dispatch, {bool Function()? current}) =>
      repo.admitDispatch(
        snapshots: [snapshot], isCurrent: current ?? () => true,
        checkReadOnly: (checkpoint) async { checkpoint(); return true; }, dispatch: dispatch,
      );
  void observe() {
    sql.observing = true;
    sql.reads.clear();
    sql.reservations = 0;
    primitive.decryptAads.clear();
    storage.operations.clear();
  }
}

final class SessionSqlRead {
  const SessionSqlRead(this.statement, this.values, this.transaction);
  final String statement;
  final List<Map<String, Object?>> values;
  final Object? transaction;
}

final class SessionTextSqlProbe extends QueryInterceptor {
  bool observing = false;
  int reservations = 0;
  final reads = <SessionSqlRead>[];
  @override
  Future<List<Map<String, Object?>>> runSelect(QueryExecutor executor, String statement, List<Object?> args) async {
    final rows = await super.runSelect(executor, statement, args);
    if (observing) reads.add(SessionSqlRead(statement, rows, Zone.current[#sessionTextTransaction]));
    return rows;
  }
  void _write() {
    if (observing) throw StateError('Session history attempted a counted write');
  }
  @override
  Future<void> runCustom(QueryExecutor executor, String statement, List<Object?> args) {
    if (observing && statement == 'DELETE FROM main."support_messages" WHERE 0' && args.isEmpty) {
      reservations++;
    } else {
      _write();
    }
    return super.runCustom(executor, statement, args);
  }
  @override
  Future<int> runInsert(QueryExecutor executor, String statement, List<Object?> args) {
    _write(); return super.runInsert(executor, statement, args);
  }
  @override
  Future<int> runUpdate(QueryExecutor executor, String statement, List<Object?> args) {
    _write(); return super.runUpdate(executor, statement, args);
  }
  @override
  Future<int> runDelete(QueryExecutor executor, String statement, List<Object?> args) {
    _write(); return super.runDelete(executor, statement, args);
  }
  @override
  Future<void> runBatched(QueryExecutor executor, BatchedStatements statements) {
    _write(); return super.runBatched(executor, statements);
  }
}
