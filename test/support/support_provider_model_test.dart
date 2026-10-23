import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/llm/transport/private_text_transport.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_model_service.dart';

import '../llm/transport/_private_text_fixture.dart';
import 'support_provider_model_fixture.dart';

void synthetic(String name, Future<void> Function() body) {
  test(name, () async {
    var attempts = 0;
    await HttpOverrides.runZoned(
      body,
      createHttpClient: (_) {
        attempts++;
        throw StateError('Synthetic native model HTTP tripwire');
      },
    );
    expect(attempts, 0);
  });
}

void main() {
  for (final protocol in [
    'openai',
    'openai_responses',
    'anthropic',
    'gemini',
    'openrouter',
    'custom_chat_completion',
    'custom_responses',
  ]) {
    synthetic(
      'actual native Astoria full preview / once / AEAD: $protocol',
      () async {
        final f = await SupportProviderModelFixture.create(
          protocol: protocol == 'custom_responses'
              ? 'custom_chat_completion'
              : protocol,
          customResponses: protocol == 'custom_responses',
        );
        try {
          await f.selectHistory(model: true);
          final submission = await f.submit(
            'Question ${SupportProviderModelFixture.key}',
          );
          expect(await submission.accepted, isTrue);
          final preparation = await submission.prepared;
          expect(preparation.reason, SupportModelRefusal.none);
          final preview = preparation.preview!;
          expect(preview.supportMessages, 1);
          expect(preview.gameMessages, 0);
          expect(preview.messages.length, 3);
          expect(preview.messages[1].text, 'Selected native history');
          expect(
            preview.messages.last.text,
            isNot(contains(SupportProviderModelFixture.key)),
          );
          expect(
            preview.messages.map((m) => m.text).join(),
            isNot(contains(SupportProviderModelFixture.excluded)),
          );
          expect(f.adapters, isEmpty);
          expect(f.dispatcherConstructions, 0);
          final approval = f.service.approve(preview)!;
          expect(f.service.approve(preview), isNull);
          final result = await f.service.dispatch(approval);
          final repeated = await f.service.dispatch(approval);
          expect(identical(result, repeated), isTrue);
          expect(result.accepted, isTrue);
          expect(result.saved, isTrue);
          expect(result.message!.status, 'complete');
          expect(result.message!.text, 'Synthetic native reply');
          expect(result.outcome!.dispatch, PrivateTextDispatch.admitted);
          expect(f.dispatcherConstructions, 1);
          final wire = f.adapters.single;
          expect(wire.calls, 1);
          expect(f.fetchInQueue, isFalse);
          final options = wire.delegate.options!;
          expect(options.method, 'POST');
          expect(options.followRedirects, isFalse);
          expect(
            options.uri.toString(),
            protocol == 'gemini' ? '${f.api.endpoint}?alt=sse' : f.api.endpoint,
          );
          final header = protocol == 'gemini'
              ? 'x-goog-api-key'
              : protocol == 'anthropic'
              ? 'x-api-key'
              : 'Authorization';
          expect(
            options.headers[header],
            protocol == 'gemini' || protocol == 'anthropic'
                ? SupportProviderModelFixture.key
                : 'Bearer ${SupportProviderModelFixture.key}',
          );
          expect(
            options.uri.toString(),
            isNot(contains(SupportProviderModelFixture.key)),
          );
          expect(
            jsonEncode(options.queryParameters),
            isNot(contains(SupportProviderModelFixture.key)),
          );
          expect(
            wire.delegate.upload,
            isNot(contains(SupportProviderModelFixture.key)),
          );
          expect(
            wire.delegate.upload,
            isNot(contains(SupportProviderModelFixture.excluded)),
          );
          final body =
              jsonDecode(wire.delegate.upload!) as Map<String, dynamic>;
          for (final message in preview.messages) {
            expect(wire.delegate.upload, contains(message.text));
          }
          if (protocol == 'gemini') {
            final generation = body['generationConfig'] as Map<String, dynamic>;
            expect(generation['temperature'], 0.25);
            expect(generation['maxOutputTokens'], 512);
          } else {
            expect(body['model'], f.api.model);
            expect(body['temperature'], 0.25);
            expect(
              body[protocol == 'openai_responses' ||
                      protocol == 'custom_responses'
                  ? 'max_output_tokens'
                  : 'max_tokens'],
              512,
            );
          }
          expect(body.keys, isNot(contains('tools')));
          expect(body.keys, isNot(contains('response_format')));
          expect(body.keys, isNot(contains('session_id')));
          final raw = await f.rawMessages();
          expect(raw, isNot(contains('Synthetic native reply')));
          expect(raw, isNot(contains('Selected native history')));
          expect(raw, isNot(contains(SupportProviderModelFixture.key)));
          final durable = await f.repo.getMessageById(preview.replyMessageId);
          expect(durable!.body, result.message!.text);
          expect((await f.apiRepo.getById(f.api.id))!.apiKey, isEmpty);
        } finally {
          await f.close();
        }
      },
    );
  }

  for (final state in [
    'absent',
    'prepared',
    'missing',
    'corrupt',
    'unavailable',
    'wrong-purpose',
  ]) {
    synthetic(
      'native model denies $state without key fallback or approval',
      () async {
        final f = await SupportProviderModelFixture.create(
          storeKey: !['absent', 'prepared'].contains(state),
          prepared: ['prepared', 'missing'].contains(state),
          purposes: state == 'wrong-purpose'
              ? {NativeProviderPurpose.roleplay}
              : {NativeProviderPurpose.astoria},
        );
        try {
          if (state == 'missing') f.storage.values.remove(f.nativeStorageKey);
          if (state == 'corrupt') {
            f.storage.values[f.nativeStorageKey] = '{synthetic-corrupt';
          }
          if (state == 'unavailable') {
            f.storage.readError = StateError('Synthetic unavailable');
          }
          final emission = await f.emit();
          expect(emission.intent, isNull);
          expect(f.adapters, isEmpty);
          expect(f.dispatcherConstructions, 0);
          expect(f.queue.entries, 0);
          expect(f.published, isEmpty);
          expect((await f.apiRepo.getById(f.api.id))!.apiKey, isEmpty);
        } finally {
          await f.close();
        }
      },
    );
  }

  synthetic('prepared native row with legacy row key never falls back', () async {
    final f = await SupportProviderModelFixture.create(
      storeKey: false,
      prepared: true,
    );
    try {
      const legacy = 'SYNTHETIC_FORBIDDEN_LEGACY_FALLBACK';
      // Explicit fixture seed, deliberately bypassing the runtime mutation guard.
      await ApiConfigRepo(f.db).put(f.api.copyWith(apiKey: legacy));
      final emission = await f.emit();
      expect(emission.intent, isNull);
      expect(f.adapters, isEmpty);
      final rows = await f.metadata.load();
      expect(rows.single.configured, isFalse);
      expect(rows.single.characterCount, 0);
      expect(rows.single.toString(), isNot(contains(legacy)));
    } finally {
      await f.close();
    }
  });

  synthetic(
    'no selected model remains offline without native credential inspection',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        await f.workspace.changeSettings(
          f.session,
          (s) => s.copyWith(clearModelId: true),
        );
        f.runtime.invalidateBindings();
        final before = f.storage.readKeys
            .where((k) => k == f.nativeStorageKey)
            .length;
        final emission = await f.emit();
        expect(emission.reason, SupportModelRefusal.noModel);
        expect(
          f.storage.readKeys.where((k) => k == f.nativeStorageKey).length,
          before,
        );
        expect(f.adapters, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'unselected model history is not borrowed from local permission',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        await f.selectHistory(model: false);
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        expect(preview.messages.length, 2);
        expect(preview.supportMessages, 0);
        f.service.cancelPreview(preview);
        await submission.finished;
        expect(f.adapters, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'source mutation during initial settings decrypt denies original stamp',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        var changed = false;
        f.primitive.beforeDecrypt = (aad) async {
          if (!changed && aad.contains('workspace-settings-v1')) {
            changed = true;
            f.native.onApiMutationStarted()();
          }
        };
        final emission = await f.emit();
        expect(changed, isTrue);
        expect(emission.intent, isNull);
        expect(f.runtime.recipientConfirmed, isFalse);
        expect(f.adapters, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'cold restart registers key but cannot renew old input or recipient approval',
    () async {
      final original = await SupportProviderModelFixture.create();
      final record = original.storage.values[original.nativeStorageKey]!;
      await original.close();
      final f = await SupportProviderModelFixture.create(
        storeKey: false,
        storedNativeRecord: record,
      );
      try {
        final emission = await f.emit(
          'Cold question ${SupportProviderModelFixture.key}',
        );
        expect(emission.intent, isNull);
        expect(f.adapters, isEmpty);
        expect(
          f.redaction.redactor.redactText(SupportProviderModelFixture.key),
          isNot(SupportProviderModelFixture.key),
        );
        // The failed cold owner is not repaired. Explicit NEW synthetic user
        // review and a NEW model issuer are necessary for the next input.
        f.service.dispose();
        f.runtime.invalidateBindings();
        await f.reconfirm();
        final fresh = f.newService();
        try {
          final next = await fresh.emitInput(
            controller: f.controller,
            uiLifetime: Object(),
            draftRevision: 2,
            text: 'Fresh question',
            isEmitterCurrent: () => true,
            isDraftCurrent: () => true,
          );
          expect(next.intent, isNotNull);
          final submission = fresh.beginSend(next.intent!);
          final preview = (await submission.prepared).preview!;
          final result = await fresh.dispatch(fresh.approve(preview)!);
          expect(result.outcome!.status, PrivateTextStatus.complete);
          expect(f.adapters.single.calls, 1);
        } finally {
          fresh.dispose();
        }
      } finally {
        await f.close();
      }
    },
  );

  for (final stop in [false, true]) {
    synthetic(
      'approval cannot renew after held vault read: Stop=$stop',
      () async {
        final f = await SupportProviderModelFixture.create();
        final entered = Completer<void>(), release = Completer<void>();
        try {
          final submission = await f.submit();
          final preview = (await submission.prepared).preview!;
          final approval = f.service.approve(preview)!;
          f.storage.beforeRead = () async {
            if (f.storage.readKeys.last == f.nativeStorageKey &&
                !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
          };
          final dispatch = f.service.dispatch(approval);
          await entered.future;
          Future<void>? disabled;
          void Function()? finishMutation;
          if (stop) {
            f.service.stop();
          } else {
            finishMutation = f.native.onApiMutationStarted();
            disabled = f.native.credentials
                .disableNativeConnectionForOrdinaryMutation(
                  connectionId: f.api.id,
                );
          }
          release.complete();
          if (disabled != null) await disabled;
          finishMutation?.call();
          final result = await dispatch;
          expect(result.saved, isTrue);
          expect(result.outcome!.status, isNot(PrivateTextStatus.complete));
          expect(result.outcome!.dispatch, PrivateTextDispatch.notAdmitted);
          expect(f.adapters, isEmpty);
          expect(f.service.approve(preview), isNull);
          await f.service.dispatch(approval);
          expect(f.adapters, isEmpty);
        } finally {
          if (!release.isCompleted) release.complete();
          await f.close();
        }
      },
    );
  }

  for (final boundary in ['dispatcher', 'factory', 'fetch']) {
    synthetic(
      'retired $boundary callback never paints into replacement model owner',
      () async {
        final f = await SupportProviderModelFixture.create();
        try {
          final submission = await f.submit();
          final preview = (await submission.prepared).preview!;
          final approval = f.service.approve(preview)!;
          void retire() {
            f.owner = false;
            f.service.stop();
          }

          if (boundary == 'dispatcher') f.onDispatcher = retire;
          if (boundary == 'factory') f.onFactory = retire;
          if (boundary == 'fetch') f.onFetch = retire;
          final painted = f.published.length;
          final result = await f.service.dispatch(approval);
          expect(result.accepted, isTrue);
          expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
          expect(f.published.length, painted);
          expect(
            f.adapters.fold<int>(0, (sum, a) => sum + a.calls),
            boundary == 'fetch' ? 1 : 0,
          );
          expect(f.service.approve(preview), isNull);
        } finally {
          await f.close();
        }
      },
    );
  }

  synthetic(
    'quiet actual native private wire receives Stop and settles once',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        f.quiet = true;
        f.response = chatDelta(
          'Partial safe',
        ); // No terminal: wire then stays quiet.
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        final dispatch = f.service.dispatch(f.service.approve(preview)!);
        await f.activity.future;
        f.service.stop();
        final result = await dispatch;
        expect(result.saved, isTrue);
        expect(result.message!.status, 'stopped');
        expect(result.outcome!.status, PrivateTextStatus.stopped);
        expect(identical(await submission.finished, result), isTrue);
        final wire = f.adapters.single.delegate;
        await wire.cancelObserved.future;
        await wire.forceClosed.future;
        expect(f.adapters.single.calls, 1);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'key returned by fake wire is redacted before encrypted original settlement',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        f.response = chatComplete(
          'Echo ${SupportProviderModelFixture.key} safe tail',
        );
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        final result = await f.service.dispatch(f.service.approve(preview)!);
        expect(result.saved, isTrue);
        expect(
          result.message!.text,
          isNot(contains(SupportProviderModelFixture.key)),
        );
        expect(
          result.outcome!.text,
          isNot(contains(SupportProviderModelFixture.key)),
        );
        expect(
          await f.rawMessages(),
          isNot(contains(SupportProviderModelFixture.key)),
        );
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'truthful native metadata is purpose-independent and local-OFF is no read',
    () async {
      final f = await SupportProviderModelFixture.create(
        purposes: {NativeProviderPurpose.roleplay},
      );
      try {
        final before = f.storage.readKeys
            .where((k) => k == f.nativeStorageKey)
            .length;
        expect(
          await f.runtime.inspectSelectedConnection(f.session, () => true),
          isFalse,
        );
        expect(
          f.storage.readKeys.where((k) => k == f.nativeStorageKey).length,
          before,
        );
        await f.permissions.selectScopeFromNative(
          f.session,
          SupportPermissionScope(
            selectionRevision: 1,
            safeCategories: [SupportSafeCategory.connections],
          ),
          isCurrent: () => true,
        );
        await f.permissions.setGrantFromNative(
          f.session,
          SupportPermission.readSafeSettings,
          true,
          isCurrent: () => true,
        );
        await f.runtime.refresh();
        expect(
          await f.runtime.inspectSelectedConnection(f.session, () => true),
          isTrue,
        );
        expect(f.runtime.inspection!.configured, isTrue);
        expect(
          f.runtime.inspection!.characterCount,
          SupportProviderModelFixture.key.runes.length,
        );
        final metadata = await f.metadata.load();
        expect(metadata.single.configured, isTrue);
        expect(
          metadata.single.characterCount,
          SupportProviderModelFixture.key.runes.length,
        );
        expect(
          metadata.single.toString(),
          isNot(contains(SupportProviderModelFixture.key)),
        );
        expect((await f.emit()).intent, isNull);
        expect(f.adapters, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'unknown protected native metadata is omitted, not empty or legacy',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        f.storage.values[f.nativeStorageKey] = 'SYNTHETIC_CORRUPT_RECORD';
        expect(await f.metadata.load(), isEmpty);
        expect((await f.emit()).intent, isNull);
        expect(f.adapters, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'bulk native metadata registers cold keys before any variable label',
    () async {
      final seed = await SupportProviderModelFixture.create();
      final record = seed.storage.values[seed.nativeStorageKey]!;
      await seed.close();
      final f = await SupportProviderModelFixture.create(
        storeKey: false,
        storedNativeRecord: record,
      );
      try {
        // Explicit synthetic cold label seed, not a production mutation bypass.
        await ApiConfigRepo(
          f.db,
        ).put(f.api.copyWith(name: 'Label ${SupportProviderModelFixture.key}'));
        final metadata = await f.metadata.load();
        expect(metadata.single.configured, isTrue);
        expect(
          metadata.single.characterCount,
          SupportProviderModelFixture.key.runes.length,
        );
        expect(
          metadata.single.displayName,
          isNot(contains(SupportProviderModelFixture.key)),
        );
        expect(
          metadata.single.toString(),
          isNot(contains(SupportProviderModelFixture.key)),
        );
        expect(f.adapters, isEmpty);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'selected native source cannot borrow a different assistant model',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        await f.workspace.changeSettings(
          f.session,
          (s) => s.copyWith(modelId: 'different-model'),
        );
        f.runtime.invalidateBindings();
        await f.reconfirm();
        expect((await f.emit()).intent, isNull);
        expect(f.adapters, isEmpty);
        expect(f.dispatcherConstructions, 0);
      } finally {
        await f.close();
      }
    },
  );

  synthetic(
    'old context approval cannot survive lease retirement or renew itself',
    () async {
      final f = await SupportProviderModelFixture.create();
      try {
        final submission = await f.submit();
        final preview = (await submission.prepared).preview!;
        final approval = f.service.approve(preview)!;
        f.runtime.invalidateLease();
        final result = await f.service.dispatch(approval);
        expect(result.outcome?.dispatch, isNot(PrivateTextDispatch.admitted));
        expect(f.service.approve(preview), isNull);
        expect(f.adapters, isEmpty);
        expect(f.dispatcherConstructions, 0);
      } finally {
        await f.close();
      }
    },
  );
}
