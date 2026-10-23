import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_model_projection_checks.dart';
import 'helpers/support_model_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'cancel preview projects only the actual saved original terminal return',
    () async {
      await ModelProviderFixture().run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final order = f.state.activeMessages.map((m) => m.id).toList();
        final barrier = f.barrier();
        final hold = f.container
            .read(supportModelDurableWritesProvider)
            .enqueue(barrier.wait);
        await barrier.entered.future;
        f.sql.writes.clear();
        send.cancelPreview(preview);
        expect(await send.accepted, isTrue);
        expect(send.approve(preview), isNull);
        expect(f.state.activeMessages.last.status, 'pending');
        expect(f.bridge.view.saved, isFalse);
        expect(f.bridge.view.busy, isTrue);
        expect(f.adapters, isEmpty);
        barrier.release();
        await hold;
        await expectStoppedProjection(f, await send.finished, preview, order);
        expect(f.adapters, isEmpty);
      });
    },
  );

  test(
    'quiet Stop updates its reply in place after a newer durable row',
    () async {
      final f = ModelProviderFixture()..quiet = true;
      const partial = 'WITHHELD_PROJECTION_PARTIAL';
      final key = ModelProviderFixture.rowKey;
      final split = key.length ~/ 2;
      final firstDelta = key.substring(0, split);
      final secondDelta = '${key.substring(split)} $partial';
      const sanitized = '${SecretRedactor.removed} $partial';
      // Two SSE deltas, one quiet physical chunk: only whole-buffer sanitation
      // can recognize the known credential spanning the event boundary.
      f.response = () => '${chatDelta(firstDelta)}${chatDelta(secondDelta)}';
      await f.run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final activity = Completer<void>();
        final stopListening = f.bridge.listen(() {
          if (f.bridge.view.phase == SupportModelPhase.activity &&
              !activity.isCompleted) {
            activity.complete();
          }
        });
        final dispatched = send.dispatch(send.approve(preview)!);
        final adapter = await f.adapterCreated.future;
        try {
          await adapter.fetched.future;
          await adapter.responseListening;
          // Activity follows decoder.consume, not fetch/subscription. Both
          // frames in the same chunk finish before this async continuation.
          await activity.future;
        } finally {
          stopListening();
        }
        expect(adapter.native.responseListens, 1);
        expect(adapter.closed, isFalse);
        expect(adapter.native.responseCancelled.isCompleted, isFalse);
        expect(f.bridge.view.phase, SupportModelPhase.activity);
        final reply = (await f.repo.getMessageById(preview.replyMessageId))!;
        expect(reply.status, 'pending');
        expect(reply.body, isEmpty);
        expect(reply.runId, preview.runId);
        expect(reply.sessionId, ModelProviderFixture.session);
        await f.repo.appendMessage(
          SupportMessage(
            id: 'projection-later-row',
            sessionId: ModelProviderFixture.session,
            role: 'system',
            body: 'Later durable native note',
            createdAt: reply.createdAt + 1,
          ),
        );
        await f.workspace.refresh();
        final order = f.state.activeMessages.map((m) => m.id).toList();
        expect(order.last, 'projection-later-row');
        expect(send.isCurrent, isTrue);
        final barrier = f.barrier();
        final hold = f.container
            .read(supportModelDurableWritesProvider)
            .enqueue(barrier.wait);
        await barrier.entered.future;
        final feedsBeforeStop = List.of(f.feeds);
        expect(
          feedsBeforeStop
              .expand((rows) => rows)
              .any(
                (m) => m.id == preview.replyMessageId && m.status == 'pending',
              ),
          isTrue,
        );
        expect(
          feedsBeforeStop
              .expand((rows) => rows)
              .any((m) => m.body.contains(partial)),
          isFalse,
          reason: 'Decoded partial output remains withheld before Stop.',
        );
        expect(await f.repo.getMessageById(preview.replyMessageId), reply);
        f.sql.writes.clear();
        send.stop();
        await adapter.cancelObserved.future;
        await adapter.native.responseCancelled.future;
        await f.container.pump();
        expect(f.bridge.view.saved, isFalse);
        expect(f.bridge.view.busy, isTrue);
        expect(await f.repo.getMessageById(preview.replyMessageId), reply);
        expect(
          f.feeds.expand((rows) => rows).any((m) => m.body.contains(partial)),
          isFalse,
          reason:
              'Stop cannot paint a result while its terminal write is held.',
        );
        expect(
          f.sql.writes.where(
            (sql) =>
                sql.startsWith('UPDATE') && sql.contains('support_messages'),
          ),
          isEmpty,
        );
        final feedsBeforeTerminal = f.feeds.length;
        barrier.release();
        await hold;
        final result = await dispatched;
        expect(await send.finished, same(result));
        await adapter.cancelObserved.future;
        expect(adapter.closed, isTrue);
        expect(adapter.fetches, 1);
        await expectStoppedProjection(f, result, preview, order);
        expect(f.state.activeMessages.last.body, 'Later durable native note');
        final message = result.message!;
        final durable = (await f.repo.getMessageById(preview.replyMessageId))!;
        expect(result.outcome!.status, PrivateTextStatus.stopped);
        expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
        expect(result.outcome!.text, sanitized);
        expect(message.text, sanitized);
        expect(message.id, reply.id);
        expect(message.sessionId, reply.sessionId);
        expect(message.runId, reply.runId);
        expect(message.role, reply.role);
        expect(message.createdAt, reply.createdAt);
        expect(durable, reply.copyWith(body: sanitized, status: 'stopped'));
        expect(f.bridge.view.saved, isTrue);
        expect(f.bridge.view.status, PrivateTextStatus.stopped);
        final terminalReplies = f.feeds
            .skip(feedsBeforeTerminal)
            .expand((rows) => rows)
            .where(
              (m) => m.id == preview.replyMessageId && m.status != 'pending',
            )
            .toList();
        expect(terminalReplies, isNotEmpty);
        for (final item in terminalReplies) {
          expect(item.status, message.status);
          expect(item.body, message.text);
          expect(item.id, message.id);
          expect(item.sessionId, message.sessionId);
          expect(item.runId, message.runId);
          expect(item.role.name, message.role);
          expect(item.createdAt.millisecondsSinceEpoch, message.createdAt);
          expect(item.cards, isEmpty);
        }
        expect(
          f.feeds
              .expand((rows) => rows)
              .where(
                (m) => const {
                  'preparing',
                  'running',
                  'pending',
                }.contains(m.status),
              )
              .any((m) => m.body.contains(partial)),
          isFalse,
          reason: 'Only the actual saved sanitized terminal DTO may expose it.',
        );
        for (final item
            in f.feeds
                .expand((rows) => rows)
                .where((m) => m.id == preview.replyMessageId)) {
          if (const {'preparing', 'running', 'pending'}.contains(item.status)) {
            expect(item.body, isEmpty);
          } else {
            expect(item.status, 'stopped');
            expect(item.body, sanitized);
          }
        }
        final durableMessages = await f.repo.getMessagesForSession(
          ModelProviderFixture.session,
        );
        final encryptedMessages = {
          for (final row in await f.db.select(f.db.supportMessages).get())
            row.id: row.toJson(),
        };
        for (final canary in [key, ModelProviderFixture.secret]) {
          for (final item in f.feeds.expand((rows) => rows)) {
            expect(item.body, isNot(contains(canary)));
          }
          expect(message.text, isNot(contains(canary)));
          expect(result.outcome!.text, isNot(contains(canary)));
          for (final row in durableMessages) {
            expect(row.body, isNot(contains(canary)));
          }
          expect(encryptedMessages.toString(), isNot(contains(canary)));
        }
      });
    },
  );

  for (final retire in [
    'session',
    'provider',
    'native-epoch',
    'disposed-owner',
  ]) {
    test(
      '$retire suppresses old result projection without inventing durable settlement',
      () async {
        await ModelProviderFixture().run((f) async {
          final send = f.send();
          final preview = await f.preview(send);
          final barrier = f.barrier();
          final hold = f.container
              .read(supportModelDurableWritesProvider)
              .enqueue(barrier.wait);
          await barrier.entered.future;
          send.cancelPreview(preview);
          switch (retire) {
            case 'session':
              f.workspace.selectSession(ModelProviderFixture.otherSession);
              await f.workspace
                  .refresh(); // Current display read sees pending before terminal.
            case 'provider':
              f.container.invalidate(supportModelUiBridgeProvider);
              f.bridge;
            case 'native-epoch':
              f.container.read(supportNativeRuntimeProvider).invalidateLease();
            case 'disposed-owner':
              f.disposed = true;
              f.container.dispose();
          }
          final feeds = f.feeds.length;
          barrier.release();
          await hold;
          final result = await send.finished;
          expect(result.accepted, isTrue);
          expect(result.saved, !f.disposed);
          if (f.disposed) {
            // Whole-container disposal revokes the original DB custody as well.
            expect(result.message, isNull);
          } else {
            expect(result.message!.status, 'stopped');
          }
          expect(
            (await f.repo.getMessageById(preview.replyMessageId))!.status,
            f.disposed ? 'pending' : 'stopped',
          );
          expect(
            f.feeds.length,
            feeds,
            reason: 'No old capture publication after retirement.',
          );
          if (!f.disposed) {
            expect(f.bridge.view.saved, isFalse);
            expect(
              f.state.messagesBySession[ModelProviderFixture.session]!
                  .singleWhere((m) => m.id == preview.replyMessageId)
                  .status,
              'pending',
            );
          }
          expect(f.adapters, isEmpty);
        });
      },
    );
  }

  for (final failure in ['cipher', 'changed-run', 'unknown-status']) {
    test(
      'failed $failure terminal never paints stopped or unchecked error text',
      () async {
        await ModelProviderFixture().run((f) async {
          final send = f.send();
          final preview = await f.preview(send);
          final order = f.state.activeMessages.map((m) => m.id).toList();
          const canary = 'RAW_PROJECTION_TERMINAL_ERROR_58179';
          if (failure == 'cipher') {
            f.primitive.afterEncrypt = (aad) async {
              if (aad.contains('support_messages')) throw StateError(canary);
            };
          } else {
            final reply = (await f.repo.getMessageById(
              preview.replyMessageId,
            ))!;
            await f.repo.putMessage(
              reply.copyWith(
                runId: failure == 'changed-run'
                    ? 'projection-wrong-run'
                    : reply.runId,
                status: failure == 'unknown-status' ? canary : reply.status,
              ),
            );
          }
          send.cancelPreview(preview);
          final result = await send.finished;
          expect(await send.accepted, isTrue);
          expect(result.saved, isFalse);
          expect(result.message, isNull);
          expect(result.reason, SupportModelRefusal.settlementFailed);
          expect(f.state.activeMessages.map((m) => m.id), order);
          expect(f.bridge.view.saved, isFalse);
          expect(f.bridge.view.busy, isFalse);
          expect(f.bridge.view.label, isNot(contains(canary)));
          expect(
            f.feeds
                .expand((rows) => rows)
                .where((m) => m.id == preview.replyMessageId)
                .every((m) => m.status == 'pending' && m.body.isEmpty),
            isTrue,
          );
          expect(f.adapters, isEmpty);
        });
      },
    );
  }
}
