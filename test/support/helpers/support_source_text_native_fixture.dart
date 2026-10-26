import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:path/path.dart' as p;
import 'package:sqlite3/sqlite3.dart' as sqlite;

import '../../credentials/fake_credential_storage.dart';
import 'support_text_context_fixture.dart';

/// Source-reader-only synthetic FILE fixture. The real openedNative executor
/// retains this exact handle; fake storage and AEAD never read a runtime vault.
/// SQL observation uses db.runWithInterceptor, not a replacement AppDatabase.
final class SupportSourceTextNativeFixture {
  static const approvedRoot = r'C:\Users\Даниил\AppData\Local\Temp\opencode';
  final spy = TextContextSqlSpy();
  final primitive = TextContextControlledCipher();
  final storage = FakeCredentialStorage();
  SecretRedactor redactor = SecretRedactor(
    knownSecrets: [SupportTextContextFixture.secret],
  );
  late final Directory directory;
  late final String sourcePath;
  late final sqlite.Database handle;
  late final AppDatabase db;
  late final SupportPayloadCipher cipher = SupportPayloadCipher(
    vault: CredentialVault(
      storage: storage,
      buildChannel: 'synthetic_source_text',
    ),
    cipher: primitive,
  );
  bool _created = false, _opened = false, _databaseReady = false;
  bool _closed = false;

  Future<void> initialize() async {
    directory = await Directory(approvedRoot).createTemp('source-text-repo-');
    _created = true;
    sourcePath = p.join(directory.path, 'original.db');
    handle = sqlite.sqlite3.open(sourcePath);
    _opened = true;
    handle.execute('PRAGMA busy_timeout=0');
    db = AppDatabase.openedNative(handle, closeUnderlyingOnClose: false);
    _databaseReady = true;
    expect(db.nativeDataSourceIdentity, isNull);
    await db.customSelect('SELECT 1').get();
    expect(db.nativeDataSourceIdentity?.belongsTo(db), isTrue);
    // Fresh creation seeds one default preset. Remove only that fresh fixture
    // row so Studio tests observe their own exact synthetic definitions.
    await (db.delete(
      db.studioPresetRows,
    )..where((t) => t.presetId.equals('default'))).go();
  }

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
      'Synthetic title ${SupportTextContextFixture.secret}',
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
            activeApiConfigId: const Value(SupportTextContextFixture.secret),
            activeModelId: const Value(SupportTextContextFixture.card),
          ),
        );
  }

  Future<void> supportMessage(
    String id, {
    String session = SupportTextContextFixture.supportId,
    String body = SupportTextContextFixture.selected,
    String role = 'assistant',
    int time = 2,
  }) async {
    final text = await encrypt(
      body,
      'support_messages',
      id,
      session,
      'body_ciphertext',
    );
    final cards = await encrypt(
      SupportTextContextFixture.card,
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
          ),
        );
  }

  Future<void> roleplay(String id, String json, {int index = 0}) async {
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: id,
            characterId: 'synthetic-character',
            sessionIndex: index,
            messagesJson: json,
            sessionVarsJson: const Value(
              '{"private":"${SupportTextContextFixture.card}"}',
            ),
            authorsNoteJson: const Value(
              '{"prompt":"${SupportTextContextFixture.reasoning}"}',
            ),
            draft: const Value(SupportTextContextFixture.secret),
          ),
        );
  }

  Future<void> seed() async {
    await supportSession(SupportTextContextFixture.supportId);
    await supportSession('synthetic-other-support');
    await supportMessage(
      'support-a',
      role: 'user',
      body:
          '${SupportTextContextFixture.selected} ${SupportTextContextFixture.secret}',
    );
    await supportMessage('support-b', body: 'Synthetic second', time: 3);
    await supportMessage(
      'support-unselected',
      body: SupportTextContextFixture.unselected,
      time: 4,
    );
    await supportMessage(
      'support-other',
      session: 'synthetic-other-support',
      body: SupportTextContextFixture.other,
    );
    await db
        .into(db.characters)
        .insert(
          CharactersCompanion.insert(
            charId: 'synthetic-character',
            name: 'Synthetic',
            description: const Value(SupportTextContextFixture.card),
            variantGroupId: const Value('synthetic-group'),
            variantOrder: const Value(0),
          ),
        );
    await roleplay(
      SupportTextContextFixture.roleplayId,
      jsonEncode([
        SupportTextContextFixture.message(
          'roleplay-a',
          role: 'user',
          body:
              '${SupportTextContextFixture.selected} ${SupportTextContextFixture.secret}',
        ),
        SupportTextContextFixture.message(
          'roleplay-unselected',
          body: SupportTextContextFixture.unselected,
        ),
        SupportTextContextFixture.message(
          'roleplay-b',
          body: 'Synthetic second',
        ),
      ]),
    );
    await roleplay(
      'synthetic-branch',
      jsonEncode([
        SupportTextContextFixture.message(
          'roleplay-a',
          body: SupportTextContextFixture.other,
        ),
      ]),
      index: 1,
    );
  }

  Future<void> replaceRoleplay(List<Object?> messages) =>
      replaceRoleplayJson(jsonEncode(messages));

  Future<void> replaceRoleplayJson(String json) async {
    await (db.update(db.chatSessions)..where(
          (t) => t.sessionId.equals(SupportTextContextFixture.roleplayId),
        ))
        .write(ChatSessionsCompanion(messagesJson: Value(json)));
  }

  /// Enable only inside a runWithInterceptor scope using this spy.
  void observe() {
    spy.observing = true;
    spy.values.clear();
    primitive.decryptAads.clear();
    storage.operations.clear();
  }

  void stopObserving() => spy.observing = false;

  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    Object? failure;
    StackTrace? stack;
    Future<void> cleanup(Future<void> Function() action) async {
      try {
        await action();
      } catch (error, trace) {
        failure ??= error;
        stack ??= trace;
      }
    }

    if (_databaseReady) await cleanup(db.close);
    if (_opened) await cleanup(() async => handle.close());
    if (_created) {
      await cleanup(() async {
        await for (final entry in directory.list(followLinks: false)) {
          expect(p.dirname(entry.path), directory.path);
          if (entry is! File && entry is! Link) {
            throw TestFailure('Unexpected non-flat synthetic source directory');
          }
          await entry.delete();
        }
        await directory.delete();
      });
    }
    if (failure != null) Error.throwWithStackTrace(failure!, stack!);
  }
}
