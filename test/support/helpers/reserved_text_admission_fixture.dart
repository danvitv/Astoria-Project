import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../credentials/fake_credential_storage.dart';
import 'support_text_context_fixture.dart' show TextContextControlledCipher;

/// Explicitly declared-schema AppDatabase subclass, NOT AppDatabase() startup.
/// A is one background native connection; B is independently sqlite3.open-ed.
/// Only createTemp's unique owned directory under the approved root is removed,
/// after both handles close. No root cleanup, env/OS vault, seed or real HTTP.
final class ReservedTextAdmissionFixture {
  ReservedTextAdmissionFixture._(this.directory, this.file);
  final Directory directory;
  final File file;
  final spy = AdmissionSqlProbe();
  final storage = FakeCredentialStorage();
  final primitive = TextContextControlledCipher();
  SecretRedactor redactor = SecretRedactor();
  late AppDatabase db;
  late sqlite.Database other;
  late final SupportPayloadCipher cipher;
  late SupportTextContextRepo repo;
  late final String originalEnvelope;
  late final String changedEnvelope;
  late final String sqliteVersion;
  late final String sqliteSourceId;
  bool _otherOpened = false;
  bool _dbOpened = false;

  static Future<ReservedTextAdmissionFixture> create({
    bool populated = true,
  }) async {
    final directory = await Directory(
      'C:/Users/Даниил/AppData/Local/Temp/opencode',
    ).createTemp('reserved-text-admission-');
    final fixture = ReservedTextAdmissionFixture._(
      directory,
      File('${directory.path}/fixture.db'),
    );
    try {
      fixture.openA();
      await fixture.db.customSelect('SELECT 1').getSingle();
      fixture.cipher = SupportPayloadCipher(
        vault: CredentialVault(
          storage: fixture.storage,
          buildChannel: 'synthetic_reserved_text',
        ),
        cipher: fixture.primitive,
      );
      fixture.repo = fixture.newRepo();
      final title = await fixture.encrypt(
        'Synthetic session',
        'support_sessions',
        'session',
        'title_ciphertext',
      );
      await fixture.db
          .into(fixture.db.supportSessions)
          .insert(
            SupportSessionsCompanion.insert(
              id: 'session',
              titleCiphertext: title,
              createdAt: const Value(1),
            ),
          );
      fixture.originalEnvelope = await fixture.encrypt(
        'Reviewed history',
        'support_messages',
        'history',
        'body_ciphertext',
      );
      fixture.changedEnvelope = await fixture.encrypt(
        'Changed history',
        'support_messages',
        'history',
        'body_ciphertext',
      );
      if (populated) {
        await fixture.db
            .into(fixture.db.supportMessages)
            .insert(
              SupportMessagesCompanion.insert(
                id: 'history',
                sessionId: 'session',
                role: 'user',
                bodyCiphertext: fixture.originalEnvelope,
                createdAt: const Value(2),
              ),
            );
      }
      // Separate synthetic trigger table proves the zero-row statement has no
      // row-trigger effect; this is fixture-only schema, never production DDL.
      await fixture.db.customStatement(
        'CREATE TABLE fixture_trigger_count (n INTEGER NOT NULL)',
      );
      await fixture.db.customStatement(
        'INSERT INTO fixture_trigger_count VALUES (0)',
      );
      await fixture.db.customStatement(
        'CREATE TRIGGER fixture_delete AFTER DELETE ON support_messages BEGIN UPDATE fixture_trigger_count SET n = n + 1; END',
      );
      fixture.other = sqlite.sqlite3.open(fixture.file.path);
      fixture._otherOpened = true;
      fixture.other.execute('PRAGMA busy_timeout = 0');
      final mode = await fixture.db
          .customSelect('PRAGMA journal_mode')
          .getSingle();
      if (mode.data.values.single != 'wal' ||
          fixture.other.select('PRAGMA journal_mode').single.values.single !=
              'wal') {
        throw StateError('Synthetic fixture requires WAL');
      }
      final identity = await fixture.db
          .customSelect('SELECT sqlite_version() AS v, sqlite_source_id() AS s')
          .getSingle();
      fixture.sqliteVersion = identity.read<String>('v');
      fixture.sqliteSourceId = identity.read<String>('s');
      return fixture;
    } catch (_) {
      await fixture.close();
      rethrow;
    }
  }

  void openA() {
    db = _AdmissionDatabase(
      NativeDatabase.createInBackground(
        file,
        readPool: 0,
        setup: _setup,
      ).interceptWith(spy),
    );
    _dbOpened = true;
  }

  static void _setup(sqlite.Database db) {
    db.execute('PRAGMA journal_mode = WAL');
    db.execute(
      'PRAGMA busy_timeout = 0',
    ); // Known capture-free setup, no handler.
  }

  SupportTextContextRepo newRepo({
    SupportTextAdmissionContract? contract =
        SupportTextAdmissionContract.auditedRootSingleConnectionNoBusyHandler,
  }) => SupportTextContextRepo(
    db: db,
    cipher: cipher,
    currentRedactor: () => redactor,
    admissionContract: contract,
  );

  Future<String> encrypt(String text, String table, String row, String field) =>
      cipher.encrypt(
        plaintext: text,
        table: table,
        rowId: row,
        sessionId: 'session',
        field: field,
      );

