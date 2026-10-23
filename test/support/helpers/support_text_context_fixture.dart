import 'dart:async';
import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../../credentials/fake_credential_storage.dart';

/// Memory-only declared schema, real AEAD, injected fake vault. No App,
/// production seed/migrations, provider, catalog, environment or HTTP startup.
final class SupportTextContextFixture {
  SupportTextContextFixture() {
    db = _TextDatabase(NativeDatabase.memory().interceptWith(spy));
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: storage,
        buildChannel: 'synthetic_exact_history',
      ),
      cipher: primitive,
    );
    repo = newRepo();
  }

  static const supportId = 'synthetic-support';
  static const roleplayId = 'synthetic-roleplay';
  static const secret = 'SYNTHETIC_HISTORY_SECRET_7b36';
  static const selected = 'SYNTHETIC_SELECTED_BODY_916e';
  static const unselected = 'SYNTHETIC_UNSELECTED_BODY_710d';
  static const card = 'SYNTHETIC_CARD_889e';
  static const reasoning = 'SYNTHETIC_REASONING_e227';
  static const attachment = 'SYNTHETIC_ATTACHMENT_b551';
  static const other = 'SYNTHETIC_OTHER_CHAT_916a';
  final spy = TextContextSqlSpy();
  final primitive = TextContextControlledCipher();
  final storage = FakeCredentialStorage();
  SecretRedactor redactor = SecretRedactor(knownSecrets: [secret]);
  late final AppDatabase db;
  late final SupportPayloadCipher cipher;
  late final SupportTextContextRepo repo;

  SupportTextContextRepo newRepo() => SupportTextContextRepo(
    db: db,
    cipher: cipher,
    currentRedactor: () => redactor,
  );

  Future<String> encrypt(
    String value,
    String table,
    String row,
    String session,
    String field,
  ) => cipher.encrypt(
    plaintext: value,
    table: table,
    rowId: row,
    sessionId: session,
    field: field,
  );

  Future<void> supportSession(String id) async {
    final title = await encrypt(
      'Synthetic title $secret',
      'support_sessions',
      id,
      id,
      'title_ciphertext',
    );
    await db
        .into(db.supportSessions)
        .insert(
          SupportSessionsCompanion.insert(
            id: id,
            titleCiphertext: title,
            createdAt: const Value(1),
            activeApiConfigId: const Value(secret),
            activeModelId: const Value(card),
          ),
        );
  }

  Future<void> supportMessage(
    String id, {
    String session = supportId,
    String body = selected,
    String role = 'assistant',
    String status = 'complete',
    int time = 2,
    String? runId,
  }) async {
    final text = await encrypt(
      body,
      'support_messages',
      id,
      session,
      'body_ciphertext',
    );
    final cards = await encrypt(
      card,
      'support_messages',
      id,
      session,
      'cards_ciphertext',
    );
    await db
        .into(db.supportMessages)
        .insert(
          SupportMessagesCompanion.insert(
            id: id,
            sessionId: session,
            role: role,
            bodyCiphertext: text,
            cardsCiphertext: Value(cards),
            createdAt: Value(time),
            status: Value(status),
            runId: Value(runId),
          ),
        );
  }

  Future<void> provenance(
    String messageId,
    String facts, {
    String session = supportId,
    int time = 2,
  }) async {
    final id = 'support.reply_provenance:$messageId';
    final text = await encrypt(
      facts,
      'support_context_blocks',
      id,
      session,
      'protected_facts_ciphertext',
    );
    await db
        .into(db.supportContextBlocks)
        .insert(
          SupportContextBlocksCompanion.insert(
            id: id,
            sessionId: session,
            startMessageId: messageId,
            endMessageId: messageId,
            summaryCiphertext: 'UNREADABLE_UNSELECTED_SUMMARY_$card',
            protectedFactsCiphertext: Value(text),
            createdAt: Value(time),
            isActive: const Value(false),
          ),
        );
  }

  static Map<String, Object?> message(
    String id, {
    String body = selected,
    String role = 'assistant',
  }) => {
    'id': id,
    'role': role,
    'content': body,
    'timestamp': 11,
    'swipeId': 1,
    'agentSwipeId': 0,
    'isHidden': false,
    'isError': false,
    'isTyping': false,
    'reasoning': reasoning,
    'swipes': [unselected, body],
    'agentSwipes': [
      {'content': body, 'reasoning': reasoning},
    ],
    'swipesMeta': [
      {'rawPrompt': card},
    ],
    'studioOutputs': [
      {'card': card},
    ],
    'imagePath': attachment,
    'extraImagePaths': [attachment],
    'cards': card,
  };

  Future<void> roleplay(
    String id,
    String json, {
    String characterId = 'synthetic-character',
    int index = 0,
  }) async {
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: id,
            characterId: characterId,
            sessionIndex: index,
            messagesJson: json,
            sessionVarsJson: const Value('{"private":"$card"}'),
            authorsNoteJson: const Value('{"prompt":"$reasoning"}'),
            draft: const Value(secret),
          ),
        );
  }

  Future<void> seed() async {
    await supportSession(supportId);
    await supportSession('synthetic-other-support');
    await supportMessage('support-a', role: 'user', body: '$selected $secret');
    await supportMessage('support-b', body: 'Synthetic second', time: 3);
    await supportMessage('support-unselected', body: unselected, time: 4);
    await supportMessage(
      'support-other',
      session: 'synthetic-other-support',
      body: other,
    );
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'synthetic-character',
            name: 'Synthetic',
            description: const Value(card),
            variantGroupId: const Value('synthetic-group'),
            variantOrder: const Value(0),
          ),
        );
    await roleplay(
      roleplayId,
      jsonEncode([
        message('roleplay-a', role: 'user', body: '$selected $secret'),
        message('roleplay-unselected', body: unselected),
        message('roleplay-b', body: 'Synthetic second'),
      ]),
    );
    await roleplay(
      'synthetic-branch',
      jsonEncode([message('roleplay-a', body: other)]),
      index: 1,
    );
  }

  Future<void> replaceRoleplay(List<Object?> messages) =>
      replaceRoleplayJson(jsonEncode(messages));
  Future<void> replaceRoleplayJson(String json) async {
    await (db.update(db.chatSessions)
          ..where((t) => t.sessionId.equals(roleplayId)))
        .write(ChatSessionsCompanion(messagesJson: Value(json)));
  }

  /// Exact byte/column comparison across every declared table; performed only
  /// outside the read-boundary spy. Never contains actual user data.
  Future<String> snapshot() async {
    final tables = <String, Object?>{};
    for (final table in db.allTables) {
      final rows = await db
          .customSelect(
            'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
          )
          .get();
      tables[table.actualTableName] = rows.map((row) => row.data).toList();
    }
    return jsonEncode(tables);
  }

  void observe() {
    spy.observing = true;
    spy.values.clear();
    primitive.decryptAads.clear();
    storage.operations.clear();
  }

  void stopObserving() {
    spy.observing = false;
  }

  Future<void> close() => db.close();
}

