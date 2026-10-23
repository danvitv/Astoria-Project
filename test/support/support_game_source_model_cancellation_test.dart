import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/support_text_context_repo.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';

import 'helpers/support_game_source_native_fixture.dart';
import 'helpers/support_model_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'settled mutation requires new emitter/preview and fresh exact H text at actual wire',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model;
        final oldEmitter = m.emitter();
        final old = m.send(from: oldEmitter);
        final oldPreview = await m.preview(old);
        final settle = f.begin(messageIds: {GameSourceNativeFixture.selected});
        await f.replaceSelectedText(
          'Fresh selected source after accepted mutation',
        );
        settle();
        expect((await old.finished).saved, isTrue);
        expect(oldEmitter.isCurrent, isFalse);
        expect(old.approve(oldPreview), isNull);
        final send = m.send();
        final preview = await m.preview(send);
        expect(preview.gameMessages, 1);
        expect(
          preview.messages[1].text,
          'Fresh selected source after accepted mutation',
        );
        expect((await send.dispatch(send.approve(preview)!)).saved, isTrue);
        final wire =
            jsonDecode(m.adapters.single.upload!) as Map<String, dynamic>;
        expect(
          (wire['messages'] as List<dynamic>).map(
            (dynamic row) => row['content'],
          ),
          preview.messages.map((row) => row.text),
        );
        expect(
          m.adapters.single.upload,
          isNot(contains('Selected synthetic game text')),
        );
        expect(
          m.adapters.single.upload,
          isNot(contains(ModelProviderFixture.excluded)),
        );
        expect(m.adapters.single.fetches, 1);
      });
    },
  );

  test(
    'raw unobserved source replacement STILL loses exact H admission before actual fetch',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model;
        final send = m.send();
        final preview = await m.preview(send);
        final approval = send.approve(preview)!;
        final user = await m.repo.getMessageById(preview.userMessageId);
        final provenance = await m.repo.getContextBlockById(
          'support.reply_provenance:${preview.replyMessageId}',
        );
        await f.replaceSelectedText(
          'Raw replacement not covered by intent producers',
        );
        // This is NOT an intent-fence claim. Exact SQL freshness remains a separate
        // final gate for bounded raw replacement paths the neutral lane qualifies.
        final result = await send.dispatch(approval);
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
        expect(result.message!.id, preview.replyMessageId);
        expect(result.message!.sessionId, preview.sessionId);
        expect(result.message!.runId, preview.runId);
        expect(await m.repo.getMessageById(preview.userMessageId), user);
        expect(
          await m.repo.getContextBlockById(
            'support.reply_provenance:${preview.replyMessageId}',
          ),
          provenance,
        );
        expect(preview.isCurrent, isFalse);
        expect(send.approve(preview), isNull);
        expect(await send.dispatch(approval), same(result));
        _expectNoActualFetch(m);
      });
    },
  );

  test(
    'quiet subscribed SSE cancels actual token and saves ORIGINAL stopped row/provenance ONCE',
    () async {
      final f = GameSourceNativeFixture();
      f.model.quiet = true;
      await f.run((f) async {
        await f.seedGame();
        final m = f.model;
        final send = m.send();
        final preview = await m.preview(send);
        final before = await m.repo.getContextBlockById(
          'support.reply_provenance:${preview.replyMessageId}',
        );
        final approval = send.approve(preview)!;
        final done = send.dispatch(approval);
        final adapter = await m.adapterCreated.future;
        await adapter.responseListening;
        expect(adapter.native.responseListens, 1);
        expect(adapter.cancelObserved.isCompleted, isFalse);
        m.sql.writes.clear();
        final settle = f.begin(messageIds: {GameSourceNativeFixture.selected});
        expect(preview.isCurrent, isFalse);
        expect(f.runtime.pending, 1);
        await adapter.cancelObserved.future;
        await adapter.native.responseCancelled.future;
        final result = await done;
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.message!.status, 'stopped');
        expect(await send.dispatch(approval), same(result));
        expect(
          (await m.repo.getMessageById(preview.replyMessageId))!.status,
          'stopped',
        );
        expect(
          await m.repo.getContextBlockById(
            'support.reply_provenance:${preview.replyMessageId}',
          ),
          before,
        );
        expect(
          m.sql.writes.where((s) => s.startsWith('UPDATE "support_messages"')),
          hasLength(1),
        );
        settle();
        settle();
        expect(f.runtime.pending, 0);
        expect(preview.isCurrent, isFalse);
        expect(adapter.fetches, 1);
        expect(adapter.closed, isTrue);
        expect(m.adapters, hasLength(1));
      });
    },
  );

  test(
    'begin during actual emitting SQL read cancels before durable user queue or H load',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model, barrier = f.model.barrier();
        var held = false;
        m.sql.afterSelect = (sql, args) async {
          if (!held && sql.contains('support_sessions')) {
            held = true;
            await barrier.wait();
          }
        };
        m.sql.observations.clear();
        m.sql.writes.clear();
        final send = m.send();
        await barrier.entered.future;
        final settle = f.begin();
        expect(f.runtime.pending, 1);
        barrier.release();
        expect(await send.accepted, isFalse);
        expect((await send.prepared).preview, isNull);
        expect((await send.finished).saved, isFalse);
        expect(m.sql.writes, isEmpty);
        f.expectNoSourceReads();
        settle();
        expect(m.adapters, isEmpty);
      });
    },
  );

  test(
    'begin during actual preparing game read stops after accepted input without preview/HTTP',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model, barrier = f.model.barrier();
        var held = false;
        m.sql.afterSelect = (sql, args) async {
          if (!held && sql.contains('chat_sessions')) {
            held = true;
            await barrier.wait();
          }
        };
        final send = m.send();
        expect(await send.accepted, isTrue);
        await barrier.entered.future;
        final settle = f.begin();
        barrier.release();
        expect((await send.prepared).preview, isNull);
        final result = await send.finished;
        expect(result.accepted, isTrue);
        expect(
          result.saved,
          isFalse,
          reason: 'No reply reservation existed yet.',
        );
        settle();
        expect(m.adapters, isEmpty);
        expect(
          (await m.repo.getMessagesForSession(
            ModelProviderFixture.session,
          )).where((r) => r.runId != null),
          hasLength(1),
        );
      });
    },
  );

  test(
    'waiting before actual fetch loses once approval when selected source begins',
    () async {
      await GameSourceNativeFixture().run((f) async {
        await f.seedGame();
        final m = f.model;
        final send = m.send();
        final preview = await m.preview(send);
        final approval = send.approve(preview)!;
        final user = await m.repo.getMessageById(preview.userMessageId);
        final provenance = await m.repo.getContextBlockById(
          'support.reply_provenance:${preview.replyMessageId}',
        );
        final barrier = m.barrier();
        var held = false;
        m.sql.afterSelect = (sql, args) async {
          if (!held && sql.contains('support_sessions')) {
            held = true;
            await barrier.wait();
          }
        };
        final result = send.dispatch(approval);
        await barrier.entered.future;
        final settle = f.begin();
        barrier.release();
        final finished = await result;
        expect(finished.accepted, isTrue);
        expect(finished.saved, isTrue);
        expect(finished.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
        expect((await send.finished).message!.status, 'stopped');
        expect(finished.message!.id, preview.replyMessageId);
        expect(finished.message!.sessionId, preview.sessionId);
        expect(finished.message!.runId, preview.runId);
        expect(
          (await m.repo.getMessageById(preview.replyMessageId))!.status,
          'stopped',
        );
        expect(await m.repo.getMessageById(preview.userMessageId), user);
        expect(
          await m.repo.getContextBlockById(
            'support.reply_provenance:${preview.replyMessageId}',
          ),
          provenance,
        );
        settle();
        expect(preview.isCurrent, isFalse);
        expect(send.approve(preview), isNull);
        expect(await send.dispatch(approval), same(await send.finished));
        _expectNoActualFetch(m);
      });
    },
  );

  for (final exact in [false, true]) {
    test(
      'same support/game SID ${exact ? 'multi-ID' : 'whole-source'} collision cancels WITHOUT revoking settlement',
      () async {
        final f = GameSourceNativeFixture();
        f.model.quiet = true;
        await f.run((f) async {
          await f.seedGame(sessionId: ModelProviderFixture.session);
          final m = f.model;
          final send = m.send();
          final preview = await m.preview(send);
          final provenance = await m.repo.getContextBlockById(
            'support.reply_provenance:${preview.replyMessageId}',
          );
          final done = send.dispatch(send.approve(preview)!);
          final adapter = await m.adapterCreated.future;
          await adapter.responseListening;
          final settle = f.begin(
            sessionId: ModelProviderFixture.session,
            messageIds: exact
                ? {
                    GameSourceNativeFixture.selected,
                    preview.userMessageId,
                    preview.replyMessageId,
                  }
                : null,
          );
          await adapter.cancelObserved.future;
          final result = await done;
          expect(result.saved, isTrue);
          expect(result.message!.status, 'stopped');
          expect(
            (await m.repo.getMessageById(preview.userMessageId))!.status,
            'complete',
          );
          expect(
            await m.repo.getContextBlockById(
              'support.reply_provenance:${preview.replyMessageId}',
            ),
            provenance,
          );
          settle();
          expect(adapter.fetches, 1);
        });
      },
    );
  }

  for (final ownId in ['user', 'reply']) {
    test(
      'exact selected game ID equals actual original support $ownId ID; game-only port keeps stopped settlement',
      () async {
        final f = GameSourceNativeFixture();
        f.model.quiet = true;
        await f.run((f) async {
          final collision = 'source-original-$ownId';
          await f.seedGame(
            sessionId: ModelProviderFixture.session,
            messageId: collision,
          );
          final m = f.model;
          // Supplemental REAL service, not a replacement/fake provider. The public
          // deterministic ID seam constructs the otherwise random exact collision.
          // All DB/native/cipher/API/coordinator/custody remain the actual providers.
          final custody = m.container.read(supportModelDatabaseCustodyProvider);
          final ids = ownId == 'user'
              ? [collision, 'source-own-reply', 'source-own-run']
              : ['source-own-user', collision, 'source-own-run'];
          var serial = 0;
          final service = SupportModelService(
            db: m.db,
            writeCipher: m.cipher,
            apiRepo: m.container.read(apiConfigRepoProvider),
            revisions: m.revisions,
            redaction: m.redaction,
            runtime: f.runtime,
            adapterFactory: m.newAdapter,
            isOwnerCurrent: () => custody.alive,
            writes: custody,
            admissionContract: SupportTextAdmissionContract
                .auditedRootSingleConnectionNoBusyHandler,
            newId: () => ids[serial++],
          );
          custody.retain(service);
          SupportModelSubmission? submission;
          try {
            final emission = await service.emitInput(
              controller: Object(),
              uiLifetime: Object(),
              draftRevision: 1,
              text: 'Exact collision native question',
              isEmitterCurrent: () => true,
              isDraftCurrent: () => true,
            );
            expect(emission.intent, isNotNull);
            submission = service.beginSend(emission.intent!);
            expect(await submission.accepted, isTrue);
            final preview = (await submission.prepared).preview!;
            expect(
              ownId == 'user' ? preview.userMessageId : preview.replyMessageId,
              collision,
            );
            final provenance = await m.repo.getContextBlockById(
              'support.reply_provenance:${preview.replyMessageId}',
            );
            final done = service.dispatch(service.approve(preview)!);
            final adapter = await m.adapterCreated.future;
            await adapter.responseListening;
            final settle = f.begin(
              sessionId: ModelProviderFixture.session,
              messageIds: {collision},
            );
            await adapter.cancelObserved.future;
            final result = await done;
            expect(result.saved, isTrue);
            expect(result.message!.status, 'stopped');
            expect(
              await m.repo.getContextBlockById(
                'support.reply_provenance:${preview.replyMessageId}',
              ),
              provenance,
            );
            settle();
            expect(service.approve(preview), isNull);
            expect(adapter.fetches, 1);
          } finally {
            service.dispose();
            await submission?.finished;
            custody.release(service);
          }
        });
      },
    );
  }

  test(
    'retained disposed provider receives game-only invalidation while ORIGINAL terminal write waits',
    () async {
      final f = GameSourceNativeFixture();
      f.model.quiet = true;
      await f.run((f) async {
        await f.seedGame(sessionId: ModelProviderFixture.session);
        final m = f.model;
        final send = m.send();
        final preview = await m.preview(send);
        final done = send.dispatch(send.approve(preview)!);
        final adapter = await m.adapterCreated.future;
        await adapter.responseListening;
        final writes = m.container.read(supportModelDurableWritesProvider);
        final barrier = m.barrier();
        final blocker = writes.enqueue(barrier.wait);
        await barrier.entered.future;
        final oldBridge = m.bridge;
        m.container.invalidate(supportModelUiBridgeProvider);
        expect(m.bridge, isNot(same(oldBridge)));
        await adapter.cancelObserved.future;
        // Old service is disposed but cannot release custody until terminal FIFO
        // unwinds. Colliding IDs must not be routed through support deletion.
        final settle = f.begin(
          sessionId: ModelProviderFixture.session,
          messageIds: {
            GameSourceNativeFixture.selected,
            preview.userMessageId,
            preview.replyMessageId,
          },
        );
        settle();
        barrier.release();
        await blocker;
        final result = await done;
        expect(result.saved, isTrue);
        expect(result.message!.status, 'stopped');
        expect(
          (await m.repo.getMessageById(preview.replyMessageId))!.status,
          'stopped',
        );
        expect(adapter.fetches, 1);
      });
    },
  );

  for (final deletion in ['message', 'session']) {
    test(
      'actual SUPPORT $deletion deletion STILL revokes original settlement',
      () async {
        final f = GameSourceNativeFixture();
        f.model.quiet = true;
        await f.run((f) async {
          await f.seedGame(sessionId: ModelProviderFixture.session);
          final m = f.model;
          final send = m.send();
          final preview = await m.preview(send);
          final done = send.dispatch(send.approve(preview)!);
          final adapter = await m.adapterCreated.future;
          await adapter.responseListening;
          final deletionDone = deletion == 'message'
              ? m.workspace.deleteMessage(preview.replyMessageId)
              : m.workspace.deleteSession(ModelProviderFixture.session);
          final result = await done;
          expect(result.saved, isFalse);
          await deletionDone;
          expect(await m.repo.getMessageById(preview.replyMessageId), isNull);
          expect(adapter.fetches, 1);
        });
      },
    );
  }

  test(
    'actual appDb replacement STILL revokes old original terminal custody',
    () async {
      final f = GameSourceNativeFixture();
      f.model.quiet = true;
      await f.run((f) async {
        await f.seedGame();
        final m = f.model;
        final send = m.send();
        final preview = await m.preview(send);
        final done = send.dispatch(send.approve(preview)!);
        final adapter = await m.adapterCreated.future;
        await adapter.responseListening;
        await m.replaceDatabase();
        expect((await done).saved, isFalse);
        expect(
          (await m.repo.getMessageById(preview.replyMessageId))!.status,
          'pending',
        );
        expect(adapter.fetches, 1);
      });
    },
  );
}

/// ROOT admission prepares the private adapter BEFORE final source reads.
/// Refusal may therefore own an adapter, but must never invoke its actual fetch.
void _expectNoActualFetch(ModelProviderFixture m) {
  expect(
    m.adapters.fold<int>(0, (total, adapter) => total + adapter.fetches),
    0,
  );
  for (final adapter in m.adapters) {
    expect(adapter.fetches, 0);
    expect(adapter.fetched.isCompleted, isFalse);
    expect(adapter.options, isNull);
    expect(adapter.upload, isNull);
    expect(adapter.native.responseListens, 0);
    expect(adapter.closed, isTrue);
    expect(adapter.native.forceClosed.isCompleted, isTrue);
  }
}
