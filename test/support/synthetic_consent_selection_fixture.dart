import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_consent_selection_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../credentials/fake_credential_storage.dart';

/// Exclusively synthetic, memory-only SQLite. No App, seed/catalog, provider,
/// private storage, filesystem database, platform vault, or network bootstrap.
final class SyntheticConsentSelectionFixture {
  SyntheticConsentSelectionFixture() {
    db = _SyntheticSelectionDatabase(
      NativeDatabase.memory().interceptWith(spy),
    );
    cipher = SupportPayloadCipher(
      vault: CredentialVault(
        storage: storage,
        buildChannel: 'synthetic_selector_test',
      ),
    );
    support = SupportRepo(db, cipher);
    repo = SupportConsentSelectionRepo(
      db: db,
      supportRepo: support,
      currentRedactor: () => redactor,
    );
  }

  static const secret = 'SELECTOR_KNOWN_SECRET_7c91';
  static const bodyCanary = 'BODY_CANARY_83ac';
  static const cardCanary = 'CARD_CANARY_c784';
  static const reasoningCanary = 'REASONING_CANARY_51be';
  static const pathCanary = r'C:\private\AVATAR_PATH_CANARY.png';
  final spy = SyntheticSelectionSqlSpy();
  final storage = FakeCredentialStorage();
  SecretRedactor redactor = SecretRedactor(knownSecrets: [secret]);
  late final AppDatabase db;
  late final SupportPayloadCipher cipher;
  late final SupportRepo support;
  late final SupportConsentSelectionRepo repo;

  Future<void> character(
    String id, {
    String name = 'Synthetic character',
    String? variantName = 'Synthetic variant',
    String group = 'synthetic_group',
    int order = 2,
    bool hidden = false,
  }) => db
      .into(db.characters)
      .insert(
        CharactersCompanion.insert(
          charId: id,
          name: name,
          variantName: Value(variantName),
          variantGroupId: Value(group),
          variantOrder: Value(order),
          hidden: Value(hidden),
          description: const Value(cardCanary),
          avatarPath: const Value(pathCanary),
          extensionsJson: const Value('{"credential":"$secret"}'),
        ),
      )
      .then((_) {});

  Future<void> roleplay(
    String id,
    String characterId,
    String json, {
    int index = 0,
    int updatedAt = 0,
  }) => db
      .into(db.chatSessions)
      .insert(
        ChatSessionsCompanion.insert(
          sessionId: id,
          characterId: characterId,
          sessionIndex: index,
          messagesJson: json,
          updatedAt: Value(updatedAt),
          sessionVarsJson: const Value('{"private":"$bodyCanary"}'),
          authorsNoteJson: const Value('{"note":"$reasoningCanary"}'),
          draft: const Value(secret),
          lastScrollAnchorJson: const Value(pathCanary),
        ),
      )
      .then((_) {});

  static Map<String, Object?> message(
    String id, {
    String role = 'assistant',
    int? timestamp = 10,
    int swipeId = 2,
    int agentSwipeId = 1,
    bool hidden = false,
    bool error = false,
    bool typing = false,
  }) => {
    'id': id,
    'role': role,
    'timestamp': timestamp,
    'swipeId': swipeId,
    'agentSwipeId': agentSwipeId,
    'isHidden': hidden,
    'isError': error,
    'isTyping': typing,
    'content': bodyCanary,
    'reasoning': reasoningCanary,
    'swipes': [bodyCanary],
    'swipesMeta': [
      {'secret': secret},
    ],
    'agentSwipes': [
      {'content': bodyCanary},
    ],
    'imagePath': pathCanary,
    'extraImagePaths': [pathCanary],
    'memoryCoverage': {'private': secret},
  };

  Future<void> supportSession(String id) async {
    await support.createSession(
      SupportSession(
        id: id,
        title: '$secret $bodyCanary',
        createdAt: 1,
        updatedAt: 2,
        activeApiConfigId: secret,
        activeModelId: pathCanary,
      ),
    );
  }

  Future<void> supportMessage(
    String id,
    String sessionId, {
    String role = 'assistant',
    String status = 'complete',
    int createdAt = 1,
  }) async {
    await support.appendMessage(
      SupportMessage(
        id: id,
        sessionId: sessionId,
        role: role,
        body: bodyCanary,
        cardsJson: '{"private":"$cardCanary"}',
        runId: secret,
        status: status,
        createdAt: createdAt,
      ),
    );
  }

  /// Byte-preserving text/ciphertext and all column values for EVERY registered
  /// table. The snapshot phase is deliberately outside selector observation.
  Future<String> snapshot() async {
    final all = <String, Object?>{};
    for (final table in db.allTables) {
      final rows = await db
          .customSelect(
            'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
          )
          .get();
      all[table.actualTableName] = rows.map((r) => r.data).toList();
    }
    return jsonEncode(all);
  }

  void observe() {
    spy.start();
    storage.operations.clear();
    storage.reads = 0;
  }

  Future<void> close() => db.close();
}

final class _SyntheticSelectionDatabase extends AppDatabase {
  _SyntheticSelectionDatabase(super.e) : super.forTesting();

  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

final class SyntheticSelectionSqlRead {
  SyntheticSelectionSqlRead(this.sql, List<Object?> args)
    : args = List.unmodifiable(args);
  final String sql;
  final List<Object?> args;
  int? returnedRows;
  Set<String> returnedColumns = {};
}

/// Stops writes at the actual executor boundary, including transaction/batch
/// paths; observes SQL, bound targets and returned column names, never bodies.
final class SyntheticSelectionSqlSpy extends QueryInterceptor {
  bool observing = false;
  final reads = <SyntheticSelectionSqlRead>[];
  int writes = 0;
  Object? selectError;
  Future<void> Function(String sql)? afterSelect;

  void start() {
    reads.clear();
    writes = 0;
    observing = true;
  }

  void _write() {
    if (!observing) return;
    writes++;
    throw StateError('Synthetic selector attempted a write');
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final record = SyntheticSelectionSqlRead(statement, args);
    if (observing) {
      reads.add(record);
      if (selectError != null) throw selectError!;
    }
    final rows = await super.runSelect(executor, statement, args);
    if (observing) {
      record.returnedRows = rows.length;
      record.returnedColumns = rows.isEmpty ? {} : rows.first.keys.toSet();
      await afterSelect?.call(statement);
    }
    return rows;
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
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) {
    _write();
    return super.runBatched(executor, statements);
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
}
