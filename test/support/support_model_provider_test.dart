import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_native_provider.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_model_provider_fixture.dart';
import 'helpers/support_model_provider_fixture_http.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'responseListening observes actual subscription and preserves raw chunks, metadata, pause/resume and done',
    () async {
      await ModelProviderIsolation().run(() async {
        final native = PrivateFixtureAdapter(
          '',
          status: 206,
          contentType: 'application/octet-stream',
          rawBytes: [0, 255, 128, 10],
          oneByteChunks: true,
        );
        final adapter = ModelProviderHttpAdapter(native);
        final request = StreamController<Uint8List>();
        final responseFuture = adapter.fetch(
          RequestOptions(path: 'https://fixture.invalid/synthetic'),
          request.stream,
          null,
        );
        var listening = false;
        unawaited(adapter.responseListening.then((_) => listening = true));
        StreamSubscription<Uint8List>? subscription;
        try {
          await adapter.fetched.future;
          expect(listening, isFalse);
          expect(native.responseListens, 0);
          request.add(Uint8List.fromList(utf8.encode('synthetic upload')));
          await request.close();
          final response = await responseFuture;
          expect(listening, isFalse, reason: 'Headers are not subscription.');
          expect(response.statusCode, 206);
          expect(response.statusMessage, 'RAW_PROVIDER_CANARY');
          expect(response.headers, {
            'content-type': ['application/octet-stream'],
            'location': [
              'https://RAW_PROVIDER_CANARY.invalid/?key=fixture-credential',
            ],
          });
          expect(response.stream.isBroadcast, isFalse);
          final chunks = <Uint8List>[];
          final done = Completer<void>();
          subscription = response.stream.listen(
            chunks.add,
            onDone: done.complete,
            cancelOnError: false,
          );
          subscription.pause();
          await adapter.responseListening;
          expect(listening, isTrue);
          expect(native.responseListens, 1);
          expect(subscription.isPaused, isTrue);
          expect(chunks, isEmpty);
          expect(done.isCompleted, isFalse);
          subscription.resume();
          await done.future;
          expect(subscription.isPaused, isFalse);
          expect(chunks.map((chunk) => chunk.toList()), [
            [0],
            [255],
            [128],
            [10],
          ]);
          expect(adapter.upload, 'synthetic upload');
          expect(adapter.fetches, 1);
        } finally {
          await subscription?.cancel();
          adapter.close(force: true);
        }
      });
    },
  );

  test(
    'responseListening returns the underlying quiet subscription for actual cancellation',
    () async {
      await ModelProviderIsolation().run(() async {
        final native = PrivateFixtureAdapter('', quiet: true);
        final adapter = ModelProviderHttpAdapter(native);
        final cancel = Completer<void>();
        try {
          final response = await adapter.fetch(
            RequestOptions(path: 'https://fixture.invalid/synthetic'),
            null,
            cancel.future,
          );
          final subscription = response.stream.listen(null);
          await adapter.responseListening;
          expect(native.responseListens, 1);
          expect(native.responseCancelled.isCompleted, isFalse);
          subscription.pause();
          expect(subscription.isPaused, isTrue);
          await subscription.cancel();
          await native.responseCancelled.future;
          cancel.complete();
          await adapter.cancelObserved.future;
          expect(adapter.fetches, 1);
        } finally {
          adapter.close(force: true);
        }
        expect(adapter.closed, isTrue);
      });
    },
  );

  test(
    'upload stream failure remains the same error and never signals responseListening',
    () async {
      await ModelProviderIsolation().run(() async {
        final native = PrivateFixtureAdapter('');
        final adapter = ModelProviderHttpAdapter(native);
        final error = StateError('SYNTHETIC_UPLOAD_STREAM_ERROR_78246');
        var listening = false;
        unawaited(adapter.responseListening.then((_) => listening = true));
        try {
          await expectLater(
            adapter.fetch(
              RequestOptions(path: 'https://fixture.invalid/synthetic'),
              Stream<Uint8List>.error(error),
              null,
            ),
            throwsA(same(error)),
          );
          expect(adapter.fetches, 1);
          expect(native.fetched.isCompleted, isTrue);
          expect(native.responseListens, 0);
          expect(listening, isFalse);
        } finally {
          adapter.close(force: true);
        }
      });
    },
  );

  test(
    'actual native/workspace/model composition accepts, previews, dispatches once and projects durable order/status',
    () async {
      final f = ModelProviderFixture();
      await f.run((f) async {
        final send = f.send(
          text: 'Native question ${ModelProviderFixture.secret}',
        );
        expect(f.bridge.view.busy, isTrue);
        expect(await send.accepted, isTrue);
        expect(
          f.state.activeMessages.where(
            (m) => m.role == SupportMessageRole.user,
          ),
          hasLength(1),
        );
        final preview = await f.preview(send);
        expect(preview.isCurrent, isTrue);
        expect(f.adapters, isEmpty);
        expect(
          f.state.isBusy,
          isFalse,
          reason: 'Preview is outside workspace FIFO.',
        );
        expect(f.bridge.view.preview, same(preview));
        final before = f.state.activeMessages.map((m) => m.id).toList();
        final user = f.state.activeMessages.singleWhere(
          (m) => m.id == preview.userMessageId,
        );
        final reply = f.state.activeMessages.singleWhere(
          (m) => m.id == preview.replyMessageId,
        );
        expect(user.runId, preview.runId);
        expect(reply.runId, preview.runId);
        expect(reply.status, 'pending');
        expect(user.createdAt.isBefore(reply.createdAt), isTrue);
        expect(f.bridge.view.isActiveRun(reply.runId, reply.sessionId), isTrue);
        final approval = send.approve(preview);
        expect(approval, isNotNull);
        expect(
          send.approve(preview),
          isNull,
          reason: 'Approval cannot be reissued.',
        );
        final result = await send.dispatch(approval!);
        expect(await send.finished, same(result));
        expect(await send.dispatch(approval), same(result));
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
        expect(f.adapters, hasLength(1));
        final adapter = f.adapters.single;
        expect(
          adapter.fetches,
          1,
          reason: 'Exactly one actual native adapter fetch.',
        );
        expect(adapter.options!.uri.toString(), f.api.endpoint);
        expect(
          adapter.options!.headers['Authorization'],
          'Bearer ${ModelProviderFixture.rowKey}',
        );
        final wire = jsonDecode(adapter.upload!) as Map<String, dynamic>;
        expect(wire['model'], 'selected-native-model');
        expect(wire['temperature'], 0.25);
        expect(wire['max_tokens'], 512);
        expect(wire['top_p'], 0.61);
        expect(wire['frequency_penalty'], 0.2);
        expect(wire['presence_penalty'], 0.3);
        expect(wire['reasoning_effort'], 'low');
        expect(wire.keys, isNot(contains('session_id')));
        expect(wire.keys, isNot(contains('tools')));
        expect(wire.keys, isNot(contains('response_format')));
        final messages = wire['messages'] as List<dynamic>;
        expect(messages, hasLength(2));
        expect(messages.last['content'], preview.messages.last.text);
        for (final canary in [
          ModelProviderFixture.secret,
          ModelProviderFixture.excluded,
          ModelProviderFixture.rowKey,
          ModelProviderFixture.staleVaultKey,
        ]) {
          expect(adapter.upload, isNot(contains(canary)));
        }
        expect(f.state.activeMessages.map((m) => m.id), before);
        expect(f.state.activeMessages.last.status, 'complete');
        expect(f.state.activeMessages.last.body, 'Safe synthetic answer');
        expect(f.state.activeMessages.last.cards, isEmpty);
        await f.container.pump();
        expect(f.bridge.view.busy, isFalse);
        expect(f.container.read(supportModelRunViewProvider).saved, isTrue);
      });
    },
  );

  test(
    'saved omit flags suppress current assistant overrides without editing selected API row',
    () async {
      final f = ModelProviderFixture();
      f.api = f.api.copyWith(
        omitTemperature: true,
        omitTopP: true,
        omitFrequencyPenalty: true,
        omitPresencePenalty: true,
        omitReasoning: true,
      );
      await f.run((f) async {
        final original = await f.container
            .read(apiConfigRepoProvider)
            .getById(f.api.id);
        final send = f.send();
        final preview = await f.preview(send);
        final result = await send.dispatch(send.approve(preview)!);
        expect(result.saved, isTrue);
        final wire =
            jsonDecode(f.adapters.single.upload!) as Map<String, dynamic>;
        for (final field in [
          'temperature',
          'top_p',
          'frequency_penalty',
          'presence_penalty',
          'reasoning_effort',
          'session_id',
        ]) {
          expect(wire.containsKey(field), isFalse);
        }
        expect(
          await f.container.read(apiConfigRepoProvider).getById(f.api.id),
          original,
        );
      });
    },
  );

  test(
    'selected USER plus bare SYSTEM refuses the whole range after durable acceptance, without inventing lineage',
    () async {
      await ModelProviderFixture().run((f) async {
        for (final (id, role, body, time) in [
          ('history-one', 'user', 'Selected public question', 3),
          (
            'history-two',
            'system',
            'Selected system data ${ModelProviderFixture.secret}',
            4,
          ),
        ]) {
          await f.repo.putMessage(
            SupportMessage(
              id: id,
              sessionId: ModelProviderFixture.session,
              role: role,
              body: body,
              createdAt: time,
            ),
          );
        }
        await f.grantHistory(
          SupportPermissionScope(
            selectionRevision: 1,
            supportHistory: SupportMessageSelection([
              'history-one',
              'history-two',
            ]),
          ),
          [SupportPermission.modelSupportHistory],
        );
        await f.workspace.refresh();
        final originalMessages = await f.repo.getMessagesForSession(
          ModelProviderFixture.session,
        );
        // Local settings/consent already own context blocks. Refusal must add
        // nothing, not erase that baseline; compare exact encrypted rows too.
        final originalContextRows = {
          for (final row in await f.db.select(f.db.supportContextBlocks).get())
            row.id: row.toJson(),
        };
        expect(originalContextRows, hasLength(2));
        final originalMessageRows = {
          for (final row in await f.db.select(f.db.supportMessages).get())
            row.id: row.toJson(),
        };
        f.sql.writes.clear();
        final send = f.send();
        expect(await send.accepted, isTrue);
        final preparation = await send.prepared;
        expect(preparation.reason, SupportModelRefusal.lineageUnavailable);
        expect(preparation.preview, isNull);
        final result = await send.finished;
        expect(result.accepted, isTrue);
        expect(result.saved, isFalse);
        expect(result.reason, SupportModelRefusal.lineageUnavailable);
        expect(result.message, isNull);
        expect(result.outcome, isNull);
        expect(f.bridge.view.preview, isNull);
        expect(f.adapters, isEmpty);
        expect(
          f.phases.where((phase) => phase.phase == SupportModelPhase.preview),
          isEmpty,
        );
        final durableMessages = await f.repo.getMessagesForSession(
          ModelProviderFixture.session,
        );
        final accepted = durableMessages.where((m) => m.runId != null).single;
        expect(accepted.role, 'user');
        expect(accepted.status, 'complete');
        expect(accepted.body, 'Actual native question');
        expect(accepted.sessionId, ModelProviderFixture.session);
        expect(durableMessages, hasLength(originalMessages.length + 1));
        expect(
          durableMessages.where((m) => m.id != accepted.id),
          originalMessages,
        );
        expect(
          {
            for (final row in await f.db.select(f.db.supportMessages).get())
              if (row.id != accepted.id) row.id: row.toJson(),
          },
          originalMessageRows,
          reason:
              'Existing USER/SYSTEM bodies and encrypted bytes stay intact.',
        );
        expect(
          {
            for (final row
                in await f.db.select(f.db.supportContextBlocks).get())
              row.id: row.toJson(),
          },
          originalContextRows,
          reason:
              'No new reply provenance, changed facts or baseline deletion.',
        );
        expect(
          f.sql.writes.where((sql) => sql.contains('support_context_blocks')),
          isEmpty,
          reason: 'Whole-range refusal must precede any reply reservation.',
        );
        final system = (await f.repo.getMessageById('history-two'))!;
        expect(system.role, 'system');
        expect(system.runId, isNull);
        expect(system.status, 'complete');
        expect(
          system.body,
          'Selected system data ${ModelProviderFixture.secret}',
        );
        // The old SYSTEM-demotion success assertion was unsupported for legacy
        // support SYSTEM: prompt demotion is not proof of a known origin.
      });
    },
  );

  test(
    'two independent USER inputs compose the exact sanitized range, never excluded history or provenance',
    () async {
      await ModelProviderFixture().run((f) async {
        // New independent USER records, NOT a relabel of history-two SYSTEM.
        const firstId = 'independent-user-one';
        const secondId = 'independent-user-two';
        const secondText = 'Selected user data ${ModelProviderFixture.secret}';
        const excludedProvenance = 'UNSELECTED_PROVIDER_PROVENANCE_58269';
        for (final (id, body, time) in [
          (firstId, 'Selected public question', 3),
          (secondId, secondText, 4),
        ]) {
          await f.repo.putMessage(
            SupportMessage(
              id: id,
              sessionId: ModelProviderFixture.session,
              role: 'user',
              body: body,
              createdAt: time,
            ),
          );
        }
        await f.repo.putContextBlock(
          const SupportContextBlock(
            id: 'support.reply_provenance:old-excluded',
            sessionId: ModelProviderFixture.session,
            startMessageId: 'old-excluded',
            endMessageId: 'old-excluded',
            summary: '',
            protectedFactsJson: '{"excluded":"$excludedProvenance"}',
            isActive: false,
            createdAt: 2,
          ),
        );
        await f.grantHistory(
          SupportPermissionScope(
            selectionRevision: 1,
            supportHistory: SupportMessageSelection([firstId, secondId]),
          ),
          [SupportPermission.modelSupportHistory],
        );
        await f.workspace.refresh();
        final send = f.send();
        final preview = await f.preview(send);
        expect(preview.supportMessages, 2);
        expect(preview.gameMessages, 0);
        expect(preview.messages, hasLength(4));
        expect(preview.messages.where((m) => m.role == 'system'), hasLength(1));
        expect(preview.messages[1].text, 'Selected public question');
        expect(preview.messages[2].role, 'user');
        expect(preview.messages[1].role, 'user');
        expect(
          preview.messages[2].text,
          f.redaction.redactor.redactText(secondText),
        );
        expect(
          preview.messages[2].text,
          isNot(contains(ModelProviderFixture.secret)),
        );
        expect(preview.messages.last.text, 'Actual native question');
        final result = await send.dispatch(send.approve(preview)!);
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.message!.status, 'complete');
        expect(result.message!.text, 'Safe synthetic answer');
        expect(await send.finished, same(result));
        expect(f.adapters, hasLength(1));
        final wire =
            jsonDecode(f.adapters.single.upload!) as Map<String, dynamic>;
        expect(
          (wire['messages'] as List<dynamic>).map((dynamic m) => m['content']),
          preview.messages.map((m) => m.text),
        );
        expect(
          (wire['messages'] as List<dynamic>).map((dynamic m) => m['role']),
          preview.messages.map((m) => m.role),
        );
        for (final canary in [
          ModelProviderFixture.excluded,
          excludedProvenance,
          ModelProviderFixture.secret,
          ModelProviderFixture.rowKey,
          ModelProviderFixture.staleVaultKey,
          ModelProviderFixture.session,
          firstId,
          secondId,
          preview.runId,
          'support.model_provenance',
          'originalRanges',
          'directReplies',
        ]) {
          expect(f.adapters.single.upload, isNot(contains(canary)));
        }
        expect(f.adapters.single.fetches, 1);
      });
    },
  );

  test(
    'missing model rejects native send; explicitly requested local help remains offline',
    () async {
      await ModelProviderFixture().run((f) async {
        final send = f.send();
        expect(await send.accepted, isFalse);
        expect((await send.prepared).reason, SupportModelRefusal.noModel);
        expect((await send.finished).reason, SupportModelRefusal.noModel);
        expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
        expect(await f.workspace.sendLocalHelp('theme'), isTrue);
        expect(f.state.activeMessages.last.cards, isNotEmpty);
        expect(f.adapters, isEmpty);
      }, configured: false);
    },
  );

  test(
    'unconfirmed recipient rejects without append, default-profile fallback or HTTP',
    () async {
      await ModelProviderFixture().run((f) async {
        final original = List.of(f.state.activeMessages);
        final send = f.send();
        expect(await send.accepted, isFalse);
        expect(
          (await send.prepared).reason,
          SupportModelRefusal.recipientRequired,
        );
        expect(f.state.activeMessages, original);
        expect(f.adapters, isEmpty);
      }, confirm: false);
    },
  );

  test(
    'legacy string send and shared local topics/open/refresh remain offline even with a model',
    () async {
      await ModelProviderFixture().run((f) async {
        expect(await f.workspace.sendUserMessage('theme'), isTrue);
        expect(
          await f.workspace.triggerQuickAction('memory_books_setup'),
          isTrue,
        );
        f.workspace.applyInitialTopic('report');
        await f.workspace.refresh();
        await f.container.pump();
        await f.workspace.refresh();
        expect(f.adapters, isEmpty);
        expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
        expect(
          f.container.read(supportNativeRuntimeProvider).sessionId,
          ModelProviderFixture.session,
        );
      });
    },
  );

  for (final status in ['preparing', 'pending', 'running']) {
    test(
      'restored $status native rows project interrupted metadata and never replay',
      () async {
        await ModelProviderFixture().run((f) async {
          await f.repo.putMessage(
            SupportMessage(
              id: 'restored-reply',
              sessionId: ModelProviderFixture.session,
              role: 'assistant',
              body: '',
              runId: 'restored-run',
              status: status,
              createdAt: 4,
            ),
          );
          await f.workspace.refresh();
          final item = f.state.activeMessages.last;
          expect(item.runId, 'restored-run');
          expect(item.status, status);
          expect(item.activity, SupportMessageActivity.interrupted);
          expect(
            item.statusLabel,
            contains('автоматическая повторная отправка отключена'),
          );
          expect(f.bridge.view.busy, isFalse);
          expect(
            f.bridge.view.isActiveRun(item.runId, item.sessionId),
            isFalse,
          );
          expect(f.adapters, isEmpty);
        });
      },
    );
  }

  for (final fail in ['cancel-preview', 'http-error', 'partial', 'limited']) {
    test(
      'durable acceptance survives $fail; no configured-model canned fallback',
      () async {
        final f = ModelProviderFixture();
        if (fail == 'http-error') {
          f.httpStatus = 401;
          f.response = () => 'RAW_PROVIDER_CANARY';
        }
        if (fail == 'partial') f.response = () => chatDelta('Safe partial');
        if (fail == 'limited') {
          f.response = () =>
              '${chatDelta('Safe limited')}${chatFinish('length')}data: [DONE]\n\n';
        }
        await f.run((f) async {
          final send = f.send();
          final preview = await f.preview(send);
          if (fail == 'cancel-preview') {
            send.cancelPreview(preview);
          } else {
            await send.dispatch(send.approve(preview)!);
          }
          final result = await send.finished;
          expect(await send.accepted, isTrue);
          expect(result.accepted, isTrue);
          expect(result.saved, isTrue);
          expect(
            f.state.activeMessages.where(
              (m) => m.role == SupportMessageRole.user,
            ),
            hasLength(1),
          );
          expect(f.state.activeMessages.last.status, switch (fail) {
            'cancel-preview' => 'stopped',
            'limited' => 'limited',
            _ => 'error',
          });
          expect(f.state.activeMessages.last.cards, isEmpty);
          expect(
            f.state.activeMessages.last.body,
            isNot(contains('RAW_PROVIDER_CANARY')),
          );
          expect(f.adapters, hasLength(fail == 'cancel-preview' ? 0 : 1));
          if (fail == 'partial') {
            expect(result.outcome!.status, PrivateTextStatus.partial);
          }
        });
      },
    );
  }

  test(
    'selected row cleared credential refuses despite same-ID populated vault',
    () async {
      await ModelProviderFixture().run((f) async {
        await f.container
            .read(apiConfigRepoProvider)
            .put(f.api.copyWith(apiKey: ''));
        final send = f.send();
        expect(await send.accepted, isFalse);
        expect((await send.finished).reason, SupportModelRefusal.unavailable);
        expect(f.adapters, isEmpty);
        await f.vault.useSecret(ApiConfigCredentialAdapter.llmSlot(f.api.id), (
          value,
        ) async {
          expect(value, ModelProviderFixture.staleVaultKey);
        });
      });
    },
  );

  test(
    'unsafe/oversize native input returns fixed reason and retains unsaved draft',
    () async {
      await ModelProviderFixture().run((f) async {
        for (final (text, reason) in [
          ('', SupportModelRefusal.unsafe),
          ('x' * 8193, SupportModelRefusal.tooLarge),
        ]) {
          final send = f.send(text: text);
          expect(await send.accepted, isFalse);
          expect((await send.prepared).reason, reason);
          await send.finished;
        }
        expect(f.adapters, isEmpty);
        expect(f.state.activeMessages.where((m) => m.runId != null), isEmpty);
      });
    },
  );
}
