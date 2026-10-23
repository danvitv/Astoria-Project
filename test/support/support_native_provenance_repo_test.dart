import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_native_provenance_validator.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';

import 'helpers/support_native_provenance_fixture.dart';
import 'helpers/support_text_context_fixture.dart';

void main() {
  final valid = SupportModelProvenanceCodec.encodeForEncryptedStorage(
    nativeRecipe(),
  );
  final unavailable = throwsA(
    isA<SupportTextContextException>().having(
      (e) => e.failure,
      'fixed failure',
      SupportTextContextFailure.unavailable,
    ),
  );

  isolatedProvenance(
    'real v1 exact observations, immutable body-only projection, ROOT and counters unchanged',
    () async {
      final f = NativeProvenanceFixture();
      try {
        await f.seed();
        final calls = <(String, SupportTextContextProvenance)>[];
        final reader = f.reader(
          validator: (session, item, current) {
            calls.add((session, item));
            return SupportModelNativeProvenanceValidator.validate(
              session,
              item,
              current,
            );
          },
        );
        final before = await f.source.snapshot();
        f.source.observe();
        final snapshot = await f.load(reader);
        expect(snapshot.messageIds, ['support-a', 'support-b']);
        expect(snapshot.messages.map((m) => m.role), ['user', 'assistant']);
        expect(
          snapshot.messages.first.text,
          '${SupportTextContextFixture.selected} ${SecretRedactor.removed}',
        );
        expect(snapshot.provenance.last.dedicatedFactsJson, valid);
        expect(snapshot.provenance.last.runId, 'synthetic-run');
        expect(() => snapshot.provenance.clear(), throwsUnsupportedError);
        expect(() => snapshot.messageIds.clear(), throwsUnsupportedError);
        expect(() => snapshot.messages.clear(), throwsUnsupportedError);
        expect(await reader.revalidate(snapshot), isTrue);
        expect(await f.reader().revalidate(snapshot), isFalse);
        expect(calls.length, 2);
        expect(identical(calls.first.$2, snapshot.provenance.last), isTrue);
        expect(
          calls.every(
            (c) =>
                c.$1 == SupportTextContextFixture.supportId &&
                c.$2.dedicatedFactsJson == valid,
          ),
          isTrue,
        );
        final projection = jsonEncode(f.source.spy.values);
        for (final canary in [
          SupportTextContextFixture.unselected,
          SupportTextContextFixture.card,
          SupportTextContextFixture.other,
          valid,
        ]) {
          expect(projection, isNot(contains(canary)));
          expect(
            snapshot.messages.map((m) => m.text).join(),
            isNot(contains(canary)),
          );
        }
        expect(
          f.source.primitive.decryptAads.every(
            (aad) =>
                aad.endsWith('|title_ciphertext') ||
                aad.endsWith('|body_ciphertext') ||
                aad.endsWith('|protected_facts_ciphertext'),
          ),
          isTrue,
        );
        expect(
          f.source.primitive.decryptAads.where(
            (aad) => aad.contains('support-unselected'),
          ),
          isEmpty,
        );
        expect(
          f.source.storage.operations.where((op) => op != 'read'),
          isEmpty,
        );
        expect(f.source.spy.writes, 0);
        f.source
            .stopObserving(); // ROOT's audited zero-row DELETE is intentional.
        var dispatched = 0;
        expect(await f.root(reader, snapshot, () => dispatched++), isTrue);
        expect(dispatched, 1);
        expect(
          calls.length,
          4,
        ); // Fresh ROOT read AND final retained observation.
        expect(identical(calls.last.$2, snapshot.provenance.last), isTrue);
        expect(await f.source.snapshot(), before);
      } finally {
        await f.close();
      }
    },
  );

  isolatedProvenance(
    'optional absence retains diagnostic equality and old nonmodel facts compatibility',
    () async {
      final f = NativeProvenanceFixture();
      try {
        await f.seed();
        final reader = f.reader(validator: null);
        await expectLater(f.load(reader), unavailable);
        const old =
            '{"version":1,"runId":"synthetic-run","sources":["synthetic-source"]}';
        await f.replaceFacts(old);
        final snapshot = await f.load(reader);
        expect(snapshot.provenance.last.dedicatedFactsJson, old);
        expect(await reader.revalidate(snapshot), isTrue);
        await expectLater(f.load(f.reader()), unavailable);
      } finally {
        await f.close();
      }
    },
  );

  isolatedProvenance(
    'private read/session association remains exact across concurrent targets and ROOT',
    () async {
      final f = NativeProvenanceFixture();
      try {
        await f.seed();
        const other = 'synthetic-other-support';
        await f.source.supportMessage(
          'other-derived',
          session: other,
          runId: 'other-run',
          time: 3,
        );
        final raw = nativeRecipeObject()
          ..['supportSessionId'] = other
          ..['replyMessageId'] = 'other-derived'
          ..['runId'] = 'other-run'
          ..['currentUserMessageId'] = 'support-other';
        await f.source.provenance(
          'other-derived',
          jsonEncode(raw),
          session: other,
          time: 3,
        );
        final targets = <(String, String)>[];
        final reader = f.reader(
          validator: (session, item, redactor) {
            targets.add((session, item.messageId));
            return SupportModelNativeProvenanceValidator.validate(
              session,
              item,
              redactor,
            );
          },
        );
        final snapshots = await Future.wait([
          f.load(reader),
          reader.loadSupport(sessionId: other, messageIds: ['other-derived']),
        ]);
        var dispatches = 0;
        expect(
          await reader.admitDispatch(
            snapshots: snapshots,
            isCurrent: () => true,
            checkReadOnly: (checkpoint) async {
              checkpoint();
              return true;
            },
            dispatch: () => dispatches++,
          ),
          isTrue,
        );
        expect(dispatches, 1);
        expect(targets.length, 6);
        expect(
          targets
              .where(
                (p) => p == (SupportTextContextFixture.supportId, 'support-b'),
              )
              .length,
          3,
        );
        expect(targets.where((p) => p == (other, 'other-derived')).length, 3);
      } finally {
        await f.close();
      }
    },
  );

  isolatedProvenance(
    'aggregate native facts budget precedes even accepting validator',
    () async {
      final f = NativeProvenanceFixture();
      try {
        final padded = '$valid${' ' * (40000 - valid.length)}';
        await f.seed(padded);
        await (f.source.db.update(f.source.db.supportMessages)
              ..where((t) => t.id.equals('support-a')))
            .write(const SupportMessagesCompanion(runId: Value('other-run')));
        await f.source.provenance('support-a', padded, time: 2);
        var calls = 0;
        await expectLater(
          f.load(
            f.reader(
              validator: (_, _, _) {
                calls++;
                return true;
              },
            ),
          ),
          throwsA(
            isA<SupportTextContextException>().having(
              (e) => e.failure,
              'aggregate limit',
              SupportTextContextFailure.limited,
            ),
          ),
        );
        expect(calls, 0);
      } finally {
        await f.close();
      }
    },
  );

  isolatedProvenance(
    'secret native run and closed policy cannot be bypassed by callback',
    () async {
      final f = NativeProvenanceFixture();
      try {
        await f.seed();
        var calls = 0;
        final reader = f.reader(
          validator: (_, _, _) {
            calls++;
            return true;
          },
        );
        await (f.source.db.update(
          f.source.db.supportMessages,
        )..where((t) => t.id.equals('support-b'))).write(
          const SupportMessagesCompanion(
            runId: Value(SupportTextContextFixture.secret),
          ),
        );
        await expectLater(f.load(reader), unavailable);
        expect(calls, 0);
        f.source.redactor = SecretRedactor(
          knownSecrets: List.filled(257, 'canary'),
        );
        await expectLater(
          f.load(reader),
          throwsA(isA<SupportTextContextException>()),
        );
        expect(calls, 0);
      } finally {
        await f.close();
      }
    },
  );

  for (final (label, facts) in <(String, String)>[
    ('malformed', '{'),
    ('duplicate', valid.replaceFirst('"version":1', '"version":1,"version":1')),
    (
      'escaped duplicate',
      valid.replaceFirst('"version":1', r'"version":1,"\u0076ersion":1'),
    ),
    (
      'unknown',
      valid.replaceFirst('"version":1', '"version":1,"extra":"private"'),
    ),
    ('version', valid.replaceFirst('"version":1', '"version":2')),
    (
      'owner',
      valid.replaceFirst(SupportTextContextFixture.supportId, 'wrong-owner'),
    ),
    ('reply', valid.replaceFirst('support-b', 'wrong-reply')),
    ('run', valid.replaceFirst('synthetic-run', 'wrong-run')),
    (
      'known ID',
      valid.replaceFirst('game-a', SupportTextContextFixture.secret),
    ),
    (
      'encoded ID',
      valid.replaceFirst(
        'game-a',
        base64Encode(utf8.encode(SupportTextContextFixture.secret)),
      ),
    ),
    (
      'URL ID',
      valid.replaceFirst('game-a', 'https://fixture.invalid/x?token=canary'),
    ),
  ]) {
    isolatedProvenance('real encrypted $label facts refused', () async {
      final f = NativeProvenanceFixture();
      try {
        await f.seed(facts);
        await expectLater(f.load(f.reader()), unavailable);
      } finally {
        await f.close();
      }
    });
  }

  for (final reason in [
    'corrupt',
    'row',
    'session',
    'field',
    'start',
    'end',
    'active',
    'time',
    'missing-run',
  ]) {
    isolatedProvenance(
      'native $reason guard precedes even an accepting callback',
      () async {
        final f = NativeProvenanceFixture();
        try {
          await f.seed();
          final db = f.source.db;
          final query = db.update(db.supportContextBlocks)
            ..where((t) => t.id.equals('support.reply_provenance:support-b'));
          switch (reason) {
            case 'corrupt':
              await query.write(
                const SupportContextBlocksCompanion(
                  protectedFactsCiphertext: Value('corrupt'),
                ),
              );
            case 'row':
              await f.replaceFacts(
                valid,
                row: 'support.reply_provenance:other',
              );
            case 'session':
              await f.replaceFacts(valid, session: 'other');
            case 'field':
              await f.replaceFacts(valid, field: 'summary_ciphertext');
            case 'start':
              await query.write(
                const SupportContextBlocksCompanion(
                  startMessageId: Value('other'),
                ),
              );
            case 'end':
              await query.write(
                const SupportContextBlocksCompanion(
                  endMessageId: Value('other'),
                ),
              );
            case 'active':
              await query.write(
                const SupportContextBlocksCompanion(isActive: Value(true)),
              );
            case 'time':
              await query.write(
                const SupportContextBlocksCompanion(createdAt: Value(9)),
              );
            case 'missing-run':
              await (db.update(db.supportMessages)
                    ..where((t) => t.id.equals('support-b')))
                  .write(const SupportMessagesCompanion(runId: Value(null)));
          }
          var calls = 0;
          await expectLater(
            f.load(
              f.reader(
                validator: (_, _, _) {
                  calls++;
                  return true;
                },
              ),
            ),
            unavailable,
          );
          expect(calls, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final facts in ['', 'x' * 65537]) {
    isolatedProvenance(
      'native empty/aggregate facts limit cannot be bypassed ${facts.length}',
      () async {
        final f = NativeProvenanceFixture();
        try {
          await f.seed(facts);
          var calls = 0;
          await expectLater(
            f.load(
              f.reader(
                validator: (_, _, _) {
                  calls++;
                  return true;
                },
              ),
            ),
            throwsA(
              isA<SupportTextContextException>().having(
                (e) => e.failure,
                'limit',
                SupportTextContextFailure.limited,
              ),
            ),
          );
          expect(calls, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final stage in ['initial', 'revalidate', 'root-fresh', 'root-final']) {
    for (final throws in [false, true]) {
      isolatedProvenance(
        'validator false/throw failclosed at $stage throw=$throws',
        () async {
          final f = NativeProvenanceFixture();
          final error = _Unprintable();
          try {
            await f.seed();
            var calls = 0;
            final failAt = switch (stage) {
              'initial' => 1,
              'root-final' => 3,
              _ => 2,
            };
            final reader = f.reader(
              validator: (_, _, _) {
                if (++calls == failAt) {
                  if (throws) throw error;
                  return false;
                }
                return true;
              },
            );
            if (stage == 'initial') {
              await expectLater(f.load(reader), unavailable);
            } else {
              final snapshot = await f.load(reader);
              if (stage == 'revalidate') {
                expect(await reader.revalidate(snapshot), isFalse);
                expect(await reader.revalidate(snapshot), isFalse);
                expect(calls, 2);
              } else {
                var dispatches = 0;
                expect(
                  await f.root(reader, snapshot, () => dispatches++),
                  isFalse,
                );
                expect(dispatches, 0);
              }
            }
            expect(error.stringified, isFalse);
          } finally {
            await f.close();
          }
        },
      );
    }
  }

  for (final stage in ['decrypt', 'revalidate', 'root']) {
    isolatedProvenance(
      'CURRENT policy rejects newly known variable ID at $stage',
      () async {
        final f = NativeProvenanceFixture();
        final entered = Completer<void>(), release = Completer<void>();
        try {
          await f.seed();
          final reader = f.reader();
          void rotate() => f.source.redactor = SecretRedactor(
            knownSecrets: [SupportTextContextFixture.secret, 'game-a'],
          );
          if (stage == 'decrypt') {
            f.source.primitive.beforeDecrypt = (aad) async {
              if (aad.endsWith('|protected_facts_ciphertext')) {
                entered.complete();
                await release.future;
              }
            };
            final load = f.load(reader);
            // Register error handling before releasing the controlled await.
            final assertion = expectLater(load, unavailable);
            await entered.future;
            rotate();
            release.complete();
            await assertion;
          } else {
            final snapshot = await f.load(reader);
            if (stage == 'revalidate') {
              rotate();
              expect(await reader.revalidate(snapshot), isFalse);
              f.source.redactor = SecretRedactor();
              expect(await reader.revalidate(snapshot), isFalse);
            } else {
              var dispatches = 0;
              expect(
                await f.root(
                  reader,
                  snapshot,
                  () => dispatches++,
                  check: (checkpoint) async {
                    rotate();
                    checkpoint();
                    return true;
                  },
                ),
                isFalse,
              );
              expect(dispatches, 0);
            }
          }
        } finally {
          if (!release.isCompleted) release.complete();
          f.source.primitive.beforeDecrypt = null;
          await f.close();
        }
      },
    );
  }

  isolatedProvenance(
    'ROOT final provenance check uses newest policy, not fresh-read cached approval',
    () async {
      final f = NativeProvenanceFixture();
      try {
        await f.seed();
        var supplierCalls = 0;
        final reader = SupportTextContextRepo(
          db: f.source.db,
          cipher: f.source.cipher,
          currentRedactor: () {
            // Initial selection/sanitize/provenance: 1..3. ROOT fresh read
            // sanitize/provenance: 4..5. Final retained sanitize/provenance: 6..7.
            // Registration is observable only on the FINAL provenance supplier.
            return ++supplierCalls < 7
                ? f.source.redactor
                : SecretRedactor(
                    knownSecrets: [SupportTextContextFixture.secret, 'game-a'],
                  );
          },
          admissionContract: SupportTextAdmissionContract
              .auditedRootSingleConnectionNoBusyHandler,
          nativeProvenanceValidator:
              SupportModelNativeProvenanceValidator.validate,
        );
        final snapshot = await f.load(reader);
        var dispatches = 0;
        expect(await f.root(reader, snapshot, () => dispatches++), isFalse);
        expect(supplierCalls, 7);
        expect(dispatches, 0);
      } finally {
        await f.close();
      }
    },
  );

  for (final change in [
    'facts',
    'facts-restore',
    'delete-recreate',
    'body',
    'unrelated',
  ]) {
    isolatedProvenance(
      'accepting callback cannot rebase unchanged native custody after $change',
      () async {
        final f = NativeProvenanceFixture();
        try {
          await f.seed();
          var calls = 0;
          final reader = f.reader(
            validator: (_, _, _) {
              calls++;
              return true;
            },
          );
          final snapshot = await f.load(reader);
          final db = f.source.db;
          if (change == 'delete-recreate') {
            final row =
                await (db.select(db.supportContextBlocks)..where(
                      (t) => t.id.equals('support.reply_provenance:support-b'),
                    ))
                    .getSingle();
            await (db.delete(
              db.supportContextBlocks,
            )..where((t) => t.id.equals(row.id))).go();
            await db
                .into(db.supportContextBlocks)
                .insert(row.toCompanion(true));
          } else if (change == 'body') {
            final body = await f.source.encrypt(
              'Synthetic changed body',
              'support_messages',
              'support-b',
              SupportTextContextFixture.supportId,
              'body_ciphertext',
            );
            await (db.update(db.supportMessages)
                  ..where((t) => t.id.equals('support-b')))
                .write(SupportMessagesCompanion(bodyCiphertext: Value(body)));
          } else if (change == 'unrelated') {
            await (db.update(db.supportSessions)
                  ..where((t) => t.id.equals('synthetic-other-support')))
                .write(const SupportSessionsCompanion(updatedAt: Value(9)));
          } else {
            final row =
                await (db.select(db.supportContextBlocks)..where(
                      (t) => t.id.equals('support.reply_provenance:support-b'),
                    ))
                    .getSingle();
            await f.replaceFacts(valid.replaceFirst('game-a', 'game-changed'));
            if (change == 'facts-restore') {
              await (db.update(
                db.supportContextBlocks,
              )..where((t) => t.id.equals(row.id))).write(
                SupportContextBlocksCompanion(
                  protectedFactsCiphertext: Value(row.protectedFactsCiphertext),
                ),
              );
            }
          }
          expect(await reader.revalidate(snapshot), isFalse);
          expect(calls, 1);
          var dispatched = 0;
          expect(await f.root(reader, snapshot, () => dispatched++), isFalse);
          expect(dispatched, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  isolatedProvenance(
    'missing legacy facts remain unknown, not callback-approved lineage',
    () async {
      final f = NativeProvenanceFixture();
      try {
        await f.source.seed();
        var calls = 0;
        final reader = f.reader(
          validator: (_, _, _) {
            calls++;
            return true;
          },
        );
        final snapshot = await f.load(reader);
        expect(
          snapshot.provenance.every((p) => p.dedicatedFactsJson == null),
          isTrue,
        );
        expect(await reader.revalidate(snapshot), isTrue);
        expect(calls, 0);
      } finally {
        await f.close();
      }
    },
  );
}

final class _Unprintable {
  bool stringified = false;
  @override
  String toString() {
    stringified = true;
    throw StateError('Private synthetic cause');
  }
}
