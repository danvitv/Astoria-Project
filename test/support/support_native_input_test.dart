import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import 'helpers/support_native_input_fixture.dart';

void main() {
  late NativeInputFixture f;
  setUp(() async {
    f = NativeInputFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  test(
    'create-only returns exact AEAD durable row and only updates parent time',
    () async {
      final parent = (await f.parentRow())!;
      final old = await f.row(NativeInputFixture.oldId);
      final foreign = await f.row('synthetic-foreign-body');
      f.observe();
      final accepted = (await f.append())!;
      expect(accepted, NativeInputFixture.input.copyWith(createdAt: 11));
      expect(f.sql.writes, hasLength(2));
      expect(f.sql.writes.first, startsWith('INSERT INTO'));
      expect(f.sql.writes.first.toUpperCase(), isNot(contains('CONFLICT')));
      expect(f.sql.writes.last, contains('"updated_at"'));
      expect(f.sql.writes.last, isNot(contains('title_ciphertext')));
      expect(f.storage.operations.where((op) => op != 'read'), isEmpty);
      final row = (await f.row(accepted.id))!;
      expect(row.bodyCiphertext, isNot(contains(accepted.body)));
      expect(row.cardsCiphertext, '');
      expect(row.runId, accepted.runId);
      expect(row.createdAt, accepted.createdAt);
      expect(await f.repo.getMessageById(accepted.id), accepted);
      expect(await f.parentRow(), parent.copyWith(updatedAt: 11));
      expect(await f.row(NativeInputFixture.oldId), old);
      expect(await f.row('synthetic-foreign-body'), foreign);
      f.current = false;
      expect(await f.repo.getMessageById(accepted.id), accepted);
      expect(await f.append(), isNull);
    },
  );

  test(
    'ordering and collisions project metadata only, never old body/cards',
    () async {
      final old = (await f.row(NativeInputFixture.oldId))!;
      final foreign = (await f.row('synthetic-foreign-body'))!;
      await (f.db.update(
        f.db.supportMessages,
      )..where((t) => t.id.equals(old.id))).write(
        const SupportMessagesCompanion(
          bodyCiphertext: Value('SYNTHETIC_LOCKED_OLD'),
        ),
      );
      f.observe();
      expect(await f.append(), isNotNull);
      final observations = List.of(f.sql.observations);
      final decrypts = List.of(f.primitive.decryptAads);
      final messageReads = observations.where(
        (o) => o.statement.contains('support_messages'),
      );
      for (final observation in messageReads) {
        if (observation.statement.contains('MAX(created_at)') ||
            observation.statement.contains('invalid_order') ||
            observation.statement.contains('AS present')) {
          expect(observation.statement, isNot(contains('body_ciphertext')));
          expect(observation.statement, isNot(contains('cards_ciphertext')));
        } else {
          expect(observation.args, [NativeInputFixture.input.id]);
          expect(
            observation.rows.every(
              (r) => r['id'] == NativeInputFixture.input.id,
            ),
            isTrue,
          );
        }
        expect(
          observation.rows.toString(),
          isNot(contains(old.cardsCiphertext)),
        );
        expect(
          observation.rows.toString(),
          isNot(contains(foreign.bodyCiphertext)),
        );
        expect(
          observation.rows.toString(),
          isNot(contains('SYNTHETIC_LOCKED_OLD')),
        );
      }
      final bodyDecrypts = decrypts.where(
        (aad) => aad.contains('|support_messages|'),
      );
      expect(bodyDecrypts, hasLength(1));
      expect(bodyDecrypts.single, contains('|${NativeInputFixture.input.id}|'));
      expect(
        observations.any((o) => o.statement.contains('support_context_blocks')),
        isFalse,
      );
      f.observe();
      final collision = NativeInputFixture.input.copyWith(
        id: NativeInputFixture.oldId,
      );
      expect(await f.append(collision), isNull);
      expect(f.sql.writes, isEmpty);
      final collisionReads = f.sql.observations.where(
        (o) => o.statement.contains('support_messages'),
      );
      expect(collisionReads, hasLength(1));
      expect(collisionReads.single.statement, contains('SELECT 1 AS present'));
      expect(
        f.primitive.decryptAads.any(
          (aad) => aad.contains('|support_messages|'),
        ),
        isFalse,
      );
    },
  );

  for (final id in [NativeInputFixture.input.id, 'synthetic-foreign-body']) {
    test(
      'same/foreign session ID collision $id never changes old bytes',
      () async {
        if (id == NativeInputFixture.input.id) await f.append();
        final before = await f.snapshot();
        expect(
          await f.append(NativeInputFixture.input.copyWith(id: id)),
          isNull,
        );
        expect(await f.snapshot(), before);
      },
    );
  }

  test(
    'simultaneous duplicate append has exactly one durable winner',
    () async {
      final results = await Future.wait([f.append(), f.append()]);
      final winner = results.whereType<SupportMessage>().single;
      expect(await f.repo.getMessageById(winner.id), winner);
      expect(winner.createdAt, 11);
    },
  );

  test(
    'invalid native role/status/cards/identity/size/clock refuse without access',
    () async {
      final m = NativeInputFixture.input;
      final before = await f.snapshot();
      f.observe();
      for (final message in [
        m.copyWith(role: 'assistant'),
        m.copyWith(role: 'tool'),
        m.copyWith(status: 'preparing'),
        m.copyWith(status: 'pending'),
        m.copyWith(cardsJson: '[]'),
        m.copyWith(isLocked: true),
        m.copyWith(id: ''),
        m.copyWith(id: 'x' * 129),
        m.copyWith(sessionId: ''),
        m.copyWith(sessionId: 'x' * 129),
        m.copyWith(clearRunId: true),
        m.copyWith(runId: ''),
        m.copyWith(runId: 'x' * 129),
        m.copyWith(runId: 'bad|run'),
        m.copyWith(runId: ' run'),
        m.copyWith(body: 'x' * 8193),
        m.copyWith(createdAt: -1),
        m.copyWith(createdAt: NativeInputFixture.maxTime + 1),
      ]) {
        expect(await f.append(message), isNull);
      }
      f.current = false;
      expect(await f.append(), isNull);
      expect(f.sql.observations, isEmpty);
      expect(f.sql.writes, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(await f.snapshot(), before);
    },
  );

  test(
    '8192 UTF16 units and 128-unit Unicode IDs retain exact input',
    () async {
      final m = NativeInputFixture.input.copyWith(
        id: '界' * 128,
        runId: '界' * 128,
        body: '🙂' * 4096,
      );
      final durable = (await f.append(m))!;
      expect(durable, m.copyWith(createdAt: 11));
      expect(await f.repo.getMessageById(durable.id), durable);
      expect(
        await f.append(m.copyWith(id: 'other', body: '${m.body}x')),
        isNull,
      );
    },
  );

  test(
    'clock floor is strict, rollback/rebuilt facade uses latest metadata',
    () async {
      final first = (await f.append(
        NativeInputFixture.input.copyWith(createdAt: 100),
      ))!;
      expect(first.createdAt, 101);
      f.repo = SupportRepo(f.db, f.cipher);
      final second = (await f.append(
        NativeInputFixture.input.copyWith(
          id: 'a-later-user',
          runId: 'second-run',
          createdAt: 0,
        ),
      ))!;
      expect(second.createdAt, 102);
      expect((await f.parentRow())!.updatedAt, 102);
      expect(await f.repo.getMessageById(second.id), second);
    },
  );

  test(
    'empty session allocates strictly above zero floor, retaining newer parent time',
    () async {
      await f.repo.deleteMessage(NativeInputFixture.oldId);
      final parent = (await f.parentRow())!;
      final durable = (await f.append(
        NativeInputFixture.input.copyWith(createdAt: 0),
      ))!;
      expect(durable.createdAt, 1);
      expect(await f.parentRow(), parent);
    },
  );

  for (final value in [
    -1,
    1.5,
    'synthetic-not-a-clock',
    NativeInputFixture.maxTime + 1,
    NativeInputFixture.maxTime,
  ]) {
    test(
      'malformed/overflow selected ordering $value refuses before MAX/encryption',
      () async {
        await f.db.customStatement(
          'UPDATE support_messages SET created_at = ? WHERE id = ?',
          [value, NativeInputFixture.oldId],
        );
        final before = await f.snapshot();
        f.observe();
        expect(await f.append(), isNull);
        expect(f.sql.writes, isEmpty);
        expect(f.primitive.encryptAads, isEmpty);
        if (value != NativeInputFixture.maxTime) {
          expect(
            f.sql.observations.any(
              (o) => o.statement.contains('MAX(created_at)'),
            ),
            isFalse,
          );
        }
        expect(await f.snapshot(), before);
      },
    );
  }

  test(
    'safe timestamp maximum is inclusive, next allocation refuses without clamp',
    () async {
      final m = NativeInputFixture.input.copyWith(
        createdAt: NativeInputFixture.maxTime - 1,
      );
      final accepted = (await f.append(m))!;
      expect(accepted.createdAt, NativeInputFixture.maxTime);
      final before = await f.snapshot();
      expect(await f.append(m.copyWith(id: 'synthetic-next')), isNull);
      expect(await f.snapshot(), before);
    },
  );

  for (final column in ['created_at', 'updated_at']) {
    for (final value in [
      -1,
      1.5,
      'synthetic-not-a-clock',
      NativeInputFixture.maxTime + 1,
    ]) {
      test(
        'invalid parent $column=$value refuses without recreation',
        () async {
          await f.db.customStatement(
            'UPDATE support_sessions SET $column = ? WHERE id = ?',
            [value, NativeInputFixture.sessionId],
          );
          final before = await f.snapshot();
          expect(await f.append(), isNull);
          expect(await f.snapshot(), before);
        },
      );
    }
  }

  for (final mode in ['missing', 'locked', 'lost-key', 'vault-fault']) {
    test(
      '$mode parent refuses user custody and preserves raw rows/vault',
      () async {
        if (mode == 'missing') {
          await f.repo.deleteSession(NativeInputFixture.sessionId);
        }
        if (mode == 'locked') {
          await (f.db.update(
            f.db.supportSessions,
          )..where((t) => t.id.equals(NativeInputFixture.sessionId))).write(
            const SupportSessionsCompanion(
              titleCiphertext: Value('SYNTHETIC_CORRUPT'),
            ),
          );
        }
        if (mode == 'lost-key') f.storage.values.clear();
        if (mode == 'vault-fault') {
          f.storage.readError = StateError('synthetic vault fault');
        }
        final before = await f.snapshot();
        f.observe();
        if (mode == 'missing') {
          expect(await f.append(), isNull);
        } else {
          await expectLater(f.append(), throwsA(isA<SupportCipherException>()));
        }
        expect(f.storage.operations.where((op) => op != 'read'), isEmpty);
        expect(await f.snapshot(), before);
      },
    );
  }

  // Every actual SELECT/encrypt/map/SQL/vault await in the append path. A pause
  // retains the SQL-owning Future; current loss stops the NEXT SQL, then rolls
  // back provisional work. This does not race/timeout a transaction callback.
  final checkpoints = <(String, int)>[
    ('invalid_parent', 1),
    ('parent-read', 1),
    ('title-decrypt', 1),
    ('AS present', 1),
    ('invalid_order', 1),
    ('MAX(created_at)', 1),
    ('body-encrypt', 1),
    ('parent-read', 2),
    ('AS present', 2),
    ('invalid_order', 2),
    ('MAX(created_at)', 2),
    ('message-insert', 1),
    ('message-read', 1),
    ('body-decrypt', 1),
    ('message-read', 2),
    ('parent-read', 3),
    ('invalid_order', 3),
    ('MAX(created_at)', 3),
    ('parent-update', 1),
    ('invalid_order', 4),
    ('MAX(created_at)', 4),
    ('parent-read', 4),
    ('message-read', 3),
    ('vault-read', 1),
    ('vault-read', 2),
    ('vault-read', 3),
  ];
  for (final (phase, ordinal) in checkpoints) {
    test(
      'owner loss at $phase #$ordinal rolls back and starts no later SQL',
      () async {
        final before = await f.snapshot();
        final entered = Completer<void>(), release = Completer<void>();
        var seen = 0;
        Future<void> checkpoint(String actual) async {
          if (actual != phase || ++seen != ordinal) return;
          entered.complete();
          await release.future;
        }

        _hooks(f, checkpoint);
        f.observe();
        final future = f.append();
        await entered.future;
        final reads = f.sql.observations.length, writes = f.sql.writes.length;
        f.current = false;
        release.complete();
        expect(await future, isNull);
        expect(f.sql.observations, hasLength(reads));
        expect(f.sql.writes, hasLength(writes));
        f.clearHooks();
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final phase in [
    'body-encrypt',
    'body-decrypt',
    'message-insert',
    'parent-update',
    'parent-read',
    'message-read',
    'invalid_order',
    'MAX(created_at)',
  ]) {
    test('$phase fault preserves every ciphertext/metadata byte', () async {
      final before = await f.snapshot();
      _hooks(f, (actual) async {
        if (actual == phase) throw StateError('synthetic boundary failure');
      });
      await expectLater(
        f.append(),
        throwsA(anyOf(isA<StateError>(), isA<SupportCipherException>())),
      );
      f.clearHooks();
      expect(await f.snapshot(), before);
    });
  }

  for (final mutation in [
    'collision',
    'delete-parent',
    'parent-metadata',
    'later-order',
  ]) {
    test(
      'reentrant $mutation during encryption cannot commit/recreate old state',
      () async {
        final before = await f.snapshot();
        f.primitive.afterEncrypt = (_) async {
          f.primitive.afterEncrypt = null;
          switch (mutation) {
            case 'collision':
              await f.db
                  .into(f.db.supportMessages)
                  .insert(
                    SupportMessagesCompanion.insert(
                      id: NativeInputFixture.input.id,
                      sessionId: NativeInputFixture.foreignId,
                      role: 'user',
                      bodyCiphertext: 'SYNTHETIC_COLLISION',
                    ),
                  );
            case 'delete-parent':
              await f.repo.deleteSession(NativeInputFixture.sessionId);
            case 'parent-metadata':
              await (f.db.update(
                f.db.supportSessions,
              )..where((t) => t.id.equals(NativeInputFixture.sessionId))).write(
                const SupportSessionsCompanion(
                  mode: Value('synthetic-new-mode'),
                ),
              );
            case 'later-order':
              await f.db.customStatement(
                'UPDATE support_messages SET created_at = 999 WHERE id = ?',
                [NativeInputFixture.oldId],
              );
          }
        };
        expect(await f.append(), isNull);
        f.clearHooks();
        // Reentrant injected changes share this transaction and roll back too;
        // independent already-durable delete/collision cases are tested above.
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final phase in ['provisional-insert', 'mapping']) {
    test(
      'replacement during $phase cannot forge exact durable accepted result',
      () async {
        final before = await f.snapshot();
        Future<void> replace() =>
            (f.db.update(
              f.db.supportMessages,
            )..where((t) => t.id.equals(NativeInputFixture.input.id))).write(
              const SupportMessagesCompanion(
                runId: Value('synthetic-replacement-run'),
              ),
            );
        if (phase == 'provisional-insert') {
          f.sql.afterWrite = (_) async {
            f.sql.afterWrite = null;
            await replace();
          };
        } else {
          f.primitive.beforeDecrypt = (aad) async {
            if (!aad.contains('|${NativeInputFixture.input.id}|')) return;
            f.primitive.beforeDecrypt = null;
            await replace();
          };
        }
        expect(await f.append(), isNull);
        f.clearHooks();
        expect(await f.snapshot(), before);
      },
    );
  }

  test(
    'queued stale native owner refuses before its first source SQL',
    () async {
      final entered = Completer<void>(), release = Completer<void>();
      f.primitive.afterEncrypt = (_) async {
        f.primitive.afterEncrypt = null;
        entered.complete();
        await release.future;
      };
      f.observe();
      final first = f.append();
      await entered.future;
      var queuedCurrent = true;
      final queued = f.repo.appendCurrentUser(
        message: NativeInputFixture.input.copyWith(id: 'synthetic-queued-user'),
        isCurrent: () => queuedCurrent,
      );
      queuedCurrent = false;
      release.complete();
      expect(await first, isNotNull);
      expect(await queued, isNull);
      expect(
        f.sql.observations.any((o) => o.args.contains('synthetic-queued-user')),
        isFalse,
      );
      expect(f.sql.writes, hasLength(2));
      expect(await f.row('synthetic-queued-user'), isNull);
    },
  );

  test(
    'malformed foreign-session clock is not loaded or used for ordering',
    () async {
      await f.db.customStatement(
        'UPDATE support_messages SET created_at = ? WHERE session_id = ?',
        ['SYNTHETIC_FOREIGN_MALFORMED_CLOCK', NativeInputFixture.foreignId],
      );
      f.observe();
      expect((await f.append())!.createdAt, 11);
      expect(
        f.sql.observations.any(
          (o) =>
              o.rows.toString().contains('SYNTHETIC_FOREIGN_MALFORMED_CLOCK'),
        ),
        isFalse,
      );
    },
  );

  test(
    'provisional corrupted body refuses locked mapped acceptance and rolls back',
    () async {
      final before = await f.snapshot();
      f.sql.afterWrite = (_) async {
        f.sql.afterWrite = null;
        await (f.db.update(
          f.db.supportMessages,
        )..where((t) => t.id.equals(NativeInputFixture.input.id))).write(
          const SupportMessagesCompanion(
            bodyCiphertext: Value('SYNTHETIC_CORRUPT_MAPPING'),
          ),
        );
      };
      await expectLater(f.append(), throwsA(isA<SupportCipherException>()));
      f.clearHooks();
      expect(await f.snapshot(), before);
    },
  );

  test(
    'interleaved later ordering after provisional parent update refuses',
    () async {
      final before = await f.snapshot();
      f.sql.afterWrite = (sql) async {
        if (!sql.contains('support_sessions')) return;
        f.sql.afterWrite = null;
        await f.db.customStatement(
          'UPDATE support_messages SET created_at = 999 WHERE id = ?',
          [NativeInputFixture.oldId],
        );
      };
      expect(await f.append(), isNull);
      f.clearHooks();
      expect(await f.snapshot(), before);
    },
  );

  test(
    'legacy append remains upsert with caller timestamp/status/cards defaults',
    () async {
      final first = await f.repo.appendMessage(
        NativeInputFixture.input.copyWith(
          createdAt: 4,
          cardsJson: '[]',
          clearRunId: true,
        ),
      );
      expect(first.createdAt, 4);
      expect(first.runId, isNull);
      expect(first.status, 'complete');
      final replaced = await f.repo.appendMessage(
        first.copyWith(body: 'SYNTHETIC_LEGACY_REPLACE', createdAt: 2),
      );
      expect(replaced.createdAt, 2);
      expect(replaced.body, 'SYNTHETIC_LEGACY_REPLACE');
      expect(await f.repo.getMessageById(first.id), replaced);
      expect((await f.parentRow())!.updatedAt, 7);
    },
  );
}

void _hooks(NativeInputFixture f, Future<void> Function(String) checkpoint) {
  f.sql.afterSelect = (sql, _) async {
    if (sql.contains('invalid_parent')) {
      await checkpoint('invalid_parent');
    } else if (sql.contains('support_sessions')) {
      await checkpoint('parent-read');
    } else if (sql.contains('AS present')) {
      await checkpoint('AS present');
    } else if (sql.contains('invalid_order')) {
      await checkpoint('invalid_order');
    } else if (sql.contains('MAX(created_at)')) {
      await checkpoint('MAX(created_at)');
    } else if (sql.contains('support_messages')) {
      await checkpoint('message-read');
    }
  };
  f.sql.afterWrite = (sql) => checkpoint(
    sql.contains('support_messages') ? 'message-insert' : 'parent-update',
  );
  f.primitive.afterEncrypt = (_) => checkpoint('body-encrypt');
  f.primitive.beforeDecrypt = (aad) => checkpoint(
    aad.endsWith('|title_ciphertext') ? 'title-decrypt' : 'body-decrypt',
  );
  f.storage.beforeRead = () => checkpoint('vault-read');
}
