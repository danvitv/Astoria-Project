import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/core/models/support_models.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_model_provenance.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_provenance_codec.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'helpers/support_model_fixture.dart';

void isolated(String name, Future<void> Function() body) {
  test(name, () async {
    var attempts = 0;
    await HttpOverrides.runZoned(
      body,
      createHttpClient: (_) {
        attempts++;
        throw StateError('Synthetic HTTP tripwire');
      },
    );
    expect(attempts, 0); // Even a swallowed startup/request attempt fails.
  });
}

Future<SupportModelRunResult> confirm(
  SupportModelFixture f,
  SupportModelSubmission submission,
) async {
  final preparation = await submission.prepared;
  expect(preparation.reason, SupportModelRefusal.none);
  final approval = f.service.approve(preparation.preview!);
  expect(approval, isNotNull);
  return f.service.dispatch(approval!);
}

void main() {
  isolated(
    'current-only native intent uses real private H/T/S and durable ordering',
    () async {
      final f = await SupportModelFixture.create();
      try {
        await f.history('unselected', body: SupportModelFixture.unselected);
        final submission = await f.submit();
        expect(await submission.accepted, isTrue);
        final preparation = await submission.prepared;
        final preview = preparation.preview!;
        expect(preview.supportMessages, 0);
        expect(preview.gameMessages, 0);
        expect(preview.messages.length, 2);
        expect(preview.messages.last.text, 'Native question');
        expect(() => preview.messages.clear(), throwsUnsupportedError);
        expect(f.adapters, isEmpty);
        expect(
          f.queue.active,
          isFalse,
        ); // User-controlled approval never holds queue.
        final result = await f.service.dispatch(f.service.approve(preview)!);
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.message!.status, 'complete');
        expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
        expect(result.outcome!.text, 'Synthetic reply');
        final adapter = f.adapters.single.delegate;
        final body = jsonDecode(adapter.upload!) as Map<String, dynamic>;
        expect(body['model'], 'fixture-model');
        expect(body['temperature'], 0.25);
        expect(body['max_tokens'], 512);
        expect(body['top_p'], 0.61);
        expect(
          adapter.options!.headers['Authorization'],
          'Bearer ${SupportModelFixture.rowKey}',
        );
        expect(f.fetchInQueue, isFalse);
        expect(adapter.upload, isNot(contains(SupportModelFixture.unselected)));
        expect(
          adapter.upload,
          isNot(contains('SYNTHETIC_CONNECTION_METADATA')),
        );
        expect(body.keys, isNot(contains('session_id')));
        expect(body.keys, isNot(contains('tools')));
        expect(body.keys, isNot(contains('response_format')));
        final user = await f.repo.getMessageById(preview.userMessageId);
        final reply = await f.repo.getMessageById(preview.replyMessageId);
        expect(user!.createdAt, lessThan(reply!.createdAt));
        final provenance = await f.repo.getContextBlockById(
          'support.reply_provenance:${reply.id}',
        );
        expect(provenance!.isActive, isFalse);
        final recipe = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
          provenance.protectedFactsJson,
        ).recipe!;
        expect(recipe.currentUserMessageId, user.id);
        expect(recipe.originalRanges, isEmpty);
        expect(recipe.directReplies, isEmpty);
        expect(f.published.where((m) => m.role == 'user').length, 1);
        expect(
          f.phases,
          containsAllInOrder([
            SupportModelPhase.preparing,
            SupportModelPhase.preview,
            SupportModelPhase.waiting,
            SupportModelPhase.activity,
            SupportModelPhase.settling,
            SupportModelPhase.settled,
          ]),
        );
      } finally {
        await f.close();
      }
    },
  );

  for (final protocol in [
    'openai',
    'openai_responses',
    'anthropic',
    'gemini',
    'openrouter',
    'custom_chat_completion',
    'custom_chat_completion_responses',
  ]) {
    isolated(
      'assistant overrides and actual native wire protocol $protocol',
      () async {
        final customResponses = protocol == 'custom_chat_completion_responses';
        final f = await SupportModelFixture.create(
          protocol: customResponses ? 'custom_chat_completion' : protocol,
          responses: customResponses,
        );
        try {
          final result = await confirm(f, await f.submit());
          expect(result.saved, isTrue);
          expect(result.outcome!.status, PrivateTextStatus.complete);
          final adapter = f.adapters.single.delegate;
          final body = jsonDecode(adapter.upload!) as Map<String, dynamic>;
          expect(body['model'] ?? body['generationConfig'], isNotNull);
          expect(f.fetchInQueue, isFalse);
          if (protocol == 'gemini') {
            expect(
              adapter.options!.uri.path,
              '/v1beta/models/fixture-model:streamGenerateContent',
            );
            expect(
              adapter.options!.uri.queryParameters['key'],
              SupportModelFixture.rowKey,
            );
            expect(adapter.options!.uri.queryParameters['alt'], 'sse');
            final generation = body['generationConfig'] as Map<String, dynamic>;
            expect(generation['temperature'], 0.25);
            expect(generation['maxOutputTokens'], 512);
            final safety = body['safetySettings'] as List<dynamic>;
            expect(safety.length, 5);
            expect(
              safety.every((dynamic s) => s['threshold'] == 'OFF'),
              isTrue,
            );
          } else {
            expect(body['model'], 'fixture-model');
            if (protocol == 'anthropic') {
              expect(
                adapter.options!.headers['x-api-key'],
                SupportModelFixture.rowKey,
              );
              // Inherited native traditional thinking adds a 1024-token response
              // budget and removes sampling; assistant inputs themselves stay 512/low.
              expect(body['max_tokens'], 1536);
              expect(body['thinking'], {
                'type': 'enabled',
                'budget_tokens': 1024,
              });
              expect(body.containsKey('temperature'), isFalse);
              expect(body.containsKey('top_p'), isFalse);
            } else {
              expect(body['temperature'], 0.25);
              expect(
                adapter.options!.headers['Authorization'],
                'Bearer ${SupportModelFixture.rowKey}',
              );
              expect(
                body[protocol == 'openai_responses' || customResponses
                    ? 'max_output_tokens'
                    : 'max_tokens'],
                512,
              );
            }
          }
          if (protocol == 'openrouter') {
            expect(
              adapter.options!.uri.toString(),
              'https://openrouter.ai/api/v1/chat/completions',
            );
          }
          expect(adapter.upload, isNot(contains('profile-model-not-selected')));
          expect(adapter.upload, isNot(contains(SupportModelFixture.rowKey)));
          expect(result.message!.text, isNot(contains('REASONING_CANARY')));
        } finally {
          await f.close();
        }
      },
    );
  }

  isolated(
    'omit flags and assistant effort mapping do not mutate saved API',
    () async {
      final f = await SupportModelFixture.create();
      try {
        f.api = f.api.copyWith(
          omitTemperature: true,
          omitTopP: true,
          omitFrequencyPenalty: true,
          omitPresencePenalty: true,
          omitReasoningEffort: true,
        );
        await f.apiRepo.put(f.api);
        await f.runtime.refresh(resolve: true);
        final review = f.runtime.recipient;
        await f.store.selectRecipientFromNative(
          SupportModelFixture.session,
          (review as SupportResolvedRecipient).recipient,
          isCurrent: () => true,
        );
        await f.runtime.refresh(resolve: true);
        f.runtime.recipientConfirmed = true;
        final result = await confirm(f, await f.submit());
        expect(result.saved, isTrue);
        final body =
            jsonDecode(f.adapters.single.delegate.upload!)
                as Map<String, dynamic>;
        for (final field in [
          'temperature',
          'top_p',
          'frequency_penalty',
          'presence_penalty',
          'reasoning_effort',
        ]) {
          expect(body.containsKey(field), isFalse);
        }
        expect(await f.apiRepo.getById(f.api.id), f.api);
      } finally {
        await f.close();
      }
    },
  );

  for (final confirmed in [false, true]) {
    isolated(
      'missing selection/confirmation retains native draft ($confirmed)',
      () async {
        final f = await SupportModelFixture.create(confirmed: confirmed);
        try {
          if (confirmed) {
            f.settings = f.settings.copyWith(clearModelId: true);
            await f.saveSettings();
          }
          final emission = await f.emit();
          expect(emission.intent, isNull);
          expect(
            emission.reason,
            confirmed
                ? SupportModelRefusal.noModel
                : SupportModelRefusal.recipientRequired,
          );
          expect(f.adapters, isEmpty);
          expect(f.published, isEmpty);
          expect(f.queue.entries, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final text in ['', 'x' * 8193, '\ud800']) {
    isolated(
      'explicit unsafe/oversize emission rejection ${text.length}',
      () async {
        final f = await SupportModelFixture.create();
        try {
          final emission = await f.emit(text);
          expect(emission.intent, isNull);
          expect(f.adapters, isEmpty);
          expect(f.queue.entries, 0);
        } finally {
          await f.close();
        }
      },
    );
  }

  isolated(
    'selected credential priming precedes immutable sanitized text',
    () async {
      final f = await SupportModelFixture.create();
      try {
        await f.seedUnobservedRowKey();
        final submission = await f.submit(
          'Typed ${SupportModelFixture.newRowKey} question',
        );
        final prepared = await submission.prepared;
        expect(
          prepared.preview!.messages.last.text,
          isNot(contains(SupportModelFixture.newRowKey)),
        );
        final result = await f.service.dispatch(
          f.service.approve(prepared.preview!)!,
        );
        expect(result.saved, isTrue);
        expect(
          (await f.repo.getMessageById(prepared.preview!.userMessageId))!.body,
          isNot(contains(SupportModelFixture.newRowKey)),
        );
        expect(
          f.adapters.single.delegate.options!.headers['Authorization'],
          'Bearer ${SupportModelFixture.newRowKey}',
        );
        expect(
          f.adapters.single.delegate.upload,
          isNot(contains(SupportModelFixture.newRowKey)),
        );
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'coordinator notification replacing owner during priming denies not rebinds',
    () async {
      final f = await SupportModelFixture.create();
      void replaced(dynamic _) {
        f.owner = false;
      }

      f.redaction.addListener(replaced);
      try {
        await f.seedUnobservedRowKey();
        final emission = await f
            .emit(); // getById observes a genuinely NEW key.
        expect(emission.intent, isNull);
        expect(f.owner, isFalse);
        expect(f.published, isEmpty);
        expect(f.adapters, isEmpty);
      } finally {
        f.redaction.removeListener(replaced);
        await f.close();
      }
    },
  );

  for (final slot in ['stale-same-ID', 'wrong-ID']) {
    isolated(
      'current durable row key wins over $slot vault credential',
      () async {
        final f = await SupportModelFixture.create();
        try {
          await f.vault.store(
            ApiConfigCredentialAdapter.llmSlot(
              slot == 'stale-same-ID' ? f.api.id : 'wrong-api',
            ),
            'SYNTHETIC_STALE_SLOT_KEY_336',
          );
          final result = await confirm(f, await f.submit());
          expect(result.saved, isTrue);
          expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
          final adapter = f.adapters.single.delegate;
          expect(
            adapter.options!.headers['Authorization'],
            'Bearer ${SupportModelFixture.rowKey}',
          );
          expect(adapter.upload, isNot(contains(SupportModelFixture.rowKey)));
          expect(
            adapter.upload,
            isNot(contains('SYNTHETIC_STALE_SLOT_KEY_336')),
          );
          expect(
            (await f.apiRepo.getById(f.api.id))!.apiKey,
            SupportModelFixture.rowKey,
          );
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final missing in ['cleared-key', 'deleted-row', 'keyless-new-route']) {
    isolated(
      '$missing never resurrects a populated same-ID vault key',
      () async {
        final f = await SupportModelFixture.create();
        try {
          if (missing == 'deleted-row') {
            await f.apiRepo.delete(f.api.id);
          } else {
            f.api = f.api.copyWith(
              apiKey: '',
              endpoint: missing == 'keyless-new-route'
                  ? 'https://new-fixture.invalid/v1/chat/completions'
                  : f.api.endpoint,
            );
            await f.apiRepo.put(f.api);
          }
          final emission = await f.emit();
          expect(emission.intent, isNull);
          expect(emission.reason, SupportModelRefusal.unavailable);
          expect(f.queue.entries, 0);
          expect(f.adapters, isEmpty);
          final row = await f.apiRepo.getById(f.api.id);
          expect(row?.apiKey, missing == 'deleted-row' ? isNull : isEmpty);
        } finally {
          await f.close();
        }
      },
    );
  }

  isolated(
    'same-ID vault rotation after approval cannot change current-row wire credential',
    () async {
      final f = await SupportModelFixture.create();
      try {
        final submission = await f.submit();
        final preparation = await submission.prepared;
        expect(preparation.reason, SupportModelRefusal.none);
        final approval = f.service.approve(preparation.preview!)!;
        await f.vault.store(
          ApiConfigCredentialAdapter.llmSlot(f.api.id),
          'SYNTHETIC_ROTATED_STALE_SLOT_611',
        );
        final result = await f.service.dispatch(approval);
        expect(result.saved, isTrue);
        expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
        expect(
          f.adapters.single.delegate.options!.headers['Authorization'],
          'Bearer ${SupportModelFixture.rowKey}',
        );
        expect(
          f.adapters.single.delegate.upload,
          isNot(contains('SYNTHETIC_ROTATED_STALE_SLOT_611')),
        );
        expect(f.adapters.single.calls, 1);
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'new key and route require new native confirmation and use only row key',
    () async {
      final f = await SupportModelFixture.create();
      try {
        f.api = f.api.copyWith(
          apiKey: SupportModelFixture.newRowKey,
          endpoint: 'https://new-fixture.invalid/v1/chat/completions',
        );
        await f.apiRepo.put(f.api);
        expect((await f.emit()).intent, isNull);
        await f.reconfirmRecipient();
        final result = await confirm(
          f,
          await f.submit('Typed ${SupportModelFixture.newRowKey}'),
        );
        expect(result.saved, isTrue);
        final adapter = f.adapters.single.delegate;
        expect(adapter.options!.uri.host, 'new-fixture.invalid');
        expect(
          adapter.options!.headers['Authorization'],
          'Bearer ${SupportModelFixture.newRowKey}',
        );
        expect(adapter.upload, isNot(contains(SupportModelFixture.newRowKey)));
        expect(adapter.upload, isNot(contains(SupportModelFixture.vaultKey)));
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'long current row credential does not exhaust short native-ID sanitation',
    () async {
      final f = await SupportModelFixture.create();
      try {
        final key = 'SYNTHETIC_LONG_ROW_KEY_${'q' * 160}';
        f.api = f.api.copyWith(apiKey: key);
        await f.apiRepo.put(f.api);
        await f.reconfirmRecipient();
        final result = await confirm(f, await f.submit());
        expect(result.saved, isTrue);
        expect(
          f.adapters.single.delegate.options!.headers['Authorization'],
          'Bearer $key',
        );
        expect(f.adapters.single.delegate.upload, isNot(contains(key)));
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'genuine new-row key priming replaces old issuer; fresh owner alone can send',
    () async {
      final f = await SupportModelFixture.create();
      SupportModelService? replacement;
      void replaced(dynamic _) {
        f.owner = false;
      }

      try {
        await f.seedUnobservedRowKey();
        f.redaction.addListener(replaced);
        final oldService = f.service;
        expect((await f.emit()).intent, isNull);
        expect(f.owner, isFalse);
        expect(f.queue.entries, 0);
        expect(f.adapters, isEmpty);
        f.redaction.removeListener(replaced);
        oldService.dispose();
        f.owner = true;
        replacement = f.newService();
        f.service = replacement;
        final result = await confirm(f, await f.submit());
        expect(result.saved, isTrue);
        expect(
          f.adapters.single.delegate.options!.headers['Authorization'],
          'Bearer ${SupportModelFixture.newRowKey}',
        );
        expect(f.adapters.single.calls, 1);
      } finally {
        f.redaction.removeListener(replaced);
        await f.close();
      }
    },
  );

  for (final loss in [
    'owner',
    'emitter',
    'draft-ABA',
    'runtime-ABA',
    'registry',
    'redactor',
  ]) {
    isolated('emitted native input cannot rebind after $loss', () async {
      final f = await SupportModelFixture.create();
      try {
        final intent = (await f.emit()).intent!;
        switch (loss) {
          case 'owner':
            f.owner = false;
          case 'emitter':
            f.emitter = false;
          case 'draft-ABA':
            f.draft = false;
          case 'runtime-ABA':
            f.runtime.selectSession('other');
            f.runtime.selectSession('session');
          case 'registry':
            final done = f.revisions.beginMutation();
            done();
          case 'redactor':
            f.redaction.registerSecret('NEW_SYNTHETIC_SECRET');
        }
        final submission = f.service.beginSend(intent);
        expect(await submission.accepted, isFalse);
        expect((await submission.prepared).preview, isNull);
        expect(f.adapters, isEmpty);
        expect(f.queue.entries, 0);
      } finally {
        await f.close();
      }
    });
  }

  isolated(
    'durable acceptance returns before preview and new draft stays independent',
    () async {
      final f = await SupportModelFixture.create();
      try {
        final submission = await f.submit();
        expect(await submission.accepted, isTrue);
        f.draft =
            false; // Editable NEW draft, not the submitted immutable text.
        final prepared = await submission.prepared;
        expect(prepared.preview, isNotNull);
        f.service.cancelPreview(prepared.preview!);
        final result = await submission.finished;
        expect(result.accepted, isTrue);
        expect(result.saved, isTrue);
        expect(result.message!.status, 'stopped');
        expect(f.adapters, isEmpty);
        expect(f.published.where((m) => m.role == 'user').length, 1);
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'same-turn duplicate intent and double approval/dispatch are once only',
    () async {
      final f = await SupportModelFixture.create();
      try {
        final intent = (await f.emit()).intent!;
        final first = f.service.beginSend(intent);
        expect(await f.service.beginSend(intent).accepted, isFalse);
        final preview = (await first.prepared).preview!;
        final approval = f.service.approve(preview)!;
        expect(f.service.approve(preview), isNull);
        final result1 = f.service.dispatch(approval);
        final result2 = f.service.dispatch(approval);
        expect(await result1, same(await result2));
        expect(f.adapters.single.calls, 1);
        expect(await f.service.beginSend(intent).accepted, isFalse);
        expect(
          f.published
              .where((m) => m.status == 'complete' && m.role == 'assistant')
              .length,
          1,
        );
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'failed append preserves acceptance false and never fetches',
    () async {
      final f = await SupportModelFixture.create();
      try {
        final intent = (await f.emit()).intent!;
        await f.repo.deleteSession(SupportModelFixture.session);
        final submission = f.service.beginSend(intent);
        expect(await submission.accepted, isFalse);
        expect((await submission.finished).accepted, isFalse);
        expect(f.adapters, isEmpty);
        expect(f.published, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  for (final denied in ['modelSupport', 'gameLocal', 'gameModel']) {
    isolated(
      'independent $denied: OFF excludes domain; ON missing local denies before H',
      () async {
        final game = denied != 'modelSupport';
        final scope = SupportPermissionScope(
          selectionRevision: 1,
          supportHistory: game ? null : SupportMessageSelection(['selected']),
          gameSessionId: game ? 'synthetic-game' : null,
          gameHistory: game ? SupportMessageSelection(['game-selected']) : null,
        );
        final f = await SupportModelFixture.create(
          scope: scope,
          grants: [
            if (denied == 'gameLocal') SupportPermission.modelGameHistory,
            if (denied == 'gameModel') SupportPermission.readGameData,
          ],
        );
        try {
          if (game) {
            await f.game();
          } else {
            await f.history('selected');
          }
          f.sql.observations.clear();
          f.primitive.decryptAads.clear();
          final submission = await f.submit();
          expect(await submission.accepted, isTrue);
          if (denied == 'gameLocal') {
            expect(
              (await submission.prepared).reason,
              SupportModelRefusal.historyDenied,
            );
            expect((await submission.finished).accepted, isTrue);
            expect(f.adapters, isEmpty);
          } else {
            final prepared = await submission.prepared;
            expect(prepared.reason, SupportModelRefusal.none);
            expect(prepared.preview!.supportMessages, 0);
            expect(prepared.preview!.gameMessages, 0);
            expect(prepared.preview!.messages.length, 2);
            final result = await f.service.dispatch(
              f.service.approve(prepared.preview!)!,
            );
            expect(result.saved, isTrue);
            expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
            expect(
              f.adapters.single.delegate.upload,
              isNot(contains('Selected')),
            );
          }
          expect(
            f.sql.observations.where(
              (o) =>
                  (o.statement.contains('ROW_NUMBER()') &&
                      o.args.contains('selected')) ||
                  o.statement.contains('json_each'),
            ),
            isEmpty,
          );
          expect(
            f.primitive.decryptAads.where((aad) => aad.contains('|selected|')),
            isEmpty,
          );
        } finally {
          await f.close();
        }
      },
    );
  }

  isolated(
    'selected support AND game text only, no metadata/body/privacy laundering',
    () async {
      final scope = SupportPermissionScope(
        selectionRevision: 1,
        supportHistory: SupportMessageSelection(['selected']),
        gameSessionId: 'synthetic-game',
        gameHistory: SupportMessageSelection(['game-selected']),
      );
      final f = await SupportModelFixture.create(
        scope: scope,
        grants: [
          SupportPermission.modelSupportHistory,
          SupportPermission.readGameData,
          SupportPermission.modelGameHistory,
        ],
      );
      try {
        await f.history('selected');
        await f.history(
          'excluded',
          body: SupportModelFixture.unselected,
          time: 3,
        );
        await f.game();
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        expect(preview.supportMessages, 1);
        expect(preview.gameMessages, 1);
        final result = await f.service.dispatch(f.service.approve(preview)!);
        expect(result.saved, isTrue);
        final upload = f.adapters.single.delegate.upload!;
        expect(upload, contains('Selected history'));
        expect(upload, contains('Selected game'));
        expect(upload, isNot(contains(SupportModelFixture.unselected)));
        expect(upload, isNot(contains('support.model_provenance')));
        final block = await f.repo.getContextBlockById(
          'support.reply_provenance:${preview.replyMessageId}',
        );
        final recipe = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
          block!.protectedFactsJson,
        ).recipe!;
        expect(recipe.originalRanges.map((r) => r.domain), [
          SupportModelSourceDomain.support,
          SupportModelSourceDomain.game,
        ]);
        expect(recipe.originalRanges.first.orderedMessageIds, ['selected']);
      } finally {
        await f.close();
      }
    },
  );

  for (final known in [false, true]) {
    isolated(
      'derived historical assistant requires encrypted recipe AND selected originating user ($known)',
      () async {
        final scope = SupportPermissionScope(
          selectionRevision: 1,
          supportHistory: SupportMessageSelection(['old-user', 'old-reply']),
        );
        final f = await SupportModelFixture.create(
          scope: scope,
          grants: [SupportPermission.modelSupportHistory],
        );
        try {
          await f.history('old-user', runId: 'old-run');
          await f.history(
            'old-reply',
            role: 'assistant',
            runId: 'old-run',
            time: 3,
          );
          if (known) {
            final recipe = SupportModelProvenance(
              supportSessionId: 'session',
              replyMessageId: 'old-reply',
              runId: 'old-run',
              currentUserMessageId: 'old-user',
              originalRanges: const [],
              directReplies: const [],
            );
            // Dedicated encrypted provenance fixture without invoking a fake codec.
            final json = SupportModelProvenanceCodec.encodeForEncryptedStorage(
              recipe,
            );
            await seedRecipe(f, 'old-reply', json, 3);
          }
          final submission = await f.submit();
          final preparation = await submission.prepared;
          if (!known) {
            expect(preparation.reason, SupportModelRefusal.lineageUnavailable);
            expect(f.adapters, isEmpty);
            await submission.finished;
          } else {
            final result = await f.service.dispatch(
              f.service.approve(preparation.preview!)!,
            );
            expect(result.saved, isTrue);
            final provenance = await f.repo.getContextBlockById(
              'support.reply_provenance:${preparation.preview!.replyMessageId}',
            );
            final recipe =
                SupportModelProvenanceCodec.decodeFromEncryptedStorage(
                  provenance!.protectedFactsJson,
                ).recipe!;
            expect(recipe.directReplies.single.messageId, 'old-reply');
            expect(recipe.directReplies.single.runId, 'old-run');
          }
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final change in [
    'body',
    'ABA',
    'key',
    'policy',
    'recipient',
    'factory',
    'redactor',
    'dispose',
  ]) {
    isolated(
      'preview $change invalidation refuses actual fetch, keeps durable user',
      () async {
        final f = await SupportModelFixture.create();
        try {
          final submission = await f.submit();
          final preview = (await submission.prepared).preview!;
          final approval = f.service.approve(preview)!;
          switch (change) {
            case 'body':
              await f.repo.mutateMessage(
                messageId: preview.userMessageId,
                mutate: (m) => m.copyWith(body: 'Changed current'),
              );
            case 'ABA':
              await f.repo.mutateMessage(
                messageId: preview.userMessageId,
                mutate: (m) => m.copyWith(body: 'Changed'),
              );
              await f.repo.mutateMessage(
                messageId: preview.userMessageId,
                mutate: (m) => m.copyWith(body: 'Native question'),
              );
            case 'key':
              f.api = f.api.copyWith(apiKey: 'CHANGED_SYNTHETIC_KEY');
              await f.apiRepo.put(f.api);
            case 'policy':
              await f.store.setGrantFromNative(
                'session',
                SupportPermission.confirmedSettingsChanges,
                true,
                isCurrent: () => true,
              );
            case 'recipient':
              f.runtime.invalidateBindings();
            case 'factory':
              f.onFactory = () {
                f.owner = false;
              };
            case 'redactor':
              f.redaction.registerSecret('Native question');
            case 'dispose':
              f.service.dispose();
          }
          final result = await f.service.dispatch(approval);
          expect(result.accepted, isTrue);
          expect(f.adapters.fold(0, (n, a) => n + a.calls), 0);
          expect(result.message?.status, isNot('complete'));
          expect(await f.repo.getMessageById(preview.userMessageId), isNotNull);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final termination in [
    'stop',
    'selection',
    'dispose',
    'registry',
    'redactor',
  ]) {
    isolated(
      'quiet SSE $termination cancels actual token; original row settles once',
      () async {
        final f = await SupportModelFixture.create();
        try {
          f.quiet = true;
          f.responseBody = () => chatDelta('Whole verified prefix');
          final submission = await f.submit();
          final preview = (await submission.prepared).preview!;
          final resultFuture = f.service.dispatch(f.service.approve(preview)!);
          // Wait for payload-free activity, not a guessed wall-clock sleep.
          await f.activity.future;
          expect(
            f.published.where((m) => m.text.contains('Whole verified prefix')),
            isEmpty,
          );
          switch (termination) {
            case 'stop':
              f.service.stop();
            case 'selection':
              f.runtime.selectSession('other');
            case 'dispose':
              f.service.dispose();
            case 'registry':
              final done = f.revisions.beginMutation();
              done();
            case 'redactor':
              f.redaction.registerSecret('Whole verified prefix');
          }
          final result = await resultFuture;
          expect(result.accepted, isTrue);
          expect(result.saved, isTrue);
          expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
          expect(result.message!.status, 'stopped');
          expect(f.adapters.single.delegate.closed, isTrue);
          await f.adapters.single.delegate.cancelObserved.future;
          final durable = await f.repo.getMessageById(preview.replyMessageId);
          expect(durable!.status, 'stopped');
          expect(f.adapters.single.calls, 1);
          if (termination == 'selection' ||
              termination == 'dispose' ||
              termination == 'registry') {
            expect(
              f.published.where(
                (m) => m.role == 'assistant' && m.status == 'stopped',
              ),
              isEmpty,
            );
          }
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final verdict in ['partial', 'malformed', 'limited', 'http-error']) {
    isolated(
      'real native $verdict is explicit, no canned success fallback',
      () async {
        final f = await SupportModelFixture.create();
        try {
          f.responseBody = () => switch (verdict) {
            'partial' => chatDelta('Partial text'),
            'malformed' => 'data: {invalid-json}\n\n',
            'limited' => '${chatDelta('Limited text')}${chatFinish('length')}',
            _ => 'SECRET_PROVIDER_ERROR_BODY',
          };
          if (verdict == 'http-error') f.status = 500;
          final result = await confirm(f, await f.submit());
          expect(result.accepted, isTrue);
          expect(result.saved, isTrue);
          expect(
            result.message!.status,
            verdict == 'limited' ? 'limited' : 'error',
          );
          expect(result.outcome!.status, isNot(PrivateTextStatus.complete));
          expect(
            result.message!.text,
            isNot(contains('SECRET_PROVIDER_ERROR_BODY')),
          );
          if (verdict == 'http-error') {
            expect(f.adapters.single.delegate.responseListens, 0);
          }
        } finally {
          await f.close();
        }
      },
    );
  }

  isolated(
    'deleted original reply refuses settlement and is never recreated',
    () async {
      final f = await SupportModelFixture.create();
      try {
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        await f.repo.deleteMessage(preview.replyMessageId);
        f.service.invalidateMessage('session', preview.replyMessageId);
        final result = await submission.finished;
        expect(result.accepted, isTrue);
        expect(result.saved, isFalse);
        expect(result.reason, SupportModelRefusal.settlementFailed);
        expect(await f.repo.getMessageById(preview.replyMessageId), isNull);
        expect(f.adapters, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  isolated(
    'unsupported saved non-stream/HTTP/extra route refuses before append',
    () async {
      final f = await SupportModelFixture.create();
      try {
        f.api = f.api.copyWith(
          stream: false,
          extraRequestParameters: [
            const ExtraRequestParameter(
              key: 'synthetic',
              value: 'true',
              enabled: true,
            ),
          ],
        );
        await f.apiRepo.put(f.api);
        final emission = await f.emit();
        expect(emission.intent, isNull);
        expect(f.adapters, isEmpty);
        expect(f.queue.entries, 0);
      } finally {
        await f.close();
      }
    },
  );
}

Future<void> seedRecipe(
  SupportModelFixture f,
  String reply,
  String recipe,
  int time,
) async {
  final id = 'support.reply_provenance:$reply';
  await f.repo.putContextBlock(
    SupportContextBlock(
      id: id,
      sessionId: 'session',
      startMessageId: reply,
      endMessageId: reply,
      summary: '',
      protectedFactsJson: recipe,
      isActive: false,
      createdAt: time,
    ),
  );
}
