import 'dart:convert';

import 'package:drift/drift.dart' hide isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/models/support_text_context.dart';

import 'support_session_text_context_fixture.dart';

Matcher _failure([SupportTextContextFailure? failure]) => throwsA(
  isA<SupportTextContextException>().having(
    (e) => failure == null || e.failure == failure,
    'fixed typed reason',
    true,
  ),
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  sessionTextTest(
    'whole roleplay discovers exact active visible native order, no selected-ID argument',
    (f) async {
      f.observe();
      final snapshot = await f.roleplay();
      expect(snapshot.isWholeSession, isTrue);
      expect(snapshot.currentInput, isNull);
      expect(snapshot.messageIds, ['game-a', 'game-b']);
      expect(snapshot.messages.map((m) => m.text), [
        'Synthetic first ${SecretRedactor.removed}',
        'Synthetic game history',
      ]);
      final sourceReads = f.sql.reads
          .where((r) => r.statement.contains('chat_sessions'))
          .toList();
      expect(sourceReads, isNotEmpty);
      expect(sourceReads.map((r) => r.transaction).toSet().length, 1);
      expect(sourceReads.every((r) => r.transaction != null), isTrue);
      final primitives = jsonEncode(
        f.sql.reads.expand((r) => r.values).toList(),
      );
      for (final canary in [
        SessionTextFixture.excluded,
        SessionTextFixture.hidden,
      ]) {
        expect(primitives, isNot(contains(canary)));
        expect(
          snapshot.messages.map((m) => m.text).join(),
          isNot(contains(canary)),
        );
      }
      expect(
        snapshot.messages.map((m) => m.text).join(),
        isNot(contains(SessionTextFixture.secret)),
      );
      final nonBodies = f.sql.reads
          .expand((r) => r.values)
          .map(
            (r) => {
              for (final entry in r.entries)
                if (entry.key != 'body') entry.key: entry.value,
            },
          )
          .toList();
      expect(jsonEncode(nonBodies), isNot(contains(SessionTextFixture.secret)));
      // Selected body is private SQL projection only; raw unrelated fragments are
      // never returned. Sanitization, not SQL, removes secrets within that body.
      expect(
        f.sql.reads
            .expand((r) => r.values)
            .any((r) => r.containsKey('messages_json')),
        isFalse,
      );
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(() => snapshot.messageIds.clear(), throwsUnsupportedError);
      expect(() => snapshot.messages.clear(), throwsUnsupportedError);
      expect(await f.repo.revalidate(snapshot), isTrue);
      var dispatches = 0;
      expect(await f.admit(snapshot, () => dispatches++), isTrue);
      expect(dispatches, 1);
      expect(f.sql.reservations, 1);
      expect(
        f.sql.reads.any((r) => r.statement == 'PRAGMA busy_timeout'),
        isTrue,
      );
      final stamps = f.sql.reads
          .expand((r) => r.values)
          .where((r) => r.containsKey('changes'));
      expect(stamps, isNotEmpty);
      expect(
        stamps.every((r) => r['changes'] is int && r['version'] is int),
        isTrue,
      );
    },
  );

  sessionTextTest(
    'metadata-only original support boundary excludes current user and complete reserved reply once',
    (f) async {
      f.observe();
      final boundary = await f.boundary();
      expect(f.primitive.decryptAads, isEmpty);
      expect(f.storage.operations, isEmpty);
      expect(
        f.sql.reads.every((r) => !r.statement.contains('ciphertext')),
        isTrue,
      );
      expect(boundary.toString(), 'SupportSessionHistoryBoundary');
      final dynamic opaque = boundary;
      expect(() => opaque.createdAt, throwsA(isA<NoSuchMethodError>()));
      expect(() => opaque.metadata, throwsA(isA<NoSuchMethodError>()));
      f.observe();
      final snapshot = await f.own(boundary);
      expect(snapshot.messageIds, ['history-a', 'history-b', 'a-before-tie']);
      expect(snapshot.messages.map((m) => m.role), [
        'user',
        'assistant',
        'user',
      ]);
      expect(identical(snapshot.currentInput, boundary), isTrue);
      expect(snapshot.provenance.length, 3);
      expect(
        snapshot.provenance.every((p) => p.dedicatedFactsJson == null),
        isTrue,
      );
      // Unknown historical assistant origins stay unknown, not declassified by
      // whole consent. The future feature/ROOT decoder must still deny them.
      expect(snapshot.provenance[1].runId, 'synthetic-old-run');
      expect(snapshot.messageIds.toSet().length, snapshot.messageIds.length);
      expect(
        f.primitive.decryptAads.any(
          (a) => a.contains('|current-user|') || a.contains('|reserved-reply|'),
        ),
        isFalse,
      );
      expect(
        f.primitive.decryptAads.every(
          (a) =>
              a.endsWith('|body_ciphertext') || a.endsWith('|title_ciphertext'),
        ),
        isTrue,
      );
      final primitives = jsonEncode(
        f.sql.reads.expand((r) => r.values).toList(),
      );
      for (final canary in [
        SessionTextFixture.input,
        SessionTextFixture.reply,
        SessionTextFixture.excluded,
      ]) {
        expect(primitives, isNot(contains(canary)));
        expect(
          snapshot.messages.map((m) => m.text).join(),
          isNot(contains(canary)),
        );
      }
      final source = f.sql.reads.where(
        (r) =>
            r.statement.contains('support_sessions') ||
            r.statement.contains('support_messages') ||
            r.statement.contains('support_context_blocks'),
      );
      expect(source.map((r) => r.transaction).toSet().length, 1);
      expect(source.every((r) => r.transaction != null), isTrue);
      expect(await f.repo.revalidate(snapshot), isTrue);
    },
  );

  sessionTextTest(
    'future roleplay is included by fresh snapshot, OLD admission rejected',
    (f) async {
      final old = await f.roleplay();
      await f.replaceGame([
        SessionTextFixture.gameMessage(
          'game-a',
          role: 'user',
          body: 'Synthetic first ${SessionTextFixture.secret}',
        ),
        SessionTextFixture.gameMessage(
          'hidden-game',
          body: SessionTextFixture.hidden,
        )..['isHidden'] = true,
        SessionTextFixture.gameMessage('game-b'),
        SessionTextFixture.gameMessage(
          'game-future',
          body: 'Synthetic new turn',
        ),
      ]);
      var dispatches = 0;
      expect(await f.admit(old, () => dispatches++), isFalse);
      expect(dispatches, 0);
      expect(await f.repo.revalidate(old), isFalse);
      final fresh = await f.roleplay();
      expect(fresh.messageIds, ['game-a', 'game-b', 'game-future']);
      expect(fresh.messages.last.text, 'Synthetic new turn');
      expect(await f.admit(fresh, () => dispatches++), isTrue);
      expect(dispatches, 1);
    },
  );

  for (final mutation in [
    'body',
    'swipe',
    'hidden',
    'added',
    'deleted',
    'reordered',
    'new-id',
    'character-hidden',
    'ABA',
  ]) {
    sessionTextTest(
      'whole roleplay retained membership/order/content revokes: $mutation',
      (f) async {
        final old = await f.roleplay();
        final a = SessionTextFixture.gameMessage(
          'game-a',
          role: 'user',
          body: 'Synthetic first ${SessionTextFixture.secret}',
        );
        final b = SessionTextFixture.gameMessage('game-b');
        if (mutation == 'body') b['content'] = 'Changed visible body';
        if (mutation == 'swipe') b['swipeId'] = 0;
        if (mutation == 'hidden') b['isHidden'] = true;
        if (mutation == 'new-id') b['id'] = 'game-new-identity';
        if (mutation == 'character-hidden') {
          await (f.db.update(f.db.characters)
                ..where((t) => t.charId.equals('synthetic-character')))
              .write(const CharactersCompanion(hidden: Value(true)));
        } else {
          await f.replaceGame([
            if (mutation == 'reordered') b,
            a,
            if (mutation != 'deleted' && mutation != 'reordered') b,
            if (mutation == 'added')
              SessionTextFixture.gameMessage('new-game-turn'),
          ]);
          if (mutation == 'ABA') {
            await f.replaceGame([
              a,
              SessionTextFixture.gameMessage(
                'hidden-game',
                body: SessionTextFixture.hidden,
              )..['isHidden'] = true,
              b,
            ]);
          }
        }
        var sent = 0;
        expect(await f.admit(old, () => sent++), isFalse);
        expect(sent, 0);
        expect(await f.repo.revalidate(old), isFalse);
      },
    );
  }

  sessionTextTest(
    'whole support fresh read stays before ORIGINAL user tuple; later boundary includes previous turns',
    (f) async {
      final boundary = await f.boundary();
      final old = await f.own(boundary);
      await f.message(
        'new-earlier-history',
        body: 'New durable earlier history',
        time: 4,
      );
      expect(await f.admit(old, () => fail('old preview dispatched')), isFalse);
      final fresh = await f.own(boundary);
      expect(fresh.messageIds, [
        'history-a',
        'history-b',
        'new-earlier-history',
        'a-before-tie',
      ]);
      await f.message(
        'later-user',
        body: 'Next current user',
        time: 20,
        runId: 'synthetic-next-run',
      );
      final later = await f.boundary(
        user: 'later-user',
        runId: 'synthetic-next-run',
      );
      final laterHistory = await f.own(later);
      expect(
        laterHistory.messageIds
            .where((id) => id == SessionTextFixture.current)
            .length,
        1,
      );
      expect(
        laterHistory.messageIds.where((id) => id == 'reserved-reply').length,
        1,
      );
      expect(laterHistory.messageIds, isNot(contains('later-user')));
    },
  );

  for (final mutation in [
    'added-after-bound',
    'deleted',
    'reordered',
    'body',
    'new-id',
  ]) {
    sessionTextTest(
      'whole support source mutation invalidates old preview: $mutation',
      (f) async {
        final boundary = await f.boundary();
        final old = await f.own(boundary);
        switch (mutation) {
          case 'added-after-bound':
            await f.message(
              'future-message',
              body: SessionTextFixture.excluded,
              time: 30,
            );
          case 'deleted':
            await (f.db.delete(
              f.db.supportMessages,
            )..where((t) => t.id.equals('history-a'))).go();
          case 'reordered':
            await (f.db.update(f.db.supportMessages)
                  ..where((t) => t.id.equals('history-a')))
                .write(const SupportMessagesCompanion(createdAt: Value(5)));
          case 'body':
            final body = await f.encrypt(
              'Changed body',
              'support_messages',
              'history-a',
              SessionTextFixture.support,
              'body_ciphertext',
            );
            await (f.db.update(f.db.supportMessages)
                  ..where((t) => t.id.equals('history-a')))
                .write(SupportMessagesCompanion(bodyCiphertext: Value(body)));
          case 'new-id':
            await (f.db.delete(
              f.db.supportMessages,
            )..where((t) => t.id.equals('history-a'))).go();
            await f.message('history-replacement', time: 2);
        }
        expect(
          await f.admit(old, () => fail('stale preview dispatched')),
          isFalse,
        );
        expect(await f.repo.revalidate(old), isFalse);
        if (mutation == 'added-after-bound') {
          expect((await f.own(boundary)).messageIds, old.messageIds);
        }
      },
    );
  }

  sessionTextTest(
    'caller-made/foreign-repo/foreign-session boundary and wrong exact USER run fail before bodies',
    (f) async {
      final boundary = await f.boundary();
      f.observe();
      await expectLater(
        f.own(_ForgedBoundary()),
        _failure(SupportTextContextFailure.invalidSelection),
      );
      await expectLater(
        f.newRepo().loadSupportSessionHistory(
          sessionId: SessionTextFixture.support,
          currentInput: boundary,
        ),
        _failure(),
      );
      await expectLater(
        f.own(boundary, session: 'synthetic-foreign-support'),
        _failure(),
      );
      expect(f.sql.reads, isEmpty);
      expect(f.primitive.decryptAads, isEmpty);
      await expectLater(f.boundary(user: 'reserved-reply'), _failure());
      await expectLater(f.boundary(runId: 'different-run'), _failure());
      await expectLater(
        f.boundary(session: 'synthetic-foreign-support'),
        _failure(),
      );
      expect(f.primitive.decryptAads, isEmpty);
    },
  );

  for (final mutation in ['run', 'role', 'time', 'session', 'deleted']) {
    sessionTextTest(
      'original durable support boundary is rechecked against exact native row: $mutation',
      (f) async {
        final boundary = await f.boundary();
        final old = await f.own(boundary);
        final update = f.db.update(f.db.supportMessages)
          ..where((t) => t.id.equals(SessionTextFixture.current));
        switch (mutation) {
          case 'run':
            await update.write(
              const SupportMessagesCompanion(runId: Value('new-run')),
            );
          case 'role':
            await update.write(
              const SupportMessagesCompanion(role: Value('assistant')),
            );
          case 'time':
            await update.write(
              const SupportMessagesCompanion(createdAt: Value(11)),
            );
          case 'session':
            await update.write(
              const SupportMessagesCompanion(
                sessionId: Value('synthetic-foreign-support'),
              ),
            );
          case 'deleted':
            await (f.db.delete(
              f.db.supportMessages,
            )..where((t) => t.id.equals(SessionTextFixture.current))).go();
        }
        f.observe();
        expect(
          await f.admit(old, () => fail('changed input row dispatched')),
          isFalse,
        );
        await expectLater(f.own(boundary), _failure());
        expect(f.primitive.decryptAads, isEmpty);
      },
    );
  }

  sessionTextTest(
    'explicit readable EMPTY roleplay remains owned and revalidated, not wildcard or fake-ID source',
    (f) async {
      await f.replaceGame([]);
      f.observe();
      final empty = await f.roleplay();
      expect(empty.isWholeSession, isTrue);
      expect(empty.sessionId, SessionTextFixture.game);
      expect(empty.messageIds, isEmpty);
      expect(empty.messages, isEmpty);
      expect(empty.provenance, isEmpty);
      expect(await f.newRepo().revalidate(empty), isFalse);
      expect(await f.repo.revalidate(empty), isTrue);
      expect(await f.admit(empty, () {}), isTrue);
      expect(
        f.sql.reads.any((r) => r.statement.contains('chat_sessions')),
        isTrue,
      );
      f.sql.observing = false;
      await f.replaceGame([
        SessionTextFixture.gameMessage('new-visible-message'),
      ]);
      expect(
        await f.admit(empty, () => fail('old EMPTY preview dispatched')),
        isFalse,
      );
      expect((await f.roleplay()).messageIds, ['new-visible-message']);
    },
  );

  sessionTextTest(
    'explicit readable EMPTY own support checks encrypted parent with zero provenance origins',
    (f) async {
      await f.supportSession('synthetic-empty-own');
      await f.message(
        'empty-current',
        session: 'synthetic-empty-own',
        runId: 'empty-run',
        time: 10,
      );
      final boundary = await f.boundary(
        session: 'synthetic-empty-own',
        user: 'empty-current',
        runId: 'empty-run',
      );
      f.observe();
      final empty = await f.own(boundary, session: 'synthetic-empty-own');
      expect(empty.messageIds, isEmpty);
      expect(empty.provenance, isEmpty);
      expect(empty.isWholeSession, isTrue);
      expect(await f.admit(empty, () {}), isTrue);
      expect(f.primitive.decryptAads, isNotEmpty);
      expect(
        f.primitive.decryptAads.every((a) => a.endsWith('|title_ciphertext')),
        isTrue,
      );
      f.storage.values.clear();
      expect(await f.repo.revalidate(empty), isFalse);
      await expectLater(
        f.own(boundary, session: 'synthetic-empty-own'),
        _failure(),
      );
    },
  );

  sessionTextTest(
    'EMPTY versus missing/hidden/corrupt source never default to all or readable success',
    (f) async {
      await f.replaceGame([]);
      final empty = await f.roleplay();
      await f.replaceGameJson('corrupt');
      expect(await f.repo.revalidate(empty), isFalse);
      await expectLater(f.roleplay(), _failure());
      await expectLater(
        f.repo.loadRoleplaySessionHistory(sessionId: 'missing-session'),
        _failure(),
      );
      await f.replaceGame([]);
      await (f.db.update(f.db.characters)
            ..where((t) => t.charId.equals('synthetic-character')))
          .write(const CharactersCompanion(hidden: Value(true)));
      await expectLater(f.roleplay(), _failure());
      await expectLater(
        f.repo.loadRoleplaySessionHistory(sessionId: ''),
        _failure(SupportTextContextFailure.invalidSelection),
      );
      await expectLater(
        f.repo.loadRoleplay(
          sessionId: SessionTextFixture.game,
          messageIds: const [],
        ),
        _failure(SupportTextContextFailure.invalidSelection),
      );
      await expectLater(
        f.repo.loadSupport(
          sessionId: SessionTextFixture.support,
          messageIds: const [],
        ),
        _failure(SupportTextContextFailure.invalidSelection),
      );
    },
  );

  for (final flag in [
    'isHidden',
    'isError',
    'isTyping',
    'isEditing',
    'isLocked',
    'isAllReasoning',
  ]) {
    sessionTextTest(
      'whole roleplay excludes $flag body without private projection',
      (f) async {
        await f.replaceGame([
          SessionTextFixture.gameMessage('visible'),
          SessionTextFixture.gameMessage(
            'excluded',
            body: SessionTextFixture.hidden,
          )..[flag] = true,
        ]);
        f.observe();
        final snapshot = await f.roleplay();
        expect(snapshot.messageIds, ['visible']);
        expect(
          jsonEncode(f.sql.reads.expand((r) => r.values).toList()),
          isNot(contains(SessionTextFixture.hidden)),
        );
      },
    );
  }

  for (final (index, json) in [
    '[null]',
    '[{"id":"duplicate","role":"user","content":"a"},{"id":"duplicate","role":"user","content":"b","isHidden":true}]',
    '[{"id":"one","id":"two","role":"user","content":"a"}]',
    '[{"id":"one","role":"user","content":"a","content":"b"}]',
    '[{"id":"one","role":"user","content":"a","isHidden":"false"}]',
    '[{"id":"one","role":"assistant","content":"a","swipeId":1,"swipes":["a"]}]',
  ].indexed) {
    sessionTextTest(
      'whole roleplay refuses corrupt relevant identity/canonical variation $index',
      (f) async {
        await f.replaceGameJson(json);
        await expectLater(
          f.roleplay(),
          _failure(SupportTextContextFailure.unavailable),
        );
      },
    );
  }

  for (final count in [512, 513, 2001]) {
    sessionTextTest(
      'whole roleplay bound $count is complete or fixed refusal, never partial',
      (f) async {
        await f.replaceGame(
          List.generate(
            count,
            (i) => {'id': 'bounded-$i', 'role': 'user', 'content': 'small'},
          ),
        );
        f.observe();
        if (count == 512) {
          final snapshot = await f.roleplay();
          expect(snapshot.messageIds.length, count);
          expect(await f.admit(snapshot, () {}), isTrue);
        } else {
          await expectLater(
            f.roleplay(),
            _failure(SupportTextContextFailure.limited),
          );
          expect(
            f.sql.reads
                .expand((r) => r.values)
                .any((r) => r.containsKey('body')),
            isFalse,
          );
        }
      },
    );
  }

  sessionTextTest(
    'roleplay source byte/aggregate budget precedes body projection and never truncates',
    (f) async {
      await f.replaceGameJson(' ' * (2 * 1024 * 1024 + 1));
      f.observe();
      await expectLater(
        f.roleplay(),
        _failure(SupportTextContextFailure.limited),
      );
      expect(
        f.sql.reads
            .expand((r) => r.values)
            .any((r) => r.containsKey('message_id')),
        isFalse,
      );
      f.sql.observing = false;
      await f.replaceGame([
        SessionTextFixture.gameMessage('large-a', body: 'x' * 40000),
        SessionTextFixture.gameMessage('large-b', body: 'y' * 40000),
      ]);
      f.observe();
      await expectLater(
        f.roleplay(),
        _failure(SupportTextContextFailure.limited),
      );
      expect(
        f.sql.reads.expand((r) => r.values).any((r) => r.containsKey('body')),
        isFalse,
      );
    },
  );

  sessionTextTest(
    'whole support complete-row and source-count limits, no partial snapshot',
    (f) async {
      final boundary = await f.boundary();
      await f.db.batch(
        (batch) => batch.insertAll(
          f.db.supportMessages,
          List.generate(
            510,
            (i) => SupportMessagesCompanion.insert(
              id: 'extra-$i',
              sessionId: SessionTextFixture.support,
              role: 'user',
              bodyCiphertext: 'not-decrypted',
              createdAt: const Value(5),
            ),
          ),
        ),
      );
      f.observe();
      await expectLater(
        f.own(boundary),
        _failure(SupportTextContextFailure.limited),
      );
      expect(
        f.primitive.decryptAads.every((a) => a.endsWith('|title_ciphertext')),
        isTrue,
      );
      f.sql.observing = false;
      await f.db.batch(
        (batch) => batch.insertAll(
          f.db.supportMessages,
          List.generate(
            1487,
            (i) => SupportMessagesCompanion.insert(
              id: 'future-extra-$i',
              sessionId: SessionTextFixture.support,
              role: 'user',
              bodyCiphertext: 'not-decrypted',
              createdAt: const Value(99),
            ),
          ),
        ),
      );
      f.observe();
      await expectLater(
        f.own(boundary),
        _failure(SupportTextContextFailure.limited),
      );
      expect(f.primitive.decryptAads, isEmpty);
    },
  );

  sessionTextTest(
    'whole support body AEAD remains bound to exact row/session/field',
    (f) async {
      final boundary = await f.boundary();
      final wrong = await f.encrypt(
        'Wrong-bound history',
        'support_messages',
        'history-a',
        'synthetic-foreign-support',
        'body_ciphertext',
      );
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('history-a')))
          .write(SupportMessagesCompanion(bodyCiphertext: Value(wrong)));
      await expectLater(f.own(boundary), _failure());
    },
  );

  sessionTextTest(
    'whole support dedicated provenance uses only reserved namespace/AAD; missing stays unknown',
    (f) async {
      const id = 'support.reply_provenance:history-b';
      const facts =
          '{"version":1,"runId":"synthetic-old-run","sources":["synthetic-source"]}';
      final protected = await f.encrypt(
        facts,
        'support_context_blocks',
        id,
        SessionTextFixture.support,
        'protected_facts_ciphertext',
      );
      await f.db
          .into(f.db.supportContextBlocks)
          .insert(
            SupportContextBlocksCompanion.insert(
              id: id,
              sessionId: SessionTextFixture.support,
              startMessageId: 'history-b',
              endMessageId: 'history-b',
              summaryCiphertext: 'unreadable-private-summary',
              protectedFactsCiphertext: Value(protected),
              isActive: const Value(false),
              createdAt: const Value(3),
            ),
          );
      final boundary = await f.boundary();
      f.observe();
      final snapshot = await f.own(boundary);
      expect(snapshot.provenance[1].dedicatedFactsJson, facts);
      expect(snapshot.provenance.first.dedicatedFactsJson, isNull);
      expect(
        f.primitive.decryptAads.any(
          (a) =>
              a.contains('|$id|') && a.endsWith('|protected_facts_ciphertext'),
        ),
        isTrue,
      );
      expect(
        f.primitive.decryptAads.any(
          (a) =>
              a.endsWith('|summary_ciphertext') ||
              a.endsWith('|cards_ciphertext'),
        ),
        isFalse,
      );
      f.sql.observing = false;
      await (f.db.update(
        f.db.supportContextBlocks,
      )..where((t) => t.id.equals(id))).write(
        const SupportContextBlocksCompanion(endMessageId: Value('history-a')),
      );
      expect(
        await f.admit(snapshot, () => fail('changed lineage dispatched')),
        isFalse,
      );
      await expectLater(f.own(boundary), _failure());
    },
  );

  sessionTextTest(
    'old exact selected-source APIs remain narrow and non-whole',
    (f) async {
      final exact = await f.repo.loadRoleplay(
        sessionId: SessionTextFixture.game,
        messageIds: ['game-b'],
      );
      expect(exact.messageIds, ['game-b']);
      expect(exact.isWholeSession, isFalse);
      expect(exact.currentInput, isNull);
      expect(await f.repo.revalidate(exact), isTrue);
      final own = await f.repo.loadSupport(
        sessionId: SessionTextFixture.support,
        messageIds: ['history-a'],
      );
      expect(own.messageIds, ['history-a']);
      expect(own.isWholeSession, isFalse);
      await expectLater(
        f.repo.loadSupport(
          sessionId: SessionTextFixture.support,
          messageIds: ['history-b', 'history-a'],
        ),
        _failure(),
      );
    },
  );

  sessionTextTest(
    'EMPTY own source still denies corrupt/deleted encrypted parent',
    (f) async {
      await f.supportSession('empty-parent');
      await f.message(
        'empty-parent-current',
        session: 'empty-parent',
        time: 10,
        runId: 'empty-parent-run',
      );
      final boundary = await f.boundary(
        session: 'empty-parent',
        user: 'empty-parent-current',
        runId: 'empty-parent-run',
      );
      final empty = await f.own(boundary, session: 'empty-parent');
      expect(empty.messages, isEmpty);
      await (f.db.update(
        f.db.supportSessions,
      )..where((t) => t.id.equals('empty-parent'))).write(
        const SupportSessionsCompanion(titleCiphertext: Value('corrupt')),
      );
      expect(
        await f.admit(empty, () => fail('corrupt EMPTY parent dispatched')),
        isFalse,
      );
      await expectLater(f.own(boundary, session: 'empty-parent'), _failure());
      await (f.db.delete(
        f.db.supportSessions,
      )..where((t) => t.id.equals('empty-parent'))).go();
      f.observe();
      await expectLater(f.own(boundary, session: 'empty-parent'), _failure());
      expect(f.primitive.decryptAads, isEmpty);
    },
  );

  sessionTextTest(
    'whole support aggregate/per-body oversize is refusal, not compression or partial body',
    (f) async {
      final boundary = await f.boundary();
      final oversized = await f.encrypt(
        'x' * 65537,
        'support_messages',
        'history-a',
        SessionTextFixture.support,
        'body_ciphertext',
      );
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('history-a')))
          .write(SupportMessagesCompanion(bodyCiphertext: Value(oversized)));
      await expectLater(
        f.own(boundary),
        _failure(SupportTextContextFailure.limited),
      );
      final a = await f.encrypt(
        'x' * 40000,
        'support_messages',
        'history-a',
        SessionTextFixture.support,
        'body_ciphertext',
      );
      final b = await f.encrypt(
        'y' * 40000,
        'support_messages',
        'history-b',
        SessionTextFixture.support,
        'body_ciphertext',
      );
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('history-a')))
          .write(SupportMessagesCompanion(bodyCiphertext: Value(a)));
      await (f.db.update(f.db.supportMessages)
            ..where((t) => t.id.equals('history-b')))
          .write(SupportMessagesCompanion(bodyCiphertext: Value(b)));
      await expectLater(
        f.own(boundary),
        _failure(SupportTextContextFailure.limited),
      );
    },
  );

  sessionTextTest(
    'source byte bound is UTF8 bytes, not merely character length',
    (f) async {
      final source = jsonEncode([
        {'id': 'unicode-body', 'role': 'user', 'content': 'ж' * (1024 * 1024)},
      ]);
      expect(source.length, lessThan(2 * 1024 * 1024));
      await f.replaceGameJson(source);
      f.observe();
      await expectLater(
        f.roleplay(),
        _failure(SupportTextContextFailure.limited),
      );
      expect(
        f.sql.reads.expand((r) => r.values).any((r) => r.containsKey('body')),
        isFalse,
      );
    },
  );

  sessionTextTest(
    'whole read redactor is fresh and exact preview cannot be rebased to new sanitization',
    (f) async {
      final snapshot = await f.roleplay();
      f.redactor = SecretRedactor(
        knownSecrets: [SessionTextFixture.secret, 'Synthetic game history'],
      );
      expect(
        await f.admit(snapshot, () => fail('changed sanitization dispatched')),
        isFalse,
      );
      expect(await f.repo.revalidate(snapshot), isFalse);
      expect((await f.roleplay()).messages.last.text, SecretRedactor.removed);
    },
  );

  sessionTextTest(
    'admission cancellation after title AEAD await stops further whole-source/body reads',
    (f) async {
      final boundary = await f.boundary();
      final snapshot = await f.own(boundary);
      var current = true;
      f.primitive.beforeDecrypt = (aad) async {
        if (aad.endsWith('|title_ciphertext')) current = false;
      };
      f.observe();
      var dispatched = 0;
      expect(
        await f.admit(snapshot, () => dispatched++, current: () => current),
        isFalse,
      );
      expect(dispatched, 0);
      expect(f.primitive.decryptAads.length, 1);
      expect(
        f.primitive.decryptAads.single.endsWith('|title_ciphertext'),
        isTrue,
      );
      expect(
        f.sql.reads.any((r) => r.statement.contains('before_current')),
        isFalse,
      );
      expect(
        f.sql.reads
            .expand((r) => r.values)
            .any((r) => r.containsKey('body_ciphertext')),
        isFalse,
      );
    },
  );

  sessionTextTest(
    'noncomplete support history and pending roleplay are omitted before body reads',
    (f) async {
      await f.message('old-pending', time: 4, status: 'pending');
      await (f.db.update(
        f.db.supportMessages,
      )..where((t) => t.id.equals('old-pending'))).write(
        const SupportMessagesCompanion(
          bodyCiphertext: Value('unreadable-not-complete'),
        ),
      );
      final boundary = await f.boundary();
      f.observe();
      final own = await f.own(boundary);
      expect(own.messageIds, ['history-a', 'history-b', 'a-before-tie']);
      expect(
        f.primitive.decryptAads.any((a) => a.contains('|old-pending|')),
        isFalse,
      );
      f.sql.observing = false;
      await f.replaceGame([
        SessionTextFixture.gameMessage('visible-game'),
        SessionTextFixture.gameMessage(
          'pending-game',
          body: SessionTextFixture.hidden,
        )..['status'] = 'pending',
      ]);
      f.observe();
      expect((await f.roleplay()).messageIds, ['visible-game']);
      expect(
        jsonEncode(f.sql.reads.expand((r) => r.values).toList()),
        isNot(contains(SessionTextFixture.hidden)),
      );
    },
  );
}

final class _ForgedBoundary implements SupportSessionHistoryBoundary {}
