import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import '../../credentials/fake_credential_storage.dart';

/// Each test starts isolation BEFORE constructing/evaluating its owned fixture.
/// Native/HTTP/file/default-opener tripwires remain through SQL/vault cleanup.
/// This is not a universal FFI sandbox: only memory SQLite may load its library.
void journalTest(String name, Future<void> Function(JournalFixture f) body) {
  test(name, () async {
    final attempts = <String>[];
    Never block(String name) {
      attempts.add(name);
      throw StateError('Outside synthetic journal fixture.');
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
            final f = JournalFixture();
            try {
              await f.seed();
              await body(f);
            } finally {
              f.clearHooks();
              await f.close();
              await messenger.platformMessagesFinished;
              expect(
                attempts,
                isEmpty,
                reason: 'No swallowed native/startup/I/O through cleanup.',
              );
            }
          },
          createFile: (_) => block('file/default database'),
          createDirectory: (_) => block('directory/default database'),
          createLink: (_) => block('link'),
        ),
        createHttpClient: (_) => block('HttpClient'),
      );
    } finally {
      messenger.allMessagesHandler = previous;
    }
  });
}

/// Owned declared schema only: NEVER AppDatabase() or inherited Studio seeding.
final class JournalMemoryDatabase extends AppDatabase {
  JournalMemoryDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());

  /// Gate after actual Drift transaction completion, not a simulated SQL write.
  /// No physical COMMIT failure/power-loss behavior is inferred from this hook.
  Future<void> Function()? afterCommit;
  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    final result = await super.transaction(action, requireNew: requireNew);
    await afterCommit?.call();
    return result;
  }
}

