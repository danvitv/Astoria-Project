import 'dart:async';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';

import 'helpers/support_guarded_reply_fixture.dart';

void main() {
  late GuardedReplyFixture f;
  setUp(() async {
    f = GuardedReplyFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  test(
    'reserve commits empty preparing reply and inactive AEAD provenance together',
    () async {
      final reserved = (await f.reserve())!;
      expect(reserved.message, GuardedReplyFixture.message);
      expect(
        reserved.provenance.protectedFactsJson,
        GuardedReplyFixture.provenanceJson,
      );
      expect(reserved.provenance.isActive, isFalse);
      expect(reserved.provenance.startMessageId, reserved.message.id);
      expect(reserved.provenance.endMessageId, reserved.message.id);
      final raw = (await f.provenanceRow())!;
      expect(
        raw.protectedFactsCiphertext,
        isNot(contains('SYNTHETIC_PROVENANCE_CANARY')),
      );
      expect(
        await f.repo.getMessageById(reserved.message.id),
        reserved.message,
      );
      expect(
        await f.repo.getContextBlockById(reserved.provenance.id),
        reserved.provenance,
      );
      expect(
        await f.repo.getContextBlocksForSession(
          reserved.message.sessionId,
          activeOnly: true,
        ),
        hasLength(1),
      );
    },
  );

  test(
    'duplicate/concurrent reserve and same ID in another session never overwrite',
    () async {
      final first = (await f.reserve())!;
      final before = await f.rows();
      expect(await f.reserve(), isNull);
      expect(
        await f.reserve(
          candidate: first.message.copyWith(
            sessionId: 'synthetic-other-session',
          ),
        ),
        isNull,
      );
      expect(await f.rows(), before);
    },
  );

  test('simultaneous reserve has exactly one committed winner', () async {
    final results = await Future.wait([f.reserve(), f.reserve()]);
    expect(results.whereType<SupportReplyReservation>(), hasLength(1));
    expect(await f.replyRow(), isNotNull);
    expect(await f.provenanceRow(), isNotNull);
  });

  for (final session in [
    GuardedReplyFixture.message.sessionId,
    'synthetic-other-session',
  ]) {
    test(
      'dedicated context collision in $session preserves all old bytes',
      () async {
        await f.repo.putContextBlock(
          SupportContextBlock(
            id: GuardedReplyFixture.contextId,
            sessionId: session,
            startMessageId: 'synthetic-other-message',
            endMessageId: 'synthetic-other-message',
            summary: 'SYNTHETIC_COLLISION_CANARY',
            createdAt: 3,
          ),
        );
        final before = await f.rows();
        expect(await f.reserve(), isNull);
        expect(await f.replyRow(), isNull);
        expect(await f.rows(), before);
      },
    );
  }

  test(
    'invalid reserve candidates and oversize provenance refuse before writes',
    () async {
      final m = GuardedReplyFixture.message;
      final before = await f.rows();
      for (final candidate in [
        m.copyWith(role: 'user'),
        m.copyWith(clearRunId: true),
        m.copyWith(runId: ''),
        m.copyWith(runId: 'bad|run'),
        m.copyWith(id: ''),
        m.copyWith(id: '界' * 400),
        m.copyWith(status: 'complete'),
        m.copyWith(body: 'not empty'),
        m.copyWith(cardsJson: '[]'),
        m.copyWith(isLocked: true),
        m.copyWith(createdAt: -1),
      ]) {
        expect(await f.reserve(candidate: candidate), isNull);
      }
      expect(await f.reserve(provenance: ' '), isNull);
      expect(await f.reserve(provenance: 'x' * 65537), isNull);
      f.current = false;
      expect(await f.reserve(), isNull);
      expect(await f.rows(), before);
    },
  );

  test('missing parent is never implicitly created', () async {
    await f.repo.deleteSession(GuardedReplyFixture.message.sessionId);
    final before = await f.rows();
    expect(await f.reserve(), isNull);
    expect(await f.rows(), before);
  });

  for (final status in ['complete', 'stopped', 'error', 'limited']) {
    test(
      '$status settles exact pending row once, preserving immutable bytes',
      () async {
        final reserved = (await f.reserve())!;
        final oldRow = (await f.replyRow())!;
        final provenance = await f.provenanceRow();
        final pending = (await f.settle(
          reserved,
          status: 'pending',
          body: null,
        ))!;
        expect((await f.replyRow())!.bodyCiphertext, oldRow.bodyCiphertext);
        final expected = (message: pending, provenance: reserved.provenance);
        final durable = (await f.settle(expected, status: status))!;
        expect(
          durable,
          pending.copyWith(status: status, body: 'SYNTHETIC_REPLY_CANARY'),
        );
        expect(await f.provenanceRow(), provenance);
        expect(await f.repo.getMessageById(durable.id), durable);
        final after = await f.rows();
        expect(await f.settle(expected, status: status), isNull);
        expect(
          await f.settle((
            message: durable,
            provenance: reserved.provenance,
          ), status: status),
          isNull,
        );
        expect(await f.rows(), after);
      },
    );
  }

  test(
    'direct preparing terminal, status-only stop, and full 65536-char body are supported',
    () async {
      final r = (await f.reserve())!;
      final body = '界' * 65536;
      expect((await f.settle(r, status: 'limited', body: body))!.body, body);
      final second = (await f.reserve(
        candidate: GuardedReplyFixture.message.copyWith(
          id: 'synthetic-second-reply',
        ),
      ))!;
      final bytes = (await f.db.select(f.db.supportMessages).get())
          .firstWhere((row) => row.id == second.message.id)
          .bodyCiphertext;
      final stopped = (await f.settle(second, status: 'stopped', body: null))!;
      expect(stopped.body, '');
      expect(
        (await f.db.select(f.db.supportMessages).get())
            .firstWhere((row) => row.id == second.message.id)
            .bodyCiphertext,
        bytes,
      );
    },
  );

  test(
    'unknown status, stale expected run/status/body and forged immutable fields refuse',
    () async {
      final r = (await f.reserve())!;
      final before = await f.rows();
      for (final candidate in [
        r.message.copyWith(runId: 'new-run'),
        r.message.copyWith(status: 'pending'),
        r.message.copyWith(body: 'changed'),
        r.message.copyWith(id: 'unknown'),
        r.message.copyWith(sessionId: 'synthetic-other-session'),
        r.message.copyWith(role: 'user'),
        r.message.copyWith(createdAt: 999),
        r.message.copyWith(cardsJson: '[]'),
      ]) {
        expect(
          await f.settle((message: candidate, provenance: r.provenance)),
          isNull,
        );
      }
      expect(await f.settle(r, status: 'streaming'), isNull);
      expect(await f.settle(r, status: 'pending'), isNull);
      expect(await f.settle(r, body: 'x' * 65537), isNull);
      expect(
        await f.settle((
          message: r.message,
          provenance: r.provenance.copyWith(protectedFactsJson: '{}'),
        )),
        isNull,
      );
      expect(await f.rows(), before);
    },
  );

  for (final change in [
    'delete-reply',
    'delete-parent',
    'delete-provenance',
    'move',
    'new-run',
    'body',
    'provenance',
    'role',
    'time',
  ]) {
    test(
      'durable $change refuses stale settlement without recreation/overwrite',
      () async {
        final r = (await f.reserve())!;
        switch (change) {
          case 'delete-reply':
            await f.repo.deleteMessage(r.message.id);
          case 'delete-parent':
            await f.repo.deleteSession(r.message.sessionId);
          case 'delete-provenance':
            await (f.db.delete(
              f.db.supportContextBlocks,
            )..where((t) => t.id.equals(r.provenance.id))).go();
          case 'move':
            await (f.db.update(
              f.db.supportMessages,
            )..where((t) => t.id.equals(r.message.id))).write(
              const SupportMessagesCompanion(
                sessionId: Value('synthetic-other-session'),
              ),
            );
          case 'new-run':
            await f.repo.putMessage(
              r.message.copyWith(runId: 'synthetic-new-run'),
            );
          case 'body':
            await f.repo.putMessage(
              r.message.copyWith(body: 'synthetic-edited'),
            );
          case 'provenance':
            await f.repo.putContextBlock(
              r.provenance.copyWith(protectedFactsJson: '{}'),
            );
          case 'role':
            await f.repo.putMessage(r.message.copyWith(role: 'user'));
          case 'time':
            await f.repo.putMessage(r.message.copyWith(createdAt: 99));
        }
        final before = await f.rows();
        expect(await f.settle(r), isNull);
        expect(await f.rows(), before);
      },
    );
  }

  for (final target in ['parent', 'reply', 'provenance']) {
    test(
      'locked $target cannot become default-readable or be overwritten',
      () async {
        final r = (await f.reserve())!;
        if (target == 'parent') {
          await (f.db.update(
            f.db.supportSessions,
          )..where((t) => t.id.equals(r.message.sessionId))).write(
            const SupportSessionsCompanion(
              titleCiphertext: Value('synthetic-corrupt'),
            ),
          );
        } else if (target == 'reply') {
          await (f.db.update(
            f.db.supportMessages,
          )..where((t) => t.id.equals(r.message.id))).write(
            const SupportMessagesCompanion(
              bodyCiphertext: Value('synthetic-corrupt'),
            ),
          );
        } else {
          await (f.db.update(
            f.db.supportContextBlocks,
          )..where((t) => t.id.equals(r.provenance.id))).write(
            const SupportContextBlocksCompanion(
              protectedFactsCiphertext: Value('synthetic-corrupt'),
            ),
          );
        }
        final before = await f.rows();
        await expectLater(f.settle(r), throwsA(isA<SupportCipherException>()));
        if (target == 'parent') {
          await expectLater(
            f.reserve(
              candidate: r.message.copyWith(id: 'synthetic-another-reply'),
            ),
            throwsA(isA<SupportCipherException>()),
          );
        }
        expect(await f.rows(), before);
      },
    );
  }

  for (final phase in ['encrypt', 'sql', 'mapped-decrypt', 'read']) {
    for (final reserve in [true, false]) {
      test(
        '${reserve ? 'reserve' : 'settle'} owner lost during $phase rolls back',
        () async {
          final r = reserve ? null : (await f.reserve())!;
          final before = await f.rows();
          final entered = Completer<void>(), release = Completer<void>();
          var decrypts = 0;
          Future<void> pause() async {
            entered.complete();
            await release.future;
          }

          if (phase == 'encrypt') {
            f.primitive.afterEncrypt = (aad) async {
              f.primitive.afterEncrypt = null;
              await pause();
            };
          } else if (phase == 'sql') {
            f.sql.afterWrite = (sql) async {
              f.sql.afterWrite = null;
              await pause();
            };
          } else if (phase == 'read') {
            f.sql.afterSelect = (sql) async {
              f.sql.afterSelect = null;
              await pause();
            };
          } else {
            f.primitive.beforeDecrypt = (aad) async {
              if (!aad.contains('|support_messages|synthetic-reply|')) return;
              decrypts++;
              if (decrypts != (reserve ? 1 : 2)) return;
              f.primitive.beforeDecrypt = null;
              await pause();
            };
          }
          final future = reserve ? f.reserve() : f.settle(r!);
          await entered.future;
          f.current = false;
          release.complete();
          expect(await future, isNull);
          expect(await f.rows(), before);
        },
      );
    }
  }

  for (final phase in ['encrypt', 'sql', 'mapped-decrypt']) {
    for (final reserve in [true, false]) {
      test(
        '${reserve ? 'reserve' : 'settle'} $phase failure preserves every byte',
        () async {
          final r = reserve ? null : (await f.reserve())!;
          final before = await f.rows();
          if (phase == 'encrypt') {
            f.primitive.afterEncrypt = (_) async {
              throw StateError('synthetic cipher failure');
            };
          } else if (phase == 'sql') {
            f.sql.afterWrite = (_) async {
              throw StateError('synthetic storage failure');
            };
          } else {
            var decrypts = 0;
            f.primitive.beforeDecrypt = (aad) async {
              if (aad.contains('|support_messages|synthetic-reply|') &&
                  ++decrypts == (reserve ? 1 : 2)) {
                throw StateError('synthetic mapped decrypt failure');
              }
            };
          }
          await expectLater(
            reserve ? f.reserve() : f.settle(r!),
            throwsA(anyOf(isA<SupportCipherException>(), isA<StateError>())),
          );
          f.sql.afterWrite = null;
          expect(await f.rows(), before);
        },
      );
    }
  }

  test(
    'second provenance insert fault rolls back the first reply insert',
    () async {
      final before = await f.rows();
      f.sql.afterWrite = (sql) async {
        if (sql.contains('support_context_blocks')) {
          throw StateError('synthetic second insert failure');
        }
      };
      await expectLater(f.reserve(), throwsStateError);
      f.sql.afterWrite = null;
      expect(await f.rows(), before);
    },
  );

  test(
    'legacy default row or preparing row without provenance cannot settle',
    () async {
      final r = (await f.reserve())!;
      await f.repo.deleteMessage(r.message.id);
      await f.repo.putMessage(
        r.message.copyWith(status: 'complete', clearRunId: true),
      );
      var before = await f.rows();
      expect(await f.settle(r), isNull);
      expect(await f.rows(), before);
      await f.repo.putMessage(r.message);
      await (f.db.delete(
        f.db.supportContextBlocks,
      )..where((t) => t.id.equals(r.provenance.id))).go();
      before = await f.rows();
      expect(await f.settle(r), isNull);
      expect(await f.rows(), before);
    },
  );

  test(
    'two competing terminal settlements have exactly one durable winner',
    () async {
      final r = (await f.reserve())!;
      final results = await Future.wait([
        f.settle(r, status: 'stopped'),
        f.settle(r, status: 'complete'),
      ]);
      expect(results.whereType<SupportMessage>(), hasLength(1));
      expect(
        await f.repo.getMessageById(r.message.id),
        results.whereType<SupportMessage>().single,
      );
    },
  );

  test(
    'fake vault read failure never overwrites the readable durable row',
    () async {
      final r = (await f.reserve())!;
      final before = await f.rows();
      f.storage.readError = StateError('synthetic vault failure');
      await expectLater(f.settle(r), throwsA(isA<SupportCipherException>()));
      await expectLater(
        f.reserve(candidate: r.message.copyWith(id: 'synthetic-another-reply')),
        throwsA(isA<SupportCipherException>()),
      );
      expect(await f.rows(), before);
    },
  );

  for (final change in ['delete', 'new-run', 'move', 'provenance', 'parent']) {
    test(
      'target $change during encryption cannot be recreated or overwritten',
      () async {
        final r = (await f.reserve())!;
        final before = await f.rows();
        f.primitive.afterEncrypt = (_) async {
          f.primitive.afterEncrypt = null;
          switch (change) {
            case 'delete':
              await f.repo.deleteMessage(r.message.id);
            case 'new-run':
              await f.repo.putMessage(
                r.message.copyWith(runId: 'synthetic-new-run'),
              );
            case 'move':
              await (f.db.update(
                f.db.supportMessages,
              )..where((t) => t.id.equals(r.message.id))).write(
                const SupportMessagesCompanion(
                  sessionId: Value('synthetic-other-session'),
                ),
              );
            case 'provenance':
              await f.repo.putContextBlock(
                r.provenance.copyWith(protectedFactsJson: '{}'),
              );
            case 'parent':
              await f.repo.deleteSession(r.message.sessionId);
          }
        };
        expect(await f.settle(r), isNull);
        // Reentrant fixture mutation shares the repository transaction and is
        // rolled back too. Independent external deletes are covered above.
        expect(await f.rows(), before);
      },
    );
  }

  for (final phase in [
    'provenance-encrypt',
    'provenance-insert',
    'provenance-summary-read',
    'provenance-facts-read',
    'final-parent-read',
  ]) {
    test(
      'reserve owner loss during $phase leaves zero reservation rows',
      () async {
        final before = await f.rows();
        if (phase == 'provenance-encrypt') {
          f.primitive.afterEncrypt = (aad) async {
            if (aad.endsWith('|protected_facts_ciphertext')) f.current = false;
          };
        } else if (phase == 'provenance-insert') {
          f.sql.afterWrite = (sql) async {
            if (sql.contains('support_context_blocks')) f.current = false;
          };
        } else {
          var parentReads = 0;
          f.primitive.beforeDecrypt = (aad) async {
            if (phase == 'provenance-summary-read' &&
                aad.endsWith('|summary_ciphertext')) {
              f.current = false;
            }
            if (phase == 'provenance-facts-read' &&
                aad.endsWith('|protected_facts_ciphertext')) {
              f.current = false;
            }
            if (phase == 'final-parent-read' &&
                aad.endsWith('|title_ciphertext') &&
                ++parentReads == 2) {
              f.current = false;
            }
          };
        }
        expect(await f.reserve(), isNull);
        expect(await f.rows(), before);
      },
    );
  }

  for (final phase in ['provisional-sql', 'mapped-decrypt']) {
    test(
      'new run during $phase cannot forge successful mapped settlement',
      () async {
        final r = (await f.reserve())!;
        final before = await f.rows();
        Future<void> replace() =>
            (f.db.update(
              f.db.supportMessages,
            )..where((t) => t.id.equals(r.message.id))).write(
              const SupportMessagesCompanion(runId: Value('synthetic-new-run')),
            );
        if (phase == 'provisional-sql') {
          f.sql.afterWrite = (_) async {
            f.sql.afterWrite = null;
            await replace();
          };
        } else {
          var reads = 0;
          f.primitive.beforeDecrypt = (aad) async {
            if (!aad.contains('|support_messages|synthetic-reply|') ||
                ++reads != 2) {
              return;
            }
            f.primitive.beforeDecrypt = null;
            await replace();
          };
        }
        expect(await f.settle(r), isNull);
        expect(await f.rows(), before);
      },
    );
  }

  for (final field in [
    'body_ciphertext',
    'summary_ciphertext',
    'protected_facts_ciphertext',
  ]) {
    test(
      'settlement owner loss while reading $field refuses without writes',
      () async {
        final r = (await f.reserve())!;
        final before = await f.rows();
        f.primitive.beforeDecrypt = (aad) async {
          if (aad.endsWith('|$field')) f.current = false;
        };
        expect(await f.settle(r), isNull);
        expect(await f.rows(), before);
      },
    );
  }

  test(
    'original-session settlement owner survives UI ownership loss',
    () async {
      final r = (await f.reserve())!;
      var uiCurrent = true;
      var settlementCurrent = true;
      uiCurrent = false;
      expect(uiCurrent, isFalse);
      final result = await f.repo.settleReply(
        expected: r,
        status: 'stopped',
        body: 'SYNTHETIC_PARTIAL_CANARY',
        isCurrent: () => settlementCurrent,
      );
      expect(result!.sessionId, GuardedReplyFixture.message.sessionId);
      expect(result.body, 'SYNTHETIC_PARTIAL_CANARY');
      settlementCurrent = false;
      expect(
        await f.repo.settleReply(
          expected: r,
          status: 'complete',
          isCurrent: () => settlementCurrent,
        ),
        isNull,
      );
    },
  );
}
