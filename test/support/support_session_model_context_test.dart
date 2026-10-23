import 'dart:convert';

import 'package:drift/drift.dart' show Value;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';

import 'helpers/support_model_provider_fixture.dart';
import 'support_session_model_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  sessionModelTest(
    'whole own owned EMPTY history enters actual ROOT; current input once; once wire',
    (f) async {
      await f.readableOwnHistory();
      await f.wholeScope(own: true);
      final send = f.send(text: 'SYNTHETIC_CURRENT_OWN_INPUT');
      final preview = await f.preview(send);
      expect(preview.supportMessages, 0);
      expect(preview.gameMessages, 0);
      expect(
        preview.messages.where((m) => m.text == 'SYNTHETIC_CURRENT_OWN_INPUT'),
        hasLength(1),
      );
      final recipe = await f.recipeFor(preview.replyMessageId);
      expect(recipe.originalRanges, isEmpty); // NOT an empty wildcard source.
      expect(recipe.directReplies, isEmpty);
      final approval = send.approve(preview)!;
      f.sql.observations.clear();
      final result = await send.dispatch(approval);
      expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
      expect(result.saved, isTrue);
      expect(await send.dispatch(approval), same(result));
      expect(f.adapters.single.fetches, 1);
      expect(
        f.adapters.single.upload,
        isNot(contains('support.model_provenance')),
      );
      // Decisive empty-custody control: only the WHOLE snapshot revalidation
      // reruns this native boundary membership discovery inside actual ROOT.
      final membership = f.sql.observations.where(
        (o) => o.statement.contains('AS before_current'),
      );
      expect(membership, isNotEmpty);
      expect(
        membership.every((o) => o.rows.every((r) => r['before_current'] == 0)),
        isTrue,
      );
      // This new later request includes the actual earlier USER/reply exactly once.
      final next = f.send(text: 'SYNTHETIC_LATER_OWN_INPUT');
      final later = await f.preview(next);
      expect(later.supportMessages, 2);
      expect(
        later.messages.where((m) => m.text == 'SYNTHETIC_CURRENT_OWN_INPUT'),
        hasLength(1),
      );
      expect(
        later.messages.where((m) => m.text == 'Safe synthetic answer'),
        hasLength(1),
      );
      expect(
        later.messages.where((m) => m.text == 'SYNTHETIC_LATER_OWN_INPUT'),
        hasLength(1),
      );
      expect(
        (await f.recipeFor(
          later.replyMessageId,
        )).originalRanges.single.orderedMessageIds,
        [preview.userMessageId, preview.replyMessageId],
      );
      next.stop();
      await next.finished;
    },
  );

  sessionModelTest(
    'whole game fresh unseen IDs cannot extend OLD approval; fresh later preview/wire',
    (f) async {
      await f.seedWholeGame();
      await f.wholeScope(game: true);
      final old = f.send();
      final oldPreview = await f.preview(old);
      expect(oldPreview.gameMessages, 1);
      final approval = old.approve(oldPreview)!;
      await f.replaceWholeGame([
        {
          'id': 'game-old',
          'role': 'user',
          'content': sessionModelGameBody,
          'timestamp': 1,
        },
        {
          'id': 'brand-new-unseen',
          'role': 'assistant',
          'content': sessionModelFutureBody,
          'timestamp': 2,
        },
        {
          'id': 'game-hidden',
          'role': 'assistant',
          'content': sessionModelHiddenBody,
          'timestamp': 3,
          'isHidden': true,
        },
      ]);
      final refused = await old.dispatch(approval);
      expect(refused.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
      expect(f.adapters.single.fetches, 0);
      final fresh = f.send();
      final preview = await f.preview(fresh);
      expect(preview.gameMessages, 2);
      expect(
        (await f.recipeFor(
          preview.replyMessageId,
        )).originalRanges.single.orderedMessageIds,
        ['game-old', 'brand-new-unseen'],
      );
      final result = await fresh.dispatch(fresh.approve(preview)!);
      expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
      expect(f.adapters.last.fetches, 1);
      expect(f.adapters.last.upload, contains(sessionModelFutureBody));
      expect(f.adapters.last.upload, isNot(contains(sessionModelHiddenBody)));
    },
  );

  for (final control in [
    'all',
    'game-local-OFF',
    'game-model-OFF',
    'foreign-origin',
  ]) {
    sessionModelTest(
      'whole grants retain exact materialized inherited origins: $control',
      (f) async {
        await f.readableOwnHistory();
        await f.seedWholeGame();
        await f.seedGameDerived(
          originGame: control == 'foreign-origin'
              ? 'foreign-game'
              : sessionModelGame,
        );
        await f.wholeScope(
          own: true,
          game: true,
          gameLocal: control != 'game-local-OFF',
          gameModel: control != 'game-model-OFF',
        );
        f.sql.observations.clear();
        f.primitive.decryptAads.clear();
        final send = f.send();
        final prepared = await send.prepared;
        if (control == 'all') {
          final preview = prepared.preview!;
          expect(preview.supportMessages, 2);
          expect(preview.gameMessages, 1);
          final result = await send.dispatch(send.approve(preview)!);
          expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
          expect(f.adapters.single.fetches, 1);
          expect(f.adapters.single.upload, contains(sessionModelGameBody));
          final stored = await f.recipeFor('derived-reply');
          expect(stored.originalRanges.single.orderedMessageIds, ['game-old']);
        } else {
          expect(prepared.preview, isNull);
          expect(
            prepared.reason,
            control == 'game-local-OFF'
                ? SupportModelRefusal.historyDenied
                : SupportModelRefusal.lineageUnavailable,
          );
          expect(f.adapters, isEmpty);
          await send.finished;
          if (control == 'game-local-OFF') {
            expect(
              f.sql.observations.where(
                (o) => o.statement.contains('json_each'),
              ),
              isEmpty,
            );
            expect(
              f.primitive.decryptAads.where(
                (a) => a.contains('|derived-reply|'),
              ),
              isEmpty,
            );
          }
          if (control == 'game-model-OFF') {
            expect(
              f.sql.observations.where(
                (o) => o.statement.contains('json_each'),
              ),
              isEmpty,
            );
          }
        }
      },
    );
  }

  sessionModelTest(
    'unknown OLD local assistant remains fail-closed, no own-history fallback',
    (f) async {
      await f.wholeScope(own: true);
      final send = f.send();
      final prepared = await send.prepared;
      expect(prepared.preview, isNull);
      expect(prepared.reason, SupportModelRefusal.lineageUnavailable);
      expect(
        await f.repo.getContextBlockById(
          'support.reply_provenance:old-excluded',
        ),
        isNull,
      );
      expect(f.adapters, isEmpty);
      await send.finished;
    },
  );

  sessionModelTest(
    'session selection with model right OFF loads neither own history nor game',
    (f) async {
      await f.seedWholeGame();
      await f.wholeScope(
        own: true,
        game: true,
        ownModel: false,
        gameModel: false,
      );
      f.primitive.decryptAads.clear();
      f.sql.observations.clear();
      final send = f.send();
      final preview = await f.preview(send);
      expect(preview.supportMessages, 0);
      expect(preview.gameMessages, 0);
      expect(
        f.primitive.decryptAads.where((a) => a.contains('|old-excluded|')),
        isEmpty,
      );
      expect(
        f.sql.observations.where((o) => o.statement.contains('json_each')),
        isEmpty,
      );
      send.stop();
      await send.finished;
    },
  );

  for (final failure in ['corrupt', 'oversize', 'missing-parent']) {
    sessionModelTest(
      'whole source refuses $failure instead of pretending empty/partial',
      (f) async {
        await f.seedWholeGame();
        await f.wholeScope(game: true);
        if (failure == 'missing-parent') {
          await (f.db.delete(
            f.db.characters,
          )..where((t) => t.charId.equals('session-model-character'))).go();
        } else {
          await (f.db.update(
            f.db.chatSessions,
          )..where((t) => t.sessionId.equals(sessionModelGame))).write(
            ChatSessionsCompanion(
              messagesJson: Value(
                failure == 'corrupt'
                    ? '[{"id":"duplicate","id":"duplicate","role":"user","content":"bad"}]'
                    : jsonEncode(
                        List.generate(
                          513,
                          (i) => {
                            'id': 'too-many-$i',
                            'role': 'user',
                            'content': 'Synthetic',
                            'timestamp': i,
                          },
                        ),
                      ),
              ),
            ),
          );
        }
        final send = f.send();
        final prepared = await send.prepared;
        expect(prepared.preview, isNull);
        expect(
          prepared.reason,
          failure == 'oversize'
              ? SupportModelRefusal.tooLarge
              : SupportModelRefusal.stale,
        );
        expect(f.adapters, isEmpty);
        await send.finished;
      },
    );
  }

  sessionModelTest(
    'Stop during whole-own pure body decrypt preserves durable USER without reopening',
    (f) async {
      await f.readableOwnHistory();
      await f.repo.appendCurrentUser(
        message: const SupportMessage(
          id: 'whole-old-user',
          sessionId: ModelProviderFixture.session,
          role: 'user',
          body: 'Synthetic earlier input',
          runId: 'old-run',
          createdAt: 3,
        ),
        isCurrent: () => true,
      );
      await f.wholeScope(own: true);
      final barrier = f.barrier();
      f.primitive.beforeDecrypt = (aad) async {
        if (aad.contains('|whole-old-user|')) await barrier.wait();
      };
      final send = f.send();
      expect(await send.accepted, isTrue);
      await barrier.entered.future;
      send.stop();
      final result = await send.finished;
      expect(result.accepted, isTrue);
      expect(result.saved, isFalse);
      expect(f.adapters, isEmpty);
      f.primitive.beforeDecrypt = null;
      barrier.release();
    },
  );

  sessionModelTest(
    'whole own empty original preview cannot rebase after queued source write',
    (f) async {
      await f.readableOwnHistory();
      await f.wholeScope(own: true);
      final send = f.send();
      final preview = await f.preview(send);
      expect(preview.supportMessages, 0);
      final approval = send.approve(preview)!;
      await f.repo.appendMessage(
        const SupportMessage(
          id: 'late-support-user',
          sessionId: ModelProviderFixture.session,
          role: 'user',
          body: 'Newly committed future input',
          createdAt: 9999999999999,
        ),
      );
      final result = await send.dispatch(approval);
      expect(result.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
      expect(f.adapters.single.fetches, 0);
      expect(f.adapters.single.upload, isNull);
    },
  );

  sessionModelTest(
    'whole preview factory reentry cannot renew original Stop custody or fetch',
    (f) async {
      await f.readableOwnHistory();
      await f.wholeScope(own: true);
      late SupportModelUiSend send;
      f.response = () {
        // Executed inside the original injected adapter constructor, not a
        // provider/issuer replacement or a fabricated fetch checkpoint.
        send.stop();
        return '';
      };
      send = f.send();
      final preview = await f.preview(send);
      final approval = send.approve(preview)!;
      final result = await send.dispatch(approval);
      expect(result.accepted, isTrue);
      expect(result.saved, isTrue);
      expect(result.message!.id, preview.replyMessageId);
      expect(result.message!.status, 'stopped');
      expect(result.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
      expect(f.adapters.single.fetches, 0);
      expect(await send.dispatch(approval), same(result));
    },
  );
}
