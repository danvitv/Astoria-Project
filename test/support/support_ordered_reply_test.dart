import 'dart:async';

import 'package:drift/drift.dart' show Value, Variable;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import 'helpers/support_native_input_fixture.dart';

void main() {
  late NativeInputFixture f;
  late SupportMessage user;
  setUp(() async {
    f = NativeInputFixture();
    await f.seed();
    user = (await f.append())!;
  });
  tearDown(() => f.close());

  test(
    'reverse-sorting reply ID receives later durable time and same-time provenance',
    () async {
      final parent = await f.parentRow();
      final userRow = await f.row(user.id);
      final old = (await f.row(NativeInputFixture.oldId))!;
      f.observe();
      final reserved = (await f.reserve(user))!;
      expect(
        reserved.message,
        NativeInputFixture.reply.copyWith(createdAt: 12),
      );
      expect(reserved.provenance.createdAt, reserved.message.createdAt);
      expect(
        reserved.provenance.protectedFactsJson,
        NativeInputFixture.provenance,
      );
      expect(reserved.provenance.summary, '');
      expect(reserved.provenance.isActive, isFalse);
      expect(reserved.provenance.startMessageId, reserved.message.id);
      expect(reserved.provenance.endMessageId, reserved.message.id);
      expect(reserved.message.id.compareTo(user.id), lessThan(0));
      final observations = List.of(f.sql.observations);
      final decrypts = List.of(f.primitive.decryptAads);
      final allowed = {user.id, reserved.message.id};
      for (final read in observations.where(
        (o) => o.statement.contains('support_messages'),
      )) {
        if (read.statement.contains('MAX(created_at)') ||
            read.statement.contains('invalid_order') ||
            read.statement.contains('AS present')) {
          expect(read.statement, isNot(contains('body_ciphertext')));
          expect(read.statement, isNot(contains('cards_ciphertext')));
        } else {
          expect(read.args, isNotEmpty);
          expect(allowed.contains(read.args.first), isTrue);
          expect(read.rows.every((row) => allowed.contains(row['id'])), isTrue);
        }
        expect(read.rows.toString(), isNot(contains(old.bodyCiphertext)));
        expect(read.rows.toString(), isNot(contains(old.cardsCiphertext)));
      }
      expect(
        decrypts.any((aad) => aad.contains('|${NativeInputFixture.oldId}|')),
        isFalse,
      );
      expect(f.storage.operations.where((op) => op != 'read'), isEmpty);
      expect(f.sql.writes, hasLength(2));
      expect(
        await f.parentRow(),
        parent,
      ); // Existing S metadata contract retained.
      expect(await f.row(user.id), userRow);
      final ordered = await f.db
          .customSelect(
            'SELECT id, created_at FROM support_messages WHERE session_id = ? '
            'ORDER BY created_at ASC, id ASC',
            variables: [Variable<String>(NativeInputFixture.sessionId)],
          )
          .get();
      expect(ordered.map((r) => r.data['id']), [
        NativeInputFixture.oldId,
        user.id,
        reserved.message.id,
      ]);
      expect(
        await f.repo.getMessageById(reserved.message.id),
        reserved.message,
      );
      expect(
        await f.repo.getContextBlockById(reserved.provenance.id),
        reserved.provenance,
      );
    },
  );

  test(
    'interleaved legacy reply ignored parent time cannot break monotonic order',
    () async {
      final legacy = (await f.repo.reserveReply(
        message: NativeInputFixture.reply.copyWith(
          id: 'synthetic-legacy-reply',
          createdAt: 500,
        ),
        provenanceJson: NativeInputFixture.provenance,
        isCurrent: f.isCurrent,
      ))!;
      expect(legacy.message.createdAt, 500);
      expect((await f.parentRow())!.updatedAt, user.createdAt);
      f.repo = SupportRepo(f.db, f.cipher);
      final ordered = (await f.reserve(user))!;
      expect(ordered.message.createdAt, 501);
      final nextUser = (await f.append(
        NativeInputFixture.input.copyWith(
          id: 'a-new-user',
          runId: 'new-run',
          createdAt: 0,
        ),
      ))!;
      expect(nextUser.createdAt, 502);
      expect(user.createdAt, lessThan(ordered.message.createdAt));
    },
  );

  test('ordered reply is strictly above its own supplied floor', () async {
    final reserved = (await f.reserve(
      user,
      candidate: NativeInputFixture.reply.copyWith(createdAt: 100),
    ))!;
    expect(reserved.message.createdAt, 101);
    expect(reserved.provenance.createdAt, 101);
  });

  test(
    'concurrent unrelated user/reply allocation keeps both rows ordered',
    () async {
      SupportReplyReservation? reserved;
      SupportMessage? other;
      await Future.wait([
        f.reserve(user).then((value) {
          reserved = value;
        }),
        f
            .append(
              NativeInputFixture.input.copyWith(
                id: 'b-interleaved-user',
                runId: 'other-run',
                createdAt: 0,
              ),
            )
            .then((value) {
              other = value;
            }),
      ]);
      expect(reserved, isNotNull);
      expect(other, isNotNull);
      expect(reserved!.message.createdAt, greaterThan(user.createdAt));
      expect({reserved!.message.createdAt, other!.createdAt}, {12, 13});
      expect(
        await f.repo.getMessageById(reserved!.message.id),
        reserved!.message,
      );
      expect(await f.repo.getMessageById(other!.id), other);
    },
  );

  test(
    'duplicate/concurrent ordered reserve has one winner and no overwrite',
    () async {
      final results = await Future.wait([f.reserve(user), f.reserve(user)]);
      final winner = results.whereType<SupportReplyReservation>().single;
      final before = await f.snapshot();
      expect(await f.reserve(user), isNull);
      expect(await f.snapshot(), before);
      expect(await f.repo.getMessageById(winner.message.id), winner.message);
    },
  );

  for (final target in ['message', 'provenance']) {
    for (final session in [
      NativeInputFixture.sessionId,
      NativeInputFixture.foreignId,
    ]) {
      test(
        '$target collision in $session preserves all existing raw bytes',
        () async {
          if (target == 'message') {
            await f.repo.putMessage(
              NativeInputFixture.reply.copyWith(
                sessionId: session,
                body: 'SYNTHETIC_COLLISION_BODY',
              ),
            );
          } else {
            await f.repo.putContextBlock(
              SupportContextBlock(
                id: 'support.reply_provenance:${NativeInputFixture.reply.id}',
                sessionId: session,
                startMessageId: 'synthetic',
                endMessageId: 'synthetic',
                summary: 'SYNTHETIC_COLLISION_CONTEXT',
                createdAt: 2,
              ),
            );
          }
          final before = await f.snapshot();
          f.observe();
          expect(await f.reserve(user), isNull);
          if (target == 'message') {
            expect(
              f.sql.observations
                  .where(
                    (o) =>
                        o.statement.contains('support_messages') &&
                        o.statement.contains('body_ciphertext'),
                  )
                  .every((o) => o.args.first == user.id),
              isTrue,
            );
          }
          expect(f.sql.writes, isEmpty);
          expect(await f.snapshot(), before);
        },
      );
    }
  }

  test(
    'forged or stale originating identity/body/status/run never reserves',
    () async {
      final before = await f.snapshot();
      for (final candidate in [
        user.copyWith(id: 'unknown-user'),
        user.copyWith(id: NativeInputFixture.reply.id),
        user.copyWith(sessionId: NativeInputFixture.foreignId),
        user.copyWith(runId: 'wrong-run'),
        user.copyWith(clearRunId: true),
        user.copyWith(body: 'SYNTHETIC_CHANGED_BODY'),
        user.copyWith(status: 'pending'),
        user.copyWith(role: 'assistant'),
        user.copyWith(createdAt: user.createdAt + 1),
        user.copyWith(cardsJson: '[]'),
        user.copyWith(isLocked: true),
      ]) {
        expect(await f.reserve(candidate), isNull);
      }
      for (final candidate in [
        NativeInputFixture.reply.copyWith(id: user.id),
        NativeInputFixture.reply.copyWith(runId: 'wrong-run'),
        NativeInputFixture.reply.copyWith(id: 'x' * 129),
        NativeInputFixture.reply.copyWith(
          createdAt: NativeInputFixture.maxTime,
        ),
        NativeInputFixture.reply.copyWith(
          createdAt: NativeInputFixture.maxTime + 1,
        ),
      ]) {
        expect(await f.reserve(user, candidate: candidate), isNull);
      }
      expect(await f.snapshot(), before);
    },
  );

  for (final change in [
    'deleted',
    'moved',
    'run',
    'body',
    'status',
    'locked',
  ]) {
    test(
      'durable originating user $change refuses without recreating/old-body fallback',
      () async {
        switch (change) {
          case 'deleted':
            await f.repo.deleteMessage(user.id);
          case 'moved':
            await (f.db.update(
              f.db.supportMessages,
            )..where((t) => t.id.equals(user.id))).write(
              const SupportMessagesCompanion(
                sessionId: Value(NativeInputFixture.foreignId),
              ),
            );
          case 'run':
            await f.repo.putMessage(user.copyWith(runId: 'new-run'));
          case 'body':
            await f.repo.putMessage(
              user.copyWith(body: 'SYNTHETIC_CHANGED_INPUT'),
            );
          case 'status':
            await f.repo.updateMessageStatus(
              messageId: user.id,
              status: 'error',
            );
          case 'locked':
            await (f.db.update(
              f.db.supportMessages,
            )..where((t) => t.id.equals(user.id))).write(
              const SupportMessagesCompanion(
                bodyCiphertext: Value('SYNTHETIC_CORRUPT'),
              ),
            );
        }
        final before = await f.snapshot();
        f.observe();
        if (change == 'locked') {
          await expectLater(
            f.reserve(user),
            throwsA(isA<SupportCipherException>()),
          );
        } else {
          expect(await f.reserve(user), isNull);
        }
        if (['deleted', 'moved', 'run', 'status'].contains(change)) {
          expect(
            f.primitive.decryptAads.any((aad) => aad.contains('|${user.id}|')),
            isFalse,
          );
          expect(
            f.sql.observations.any(
              (o) => o.rows.any((row) => row['id'] == user.id),
            ),
            isFalse,
          );
        }
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final value in [
    -1,
    1.5,
    'synthetic-bad-order',
    NativeInputFixture.maxTime,
    NativeInputFixture.maxTime + 1,
  ]) {
    test(
      'ordered reservation rejects malformed/overflow metadata $value',
      () async {
        await f.db.customStatement(
          'UPDATE support_messages SET created_at = ? WHERE id = ?',
          [value, NativeInputFixture.oldId],
        );
        final before = await f.snapshot();
        expect(await f.reserve(user), isNull);
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final status in ['complete', 'stopped', 'error', 'limited']) {
    test(
      'ordered reservation reuses byte-preserving pending and once-only $status settlement',
      () async {
        final reservation = (await f.reserve(user))!;
        final raw = (await f.row(reservation.message.id))!;
        final parent = await f.parentRow();
        final provenance = await (f.db.select(
          f.db.supportContextBlocks,
        )..where((t) => t.id.equals(reservation.provenance.id))).getSingle();
        final pending = (await f.repo.settleReply(
          expected: reservation,
          status: 'pending',
          isCurrent: f.isCurrent,
        ))!;
        expect((await f.row(pending.id))!.bodyCiphertext, raw.bodyCiphertext);
        final expected = (message: pending, provenance: reservation.provenance);
        final durable = (await f.repo.settleReply(
          expected: expected,
          status: status,
          body: 'SYNTHETIC_TERMINAL_TEXT',
          isCurrent: f.isCurrent,
        ))!;
        expect(
          durable,
          pending.copyWith(status: status, body: 'SYNTHETIC_TERMINAL_TEXT'),
        );
        final written = (await f.row(durable.id))!;
        expect(
          written.copyWith(
            bodyCiphertext: raw.bodyCiphertext,
            status: raw.status,
          ),
          raw,
        );
        expect(
          await (f.db.select(
            f.db.supportContextBlocks,
          )..where((t) => t.id.equals(reservation.provenance.id))).getSingle(),
          provenance,
        );
        expect(await f.parentRow(), parent);
        final before = await f.snapshot();
        expect(
          await f.repo.settleReply(
            expected: expected,
            status: status,
            body: 'SYNTHETIC_SECOND_RESULT',
            isCurrent: f.isCurrent,
          ),
          isNull,
        );
        expect(await f.snapshot(), before);
      },
    );
  }

  final checkpoints = <(String, int)>[
    ('origin-read', 1),
    ('origin-decrypt', 1),
    ('origin-read', 2),
    ('origin-read', 3),
    ('invalid_order', 1),
    ('invalid_order', 2),
    ('invalid_order', 3),
    ('MAX(created_at)', 1),
    ('MAX(created_at)', 2),
    ('MAX(created_at)', 3),
    ('AS present', 1),
    ('AS present', 2),
    ('reply-encrypt', 1),
    ('summary-encrypt', 1),
    ('facts-encrypt', 1),
    ('reply-insert', 1),
    ('provenance-insert', 1),
    ('reply-decrypt', 1),
    ('summary-decrypt', 1),
    ('facts-decrypt', 1),
    ('parent-decrypt', 2),
  ];
  for (final (phase, ordinal) in checkpoints) {
    test(
      'ordered current loss at $phase #$ordinal rolls back both reservation rows',
      () async {
        final before = await f.snapshot();
        final entered = Completer<void>(), release = Completer<void>();
        var seen = 0;
        _hooks(f, user, (actual) async {
          if (actual != phase || ++seen != ordinal) return;
          entered.complete();
          await release.future;
        });
        f.observe();
        final future = f.reserve(user);
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
    'origin-decrypt',
    'reply-encrypt',
    'summary-encrypt',
    'facts-encrypt',
    'reply-insert',
    'provenance-insert',
    'reply-decrypt',
    'summary-decrypt',
    'facts-decrypt',
    'MAX(created_at)',
  ]) {
    test(
      'ordered $phase failure preserves originating user and every raw byte',
      () async {
        final before = await f.snapshot();
        _hooks(f, user, (actual) async {
          if (actual == phase) throw StateError('synthetic ordered failure');
        });
        await expectLater(
          f.reserve(user),
          throwsA(anyOf(isA<StateError>(), isA<SupportCipherException>())),
        );
        f.clearHooks();
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final change in ['origin-run', 'origin-delete', 'later-order']) {
    for (final phase in ['encrypt', 'provisional-insert', 'mapped-decrypt']) {
      test(
        '$change during ordered $phase cannot forge successful reservation',
        () async {
          final before = await f.snapshot();
          Future<void> mutate() async {
            switch (change) {
              case 'origin-run':
                await (f.db.update(
                  f.db.supportMessages,
                )..where((t) => t.id.equals(user.id))).write(
                  const SupportMessagesCompanion(
                    runId: Value('synthetic-new-run'),
                  ),
                );
              case 'origin-delete':
                await f.repo.deleteMessage(user.id);
              case 'later-order':
                await f.db.customStatement(
                  'UPDATE support_messages SET created_at = 999 WHERE id = ?',
                  [NativeInputFixture.oldId],
                );
            }
          }

          if (phase == 'encrypt') {
            f.primitive.afterEncrypt = (_) async {
              f.primitive.afterEncrypt = null;
              await mutate();
            };
          } else if (phase == 'provisional-insert') {
            f.sql.afterWrite = (_) async {
              f.sql.afterWrite = null;
              await mutate();
            };
          } else {
            f.primitive.beforeDecrypt = (aad) async {
              if (!aad.contains('|${NativeInputFixture.reply.id}|')) return;
              f.primitive.beforeDecrypt = null;
              await mutate();
            };
          }
          expect(await f.reserve(user), isNull);
          f.clearHooks();
          // Reentrant injections roll back in the same transaction. This isn't
          // evidence of physical external-writer/COMMIT-fault schedules.
          expect(await f.snapshot(), before);
        },
      );
    }
  }

  for (final target in ['origin', 'reply', 'provenance']) {
    test(
      '$target changed during final metadata await cannot forge durable reservation',
      () async {
        final before = await f.snapshot();
        var maxima = 0;
        f.sql.afterSelect = (sql, _) async {
          if (!sql.contains('MAX(created_at)') || ++maxima != 3) return;
          f.sql.afterSelect = null;
          if (target == 'provenance') {
            await (f.db.update(f.db.supportContextBlocks)..where(
                  (t) => t.id.equals(
                    'support.reply_provenance:${NativeInputFixture.reply.id}',
                  ),
                ))
                .write(
                  const SupportContextBlocksCompanion(isActive: Value(true)),
                );
          } else {
            await (f.db.update(f.db.supportMessages)..where(
                  (t) => t.id.equals(
                    target == 'origin' ? user.id : NativeInputFixture.reply.id,
                  ),
                ))
                .write(
                  const SupportMessagesCompanion(
                    runId: Value('synthetic-final-replacement'),
                  ),
                );
          }
        };
        expect(await f.reserve(user), isNull);
        f.clearHooks();
        expect(await f.snapshot(), before);
      },
    );
  }

  test(
    'later canceled preparation preserves successful exact durable user acceptance',
    () async {
      final before = await f.snapshot();
      f.observe();
      f.current = false;
      expect(await f.reserve(user), isNull);
      expect(f.sql.observations, isEmpty);
      expect(f.sql.writes, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(await f.snapshot(), before);
      expect(await f.repo.getMessageById(user.id), user);
    },
  );

  test(
    'ordered reply may allocate safe maximum but never overflow or tie',
    () async {
      final result = (await f.reserve(
        user,
        candidate: NativeInputFixture.reply.copyWith(
          createdAt: NativeInputFixture.maxTime - 1,
        ),
      ))!;
      expect(result.message.createdAt, NativeInputFixture.maxTime);
      expect(result.provenance.createdAt, NativeInputFixture.maxTime);
      final before = await f.snapshot();
      expect(
        await f.reserve(
          user,
          candidate: NativeInputFixture.reply.copyWith(
            id: 'synthetic-overflow-reply',
          ),
        ),
        isNull,
      );
      expect(
        await f.append(
          NativeInputFixture.input.copyWith(id: 'synthetic-overflow-user'),
        ),
        isNull,
      );
      expect(await f.snapshot(), before);
    },
  );

  test(
    'legacy reserve retains exact caller time and default contracts even below history',
    () async {
      final parent = await f.parentRow();
      final legacy = (await f.repo.reserveReply(
        message: NativeInputFixture.reply,
        provenanceJson: NativeInputFixture.provenance,
        isCurrent: f.isCurrent,
      ))!;
      expect(legacy.message, NativeInputFixture.reply);
      expect(legacy.provenance.createdAt, 0);
      expect(await f.parentRow(), parent);
      final stopped = await f.repo.settleReply(
        expected: legacy,
        status: 'stopped',
        isCurrent: f.isCurrent,
      );
      expect(stopped, NativeInputFixture.reply.copyWith(status: 'stopped'));
      final wideLegacy = NativeInputFixture.reply.copyWith(
        id: 'x' * 129,
        createdAt: NativeInputFixture.maxTime + 1,
      );
      expect(
        (await f.repo.reserveReply(
          message: wideLegacy,
          provenanceJson: NativeInputFixture.provenance,
          isCurrent: f.isCurrent,
        ))!.message,
        wideLegacy,
      );
    },
  );
}

void _hooks(
  NativeInputFixture f,
  SupportMessage user,
  Future<void> Function(String) checkpoint,
) {
  f.sql.afterSelect = (sql, args) async {
    if (sql.contains('invalid_order')) {
      await checkpoint('invalid_order');
    } else if (sql.contains('MAX(created_at)')) {
      await checkpoint('MAX(created_at)');
    } else if (sql.contains('AS present')) {
      await checkpoint('AS present');
    } else if (sql.contains('support_messages') && args.contains(user.id)) {
      await checkpoint('origin-read');
    }
  };
  f.sql.afterWrite = (sql) => checkpoint(
    sql.contains('support_messages') ? 'reply-insert' : 'provenance-insert',
  );
  String label(String aad, String operation) {
    if (aad.endsWith('|title_ciphertext')) return 'parent-$operation';
    if (aad.endsWith('|summary_ciphertext')) return 'summary-$operation';
    if (aad.endsWith('|protected_facts_ciphertext')) return 'facts-$operation';
    return '${aad.contains('|${user.id}|') ? 'origin' : 'reply'}-$operation';
  }

  f.primitive.afterEncrypt = (aad) => checkpoint(label(aad, 'encrypt'));
  f.primitive.beforeDecrypt = (aad) => checkpoint(label(aad, 'decrypt'));
}
