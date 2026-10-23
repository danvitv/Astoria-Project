import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';

import 'helpers/support_text_context_fixture.dart';

void main() {
  late SupportTextContextFixture f;
  setUp(() async {
    f = SupportTextContextFixture();
    await f.seed();
  });
  tearDown(() => f.close());

  Future<SupportTextContextSnapshot> support([
    List<String> ids = const ['support-a', 'support-b'],
  ]) => f.repo.loadSupport(
    sessionId: SupportTextContextFixture.supportId,
    messageIds: ids,
  );
  Future<SupportTextContextSnapshot> roleplay([
    List<String> ids = const ['roleplay-a', 'roleplay-b'],
  ]) => f.repo.loadRoleplay(
    sessionId: SupportTextContextFixture.roleplayId,
    messageIds: ids,
  );

  Matcher failure([SupportTextContextFailure? reason]) => throwsA(
    isA<SupportTextContextException>().having(
      (e) => reason == null || e.failure == reason,
      'fixed reason',
      true,
    ),
  );

  for (final isSupport in [true, false]) {
    test(
      '${isSupport ? 'support' : 'roleplay'} exact text projection is immutable, read-only and sanitized',
      () async {
        final before = await f.snapshot();
        f.observe();
        final s = await (isSupport ? support() : roleplay());
        expect(s.messages.map((m) => m.text), [
          '${SupportTextContextFixture.selected} ${SecretRedactor.removed}',
          'Synthetic second',
        ]);
        expect(s.messages.map((m) => m.role), ['user', 'assistant']);
        expect(
          () => s.messages.add(
            const SupportTextContextMessage(role: 'user', text: 'forged'),
          ),
          throwsUnsupportedError,
        );
        expect(() => s.messageIds.clear(), throwsUnsupportedError);
        expect(() => s.provenance.clear(), throwsUnsupportedError);
        expect(await f.repo.revalidate(s), isTrue);
        expect(await f.newRepo().revalidate(s), isFalse);
        expect(s.toString(), 'SupportTextContextSnapshot');
        final dynamic opaque = s;
        expect(() => opaque.owner, throwsA(isA<NoSuchMethodError>()));
        expect(() => opaque.observation, throwsA(isA<NoSuchMethodError>()));
        expect(() => opaque.stamp, throwsA(isA<NoSuchMethodError>()));
        final native = jsonEncode(
          f.spy.values,
        ); // Synthetic SQL primitives only.
        for (final canary in [
          SupportTextContextFixture.unselected,
          SupportTextContextFixture.card,
          SupportTextContextFixture.reasoning,
          SupportTextContextFixture.attachment,
          SupportTextContextFixture.other,
        ]) {
          expect(native, isNot(contains(canary)));
          expect(s.messages.map((m) => m.text).join(), isNot(contains(canary)));
        }
        expect(f.spy.writes, 0);
        expect(f.storage.operations.where((op) => op != 'read'), isEmpty);
        if (isSupport) {
          expect(
            f.primitive.decryptAads.every(
              (aad) =>
                  aad.endsWith('|title_ciphertext') ||
                  aad.endsWith('|body_ciphertext'),
            ),
            isTrue,
          );
          expect(
            f.primitive.decryptAads.any(
              (aad) => aad.contains('support-unselected'),
            ),
            isFalse,
          );
          expect(
            s.provenance.every((p) => p.dedicatedFactsJson == null),
            isTrue,
          );
        } else {
          expect(f.primitive.decryptAads, isEmpty);
        }
        f.stopObserving();
        expect(await f.snapshot(), before);
      },
    );
  }

  test(
    'caller-made snapshot rejected without inspecting its getters',
    () async {
      f.observe();
      expect(await f.repo.revalidate(_ForgedSnapshot()), isFalse);
      expect(f.spy.values, isEmpty);
    },
  );

  for (final ids in <List<String>>[
    [],
    ['support-a', 'support-a'],
    ['support-b', 'support-a'],
    ['missing'],
    ['support-other'],
    List.generate(513, (i) => 'synthetic-$i'),
  ]) {
    test(
      'support refuses exact invalid/missing/foreign/order selection ${ids.length} ${ids.take(2).join(',')}',
      () async {
        await expectLater(support(ids), failure());
      },
    );
  }
  for (final ids in <List<String>>[
    [],
    ['roleplay-a', 'roleplay-a'],
    ['roleplay-b', 'roleplay-a'],
    ['missing'],
    List.generate(513, (i) => 'synthetic-$i'),
  ]) {
    test(
      'roleplay refuses exact invalid/missing/order selection ${ids.length} ${ids.take(2).join(',')}',
      () async {
        await expectLater(roleplay(ids), failure());
      },
    );
  }

  for (final status in [
    'preparing',
    'pending',
    'stopped',
    'error',
    'limited',
    'unknown',
  ]) {
    test(
      'support refuses noncomplete status $status without silent drop',
      () async {
        await (f.db.update(f.db.supportMessages)
              ..where((t) => t.id.equals('support-b')))
            .write(SupportMessagesCompanion(status: Value(status)));
        await expectLater(support(), failure());
      },
    );
  }
  for (final role in ['tool', '', 'unknown']) {
    test('support refuses unknown role $role', () async {
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('support-b')))
          .write(SupportMessagesCompanion(role: Value(role)));
      await expectLater(support(), failure());
    });
  }

  test('body-only decrypt enforces row/session/field AEAD binding', () async {
    final wrong = await f.encrypt(
      'Synthetic body',
      'support_messages',
      'support-b',
      'synthetic-other-support',
      'body_ciphertext',
    );
    await (f.db.update(f.db.supportMessages)
          ..where((t) => t.id.equals('support-b')))
        .write(SupportMessagesCompanion(bodyCiphertext: Value(wrong)));
    await expectLater(support(), failure());
  });

  for (final parent in [true, false]) {
    test(
      'corrupt ${parent ? 'parent' : 'body'} fails exact support read',
      () async {
        if (parent) {
          await (f.db.update(
                f.db.supportSessions,
              )..where((t) => t.id.equals(SupportTextContextFixture.supportId)))
              .write(
                const SupportSessionsCompanion(
                  titleCiphertext: Value('corrupt'),
                ),
              );
        } else {
          await (f.db.update(
            f.db.supportMessages,
          )..where((t) => t.id.equals('support-b'))).write(
            const SupportMessagesCompanion(bodyCiphertext: Value('corrupt')),
          );
        }
        await expectLater(support(), failure());
      },
    );
  }

  test(
    'locked vault fails without key seeding/write or source mutation',
    () async {
      final before = await f.snapshot();
      f.storage.values.clear();
      f.observe();
      await expectLater(support(), failure());
      expect(f.storage.operations.where((op) => op != 'read'), isEmpty);
      f.stopObserving();
      expect(await f.snapshot(), before);
    },
  );

  test(
    'unreadable cards are excluded, not decrypted by body-only loader',
    () async {
      await (f.db.update(
        f.db.supportMessages,
      )..where((t) => t.id.equals('support-a'))).write(
        const SupportMessagesCompanion(cardsCiphertext: Value('corrupt-card')),
      );
      expect((await support()).messages.length, 2);
    },
  );

  for (final mutation in <Map<String, Object?>>[
    {'isHidden': true},
    {'isError': true},
    {'isTyping': true},
    {'isEditing': true},
    {'isAllReasoning': true},
    {'isLocked': true},
    {'status': 'pending'},
    {'role': 'tool'},
    {'content': 1},
    {
      'content': {'private': SupportTextContextFixture.card},
    },
    {'swipeId': -1},
    {'agentSwipeId': '1'},
    {'timestamp': 'invalid'},
    {'isHidden': 'false'},
  ]) {
    test(
      'roleplay refuses malformed/ineligible selected body ${mutation.keys.first}',
      () async {
        await f.replaceRoleplay([
          SupportTextContextFixture.message('roleplay-a')..addAll(mutation),
        ]);
        await expectLater(roleplay(['roleplay-a']), failure());
      },
    );
  }

  test(
    'duplicate durable message IDs and duplicate relevant keys are refused',
    () async {
      await f.replaceRoleplay([
        SupportTextContextFixture.message('roleplay-a'),
        SupportTextContextFixture.message('roleplay-a'),
      ]);
      await expectLater(roleplay(['roleplay-a']), failure());
      await f.replaceRoleplayJson(
        '[{"id":"roleplay-a","role":"user","content":"Synthetic one","content":"Synthetic two"}]',
      );
      await expectLater(roleplay(['roleplay-a']), failure());
    },
  );

  for (final invalid in [
    'corrupt',
    '{}',
    '[null]',
    '[1]',
    '["not a message"]',
  ]) {
    test(
      'corrupt/nonarray/unknown roleplay source refused: $invalid',
      () async {
        await f.replaceRoleplayJson(invalid);
        await expectLater(roleplay(['roleplay-a']), failure());
      },
    );
  }

  test(
    'same IDs in a branch do not substitute selected source session',
    () async {
      final s = await f.repo.loadRoleplay(
        sessionId: 'synthetic-branch',
        messageIds: ['roleplay-a'],
      );
      expect(s.messages.single.text, SupportTextContextFixture.other);
      final original = await roleplay(['roleplay-a']);
      expect(
        original.messages.single.text,
        contains(SupportTextContextFixture.selected),
      );
    },
  );

  test(
    'roleplay source byte cap precedes json_each; count and aggregate body caps refuse',
    () async {
      await f.replaceRoleplayJson(' ' * (2 * 1024 * 1024 + 1));
      await expectLater(
        roleplay(['roleplay-a']),
        failure(SupportTextContextFailure.limited),
      );
      await f.replaceRoleplay(
        List.generate(
          2001,
          (i) => {'id': 'synthetic-$i', 'role': 'user', 'content': 'small'},
        ),
      );
      await expectLater(
        roleplay(['synthetic-0']),
        failure(SupportTextContextFailure.limited),
      );
      await f.replaceRoleplay([
        SupportTextContextFixture.message('roleplay-a', body: 'x' * 40000),
        SupportTextContextFixture.message('roleplay-b', body: 'y' * 40000),
      ]);
      f.observe();
      await expectLater(roleplay(), failure(SupportTextContextFailure.limited));
      expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
    },
  );

  test(
    'support aggregate and per-body oversized input fails without substitution',
    () async {
      final large = await f.encrypt(
        'x' * 65537,
        'support_messages',
        'support-b',
        SupportTextContextFixture.supportId,
        'body_ciphertext',
      );
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('support-b')))
          .write(SupportMessagesCompanion(bodyCiphertext: Value(large)));
      await expectLater(support(), failure(SupportTextContextFailure.limited));
    },
  );

  test(
    'support source-count cap refuses even when selected row is tiny',
    () async {
      await f.db.batch(
        (batch) => batch.insertAll(
          f.db.supportMessages,
          List.generate(
            1998,
            (i) => SupportMessagesCompanion.insert(
              id: 'synthetic-extra-$i',
              sessionId: SupportTextContextFixture.supportId,
              role: 'user',
              bodyCiphertext: 'not-decrypted',
              createdAt: const Value(99),
            ),
          ),
        ),
      );
      await expectLater(support(), failure(SupportTextContextFailure.limited));
    },
  );

  for (final change in [
    'text',
    'swipe',
    'hidden',
    'order',
    'scope',
    'delete',
    'ABA',
  ]) {
    test(
      'roleplay preview invalidates for $change, including identical-content ABA',
      () async {
        final s = await roleplay(['roleplay-a']);
        final a = SupportTextContextFixture.message(
          'roleplay-a',
          body:
              '${SupportTextContextFixture.selected} ${SupportTextContextFixture.secret}',
        );
        if (change == 'delete') {
          await (f.db.delete(f.db.chatSessions)..where(
                (t) => t.sessionId.equals(SupportTextContextFixture.roleplayId),
              ))
              .go();
        } else if (change == 'scope') {
          await (f.db.update(f.db.chatSessions)..where(
                (t) => t.sessionId.equals(SupportTextContextFixture.roleplayId),
              ))
              .write(
                const ChatSessionsCompanion(
                  characterId: Value('synthetic-other-character'),
                ),
              );
        } else {
          if (change == 'text' || change == 'ABA') {
            a['content'] = 'Synthetic edited';
          }
          if (change == 'swipe') a['swipeId'] = 0;
          if (change == 'hidden') a['isHidden'] = true;
          await f.replaceRoleplay(
            change == 'order'
                ? [SupportTextContextFixture.message('different'), a]
                : [a],
          );
          if (change == 'ABA') {
            await f.replaceRoleplay([
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
            ]);
          }
        }
        expect(await f.repo.revalidate(s), isFalse);
        expect(await f.repo.revalidate(s), isFalse);
      },
    );
  }

  for (final change in ['edit', 'role', 'reparent', 'delete', 'ABA']) {
    test('support preview invalidates for $change', () async {
      final s = await support(['support-a']);
      final original = await (f.db.select(
        f.db.supportMessages,
      )..where((t) => t.id.equals('support-a'))).getSingle();
      if (change == 'delete') {
        await (f.db.delete(
          f.db.supportMessages,
        )..where((t) => t.id.equals('support-a'))).go();
      } else {
        final edit = await f.encrypt(
          'Synthetic edited',
          'support_messages',
          'support-a',
          SupportTextContextFixture.supportId,
          'body_ciphertext',
        );
        await (f.db.update(
          f.db.supportMessages,
        )..where((t) => t.id.equals('support-a'))).write(
          change == 'role'
              ? const SupportMessagesCompanion(role: Value('system'))
              : change == 'reparent'
              ? const SupportMessagesCompanion(
                  sessionId: Value('synthetic-other-support'),
                )
              : SupportMessagesCompanion(bodyCiphertext: Value(edit)),
        );
        if (change == 'ABA') {
          await (f.db.update(
            f.db.supportMessages,
          )..where((t) => t.id.equals('support-a'))).write(
            SupportMessagesCompanion(
              bodyCiphertext: Value(original.bodyCiphertext),
            ),
          );
        }
      }
      expect(await f.repo.revalidate(s), isFalse);
    });
  }

  test(
    'redactor supplier is fresh after decrypt awaits and during revalidation',
    () async {
      final s = await support(['support-a']);
      f.redactor = SecretRedactor(
        knownSecrets: [
          SupportTextContextFixture.secret,
          SupportTextContextFixture.selected,
        ],
      );
      expect(await f.repo.revalidate(s), isFalse);
      final entered = Completer<void>(), release = Completer<void>();
      f.redactor = SecretRedactor(
        knownSecrets: [SupportTextContextFixture.secret],
      );
      f.primitive.beforeDecrypt = (aad) async {
        if (aad.contains('|support-a|') && aad.endsWith('|body_ciphertext')) {
          entered.complete();
          await release.future;
        }
      };
      final future = support(['support-a']);
      await entered.future;
      f.redactor = SecretRedactor(
        knownSecrets: [
          SupportTextContextFixture.secret,
          SupportTextContextFixture.selected,
        ],
      );
      release.complete();
      expect(
        (await future).messages.single.text,
        '${SecretRedactor.removed} ${SecretRedactor.removed}',
      );
    },
  );

  test(
    'dedicated bounded provenance only; missing declaration stays unknown',
    () async {
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('support-b')))
          .write(const SupportMessagesCompanion(runId: Value('synthetic-run')));
      const facts =
          '{"version":1,"runId":"synthetic-run","sources":["synthetic-source"]}';
      await f.provenance('support-b', facts, time: 3);
      f.observe();
      final s = await support();
      expect(s.provenance.first.dedicatedFactsJson, isNull);
      expect(s.provenance.last.dedicatedFactsJson, facts);
      expect(s.provenance.last.runId, 'synthetic-run');
      expect(
        f.primitive.decryptAads.any(
          (aad) =>
              aad.endsWith('|summary_ciphertext') ||
              aad.endsWith('|cards_ciphertext'),
        ),
        isFalse,
      );
      expect(
        jsonEncode(f.spy.values),
        isNot(contains(SupportTextContextFixture.card)),
      );
      expect(await f.repo.revalidate(s), isTrue);
      f.stopObserving();
      await (f.db.update(
        f.db.supportContextBlocks,
      )..where((t) => t.id.equals('support.reply_provenance:support-b'))).write(
        const SupportContextBlocksCompanion(endMessageId: Value('support-a')),
      );
      expect(await f.repo.revalidate(s), isFalse);
      await expectLater(support(), failure());
    },
  );

  test(
    'arbitrary SQL failures never invoke error toString or leak details',
    () async {
      f.observe();
      final error = _DangerousError();
      f.spy.selectError = error;
      await expectLater(
        support(),
        failure(SupportTextContextFailure.unavailable),
      );
      await expectLater(
        roleplay(),
        failure(SupportTextContextFailure.unavailable),
      );
      expect(error.stringified, isFalse);
      expect(f.spy.writes, 0);
    },
  );

  test('current variation must resolve to the same explicit content', () async {
    final a = SupportTextContextFixture.message('roleplay-a');
    a['agentSwipes'] = [
      {'content': 'Synthetic changed active body'},
    ];
    await f.replaceRoleplay([a]);
    await expectLater(roleplay(['roleplay-a']), failure());
    a['agentSwipes'] = [];
    a['swipes'] = ['Synthetic base', 'Synthetic stale green body'];
    await f.replaceRoleplay([a]);
    await expectLater(roleplay(['roleplay-a']), failure());
    a['swipes'] = [SupportTextContextFixture.selected];
    a['swipeId'] = 1;
    await f.replaceRoleplay([a]);
    await expectLater(roleplay(['roleplay-a']), failure());
    a['swipeId'] = 0;
    await f.replaceRoleplay([a]);
    expect(
      (await roleplay(['roleplay-a'])).messages.single.text,
      SupportTextContextFixture.selected,
    );
  });

  test('512 exact ordered IDs are admitted', () async {
    final ids = List.generate(512, (i) => 'synthetic-exact-$i');
    await f.replaceRoleplay([
      for (final id in ids)
        {'id': id, 'role': 'user', 'content': 'Synthetic small'},
    ]);
    final s = await roleplay(ids);
    expect(s.messageIds, ids);
    expect(s.messages.length, 512);
    expect(await f.repo.revalidate(s), isTrue);
  });

  test('roleplay byte bound is not merely a character bound', () async {
    final json = jsonEncode([
      {'id': 'roleplay-a', 'role': 'user', 'content': 'ж' * (1024 * 1024)},
    ]);
    expect(json.length, lessThan(2 * 1024 * 1024));
    await f.replaceRoleplayJson(json);
    f.observe();
    await expectLater(
      roleplay(['roleplay-a']),
      failure(SupportTextContextFailure.limited),
    );
    expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
  });

  test(
    'hidden character refuses exact source load and previous preview',
    () async {
      final s = await roleplay(['roleplay-a']);
      await (f.db.update(f.db.characters)
            ..where((t) => t.charId.equals('synthetic-character')))
          .write(const CharactersCompanion(hidden: Value(true)));
      expect(await f.repo.revalidate(s), isFalse);
      await expectLater(roleplay(['roleplay-a']), failure());
    },
  );

  test(
    'delete/recreate exact ciphertext and roleplay row is still ABA',
    () async {
      final supportSnapshot = await support(['support-a']);
      final message = await (f.db.select(
        f.db.supportMessages,
      )..where((t) => t.id.equals('support-a'))).getSingle();
      await (f.db.delete(
        f.db.supportMessages,
      )..where((t) => t.id.equals('support-a'))).go();
      await f.db.into(f.db.supportMessages).insert(message.toCompanion(true));
      expect(await f.repo.revalidate(supportSnapshot), isFalse);
      final gameSnapshot = await roleplay(['roleplay-a']);
      final session =
          await (f.db.select(f.db.chatSessions)..where(
                (t) => t.sessionId.equals(SupportTextContextFixture.roleplayId),
              ))
              .getSingle();
      await (f.db.delete(f.db.chatSessions)..where(
            (t) => t.sessionId.equals(SupportTextContextFixture.roleplayId),
          ))
          .go();
      await f.db.into(f.db.chatSessions).insert(session.toCompanion(true));
      expect(await f.repo.revalidate(gameSnapshot), isFalse);
    },
  );

  test(
    'missing actual character refuses an otherwise exact roleplay body',
    () async {
      await f.roleplay(
        'synthetic-orphan-session',
        jsonEncode([
          SupportTextContextFixture.message('synthetic-orphan-message'),
        ]),
        characterId: 'synthetic-missing-character',
      );
      final before = await f.snapshot();
      f.observe();
      await expectLater(
        f.repo.loadRoleplay(
          sessionId: 'synthetic-orphan-session',
          messageIds: ['synthetic-orphan-message'],
        ),
        failure(SupportTextContextFailure.unavailable),
      );
      expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
      expect(f.spy.writes, 0);
      expect(f.storage.operations, isEmpty);
      f.stopObserving();
      expect(await f.snapshot(), before);
    },
  );

  test(
    'deleted actual character refuses fresh load and previous preview',
    () async {
      final s = await roleplay(['roleplay-a']);
      await (f.db.delete(
        f.db.characters,
      )..where((t) => t.charId.equals('synthetic-character'))).go();
      final source = await f.db
          .customSelect(
            'SELECT COUNT(*) AS n FROM chat_sessions WHERE session_id = ?',
            variables: [
              Variable.withString(SupportTextContextFixture.roleplayId),
            ],
          )
          .getSingle();
      expect(
        source.read<int>('n'),
        1,
      ); // Body/session still exist: not a cascade.
      final before = await f.snapshot();
      f.observe();
      expect(await f.repo.revalidate(s), isFalse);
      await expectLater(
        roleplay(['roleplay-a']),
        failure(SupportTextContextFailure.unavailable),
      );
      expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
      expect(f.spy.writes, 0);
      expect(f.storage.operations, isEmpty);
      f.stopObserving();
      expect(await f.snapshot(), before);
    },
  );

  for (final (caseIndex, order) in <Object>[
    -1,
    1000001,
    1.25,
    'synthetic-not-an-integer',
    Uint8List.fromList(utf8.encode(SupportTextContextFixture.card)),
  ].indexed) {
    test(
      'native variant order must be a sane integer case $caseIndex',
      () async {
        final s = await roleplay(['roleplay-a']);
        await f.db.customStatement(
          'UPDATE characters SET variant_order = ? WHERE char_id = ?',
          [order, 'synthetic-character'],
        );
        f.observe();
        expect(await f.repo.revalidate(s), isFalse);
        await expectLater(
          roleplay(['roleplay-a']),
          failure(SupportTextContextFailure.unavailable),
        );
        expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
        expect(
          jsonEncode(f.spy.values),
          isNot(contains(SupportTextContextFixture.card)),
        );
        expect(f.spy.writes, 0);
      },
    );
  }

  test(
    'non-text native group metadata is refused without exporting it',
    () async {
      final s = await roleplay(['roleplay-a']);
      await f.db.customStatement(
        'UPDATE characters SET variant_group_id = ? WHERE char_id = ?',
        [
          Uint8List.fromList(utf8.encode(SupportTextContextFixture.card)),
          'synthetic-character',
        ],
      );
      f.observe();
      expect(await f.repo.revalidate(s), isFalse);
      await expectLater(
        roleplay(['roleplay-a']),
        failure(SupportTextContextFailure.unavailable),
      );
      expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
      expect(
        jsonEncode(f.spy.values),
        isNot(contains(SupportTextContextFixture.card)),
      );
    },
  );

  test(
    'malformed native session index is refused before body projection',
    () async {
      await f.db.customStatement(
        'UPDATE chat_sessions SET session_index = ? WHERE session_id = ?',
        [1.25, SupportTextContextFixture.roleplayId],
      );
      f.observe();
      await expectLater(
        roleplay(['roleplay-a']),
        failure(SupportTextContextFailure.unavailable),
      );
      expect(f.spy.values.any((row) => row.containsKey('body')), isFalse);
    },
  );

  test(
    'legacy empty group and sane variant-order boundary stay native, not invented',
    () async {
      await (f.db.update(
        f.db.characters,
      )..where((t) => t.charId.equals('synthetic-character'))).write(
        const CharactersCompanion(
          variantGroupId: Value(''),
          variantOrder: Value(1000000),
        ),
      );
      f.observe();
      final s = await roleplay(['roleplay-a']);
      expect(
        s.messages.single.text,
        contains(SupportTextContextFixture.selected),
      );
      final header = f.spy.values.singleWhere(
        (row) => row.containsKey('character_native_identity'),
      );
      expect(header['character_native_identity'], isA<int>());
      expect(header['variant_group_id'], '');
      expect(header['variant_order'], 1000000);
      expect(await f.repo.revalidate(s), isTrue);
    },
  );

  test(
    'unrelated writes invalidate; preview must follow preparation writes',
    () async {
      final s = await support(['support-a']);
      await (f.db.update(f.db.supportSessions)
            ..where((t) => t.id.equals('synthetic-other-support')))
          .write(const SupportSessionsCompanion(updatedAt: Value(10)));
      expect(await f.repo.revalidate(s), isFalse);
      expect(await f.repo.revalidate(await support(['support-a'])), isTrue);
    },
  );

  test(
    'observed vault lock permanently revokes preview after key restore',
    () async {
      final s = await support(['support-a']);
      final keys = Map<String, String>.from(f.storage.values);
      f.storage.values.clear();
      expect(await f.repo.revalidate(s), isFalse);
      f.storage.values.addAll(keys);
      expect(await f.repo.revalidate(s), isFalse);
    },
  );

  test(
    'dedicated provenance corruption, oversize and secrets refuse',
    () async {
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('support-b')))
          .write(const SupportMessagesCompanion(runId: Value('synthetic-run')));
      await f.provenance('support-b', 'x' * 65537, time: 3);
      await expectLater(support(), failure(SupportTextContextFailure.limited));
      final query = f.db.update(f.db.supportContextBlocks)
        ..where((t) => t.id.equals('support.reply_provenance:support-b'));
      await query.write(
        const SupportContextBlocksCompanion(
          protectedFactsCiphertext: Value('corrupt'),
        ),
      );
      await expectLater(support(), failure());
      final facts = await f.encrypt(
        '{"private":"${SupportTextContextFixture.secret}"}',
        'support_context_blocks',
        'support.reply_provenance:support-b',
        SupportTextContextFixture.supportId,
        'protected_facts_ciphertext',
      );
      await query.write(
        SupportContextBlocksCompanion(protectedFactsCiphertext: Value(facts)),
      );
      await expectLater(
        support(),
        failure(SupportTextContextFailure.unavailable),
      );
    },
  );
}

final class _ForgedSnapshot implements SupportTextContextSnapshot {
  @override
  dynamic noSuchMethod(Invocation invocation) =>
      throw StateError('forged getter was inspected');
}

final class _DangerousError {
  bool stringified = false;
  @override
  String toString() {
    stringified = true;
    throw StateError('synthetic private error');
  }
}
