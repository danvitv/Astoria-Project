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

  Future<SupportUserEditingObservation> capture([
    SupportMessage? selected,
  ]) async => (await f.repo.readUserForEditing(
    expectedUser: selected ?? user,
    isCurrent: f.isCurrent,
  ))!;
  Future<SupportMessage?> edit(
    SupportUserEditingObservation observed, [
    String body = 'Edited wording',
  ]) => f.repo.editUserMessage(
    expected: observed,
    body: body,
    isCurrent: f.isCurrent,
  );

  for (final dependency in [
    'native answer',
    'checkpoint',
    'orphaned provenance',
  ]) {
    test(
      'user edit refuses $dependency without changing the existing question or history',
      () async {
        final observed = await capture();
        if (dependency == 'native answer') {
          await f.repo.putMessage(
            SupportMessage(
              id: 'dependent-answer',
              sessionId: user.sessionId,
              role: 'assistant',
              body: 'Answer to the original wording',
              runId: 'dependent-native-run',
              createdAt: user.createdAt + 1,
            ),
          );
        } else {
          final checkpoint = dependency == 'checkpoint';
          await f.repo.putContextBlock(
            SupportContextBlock(
              id: checkpoint
                  ? 'dependent-checkpoint'
                  : 'support.reply_provenance:missing-answer',
              sessionId: user.sessionId,
              startMessageId: checkpoint ? user.id : 'missing-answer',
              endMessageId: checkpoint ? user.id : 'missing-answer',
              summary: 'Original history',
              protectedFactsJson: '{}',
              isActive: checkpoint,
              createdAt: user.createdAt + 1,
            ),
          );
        }
        final before = await f.snapshot();
        expect(
          await f.repo.readUserForEditing(
            expectedUser: user,
            isCurrent: f.isCurrent,
          ),
          isNull,
        );
        expect(await edit(observed), isNull);
        expect(await f.snapshot(), before);
      },
    );
  }

  for (final legacy in [false, true]) {
    test(
      'user edit preserves metadata/cards/later answer/provenance and every other table; legacy=$legacy',
      () async {
        if (legacy) user = user.copyWith(clearRunId: true);
        user = user.copyWith(cardsJson: '["synthetic-retained-card"]');
        await f.repo.putMessage(user);
        await f.repo.putMessage(
          SupportMessage(
            id: 'later-answer',
            sessionId: user.sessionId,
            role: 'assistant',
            body: 'Existing local answer stays',
            createdAt: user.createdAt + 1,
          ),
        );
        await f.repo.putContextBlock(
          SupportContextBlock(
            id: 'unrelated-local-context',
            sessionId: user.sessionId,
            startMessageId: '',
            endMessageId: '',
            summary: '',
            protectedFactsJson: '{"old":"dependent provenance"}',
            isActive: false,
            createdAt: user.createdAt + 1,
          ),
        );
        final observation = await capture();
        final raw = (await f.row(user.id))!;
        final before = await f.snapshot();
        final next = (await edit(observation, '  New user wording  '))!;
        expect(next, user.copyWith(body: '  New user wording  '));
        final written = (await f.row(user.id))!;
        expect(written.copyWith(bodyCiphertext: raw.bodyCiphertext), raw);
        // Normalize ONLY the changed ciphertext for an exact full-table comparison.
        await f.db.customStatement(
          'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
          [raw.bodyCiphertext, user.id],
        );
        expect(await f.snapshot(), before);
        await f.db.customStatement(
          'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
          [written.bodyCiphertext, user.id],
        );
        final fresh = await capture(next);
        final afterEdit = await f.snapshot();
        expect(await edit(observation), isNull);
        expect(await f.snapshot(), afterEdit);
        expect(await edit(fresh, ''), isNull);
        expect(await f.snapshot(), afterEdit);
      },
    );
  }

  for (final change in [
    'body ABA',
    'parent ABA',
    'deleted',
    'changed role',
    'changed run',
    'locked ciphertext',
    'stale guard',
  ]) {
    test('user edit refuses $change and preserves all current bytes', () async {
      final observation = await capture();
      switch (change) {
        case 'body ABA':
          await f.repo.putMessage(user.copyWith(body: 'Temporary'));
          await f.repo.putMessage(user);
        case 'parent ABA':
          final parent = (await f.repo.getSessionById(user.sessionId))!;
          await f.repo.putSession(parent.copyWith(title: 'Temporary'));
          await f.repo.putSession(parent);
        case 'deleted':
          await f.repo.deleteMessage(user.id);
        case 'changed role':
          await f.repo.putMessage(user.copyWith(role: 'assistant'));
        case 'changed run':
          await f.repo.putMessage(user.copyWith(runId: 'changed-run'));
        case 'locked ciphertext':
          await f.db.customStatement(
            'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
            ['corrupt', user.id],
          );
        case 'stale guard':
          f.current = false;
      }
      final before = await f.snapshot();
      expect(await edit(observation), isNull);
      expect(await f.snapshot(), before);
    });
  }

  for (final selection in [
    'wrong session',
    'wrong role',
    'locked selection',
    'wrong body',
    'corrupt body',
    'corrupt parent',
    'invalid timestamp',
    'invalid run',
  ]) {
    test(
      'user editing observation refuses $selection without writes',
      () async {
        var selected = user;
        switch (selection) {
          case 'wrong session':
            selected = user.copyWith(sessionId: NativeInputFixture.foreignId);
          case 'wrong role':
            selected = user.copyWith(role: 'assistant');
          case 'locked selection':
            selected = user.copyWith(isLocked: true);
          case 'wrong body':
            selected = user.copyWith(body: 'Forged');
          case 'corrupt body':
            await f.db.customStatement(
              'UPDATE support_messages SET body_ciphertext = ? WHERE id = ?',
              ['corrupt', user.id],
            );
          case 'corrupt parent':
            await f.db.customStatement(
              'UPDATE support_sessions SET title_ciphertext = ? WHERE id = ?',
              ['corrupt', user.sessionId],
            );
          case 'invalid timestamp':
            await f.db.customStatement(
              'UPDATE support_messages SET created_at = 0.5 WHERE id = ?',
              [user.id],
            );
          case 'invalid run':
            selected = user.copyWith(runId: '');
            await f.repo.putMessage(selected);
        }
        final before = await f.snapshot();
        expect(
          await f.repo.readUserForEditing(
            expectedUser: selected,
            isCurrent: f.isCurrent,
          ),
          isNull,
        );
        expect(await f.snapshot(), before);
      },
    );
  }

  test(
    'user edit rejects blank, oversized and invalid Unicode text without changing bytes',
    () async {
      final observation = await capture();
      final before = await f.snapshot();
      for (final body in [
        '',
        ' \n ',
        List.filled(8193, 'x').join(),
        '\uD800',
      ]) {
        expect(await edit(observation, body), isNull);
        expect(await f.snapshot(), before);
      }
      expect(
        (await edit(observation, List.filled(8192, 'x').join()))!.body.length,
        8192,
      );
    },
  );

  test('two edits of the same observation have one durable winner', () async {
    final observation = await capture();
    final results = await Future.wait([
      edit(observation, 'A'),
      edit(observation, 'B'),
    ]);
    expect(results.whereType<SupportMessage>(), hasLength(1));
    expect(
      await f.repo.getMessageById(user.id),
      results.whereType<SupportMessage>().single,
    );
  });

  for (final status in [
    'preparing',
    'pending',
    'stopped',
    'error',
    'limited',
  ]) {
    test(
      'editing preserves sound user status $status; retry still requires complete',
      () async {
        user = user.copyWith(status: status);
        await f.repo.putMessage(user);
        final observation = await capture();
        expect(await edit(observation), user.copyWith(body: 'Edited wording'));
        final edited = (await f.repo.getMessageById(user.id))!;
        expect(
          await f.repo.readUnansweredUser(
            expectedUser: edited,
            isCurrent: f.isCurrent,
          ),
          isNull,
        );
      },
    );
  }

  for (final phase in ['encrypt', 'SQL', 'mapped return']) {
    test(
      'user edit retirement during $phase rolls back exact original bytes',
      () async {
        final observation = await capture();
        final before = await f.snapshot();
        final entered = Completer<void>(), release = Completer<void>();
        addTearDown(() {
          if (!release.isCompleted) release.complete();
        });
        var provisionalWrite = false;
        Future<void> pause(String text) async {
          if (entered.isCompleted || !text.contains('support_messages')) return;
          entered.complete();
          await release.future;
        }

        if (phase == 'encrypt') {
          f.primitive.afterEncrypt = pause;
        } else if (phase == 'SQL') {
          f.sql.afterWrite = pause;
        } else {
          f.sql.afterWrite = (sql) async {
            if (sql.startsWith('UPDATE "support_messages"'))
              provisionalWrite = true;
          };
          f.primitive.beforeDecrypt = (aad) async {
            if (provisionalWrite) await pause(aad);
          };
        }
        final pending = edit(observation);
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