final class JournalFixture {
  JournalFixture() {
    db = JournalMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
    vault = CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_journal',
    );
    cipher = SupportPayloadCipher(vault: vault, cipher: primitive);
    repo = SupportRepo(db, cipher);
    primitive.event = event;
    sql.event = event;
    storage.beforeRead = () => event('vault-read');
    storage.beforeWrite = () => event('vault-write');
  }

  static const id = 'synthetic-mutation';
  static const sessionId = 'synthetic-journal-session';
  static const foreignId = 'synthetic-journal-foreign';
  static const canary = 'SYNTHETIC_NATIVE_EVIDENCE_CANARY';
  static final candidate = SupportMutationRecord(
    id: id,
    sessionId: sessionId,
    domain: 'theme.selection',
    targetId: 'installed-active-selection',
    beforeJson: SupportMutationEvidence.encode(
      '{"selection":"synthetic-a","safe":"$canary"}',
    ),
    afterJson: SupportMutationEvidence.encode(
      '{"selection":"synthetic-b","safe":"$canary"}',
    ),
    status: 'pending',
    createdAt: 4,
  );

  final storage = FakeCredentialStorage();
  final primitive = JournalControlledCipher();
  final sql = JournalControlledSql();
  late final JournalMemoryDatabase db;
  late final CredentialVault vault;
  late final SupportPayloadCipher cipher;
  late final SupportRepo repo;
  final events = <String>[];
  Future<void> Function(String event)? hook;
  bool current = true;
  bool isCurrent() => current;
  Future<void> event(String event) async {
    events.add(event);
    await hook?.call(event);
  }

  Future<void> seed() async {
    for (final id in [sessionId, foreignId]) {
      await repo.createSession(
        SupportSession(
          id: id,
          title: 'SYNTHETIC_TITLE',
          createdAt: 1,
          updatedAt: 2,
          pinned: true,
        ),
      );
    }
    await repo.putMessage(
      const SupportMessage(
        id: 'synthetic-message',
        sessionId: sessionId,
        role: 'user',
        body: 'SYNTHETIC_UNRELATED_HISTORY',
        createdAt: 3,
      ),
    );
    await repo.putContextBlock(
      const SupportContextBlock(
        id: 'synthetic-context',
        sessionId: sessionId,
        startMessageId: 'synthetic-message',
        endMessageId: 'synthetic-message',
        summary: 'SYNTHETIC_UNRELATED_CONTEXT',
        createdAt: 3,
      ),
    );
    await repo.putReport(
      const SupportReportRecord(
        id: 'synthetic-report',
        sessionId: sessionId,
        fileHash: 'synthetic-hash',
        createdAt: 3,
      ),
    );
    observe();
  }

  void observe() => events.clear();
  void clearHooks() {
    hook = null;
    db.afterCommit = null;
    storage.readError = null;
    storage.writeError = null;
  }

  Future<SupportMutationReservation?> reserve([
    SupportMutationRecord? record,
  ]) => repo.reserveMutation(record: record ?? candidate, isCurrent: isCurrent);
  Future<SupportMutationReservation?> read({
    String id = id,
    String session = sessionId,
    String domain = 'theme.selection',
    String target = 'installed-active-selection',
  }) => repo.readCurrentMutation(
    id: id,
    sessionId: session,
    domain: domain,
    targetId: target,
    isCurrent: isCurrent,
  );
  Future<SupportMutationReservation?> settle(
    SupportMutationReservation expected, [
    SupportMutationFact fact = SupportMutationFact.applied,
  ]) => repo.settleMutation(
    expected: expected,
    fact: fact,
    hasOriginalDbCustody: isCurrent,
  );
  Future<SupportMutationReservation?> undo(
    SupportMutationReservation expected,
  ) => repo.reserveMutationUndo(expected: expected, isCurrent: isCurrent);
  Future<bool> delete() => repo.deleteSessionIfMutationsSettled(
    sessionId: sessionId,
    isCurrent: isCurrent,
  );
  Future<SupportMutationJournalRow?> row([String id = id]) => (db.select(
    db.supportMutationJournal,
  )..where((t) => t.id.equals(id))).getSingleOrNull();
  Future<void> change(SupportMutationJournalCompanion update) => (db.update(
    db.supportMutationJournal,
  )..where((t) => t.id.equals(id))).write(update);
  Future<void> remove() => (db.delete(
    db.supportMutationJournal,
  )..where((t) => t.id.equals(id))).go();

  /// Exact raw bytes of every declared table, not just the target DTO/status.
  Future<String> snapshot() async {
    final tables = <String, Object>{};
    for (final table in db.allTables) {
      final rows = await db
          .customSelect(
            'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
          )
          .get();
      tables[table.actualTableName] = rows.map((r) => r.data).toList();
    }
    return jsonEncode(tables);
  }

  Future<void> close() => db.close();
}

/// Real AEAD both directions, with deterministic awaited boundary observation.
final class JournalControlledCipher implements Cipher {
  final delegate = Xchacha20.poly1305Aead();
  Future<void> Function(String)? event;
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
    final box = await delegate.encrypt(
      clearText,
      secretKey: secretKey,
      nonce: nonce,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
    await event?.call('encrypt:$context');
    return box;
  }

  @override
  Future<List<int>> decrypt(
    SecretBox box, {
    required SecretKey secretKey,
    List<int> aad = const [],
    Uint8List? possibleBuffer,
  }) async {
    final context = utf8.decode(aad);
    await event?.call('decrypt-before:$context');
    final result = await delegate.decrypt(
      box,
      secretKey: secretKey,
      aad: aad,
      possibleBuffer: possibleBuffer,
    );
    await event?.call('decrypt-after:$context');
    return result;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

final class JournalControlledSql extends QueryInterceptor {
  Future<void> Function(String)? event;
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runSelect(executor, statement, args);
    await event?.call('select:$statement');
    return result;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runInsert(executor, statement, args);
    await event?.call('insert:$statement');
    return result;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runUpdate(executor, statement, args);
    await event?.call('update:$statement');
    return result;
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final result = await super.runDelete(executor, statement, args);
    await event?.call('delete:$statement');
    return result;
  }
}

final class JournalBarrier {
  final entered = Completer<void>();
  final release = Completer<void>();
  Future<void> wait() async {
    if (!entered.isCompleted) entered.complete();
    await release.future;
  }
}
