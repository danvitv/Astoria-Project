import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/models/support_models.dart';

import 'helpers/support_guarded_reply_fixture.dart';

void main() {
  late GuardedReplyFixture f;
  const user = SupportMessage(
    id: 'synthetic-origin-user',
    sessionId: 'synthetic-original-session',
    role: 'user',
    body: 'SYNTHETIC_ORIGINAL_INPUT',
    runId: 'synthetic-run',
    createdAt: 3,
  );
  late SupportReplyReservation settled;
  setUp(() async {
    f = GuardedReplyFixture();
    await f.seed();
    await f.repo.putMessage(user);
    final pending = (await f.reserve())!;
    settled = (
      message: (await f.settle(pending))!,
      provenance: pending.provenance,
    );
  });
  tearDown(() => f.close());

  Future<SupportReplyRegenerationObservation> capture() async =>
      (await f.repo.readReplyForRegeneration(
        expectedReply: settled.message,
        isCurrent: f.isCurrent,
      ))!;
  Future<SupportReplyReservation?> claim(
    SupportReplyRegenerationObservation old, {
    SupportMessage origin = user,
    String attempt = 'synthetic-reattempt',
  }) => f.repo.reserveRegeneratedReply(
    expected: old,
    originatingUser: origin,
    attemptRunId: attempt,
    provenanceJson: '{"synthetic":"fresh"}',
    isCurrent: f.isCurrent,
  );

  test(
    'regeneration replaces in place; user encrypted bytes and order stay exact',
    () async {
      final old = await capture();
      final before = await f.rows();
      final userRow = (await f.db.select(f.db.supportMessages).get())
          .singleWhere((m) => m.id == user.id);
      final parent = before['sessions'];
      final next = (await claim(old))!;
      expect(
        next.message,
        settled.message.copyWith(
          body: '',
          status: 'preparing',
          runId: 'synthetic-reattempt',
        ),
      );
      expect(
        next.provenance,
        old.provenance.copyWith(protectedFactsJson: '{"synthetic":"fresh"}'),
      );
      expect((await f.rows())['sessions'], parent);
      expect(
        (await f.db.select(f.db.supportMessages).get()).singleWhere(
          (m) => m.id == user.id,
        ),
        userRow,
      );
      expect(
        (await f.rows())['messages'],
        hasLength(before['messages']!.length),
      );
      final durable = (await f.settle(next, body: 'New answer'))!;
      expect(durable.id, settled.message.id);
      expect(durable.createdAt, settled.message.createdAt);
      expect(await f.repo.getMessageById(user.id), user);
      // The old attempt can neither settle nor reserve its original create-only ID.
      expect(await f.settle(settled), isNull);
      expect(await f.reserve(), isNull);
    },
  );

  test(
    'concurrent re-reservation has one winner and stale attempt cannot replay',
    () async {
      final old = await capture();
      final results = await Future.wait([
        claim(old),
        claim(old, attempt: 'other-attempt'),
      ]);
      expect(results.whereType<SupportReplyReservation>(), hasLength(1));
      final before = await f.rows();
      expect(await claim(old), isNull);
      expect(await f.rows(), before);
    },
  );

  for (final status in ['error', 'stopped', 'limited']) {
    test(
      'latest terminal $status remains eligible for a fresh in-place attempt',
      () async {
        final terminal = settled.message.copyWith(status: status, body: '');
        await f.repo.putMessage(terminal);
        final observation = (await f.repo.readReplyForRegeneration(
          expectedReply: terminal,
          isCurrent: f.isCurrent,
        ))!;
        expect((await claim(observation))!.message.status, 'preparing');
      },
    );
  }

  for (final change in [
    'body ABA',
    'provenance ABA',
    'newer user',
    'deleted target',
    'changed origin',
    'run reused',
    'stale guard',
  ]) {
    test('regeneration refuses $change without writes', () async {
      final old = await capture();
      var origin = user;
      var attempt = 'synthetic-reattempt';
      switch (change) {
        case 'body ABA':
          await f.repo.putMessage(
            settled.message.copyWith(body: 'Temporary edit'),
          );
          await f.repo.putMessage(settled.message);
        case 'provenance ABA':
          await f.repo.putContextBlock(
            old.provenance.copyWith(protectedFactsJson: '{}'),
          );
          await f.repo.putContextBlock(old.provenance);
        case 'newer user':
          await f.repo.putMessage(
            user.copyWith(id: 'newer-input', createdAt: 9),
          );
        case 'deleted target':
          await f.repo.deleteMessage(settled.message.id);
        case 'changed origin':
          origin = user.copyWith(body: 'Forged input');
        case 'run reused':
          attempt = user.runId!;
        case 'stale guard':
          f.current = false;
      }
      final before = await f.rows();
      expect(await claim(old, origin: origin, attempt: attempt), isNull);
      expect(await f.rows(), before);
    });
  }

  for (final phase in ['encrypt', 'sql']) {
    test(
      'regeneration owner lost during $phase rolls back both rows',
      () async {
        final old = await capture();
        final before = await f.rows();
        final entered = Completer<void>(), release = Completer<void>();
        var paused = false;
        Future<void> pause(String value) async {
          if (paused || !value.contains('support_messages')) return;
          paused = true;
          entered.complete();
          await release.future;
        }

        if (phase == 'encrypt') {
          f.primitive.afterEncrypt = pause;
        } else {
          f.sql.afterWrite = pause;
        }
        final pending = claim(old);
        await entered.future;
        f.current = false;
        release.complete();
        expect(await pending, isNull);
        f.primitive.afterEncrypt = null;
        f.sql.afterWrite = null;
        expect(await f.rows(), before);
      },
    );
  }
}
