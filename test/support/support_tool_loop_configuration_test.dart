import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/native_provider_credentials.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_app_action_context.dart';
import 'package:glaze_flutter/features/support_assistant/services/app_control/support_app_connections_adapter.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_connections_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_tool_loop_configuration_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final action in ['create', 'update']) {
    configurationWidgetTest(
      'actual MODEL Send -> exact native Apply -> $action CAS survives OWN source fence once',
      (tester, f) async {
        if (action == 'update') await configurationUpdateSource(tester, f);
        final repo = f.core.native.apiRepo;
        final before = await tester.runAsync(repo.getConfigIds);
        final original = f.core.native.native;
        final oldAuth = original.auth.referenceFor(
          f.core.native.api,
          NativeProviderPurpose.astoria,
        )!;
        final oldSource = original.sources.captureOriginalStamp();
        final keyRecord =
            f.core.native.storage.values[f.core.native.nativeStorageKey];
        final writes = f.core.native.storage.writeKeys.length;
        final request = f.core.call(
          'astoria_connection_$action',
          action == 'create'
              ? configurationCreate
              : {
                  'connectionId': f.core.native.api.id,
                  'name': configurationName,
                  'maxTokens': 2048,
                  'contextSize': 16384,
                  'temperature': 0.3,
                },
        );
        // A second typed call in this SAME turn must not execute after the
        // admitted configuration effect retires the original network source.
        final extra = f.core.call('astoria_preferences_update', {
          'hideTooltips': true,
        }, id: 'call_2');
        final message =
            ((request['choices'] as List).single as Map)['message'] as Map;
        final extraMessage =
            ((extra['choices'] as List).single as Map)['message'] as Map;
        (message['tool_calls'] as List).addAll(
          extraMessage['tool_calls'] as List,
        );
        f.core.replies.add(request);
        await configurationSend(tester, f);
        final preview = tester
            .widget<Text>(
              find.descendant(
                of: find.byKey(
                  const ValueKey('support_tool_confirmation_preview'),
                ),
                matching: find.byType(Text),
              ),
            )
            .data!;
        expect(preview, contains('astoria_connection_$action'));
        expect(preview, contains(configurationName));
        expect(preview, contains('2048'));
        configurationNoEgress(f, preview);
        final oldApply = tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_tool_confirmation_accept')),
            )
            .onTap!;
        await configurationDecision(tester, 'accept');
        await configurationIdle(tester, f);
        final reply = await configurationReply(tester, f);
        final after = await tester.runAsync(repo.getConfigIds);
        final id = action == 'create'
            ? after!.singleWhere((id) => !before!.contains(id))
            : f.core.native.api.id;
        final saved = await tester.runAsync(() => repo.inspectKeyless(id));
        expect(saved, isNotNull);
        expect(saved!.view.displayName, configurationName);
        expect(saved.view.maxTokens, 2048);
        expect(saved.view.contextSize, 16384);
        expect(saved.view.temperature, 0.3);
        expect(
          saved.view.endpoint,
          'https://api.openai.com/v1/chat/completions',
        );
        expect(
          saved.view.model,
          action == 'create' ? 'synthetic-model' : f.core.native.api.model,
        );
        expect(after!.length, before!.length + (action == 'create' ? 1 : 0));
        expect(reply.status, 'stopped');
        expect(reply.body, contains('astoria_connection_$action'));
        expect(reply.body, contains('изменение сохранено'));
        expect(
          reply.body,
          isNot(contains('результат изменения не подтверждён')),
        );
        expect(f.core.wire, hasLength(1));
        expect(f.core.prefs.getBool('hideTooltips'), isNot(isTrue));
        expect(original.auth.isCurrent(oldAuth), isFalse);
        expect(
          original.sources.isOriginalCurrent(
            oldSource,
            () => original.isCurrent,
          ),
          isFalse,
        );
        expect(
          f.core.native.storage.values[f.core.native.nativeStorageKey],
          keyRecord,
        );
        expect(
          f.core.native.storage.writeKeys
              .skip(writes)
              .any((key) => key.contains('native_llm')),
          isFalse,
        );
        final metadata = await tester.runAsync(
          () => original.credentialReader.readConfiguration(
            connectionId: id,
            isCurrent: () => original.isCurrent,
          ),
        );
        expect(metadata!.metadata, isNotNull);
        expect(metadata.metadata!.configured, action == 'update');
        expect(
          metadata.metadata!.characterCount,
          action == 'update' ? f.core.boundSyntheticSecret.runes.length : 0,
        );
        oldApply(); // Retained final button is inert; no second native attempt.
        await tester.pump();
        expect(await tester.runAsync(repo.getConfigIds), after);
        expect(f.core.wire, hasLength(1));
        expect(f.router.routeInformationProvider.value.uri.path, '/support');
        configurationNoEgress(f, reply.body);
      },
    );
  }

  configurationWidgetTest(
    'actual model configuration Cancel has no domain/key effect',
    (tester, f) async {
      final before = await tester.runAsync(f.core.native.apiRepo.getConfigIds);
      final writes = f.core.native.storage.writeKeys.length;
      f.core.replies.addAll([
        f.core.call('astoria_connection_create', configurationCreate),
        f.core.answer('Everything succeeded.'),
      ]);
      await configurationSend(tester, f);
      await configurationDecision(tester, 'cancel');
      await configurationIdle(tester, f);
      final reply = await configurationReply(tester, f);
      expect(await tester.runAsync(f.core.native.apiRepo.getConfigIds), before);
      expect(f.core.native.storage.writeKeys.length, writes);
      expect(reply.body, isNot(contains('Everything succeeded.')));
      expect(reply.body, isNot(contains('изменение сохранено')));
      expect(reply.status, 'error');
      expect(
        f.core.wire,
        hasLength(2),
      ); // Cancel truth is correlated, never retried.
      final result = (f.core.wire.last['messages'] as List)
          .where((m) => m['role'] == 'tool')
          .single;
      expect(result['tool_call_id'], 'call_1');
      final content = jsonDecode(result['content'] as String) as Map;
      expect(content['code'], 'denied');
      expect(content['effect'], 'none');
      configurationNoEgress(f, reply.body);
    },
  );

  for (final replacement in [
    'Stop',
    'issuer',
    'session',
    'source',
    'ROOT',
    'UI',
  ]) {
    configurationWidgetTest(
      '$replacement after actual Apply but BEFORE terminal admission denies all writes',
      (tester, f) async {
        final before = await tester.runAsync(
          f.core.native.apiRepo.getConfigIds,
        );
        final writes = f.core.native.storage.writeKeys.length;
        f.core.replies.add(
          f.core.call('astoria_connection_create', configurationCreate),
        );
        await configurationSend(tester, f);
        final stop = tester
            .widget<IconButton>(
              find.byKey(const ValueKey('support_composer_stop_btn')),
            )
            .onPressed!;
        final entered = Completer<void>(), release = configurationRelease(f);
        f.core.native.storage.beforeRead = () async {
          if (!entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        await configurationDecision(tester, 'accept');
        await f.join(tester, entered.future);
        switch (replacement) {
          case 'Stop':
            stop(); // Actual original native composer Stop callback.
          case 'issuer':
            f.core.native.native.dispose();
          case 'session':
            f.core.native.runtime.selectSession('hidden-session', force: true);
          case 'source':
            f.core.native.revisions.beginMutation()();
          case 'ROOT':
            f.core.native.rootCurrent = false;
          case 'UI':
            f.router.go('/menu/settings');
        }
        f.core.displayCurrent = false;
        final painted = f.core.displayed.length;
        release.complete();
        await configurationIdle(tester, f);
        f.core.native.storage.beforeRead = null;
        expect(
          await tester.runAsync(f.core.native.apiRepo.getConfigIds),
          before,
        );
        expect(f.core.native.storage.writeKeys.length, writes);
        expect(f.core.wire, hasLength(1));
        expect(f.core.displayed.length, painted);
        final reply = await configurationReply(tester, f);
        expect(reply.body, isNot(contains('изменение сохранено')));
        expect(reply.status, 'stopped');
        configurationNoEgress(f, reply.body);
      },
    );
  }

  configurationWidgetTest(
    'actual latest-target ordinary CAS wins during native preflight; old Apply cannot overwrite',
    (tester, f) async {
      await configurationUpdateSource(tester, f);
      f.core.replies.add(
        f.core.call('astoria_connection_update', {
          'connectionId': f.core.native.api.id,
          'name': configurationName,
        }),
      );
      await configurationSend(tester, f);
      final entered = Completer<void>(), release = configurationRelease(f);
      f.core.native.sql.afterSelect = (statement, args) async {
        if (!entered.isCompleted && statement.contains('api_configs')) {
          entered.complete();
          await release.future;
        }
      };
      await configurationDecision(tester, 'accept');
      await f.join(tester, entered.future);
      f.core.native.sql.afterSelect = null;
      await tester.runAsync(
        () => f.core.native.apiRepo.put(
          f.core.native.api.copyWith(
            name: 'Competing native edit',
            maxTokens: 8192,
          ),
        ),
      );
      release.complete();
      await configurationIdle(tester, f);
      final saved = await tester.runAsync(
        () => f.core.native.apiRepo.inspectKeyless(f.core.native.api.id),
      );
      expect(saved!.view.displayName, 'Competing native edit');
      expect(saved.view.maxTokens, 8192);
      final reply = await configurationReply(tester, f);
      expect(reply.body, isNot(contains('изменение сохранено')));
      expect(f.core.wire, hasLength(1));
      configurationNoEgress(f, reply.body);
    },
  );

  configurationWidgetTest(
    'real Stop at terminal ORIGINAL ROOT checkpoint prevents fence/domain admission',
    (tester, f) async {
      final before = await tester.runAsync(f.core.native.apiRepo.getConfigIds);
      final writes = f.core.native.storage.writeKeys.length;
      f.core.replies.add(
        f.core.call('astoria_connection_create', configurationCreate),
      );
      await configurationSend(tester, f);
      final stop = tester
          .widget<IconButton>(
            find.byKey(const ValueKey('support_composer_stop_btn')),
          )
          .onPressed!;
      var stopped = false;
      f.core.native.sql.afterSelect = (statement, args) async {
        if (!stopped && statement.contains('support_messages')) {
          stopped = true;
          stop();
        }
      };
      await configurationDecision(tester, 'accept');
      await configurationIdle(tester, f);
      f.core.native.sql.afterSelect = null;
      expect(
        stopped,
        isTrue,
      ); // After the confirmation, only terminal ROOT reads H.
      expect(await tester.runAsync(f.core.native.apiRepo.getConfigIds), before);
      expect(f.core.native.storage.writeKeys.length, writes);
      expect(f.core.wire, hasLength(1));
      expect(
        (await configurationReply(tester, f)).body,
        isNot(contains('изменение сохранено')),
      );
    },
  );

  for (final invalidation in [
    'protected model change',
    'corrupt protected metadata',
  ]) {
    configurationWidgetTest(
      'exact Apply cannot bypass $invalidation or export key/error JSON',
      (tester, f) async {
        await configurationUpdateSource(tester, f);
        final ui = configurationUi(tester, f);
        final before = await tester.runAsync(
          () => f.core.native.apiRepo.inspectKeyless(f.core.native.api.id),
        );
        final keyRecord =
            f.core.native.storage.values[f.core.native.nativeStorageKey];
        final writes = f.core.native.storage.writeKeys.length;
        f.core.replies.add(
          f.core.call('astoria_connection_update', {
            'connectionId': f.core.native.api.id,
            if (invalidation == 'protected model change')
              'model': 'other-model'
            else
              'name': configurationName,
          }),
        );
        final send = await configurationAction(
          tester,
          () => f.core.send(toolUi: ui.ports),
        );
        await f.join(tester, f.core.firstFetch.future);
        await configurationModal(tester, f);
        if (invalidation == 'corrupt protected metadata') {
          var injected = false;
          f.core.native.storage.beforeRead = () async {
            if (!injected) {
              injected = true;
              f.core.native.storage.values[f.core.native.nativeStorageKey] =
                  '{"SYNTHETIC_NATIVE_FAILURE_RAW":"invalid protected record"}';
            }
          };
        }
        await configurationDecision(tester, 'accept');
        final result = await f.join(tester, send.finished);
        f.core.native.storage.beforeRead = null;
        final after = await tester.runAsync(
          () => f.core.native.apiRepo.inspectKeyless(f.core.native.api.id),
        );
        expect(after!.view, before!.view);
        expect(f.core.native.storage.writeKeys.length, writes);
        if (invalidation == 'protected model change') {
          expect(
            f.core.native.storage.values[f.core.native.nativeStorageKey],
            keyRecord,
          );
        }
        expect(result.message?.text, isNot(contains('изменение сохранено')));
        expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
        expect(f.core.wire, hasLength(1));
        configurationNoEgress(f, result.message?.text ?? '');
        ui.dispose();
      },
    );
  }

  for (final interruption in ['Stop', 'session and route']) {
    configurationWidgetTest(
      'already admitted native CAS joins persisted fact after $interruption; never paints B',
      (tester, f) async {
        await configurationUpdateSource(tester, f);
        final ui = configurationUi(tester, f);
        f.core.replies.add(
          f.core.call('astoria_connection_update', {
            'connectionId': f.core.native.api.id,
            'name': configurationName,
          }),
        );
        final send = await configurationAction(
          tester,
          () => f.core.send(toolUi: ui.ports),
        );
        await f.join(tester, f.core.firstFetch.future);
        await configurationModal(tester, f);
        final entered = Completer<void>(), release = configurationRelease(f);
        f.core.native.sql.afterWrite = (statement) async {
          if (!entered.isCompleted && statement.contains('api_configs')) {
            entered.complete();
            await release.future;
          }
        };
        await configurationDecision(tester, 'accept');
        await f.join(tester, entered.future);
        if (interruption == 'Stop') {
          send.stop();
        } else {
          f.core.native.runtime.selectSession('hidden-session', force: true);
          f.router.go('/menu/settings');
        }
        f.core.displayCurrent = false;
        final painted = f.core.displayed.length;
        release.complete();
        final result = await f.join(tester, send.finished);
        f.core.native.sql.afterWrite = null;
        expect(result.saved, isTrue);
        expect(result.message?.text, contains('изменение сохранено'));
        expect(result.outcome?.status, PrivateTextStatus.stopped);
        final saved = await tester.runAsync(
          () => f.core.native.apiRepo.inspectKeyless(f.core.native.api.id),
        );
        expect(saved!.view.displayName, configurationName);
        expect(f.core.wire, hasLength(1));
        expect(f.core.displayed.length, painted);
        await tester.pumpAndSettle();
        if (interruption == 'session and route') {
          expect(find.textContaining('изменение сохранено'), findsNothing);
          expect(
            f.router.routeInformationProvider.value.uri.path,
            '/menu/settings',
          );
        }
        configurationNoEgress(f, result.message?.text ?? '');
        ui.dispose();
      },
    );
  }

  for (final failure in [
    'SQL provisional write',
    'native preparation write then throw',
  ]) {
    configurationWidgetTest(
      '$failure after native admission remains factual uncertainty with no retry/replay',
      (tester, f) async {
        if (failure == 'SQL provisional write') {
          await configurationUpdateSource(tester, f);
        }
        final ui = configurationUi(tester, f);
        final before = await tester.runAsync(
          f.core.native.apiRepo.getConfigIds,
        );
        f.core.replies.add(
          f.core.call(
            failure == 'SQL provisional write'
                ? 'astoria_connection_update'
                : 'astoria_connection_create',
            failure == 'SQL provisional write'
                ? {
                    'connectionId': f.core.native.api.id,
                    'name': configurationName,
                  }
                : configurationCreate,
          ),
        );
        final send = await configurationAction(
          tester,
          () => f.core.send(toolUi: ui.ports),
        );
        await f.join(tester, f.core.firstFetch.future);
        await configurationModal(tester, f);
        final retained = tester
            .widget<GlazeActionButton>(
              find.byKey(const ValueKey('support_tool_confirmation_accept')),
            )
            .onTap!;
        if (failure == 'SQL provisional write') {
          f.core.native.sql.afterWrite = (statement) async {
            if (statement.contains('api_configs')) {
              throw StateError('SYNTHETIC_NATIVE_FAILURE_RAW');
            }
          };
        } else {
          f.core.native.storage.writeThenThrow = true;
        }
        await configurationDecision(tester, 'accept');
        final result = await f.join(tester, send.finished);
        f.core.native.sql.afterWrite = null;
        f.core.native.storage.writeThenThrow = false;
        expect(result.saved, isTrue);
        expect(
          result.message?.text,
          contains('результат изменения не подтверждён'),
        );
        expect(result.message?.text, isNot(contains('изменение сохранено')));
        expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
        expect(
          await tester.runAsync(f.core.native.apiRepo.getConfigIds),
          before,
        );
        if (failure == 'SQL provisional write') {
          final observed = await tester.runAsync(
            () => f.core.native.apiRepo.inspectKeyless(f.core.native.api.id),
          );
          expect(
            observed!.view.displayName,
            isNot(configurationName),
          ); // Transaction rollback, not COMMIT fault evidence.
        } else {
          expect(
            f.core.native.storage.writeKeys.any(
              (key) => key.contains('native_prepared'),
            ),
            isTrue,
          );
          expect(
            f.core.native.storage.values.keys.any(
              (key) => key.contains('native_prepared'),
            ),
            isTrue,
          );
        }
        final writes = f.core.native.sql.writes.length;
        retained();
        await tester.pump();
        expect(f.core.native.sql.writes.length, writes);
        expect(f.core.wire, hasLength(1));
        configurationNoEgress(f, result.message?.text ?? '');
        ui.dispose();
      },
    );
  }

  toolLoopTest(
    'actual native create/update previews form BEFORE confirmation; no unconfirmed terminal effect',
    (f) async {
      // Real guarded ordinary setup in this declared synthetic native root only.
      final repo = f.native.apiRepo;
      final saved = (await repo.getById(f.native.api.id))!;
      await repo.put(saved.copyWith(embeddingUseSame: false));
      final before = await repo.getConfigIds();
      final writes = f.native.storage.writeKeys.length;
      final root = ConfigurationPreviewOnlyRoot();
      final context = SupportAppActionContext(
        runId: 'preview-before-confirmation',
        sessionId: f.native.session,
        cancelToken: CancelToken(),
        isCurrent: () => f.native.native.isCurrent,
        allowReversibleChanges: true,
        terminalRoot: root,
      );
      final adapter = SupportAppConnectionsAdapter(
        repo: repo,
        native: SupportAppControlNativeConnections(
          runtime: f.native.native,
          isOriginalRoot: () => f.native.rootCurrent,
        ),
      );
      for (final action in ['create', 'update']) {
        final prepared = await adapter.prepare(
          'astoria_connection_$action',
          action == 'create'
              ? configurationCreate
              : {'connectionId': saved.id, 'name': configurationName},
          context,
        );
        expect(prepared, isNotNull);
        expect(prepared!.observationIsCurrent(), isTrue);
        expect(prepared.observation, isA<KeylessApiConfigTerminalPlan>());
        expect(prepared.preview, isNotEmpty);
        expect(
          context.isConfirmedTerminalPlan(
            prepared.observation as KeylessApiConfigTerminalPlan,
          ),
          isFalse,
        );
        final outcome = await prepared.execute(() => context.current);
        expect(outcome.code.name, 'conflict');
        expect(outcome.effect.name, 'none');
      }
      expect(root.attempts, 0);
      expect(await repo.getConfigIds(), before);
      expect(
        (await repo.inspectKeyless(saved.id))!.view.displayName,
        saved.name,
      );
      expect(f.native.storage.writeKeys.length, writes);
      expect(f.wire, isEmpty);
    },
  );

  toolLoopTest(
    'native terminal bool/no capsule cannot effect; wrong issuer and retained/replayed capsule denied',
    (f) async {
      final before = await f.native.apiRepo.getConfigIds();
      final revision = f.native.revisions.revision;
      final writes = f.native.storage.writeKeys.length;
      final port = ConfigurationNoCapsulePort(() => f.native.native.isCurrent);
      final owner = KeylessApiConfigTerminalEffectOwner(
        repo: f.native.apiRepo,
        admission: port,
      );
      final plan = owner.create(configurationDraft());
      port.plan = plan;
      final other = KeylessApiConfigTerminalEffectOwner(
        repo: f.native.apiRepo,
        admission: port,
      );
      expect(await other.execute(plan), isNull);
      expect(port.attempts, 0);
      expect(await owner.execute(plan), isNull);
      expect(port.attempts, 1);
      expect(await owner.execute(plan), isNull);
      expect(port.attempts, 1);
      expect(port.retained, isNotNull);
      expect(
        () => port.retained!.dispatch(),
        throwsA(isA<KeylessApiConfigException>()),
      );
      expect(await f.native.apiRepo.getConfigIds(), before);
      expect(f.native.revisions.revision, revision);
      expect(f.native.storage.writeKeys.length, writes);
      expect(f.wire, isEmpty);
    },
  );

  toolLoopTest(
    'actual native composition cannot execute an unconfirmed opaque configuration plan',
    (f) async {
      final before = await f.native.apiRepo.getConfigIds();
      final context = SupportAppActionContext(
        runId: 'unconfirmed-native-run',
        sessionId: f.native.session,
        cancelToken: CancelToken(),
        isCurrent: () => f.native.native.isCurrent,
        allowReversibleChanges: true,
      );
      final native = SupportAppControlNativeConnections(
        runtime: f.native.native,
        isOriginalRoot: () => f.native.rootCurrent,
      );
      final owner = native.terminalEffects(f.native.apiRepo, context)!;
      expect(await owner.execute(owner.create(configurationDraft())), isNull);
      expect(await f.native.apiRepo.getConfigIds(), before);
      expect(f.wire, isEmpty);
    },
  );
}
