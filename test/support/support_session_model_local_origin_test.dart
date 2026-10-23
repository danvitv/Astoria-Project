import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_view.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_card_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_send_service.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_store.dart';

import 'helpers/support_model_provider_fixture.dart';
import 'support_session_model_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  sessionModelTest(
    'actual native workspace help atomically owns fixed local origin; later whole-own model accepts it',
    (f) async {
      await f.readableOwnHistory();
      const current = 'Настрой провайдера, SYNTHETIC_USER_ONLY_103';
      expect(await f.workspace.sendLocalHelp(current), isTrue);
      final rows = await f.repo.getMessagesForSession(
        ModelProviderFixture.session,
      );
      expect(rows, hasLength(2));
      final user = rows.first;
      final reply = rows.last;
      expect(user.role, 'user');
      expect(reply.role, 'assistant');
      expect(reply.status, 'complete');
      expect(reply.runId, user.runId);
      expect(reply.runId, isNotNull);
      expect(reply.createdAt, greaterThan(user.createdAt));
      expect(reply.body, isNot(contains(current)));
      expect(reply.cardsJson, isNot(contains(current)));
      expect(const SupportCardCodec().decode(reply.cardsJson), isNotEmpty);
      final recipe = await f.recipeFor(reply.id);
      expect(recipe.currentUserMessageId, user.id);
      expect(recipe.replyMessageId, reply.id);
      expect(recipe.runId, user.runId);
      expect(recipe.originalRanges, isEmpty);
      expect(recipe.directReplies, isEmpty);
      final raw = await (f.db.select(
        f.db.supportMessages,
      )..where((t) => t.id.equals(reply.id))).getSingle();
      expect(raw.bodyCiphertext, isNot(contains(reply.body)));
      expect(raw.cardsCiphertext, isNot(contains('Настройка провайдера')));
      expect(f.adapters, isEmpty);
      await f.wholeScope(own: true);
      final send = f.send(text: 'Synthetic later model question');
      final preview = await f.preview(send);
      expect(preview.supportMessages, 2);
      expect(preview.gameMessages, 0);
      expect(preview.messages.where((m) => m.text == current), hasLength(1));
      expect(preview.messages.where((m) => m.text == reply.body), hasLength(1));
      final result = await send.dispatch(send.approve(preview)!);
      expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
      expect(f.adapters.single.fetches, 1);
      expect(
        f.adapters.single.upload,
        isNot(contains('support.model_provenance')),
      );
      expect(f.adapters.single.upload, isNot(contains('providerSetup')));
    },
  );

  for (final failure in [
    'reply-insert',
    'origin-insert',
    'settle',
    'cards-encrypt',
    'parent-update',
  ]) {
    sessionModelTest(
      'native LOCAL $failure failure leaves durable USER only, no incomplete/fake origin',
      (f) async {
        await f.readableOwnHistory();
        var replyPhase = false;
        final published = <SupportMessageItem>[];
        var acceptedUser = 0, acceptedReply = 0, inspections = 0;
        f.sql.afterWrite = (statement) async {
          if (!replyPhase) return;
          final shouldFail = switch (failure) {
            'reply-insert' => statement.startsWith(
              'INSERT INTO "support_messages"',
            ),
            'origin-insert' => statement.startsWith(
              'INSERT INTO "support_context_blocks"',
            ),
            'settle' => statement.startsWith('UPDATE "support_messages"'),
            'parent-update' => statement.startsWith(
              'UPDATE "support_sessions"',
            ),
            _ => false,
          };
          if (shouldFail) {
            throw StateError('Synthetic local append SQL failure');
          }
        };
        f.primitive.afterEncrypt = (aad) async {
          if (replyPhase &&
              failure == 'cards-encrypt' &&
              aad.endsWith('|cards_ciphertext')) {
            throw StateError('Synthetic local cards AEAD failure');
          }
        };
        final sender = SupportWorkspaceSendService(
          store: f.workspaceStore,
          isCurrent: () => true,
          publish: (item) {
            published.add(item);
            if (item.role == SupportMessageRole.user) replyPhase = true;
          },
          acceptUser: () => acceptedUser++,
          acceptReply: () => acceptedReply++,
          inspectConnection: (_, _) async {
            inspections++;
            return false;
          },
        );
        await expectLater(
          sender.send(
            ModelProviderFixture.session,
            text: 'Помоги настроить тему',
          ),
          throwsA(isA<SupportReplyUnavailable>()),
        );
        f.sql.afterWrite = null;
        f.primitive.afterEncrypt = null;
        expect(acceptedUser, 1);
        expect(acceptedReply, 0);
        expect(
          inspections,
          0,
        ); // Preserve catalog's setup-without-inspection change.
        expect(published, hasLength(1));
        final rows = await f.repo.getMessagesForSession(
          ModelProviderFixture.session,
        );
        expect(rows, hasLength(1));
        expect(rows.single.role, 'user');
        final blocks = await f.repo.getContextBlocksForSession(
          ModelProviderFixture.session,
        );
        expect(
          blocks.where((b) => b.id.startsWith('support.reply_provenance:')),
          isEmpty,
        );
        expect(f.adapters, isEmpty);
      },
    );
  }

  sessionModelTest(
    'native local origin must match exact durable USER, no foreign/replaced origin',
    (f) async {
      await f.readableOwnHistory();
      final user = await f.workspaceStore.appendNativeLocalUser(
        ModelProviderFixture.session,
        'Synthetic origin',
        runId: 'synthetic-local-run',
        isCurrent: () => true,
      );
      final reply = SupportMessageItem(
        id: 'synthetic-local-reply',
        sessionId: ModelProviderFixture.otherSession,
        role: SupportMessageRole.assistant,
        body: 'Fixed synthetic response',
        createdAt: DateTime.fromMillisecondsSinceEpoch(20, isUtc: true),
      );
      await expectLater(
        f.workspaceStore.appendNativeLocalReply(
          reply,
          originatingUser: user,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(await f.repo.getMessageById(reply.id), isNull);
      expect(
        await f.repo.getContextBlockById(
          'support.reply_provenance:${reply.id}',
        ),
        isNull,
      );
      await f.repo.mutateMessage(
        messageId: user.id,
        mutate: (m) => m.copyWith(body: 'Changed original'),
      );
      final ownReply = SupportMessageItem(
        id: reply.id,
        sessionId: user.sessionId,
        role: reply.role,
        body: reply.body,
        createdAt: reply.createdAt,
      );
      await expectLater(
        f.workspaceStore.appendNativeLocalReply(
          ownReply,
          originatingUser: user,
          isCurrent: () => true,
        ),
        throwsStateError,
      );
      expect(await f.repo.getMessageById(reply.id), isNull);
      expect(
        await f.repo.getContextBlockById(
          'support.reply_provenance:${reply.id}',
        ),
        isNull,
      );
    },
  );

  sessionModelTest(
    'native local retirement DURING provenance encryption rolls back both rows, no replacement paint',
    (f) async {
      await f.readableOwnHistory();
      var current = true;
      final painted = <SupportMessageItem>[];
      var acceptedUser = 0, acceptedReply = 0;
      f.primitive.afterEncrypt = (aad) async {
        if (aad.contains('|support.reply_provenance:') &&
            aad.endsWith('|protected_facts_ciphertext')) {
          current = false;
        }
      };
      final sender = SupportWorkspaceSendService(
        store: f.workspaceStore,
        isCurrent: () => current,
        publish: painted.add,
        acceptUser: () => acceptedUser++,
        acceptReply: () => acceptedReply++,
        inspectConnection: (_, _) async => false,
      );
      await expectLater(
        sender.send(
          ModelProviderFixture.session,
          text: 'Synthetic native help',
        ),
        throwsA(isA<SupportReplyUnavailable>()),
      );
      f.primitive.afterEncrypt = null;
      expect(acceptedUser, 1);
      expect(acceptedReply, 0);
      expect(painted, hasLength(1));
      final rows = await f.repo.getMessagesForSession(
        ModelProviderFixture.session,
      );
      expect(rows, hasLength(1));
      expect(
        (await f.repo.getContextBlocksForSession(
          ModelProviderFixture.session,
        )).where((b) => b.id.startsWith('support.reply_provenance:')),
        isEmpty,
      );
    },
  );

  sessionModelTest(
    'native local durable commit survives immediate UI retirement without replacement paint',
    (f) async {
      await f.readableOwnHistory();
      var current = true;
      final store = _RetiringLocalStore(f, () => current = false);
      final painted = <SupportMessageItem>[];
      var acceptedUser = 0, acceptedReply = 0;
      await SupportWorkspaceSendService(
        store: store,
        isCurrent: () => current,
        publish: painted.add,
        acceptUser: () => acceptedUser++,
        acceptReply: () => acceptedReply++,
        inspectConnection: (_, _) async => false,
      ).send(ModelProviderFixture.session, text: 'Synthetic native help');
      expect(acceptedUser, 1);
      expect(acceptedReply, 0); // Retired topic cannot be consumed or painted.
      expect(painted, hasLength(1));
      final rows = await f.repo.getMessagesForSession(
        ModelProviderFixture.session,
      );
      expect(rows, hasLength(2));
      final recipe = await f.recipeFor(rows.last.id);
      expect(recipe.currentUserMessageId, rows.first.id);
      expect(rows.last.status, 'complete');
      expect(f.adapters, isEmpty);
    },
  );

  sessionModelTest(
    'topic-only legacy reply receives no invented USER or origin; later whole refuses it',
    (f) async {
      await f.readableOwnHistory();
      expect(await f.workspace.triggerQuickAction('theme_setup'), isTrue);
      final rows = await f.repo.getMessagesForSession(
        ModelProviderFixture.session,
      );
      expect(rows, hasLength(1));
      expect(rows.single.role, 'assistant');
      expect(rows.single.runId, isNull);
      expect(
        await f.repo.getContextBlockById(
          'support.reply_provenance:${rows.single.id}',
        ),
        isNull,
      );
      await f.wholeScope(own: true);
      final send = f.send();
      expect(
        (await send.prepared).reason,
        SupportModelRefusal.lineageUnavailable,
      );
      expect(f.adapters, isEmpty);
      await send.finished;
    },
  );
}

/// Only an AFTER-durable-return observation is overridden. The real production
/// append/AEAD/transaction runs unchanged; no synthetic success is fabricated.
final class _RetiringLocalStore extends SupportWorkspaceStore {
  _RetiringLocalStore(ModelProviderFixture f, this.afterCommit)
    : super(f.repo, () => f.redaction.redactor);
  final void Function() afterCommit;
  @override
  Future<SupportMessageItem> appendNativeLocalReply(
    SupportMessageItem item, {
    required SupportMessageItem originatingUser,
    required bool Function() isCurrent,
  }) async {
    final durable = await super.appendNativeLocalReply(
      item,
      originatingUser: originatingUser,
      isCurrent: isCurrent,
    );
    afterCommit();
    return durable;
  }
}
