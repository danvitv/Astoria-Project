import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';

import 'helpers/support_native_input_fixture.dart';

void main() {
  late NativeInputFixture f;
  late SupportMessage user;
  setUp(() async {
    f = NativeInputFixture();
    await f.seed();
    user = (await f.append())!;
  });
  tearDown(() {
    f.clearHooks();
    return f.close();
  });

  Future<SupportUnansweredUserObservation> capture() async => (await f.repo
      .readUnansweredUser(expectedUser: user, isCurrent: f.isCurrent))!;
  Future<SupportReplyReservation?> claim(
    SupportUnansweredUserObservation observation, {
    String attempt = 'fresh-retry-run',
    String id = 'retry-assistant',
  }) => f.repo.reserveUnansweredReply(
    expected: observation,
    message: NativeInputFixture.reply.copyWith(id: id, runId: attempt),
    provenanceJson: NativeInputFixture.provenance,
    isCurrent: f.isCurrent,
  );

  test(
    'unanswered retry creates only one new assistant/provenance; exact user and parent bytes stay',
    () async {
      final observation = await capture();
      final original = await f.row(user.id);
      final parent = await f.parentRow();
      final rows = await f.db.select(f.db.supportMessages).get();
      final context = await f.db.select(f.db.supportContextBlocks).get();
      f.observe();
      final next = (await claim(observation))!;
      expect(next.message.role, 'assistant');
      expect(next.message.runId, 'fresh-retry-run');
      expect(next.message.createdAt, greaterThan(user.createdAt));
      expect(next.provenance.id, 'support.reply_provenance:retry-assistant');
      expect(await f.row(user.id), original);
      expect(await f.parentRow(), parent);
      expect(await f.repo.getMessageById(user.id), user);
      expect(
        await f.db.select(f.db.supportMessages).get(),
        hasLength(rows.length + 1),
      );
      expect(
        await f.db.select(f.db.supportContextBlocks).get(),
        hasLength(context.length + 1),
      );
      expect(
        f.primitive.decryptAads.where(
          (aad) => aad.contains(NativeInputFixture.oldId),
        ),
        isEmpty,
      );
      expect(
        f.primitive.decryptAads.where(
          (aad) => aad.contains('synthetic-foreign-body'),
        ),
        isEmpty,
      );
      final settled = await f.repo.settleReply(
        expected: next,
        status: 'complete',
        body: 'New answer',
        isCurrent: f.isCurrent,
      );
      expect(settled!.id, next.message.id);
      expect(await f.row(user.id), original);
      expect(
        await f.repo.readUnansweredUser(
          expectedUser: user,
          isCurrent: f.isCurrent,
        ),
        isNull,
      );
    },
  );

  test(
    'two unanswered claims with different IDs have one winner, never duplicate the user',
    () async {
      final observation = await capture();
      final results = await Future.wait([
        claim(observation),
        claim(observation, attempt: 'second-retry-run', id: 'second-assistant'),
      ]);
      expect(results.whereType<SupportReplyReservation>(), hasLength(1));
      final before = await f.snapshot();
      expect(
        await claim(observation, attempt: 'third-run', id: 'third-assistant'),
        isNull,
      );
      expect(await f.snapshot(), before);
      expect(
        (await f.db.select(f.db.supportMessages).get()).where(
          (m) => m.id == user.id,
        ),
        hasLength(1),
      );
    },
  );

  for (final change in [
    'changed body',
    'body ABA',
    'parent ABA',
    'deleted user',
    'newer user',
    'newer system',
    'timestamp tie',
    'invalid tail metadata',
    'locked body',
    'stale guard',
    'original run reused',
  ]) {
    test(
      'unanswered claim refuses $change without writing any table',
      () async {
        final observation = await capture();
        var attempt = 'fresh-retry-run';
        switch (change) {
          case 'changed body':
            await f.repo.putMessage(user.copyWith(body: 'Changed'));
          case 'body ABA':
            await f.repo.putMessage(user.copyWith(body: 'Temporary'));
            await f.repo.putMessage(user);
          case 'parent ABA':
            final parent = (await f.repo.getSessionById(user.sessionId))!;
            await f.repo.putSession(parent.copyWith(title: 'Temporary'));
            await f.repo.putSession(parent);
          case 'deleted user':
            await f.repo.deleteMessage(user.id);
          case 'newer user':
            await f.repo.putMessage(
              user.copyWith(id: 'later-user', createdAt: user.createdAt + 1),
            );
          case 'newer system':
            await f.repo.putMessage(
              user.copyWith(
                id: 'later-system',
                role: 'system',
                createdAt: user.createdAt + 1,
              ),
            );
          case 'timestamp tie':
            await f.repo.putMessage(user.copyWith(id: 'tied-user'));
          case 'invalid tail metadata':
            await f.db.customStatement(
              'UPDATE support_messages SET created_at = 0.5 WHERE id = ?',
              [NativeInputFixture.oldId],
            );
          case 'locked body':
            await f.db.customStatement(
              'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
              ['corrupt', user.id],
            );
          case 'stale guard':
            f.current = false;
          case 'original run reused':
            attempt = user.runId!;
        }
        final before = await f.snapshot();
        expect(await claim(observation, attempt: attempt), isNull);
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final selection in [
    'legacy',
    'locked selection',
    'wrong role',
    'pending',
    'wrong session',
    'forged body',
  ]) {
    test('unanswered observation refuses $selection before claiming', () async {
      var selected = user;
      switch (selection) {
        case 'legacy':
          selected = user.copyWith(clearRunId: true);
          await f.repo.putMessage(selected);
        case 'locked selection':
          selected = user.copyWith(isLocked: true);
        case 'wrong role':
          selected = user.copyWith(role: 'assistant');
        case 'pending':
          selected = user.copyWith(status: 'pending');
        case 'wrong session':
          selected = user.copyWith(sessionId: NativeInputFixture.foreignId);
        case 'forged body':
          selected = user.copyWith(body: 'Forged');
      }
      final before = await f.snapshot();
      expect(
        await f.repo.readUnansweredUser(
          expectedUser: selected,
          isCurrent: f.isCurrent,
        ),
        isNull,
      );
      expect(await f.snapshot(), before);
    });
  }

  for (final phase in ['encrypt', 'assistant SQL', 'provenance SQL']) {
    test(
      'unanswered retry retirement during $phase rolls back actual reservation',
      () async {
        final observation = await capture();
        final before = await f.snapshot();
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        Future<void> pause(String text) async {
          final target = phase == 'provenance SQL'
              ? 'support_context_blocks'
              : 'support_messages';
          if (entered.isCompleted || !text.contains(target)) return;
          entered.complete();
          await release.future;
        }

        if (phase == 'encrypt') {
          f.primitive.afterEncrypt = pause;
        } else {
          f.sql.afterWrite = pause;
        }
        final pending = claim(observation);
        await entered.future;
        f.current = false;
        release.complete();
        expect(await pending, isNull);
        f.clearHooks();
        expect(await f.snapshot(), before);
      },
    );
  }
}