  Future<SupportTextContextSnapshot> preview() =>
      repo.loadSupport(sessionId: 'session', messageIds: ['history']);

  Future<void> seedRoleplay() async {
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'synthetic-character',
            name: 'Synthetic',
            variantGroupId: const Value('synthetic-group'),
            variantOrder: const Value(0),
          ),
        );
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: 'synthetic-game',
            characterId: 'synthetic-character',
            sessionIndex: 0,
            messagesJson: jsonEncode([
              {
                'id': 'game-history',
                'role': 'user',
                'content': 'Reviewed game',
                'timestamp': 1,
              },
            ]),
          ),
        );
  }

  Future<(int, int)> stamp() async {
    final row = await db
        .customSelect(
          'SELECT total_changes() AS c, data_version AS v FROM pragma_data_version',
        )
        .getSingle();
    return (row.read<int>('c'), row.read<int>('v'));
  }

  Future<String> tableBytes() async {
    final result = <String, Object?>{};
    for (final table in db.allTables) {
      result[table.actualTableName] =
          (await db
                  .customSelect(
                    'SELECT * FROM "${table.actualTableName}" ORDER BY rowid',
                  )
                  .get())
              .map((r) => r.data)
              .toList();
    }
    result['fixture_trigger_count'] =
        (await db.customSelect('SELECT n FROM fixture_trigger_count').get())
            .map((r) => r.data)
            .toList();
    return jsonEncode(result);
  }

  bool otherWriterBusy() {
    try {
      other.execute('BEGIN IMMEDIATE');
      other.execute('ROLLBACK');
      return false;
    } on sqlite.SqliteException catch (error) {
      if (error.resultCode != 5) rethrow;
      return true;
    }
  }

  void otherWrite() => other.execute(
    'UPDATE support_sessions SET updated_at = updated_at + 1 WHERE id = ?',
    ['session'],
  );

  Future<void> ownWrite() => db.customStatement(
    'UPDATE support_sessions SET updated_at = updated_at + 1 WHERE id = ?',
    ['session'],
  );

  /// Owning-db read shape, with a checkpoint immediately after awaited SQL.
  Future<bool> readOnlyPolicy(void Function() checkpoint) async {
    checkpoint();
    final row = await db
        .customSelect(
          'SELECT id FROM support_sessions WHERE id = ?',
          variables: [Variable.withString('session')],
        )
        .getSingleOrNull();
    checkpoint();
    return row?.read<String>('id') == 'session';
  }

  Future<void> reconnect() async {
    repo.revokeAdmissionOwner();
    await db.close();
    _dbOpened = false;
    openA();
    await db.customSelect('SELECT 1').getSingle();
    repo = newRepo();
  }

  Future<void> close() async {
    try {
      if (_otherOpened) {
        other.close();
        _otherOpened = false;
      }
    } finally {
      if (_dbOpened) {
        await db.close();
        _dbOpened = false;
      }
    }
    await directory.delete(
      recursive: true,
    ); // Only createTemp's retained owner.
  }
}

final class _AdmissionDatabase extends AppDatabase {
  _AdmissionDatabase(super.e) : super.forTesting();
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (m) => m.createAll());
}

/// Fixture-only SQL event classifications, never request/credential captures.
final class AdmissionSqlProbe extends QueryInterceptor {
  final events = <String>[];
  Future<void> Function()? afterReserve;
  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    events.add(statement == 'PRAGMA busy_timeout' ? 'timeout' : 'read');
    return super.runSelect(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final reserve = statement == 'DELETE FROM main."support_messages" WHERE 0';
    events.add(reserve ? 'reserve' : 'custom');
    await super.runCustom(executor, statement, args);
    if (reserve) await afterReserve?.call();
  }
}

final class UnprintableAdmissionError implements Exception {
  const UnprintableAdmissionError();
  @override
  String toString() =>
      throw StateError('Private raw error must not be formatted');
}

/// Actual fetch is SYNCHRONOUS at entry and records counts only. HTTP response
/// may be paused beyond DB release. No options/upload/header/body capture.
final class ReservedFixtureAdapter implements HttpClientAdapter {
  ReservedFixtureAdapter({
    this.onFetch,
    this.syncThrow = false,
    this.fastReject = false,
  });
  final void Function()? onFetch;
  final bool syncThrow;
  final bool fastReject;
  final fetched = Completer<void>();
  final response = Completer<ResponseBody>();
  int fetches = 0;
  bool closed = false;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) {
    fetches++;
    onFetch?.call();
    if (!fetched.isCompleted) fetched.complete();
    if (syncThrow) throw const UnprintableAdmissionError();
    if (fastReject) return Future.error(const UnprintableAdmissionError());
    return response.future;
  }

  void complete({int status = 200}) {
    final bytes = utf8.encode(
      'data: {"choices":[{"index":0,"delta":{"content":"Safe reply"},"finish_reason":null}]}\n\ndata: {"choices":[{"index":0,"delta":{},"finish_reason":"stop"}]}\n\ndata: [DONE]\n\n',
    );
    response.complete(
      ResponseBody(
        Stream.value(Uint8List.fromList(bytes)),
        status,
        headers: {
          'content-type': ['text/event-stream'],
        },
      ),
    );
  }

  @override
  void close({bool force = false}) => closed = true;
}