final class _TextDatabase extends AppDatabase {
  _TextDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final class TextContextControlledCipher implements Cipher {
  final Cipher delegate = Xchacha20.poly1305Aead();
  final decryptAads = <String>[];
  Future<void> Function(String aad)? beforeDecrypt;
  @override
  List<int> newNonce() => delegate.newNonce();
  @override
  Future<SecretBox> encrypt(
    List<int> clearText, {
    required SecretKey secretKey,
    List<int>? nonce,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) => delegate.encrypt(
    clearText,
    secretKey: secretKey,
    nonce: nonce,
    aad: aad,
    possibleBuffer: possibleBuffer,
  );
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
    return delegate.decrypt(
      secretBox,
      secretKey: secretKey,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Observes actual returned SQL primitive values for canary exclusion; refuses
/// writes at every executor path, and can inject a non-stringifiable failure.
final class TextContextSqlSpy extends QueryInterceptor {
  bool observing = false;
  int writes = 0;
  final values = <Map<String, Object?>>[];
  Object? selectError;
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (observing && selectError != null) throw selectError!;
    final rows = await super.runSelect(executor, statement, args);
    if (observing) values.addAll(rows);
    return rows;
  }

  void _write() {
    if (observing) {
      writes++;
      throw StateError('Synthetic exact reader attempted write');
    }
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _write();
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _write();
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _write();
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    _write();
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    _write();
    return super.runBatched(executor, statements);
  }
}
