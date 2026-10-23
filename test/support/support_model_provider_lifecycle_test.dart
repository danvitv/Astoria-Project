import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_dependencies.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_workspace_provider.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_model_provider_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final invalidation in [
    'draft-ABA',
    'controller-replaced',
    'UI-retired',
    'provider-replaced',
  ]) {
    test(
      'actual emitted $invalidation before awaited emission cannot rebind or append',
      () async {
        await ModelProviderFixture().run((f) async {
          final barrier = f.barrier();
          var revision = 1, originalController = true, paused = false;
          final controller = Object(), lifetime = Object();
          final emitter = f.emitter(
            controller: controller,
            lifetime: lifetime,
            current: () => originalController,
          );
          f.primitive.beforeDecrypt = (_) async {
            if (!paused) {
              paused = true;
              await barrier.wait();
            }
          };
          final send = f.send(
            from: emitter,
            revision: revision,
            draftCurrent: () => revision == 1,
          );
          await barrier.entered.future;
          switch (invalidation) {
            case 'draft-ABA':
              revision++; // A→B
              revision++; // B→A, same text is NOT the original emitted revision.
            case 'controller-replaced':
              originalController = false;
            case 'UI-retired':
              emitter.retire();
            case 'provider-replaced':
              f.container.invalidate(supportModelUiBridgeProvider);
              expect(
                f.bridge,
                isNotNull,
              ); // Explicit replacement, not a late rebind.
          }
          barrier.release();
          expect(await send.accepted, isFalse);
          expect((await send.prepared).preview, isNull);
          expect((await send.finished).accepted, isFalse);
          expect(f.adapters, isEmpty);
          expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
        });
      },
    );
  }

  test(
    'retained retired issuer and false synchronous emitter predicate cause zero reads/HTTP',
    () async {
      await ModelProviderFixture().run((f) async {
        final emitter = f.emitter();
        f.container.invalidate(supportModelUiBridgeProvider);
        f.bridge;
        f.sql.observations.clear();
        final old = f.send(from: emitter);
        final rejected = f.send(from: f.emitter(current: () => false));
        expect((await old.finished).reason, SupportModelRefusal.stale);
        expect((await rejected.finished).reason, SupportModelRefusal.stale);
        expect(f.sql.observations, isEmpty);
        expect(f.adapters, isEmpty);
      });
    },
  );

  test(
    'displayed emitter intrinsically binds original session/lifetime, rejecting selection ABA before a retained Send callback',
    () async {
      await ModelProviderFixture().run((f) async {
        final oldEmitter = f.emitter(current: () => true);
        f.workspace.selectSession(ModelProviderFixture.otherSession);
        f.workspace.selectSession(ModelProviderFixture.session);
        await f.workspace.refresh();
        f.sql.observations.clear();
        expect(oldEmitter.isCurrent, isFalse);
        final send = f.send(from: oldEmitter);
        expect((await send.finished).reason, SupportModelRefusal.stale);
        expect(await send.accepted, isFalse);
        expect(
          f.sql.observations,
          isEmpty,
          reason:
              'Reject emitted target before any awaited source/config read.',
        );
        expect(f.adapters, isEmpty);
      });
    },
  );

  test(
    'same-turn duplicate claim starts one actual append, not two concurrent emissions',
    () async {
      await ModelProviderFixture().run((f) async {
        final emitter = f.emitter();
        final first = f.send(from: emitter);
        final duplicate = f.send(from: emitter);
        expect((await duplicate.finished).reason, SupportModelRefusal.busy);
        final preview = await f.preview(first);
        first.cancelPreview(preview);
        expect((await first.finished).saved, isTrue);
        expect(
          f.state.activeMessages.where(
            (m) => m.role == SupportMessageRole.user,
          ),
          hasLength(1),
        );
        expect(f.adapters, isEmpty);
      });
    },
  );

  test(
    'new draft AFTER durable acceptance does not cancel immutable native question',
    () async {
      await ModelProviderFixture().run((f) async {
        var revision = 1;
        final send = f.send(
          text: 'Original approved text',
          draftCurrent: () => revision == 1,
        );
        expect(await send.accepted, isTrue);
        revision += 2; // New typing/ABA after acceptance is independent.
        final preview = await f.preview(send);
        expect(preview.messages.last.text, 'Original approved text');
        final result = await send.dispatch(send.approve(preview)!);
        expect(result.saved, isTrue);
        expect(f.adapters.single.upload, contains('Original approved text'));
      });
    },
  );

  test(
    'Stop during preparing before user append finishes rolls back and never allocates replacement work',
    () async {
      await ModelProviderFixture().run((f) async {
        final barrier = f.barrier();
        var paused = false;
        f.sql.afterSelect = (sql, _) async {
          if (!paused && sql.contains('MAX(created_at)')) {
            paused = true;
            await barrier.wait();
          }
        };
        final send = f.send();
        await barrier.entered.future;
        send.stop();
        barrier.release();
        expect(await send.accepted, isFalse);
        expect((await send.finished).accepted, isFalse);
        expect(f.adapters, isEmpty);
        expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
      });
    },
  );

  test(
    'Stop during exact selected preparation retains committed user while late pure crypto cannot resume SQL',
    () async {
      await ModelProviderFixture().run((f) async {
        await f.repo.putMessage(
          const SupportMessage(
            id: 'selected-history',
            sessionId: ModelProviderFixture.session,
            role: 'user',
            body: 'Exact selected body',
            createdAt: 3,
          ),
        );
        await f.grantHistory(
          SupportPermissionScope(
            selectionRevision: 1,
            supportHistory: SupportMessageSelection(['selected-history']),
          ),
          [SupportPermission.modelSupportHistory],
        );
        final barrier = f.barrier();
        var paused = false;
        f.primitive.beforeDecrypt = (aad) async {
          if (!paused && aad.contains('|selected-history|')) {
            paused = true;
            await barrier.wait();
          }
        };
        final send = f.send();
        expect(await send.accepted, isTrue);
        await barrier.entered.future;
        send.stop();
        final result = await send.finished;
        expect(result.accepted, isTrue);
        expect(result.saved, isFalse);
        expect(f.adapters, isEmpty);
        final reads = f.sql.observations.length;
        barrier.release();
        await f.container.pump();
        expect(
          f.sql.observations.length,
          reads,
          reason: 'Late PURE decrypt has no SQL continuation.',
        );
      });
    },
  );

  test(
    'quiet native SSE is outside FIFO; Stop cancels exact adapter and preserves accepted user',
    () async {
      final f = ModelProviderFixture()..quiet = true;
      f.response = () => chatDelta('WITHHELD_SAFE_PARTIAL');
      await f.run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final dispatched = send.dispatch(send.approve(preview)!);
        final adapter = await f.adapterCreated.future;
        await adapter.fetched.future;
        expect(
          await f.workspace.renameSession(
            ModelProviderFixture.session,
            'Local durable rename',
          ),
          isTrue,
          reason: 'HTTP cannot monopolize durable FIFO.',
        );
        expect(f.state.isBusy, isFalse);
        expect(
          f.feeds
              .expand((rows) => rows)
              .any((m) => m.body.contains('WITHHELD_SAFE_PARTIAL')),
          isFalse,
        );
        send.stop();
        final result = await dispatched;
        await send.finished;
        await adapter.cancelObserved.future;
        expect(adapter.closed, isTrue);
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.message!.status, 'stopped');
        expect(f.adapters, hasLength(1));
        expect(f.bridge.view.busy, isFalse);
      });
    },
  );

  test(
    'old Stop and old preview cancel cannot affect a later quiet request on the same issuer',
    () async {
      final f = ModelProviderFixture()..quiet = true;
      await f.run((f) async {
        final emitter = f.emitter();
        final old = f.send(from: emitter);
        final oldPreview = await f.preview(old);
        old.cancelPreview(oldPreview);
        await old.finished;
        final next = f.send(
          from: emitter,
          text: 'Next exact question',
          revision: 2,
        );
        final preview = await f.preview(next);
        final dispatched = next.dispatch(next.approve(preview)!);
        final adapter = await f.adapterCreated.future;
        await adapter.fetched.future;
        old.stop();
        old.cancelPreview(oldPreview);
        expect(next.isCurrent, isTrue);
        expect(adapter.cancelObserved.isCompleted, isFalse);
        next.stop();
        await dispatched;
        await next.finished;
        await adapter.cancelObserved.future;
      });
    },
  );

  for (final invalidate in [
    'selection-ABA',
    'bridge-provider',
    'workspace-provider',
    'native-controller',
    'native-runtime',
    'API-config',
    'import',
    'permission',
  ]) {
    test(
      '$invalidate retires captured preview but original valid DB settlement survives',
      () async {
        await ModelProviderFixture().run((f) async {
          final send = f.send();
          final preview = await f.preview(send);
          final originalOrder = f.state.activeMessages
              .map((m) => m.id)
              .toList();
          switch (invalidate) {
            case 'selection-ABA':
              f.workspace.selectSession(ModelProviderFixture.otherSession);
              f.workspace.selectSession(ModelProviderFixture.session);
            case 'bridge-provider':
              f.container.invalidate(supportModelUiBridgeProvider);
              f.bridge;
            case 'workspace-provider':
              f.container.invalidate(supportWorkspaceProvider);
              f.workspace;
            case 'native-controller':
              f.container.invalidate(supportNativeConsentControllerProvider);
              f.bridge;
            case 'native-runtime':
              f.container.invalidate(supportNativeRuntimeProvider);
              f.bridge;
            case 'API-config':
              await f.container
                  .read(apiConfigRepoProvider)
                  .put(f.api.copyWith(temperature: 1.8));
            case 'import':
              final registry = f.revisions;
              final settle = registry
                  .beginMutation(); // Actual outer import fence.
              settle();
            case 'permission':
              final runtime = f.container.read(supportNativeRuntimeProvider);
              runtime
                  .invalidateLease(); // Same native admission used by toggles.
          }
          expect(preview.isCurrent, isFalse);
          expect(send.approve(preview), isNull);
          final result = await send.finished;
          expect(result.accepted, isTrue);
          expect(
            result.saved,
            isTrue,
            reason: 'Reactive retirement is not original DB destruction.',
          );
          final durable = await f.repo.getMessageById(preview.replyMessageId);
          expect(durable!.status, 'stopped');
          expect(f.adapters, isEmpty);
          await f.workspace.refresh();
          f.workspace.selectSession(ModelProviderFixture.session);
          await f.workspace.refresh();
          expect(f.state.activeMessages.map((m) => m.id), originalOrder);
          expect(f.state.activeMessages.last.status, 'stopped');
        });
      },
    );
  }

  test(
    'key rotation retires original preview, fresh confirmed receiver uses ONLY current row key',
    () async {
      await ModelProviderFixture().run((f) async {
        final old = f.send();
        final oldPreview = await f.preview(old);
        final originalReply = (await f.repo.getMessageById(
          oldPreview.replyMessageId,
        ))!;
        final originalUser = (await f.repo.getMessageById(
          oldPreview.userMessageId,
        ))!;
        final provenanceId =
            'support.reply_provenance:${oldPreview.replyMessageId}';
        final originalProvenance = await f.repo.getContextBlockById(
          provenanceId,
        );
        expect(originalProvenance, isNotNull);
        const rotated = 'SYNTHETIC_PROVIDER_ROTATED_KEY_98576';
        f.api = f.api.copyWith(
          apiKey: rotated,
          endpoint: 'https://rotated.invalid/v1/chat/completions',
        );
        await f.container.read(apiConfigRepoProvider).put(f.api);
        expect(oldPreview.isCurrent, isFalse);
        expect(old.approve(oldPreview), isNull);
        final stopped = await old.finished;
        expect(stopped.accepted, isTrue);
        expect(stopped.saved, isTrue);
        expect(stopped.message!.id, oldPreview.replyMessageId);
        expect(stopped.message!.sessionId, oldPreview.sessionId);
        expect(stopped.message!.runId, oldPreview.runId);
        expect(stopped.message!.status, 'stopped');
        expect(stopped.message!.text, isEmpty);
        expect(
          await f.repo.getMessageById(oldPreview.replyMessageId),
          originalReply.copyWith(status: 'stopped', body: ''),
        );
        expect(
          await f.repo.getMessageById(oldPreview.userMessageId),
          originalUser,
        );
        expect(
          await f.repo.getContextBlockById(provenanceId),
          originalProvenance,
        );
        expect(f.adapters, isEmpty, reason: 'Old preview never reached fetch.');
        await f.confirmRecipient();
        await f.container.pump();
        final fresh = f.send();
        final preview = await f.preview(fresh);
        final result = await fresh.dispatch(fresh.approve(preview)!);
        expect(result.saved, isTrue);
        expect(f.adapters, hasLength(1));
        expect(f.adapters.single.fetches, 1);
        expect(
          f.adapters.single.options!.headers['Authorization'],
          'Bearer $rotated',
        );
        expect(f.adapters.single.options!.uri.host, 'rotated.invalid');
        expect(f.adapters.single.options!.uri.toString(), f.api.endpoint);
        expect(
          await f.container.read(apiConfigRepoProvider).getById(f.api.id),
          f.api,
        );
        for (final key in [
          rotated,
          ModelProviderFixture.rowKey,
          ModelProviderFixture.staleVaultKey,
        ]) {
          expect(f.adapters.single.upload, isNot(contains(key)));
        }
        await f.vault.useSecret(ApiConfigCredentialAdapter.llmSlot(f.api.id), (
          value,
        ) async {
          expect(value, ModelProviderFixture.staleVaultKey);
        });
      });
    },
  );

  for (final target in ['user', 'reply', 'session', 'selected-history']) {
    test(
      'synchronous $target deletion fencing precedes queued deletion and cannot resurrect originals',
      () async {
        await ModelProviderFixture().run((f) async {
          if (target == 'selected-history') {
            await f.repo.putMessage(
              const SupportMessage(
                id: 'selected-history',
                sessionId: ModelProviderFixture.session,
                role: 'user',
                body: 'Selected text',
                createdAt: 3,
              ),
            );
            await f.grantHistory(
              SupportPermissionScope(
                selectionRevision: 1,
                supportHistory: SupportMessageSelection(['selected-history']),
              ),
              [SupportPermission.modelSupportHistory],
            );
            await f.workspace.refresh();
          }
          final send = f.send();
          final preview = await f.preview(send);
          final barrier = f.barrier();
          final hold = f.container
              .read(supportModelDurableWritesProvider)
              .enqueue(barrier.wait);
          await barrier.entered.future;
          final id = switch (target) {
            'user' => preview.userMessageId,
            'reply' => preview.replyMessageId,
            _ => 'selected-history',
          };
          final deletion = target == 'session'
              ? f.workspace.deleteSession(ModelProviderFixture.session)
              : f.workspace.deleteMessage(id);
          expect(
            preview.isCurrent,
            isFalse,
            reason: 'Must fence synchronously BEFORE deletion can enter FIFO.',
          );
          expect(send.approve(preview), isNull);
          barrier.release();
          await hold;
          expect(await deletion, isTrue);
          final result = await send.finished;
          expect(result.accepted, isTrue);
          expect(f.adapters, isEmpty);
          if (target == 'session') {
            expect(
              await f.repo.getSessionById(ModelProviderFixture.session),
              isNull,
            );
            expect(await f.repo.getMessageById(preview.replyMessageId), isNull);
          } else {
            expect(await f.repo.getMessageById(id), isNull);
          }
          if (target != 'selected-history') expect(result.saved, isFalse);
        });
      },
    );
  }

  test(
    'provider disposal during queued terminal write keeps original custody and suppresses replacement publication',
    () async {
      await ModelProviderFixture().run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final barrier = f.barrier();
        final hold = f.container
            .read(supportModelDurableWritesProvider)
            .enqueue(barrier.wait);
        await barrier.entered.future;
        send.stop();
        f.container.invalidate(supportModelUiBridgeProvider);
        final fresh = f.bridge;
        expect(fresh.view.preview, isNull);
        barrier.release();
        await hold;
        final result = await send.finished;
        expect(result.saved, isTrue);
        expect(
          (await f.repo.getMessageById(preview.replyMessageId))!.status,
          'stopped',
        );
        expect(fresh.view.preview, isNull);
        expect(
          fresh.view.saved,
          isFalse,
          reason: 'Old completion cannot paint a fresh issuer.',
        );
      });
    },
  );

  test(
    'real original data-owner retirement revokes terminal settlement, unlike selection/service replacement',
    () async {
      await ModelProviderFixture().run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final custody = f.container.read(supportModelDatabaseCustodyProvider);
        custody.revoke(); // Explicit ORIGINAL data-owner destruction boundary.
        expect((await send.finished).saved, isFalse);
        expect(
          (await f.repo.getMessageById(preview.replyMessageId))!.status,
          'pending',
        );
        expect(f.adapters, isEmpty);
      });
    },
  );

  test(
    'actual appDb replacement revokes original settlement before queued terminal write and never paints new workspace',
    () async {
      await ModelProviderFixture().run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final barrier = f.barrier();
        final hold = f.container
            .read(supportModelDurableWritesProvider)
            .enqueue(barrier.wait);
        await barrier.entered.future;
        send.stop();
        await f.replaceDatabase();
        expect(preview.isCurrent, isFalse);
        barrier.release();
        await hold;
        expect((await send.finished).saved, isFalse);
        expect(
          (await f.repo.getMessageById(preview.replyMessageId))!.status,
          'pending',
        );
        await f.workspace.refresh();
        expect(f.state.sessions, isEmpty);
        expect(f.state.activeMessages, isEmpty);
        expect(f.bridge.view.saved, isFalse);
        expect(f.adapters, isEmpty);
      });
    },
  );

  for (final failure in ['user-append', 'terminal']) {
    test(
      'actual cipher $failure failure preserves separate acceptance and does not publish speculative saved text',
      () async {
        await ModelProviderFixture().run((f) async {
          SupportModelUiSend send;
          SupportModelPreview? preview;
          if (failure == 'terminal') {
            send = f.send();
            preview = await f.preview(send);
          } else {
            send = f.send();
          }
          f.primitive.afterEncrypt = (aad) async {
            if (aad.contains('support_messages')) {
              throw StateError('RAW_SYNTHETIC_CIPHER_ERROR_9281');
            }
          };
          if (preview != null) await send.dispatch(send.approve(preview)!);
          final result = await send.finished;
          expect(await send.accepted, failure == 'terminal');
          expect(result.accepted, failure == 'terminal');
          expect(result.saved, isFalse);
          expect(
            result.reason,
            failure == 'terminal'
                ? SupportModelRefusal.settlementFailed
                : SupportModelRefusal.appendFailed,
          );
          expect(
            f.bridge.view.label,
            isNot(contains('RAW_SYNTHETIC_CIPHER_ERROR')),
          );
          if (preview != null) {
            expect(
              (await f.repo.getMessageById(preview.replyMessageId))!.status,
              'pending',
            );
            expect(f.state.activeMessages.last.body, isEmpty);
            expect(f.bridge.view.saved, isFalse);
          } else {
            expect(f.adapters, isEmpty);
            expect(
              f.state.activeMessages.where((m) => m.runId != null),
              isEmpty,
            );
          }
        });
      },
    );
  }

  test(
    'terminal projection replaces reply in stable position even after a newer durable row',
    () async {
      final f = ModelProviderFixture()..quiet = true;
      await f.run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final dispatched = send.dispatch(send.approve(preview)!);
        final adapter = await f.adapterCreated.future;
        await adapter.fetched.future;
        final reply = await f.repo.getMessageById(preview.replyMessageId);
        await f.repo.appendMessage(
          SupportMessage(
            id: 'later-local-row',
            sessionId: ModelProviderFixture.session,
            role: 'system',
            body: 'Later native note',
            createdAt: reply!.createdAt + 1,
          ),
        );
        await f.workspace.refresh();
        final before = f.state.activeMessages.map((m) => m.id).toList();
        expect(before.last, 'later-local-row');
        send.stop();
        expect((await dispatched).saved, isTrue);
        await send.finished;
        expect(f.state.activeMessages.map((m) => m.id), before);
        expect(
          f.state.activeMessages
              .singleWhere((m) => m.id == preview.replyMessageId)
              .status,
          'stopped',
        );
        for (final feed in f.feeds) {
          expect(feed.map((m) => m.id).toSet().length, feed.length);
          final user = feed.indexWhere((m) => m.id == preview.userMessageId);
          final reply = feed.indexWhere((m) => m.id == preview.replyMessageId);
          if (reply >= 0) expect(user, inInclusiveRange(0, reply - 1));
        }
      });
    },
  );

  test(
    'retiring original owning UI lifetime stops its quiet native token without relying on provider disposal',
    () async {
      final f = ModelProviderFixture()..quiet = true;
      await f.run((f) async {
        final emitter = f.emitter();
        final send = f.send(from: emitter);
        final preview = await f.preview(send);
        final dispatched = send.dispatch(send.approve(preview)!);
        final adapter = await f.adapterCreated.future;
        await adapter.fetched.future;
        await adapter.responseListening;
        expect(adapter.native.responseListens, 1);
        emitter.retire();
        expect((await dispatched).saved, isTrue);
        await send.finished;
        await adapter.cancelObserved.future;
        expect(adapter.closed, isTrue);
        expect(f.adapters, hasLength(1));
        expect(adapter.fetches, 1);
        expect(f.bridge.view.preview, isNull);
        expect(f.bridge.view.busy, isFalse);
        expect(
          (await f.repo.getMessageById(preview.replyMessageId))!.status,
          'stopped',
        );
      });
    },
  );

  test(
    'owning UI retirement at actual fetch-start retains conservative early-admission failure, not quiet SSE evidence',
    () async {
      final f = ModelProviderFixture()..quiet = true;
      await f.run((f) async {
        final emitter = f.emitter();
        final send = f.send(from: emitter);
        final preview = await f.preview(send);
        final dispatched = send.dispatch(send.approve(preview)!);
        final adapter = await f.adapterCreated.future;
        await adapter.fetched.future;
        // Original early schedule: actual fetch invocation is established, but
        // no release/header/subscription barrier has been awaited here.
        emitter.retire();
        final result = await dispatched;
        expect(await send.finished, same(result));
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.outcome!.dispatch, PrivateTextDispatch.admittedFailed);
        expect(result.outcome!.status, PrivateTextStatus.error);
        expect(result.message!.status, 'error');
        expect(result.message!.text, isEmpty);
        expect(
          (await f.repo.getMessageById(preview.replyMessageId))!.status,
          'error',
        );
        await adapter.cancelObserved.future;
        expect(adapter.closed, isTrue);
        expect(f.adapters, hasLength(1));
        expect(adapter.fetches, 1, reason: 'Actual dispatch was nonzero.');
        expect(f.bridge.view.preview, isNull);
        expect(f.bridge.view.busy, isFalse);
      });
    },
  );

  test(
    'original terminal settlement is not queued behind a retired broad workspace display read',
    () async {
      await ModelProviderFixture().run((f) async {
        final send = f.send();
        final preview = await f.preview(send);
        final barrier = f.barrier();
        var paused = false;
        f.primitive.beforeDecrypt = (aad) async {
          if (!paused && aad.contains('|old-excluded|')) {
            paused = true;
            await barrier.wait();
          }
        };
        final reload = f.workspace.refresh();
        await barrier.entered.future;
        f.workspace.selectSession(ModelProviderFixture.otherSession);
        final result =
            await send.finished; // MUST finish while display remains gated.
        expect(result.saved, isTrue);
        expect(barrier.released, isFalse);
        expect(
          (await f.repo.getMessageById(preview.replyMessageId))!.status,
          'stopped',
        );
        barrier.release();
        await reload;
        f.workspace.selectSession(ModelProviderFixture.session);
        await f.workspace.refresh();
        expect(
          f.state.activeMessages
              .singleWhere((m) => m.id == preview.replyMessageId)
              .status,
          'stopped',
          reason: 'Stale broad reload cannot replace a newer terminal row.',
        );
        expect(f.adapters, isEmpty);
      });
    },
  );

  test(
    'current selected credential priming during emission retires original issuer, never rebinds after await',
    () async {
      await ModelProviderFixture().run((f) async {
        final originalEmitter = f.emitter();
        const newKey = 'SYNTHETIC_PROVIDER_COLD_ROW_KEY_83267';
        await f.seedUnobservedKey(newKey);
        final old = f.send(from: originalEmitter);
        expect(await old.accepted, isFalse);
        expect((await old.prepared).preview, isNull);
        expect((await old.finished).reason, SupportModelRefusal.stale);
        expect(f.adapters, isEmpty);
        await f.container.pump();
        await f.confirmRecipient();
        final fresh = f.send();
        final preview = await f.preview(fresh);
        expect((await fresh.dispatch(fresh.approve(preview)!)).saved, isTrue);
        expect(f.adapters.single.fetches, 1);
        expect(
          f.adapters.single.options!.headers['Authorization'],
          'Bearer $newKey',
        );
        expect(f.adapters.single.upload, isNot(contains(newKey)));
      });
    },
  );
}
