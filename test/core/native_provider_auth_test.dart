import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import 'native_provider_fixture.dart';

void main() {
  test(
    'fresh restart observes binding without restoring approvals or reading legacy',
    () async {
      final original = NativeProviderFixture();
      await original.store(purposes: NativeProviderPurpose.values.toSet());
      final retired = await original.inspect();
      final restart = NativeProviderFixture(
        storage: original.storage,
        row: original.row,
      );
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: restart.credentials,
        transport: (binding, key) async {
          binding.requireFinalRequest(
            uri: binding.route.endpoint,
            method: 'POST',
            protocol: binding.route.protocol,
            purpose: binding.purpose,
            model: binding.connection.model,
            stream: true,
          );
          expect(key, nativeCanary);
          calls++;
        },
      );
      await expectLater(
        broker.dispatch(retired, route: restart.route(), isCurrent: () => true),
        throwsNative(NativeProviderFailure.stale),
      );
      for (final purpose in NativeProviderPurpose.values) {
        final observation = await restart.inspect(purpose);
        await broker.dispatch(
          observation,
          route: restart.route(purpose),
          isCurrent: () => true,
        );
        expect(
          await broker.metadata(observation, isCurrent: () => true),
          CredentialMetadata.fromSecret(nativeCanary),
        );
      }
      expect(calls, 4);
    },
  );

  test(
    'exact final URI/method/protocol/purpose/model binding and no redirect approval',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final observation = await f.inspect();
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (binding, key) async {
          expect(key, nativeCanary);
          final mutations = [
            (
              'https://other.example/v1/chat/completions',
              'POST',
              binding.route.protocol,
              binding.purpose,
              binding.connection.model,
            ),
            (
              'https://api.openai.com/v1/models',
              'POST',
              binding.route.protocol,
              binding.purpose,
              binding.connection.model,
            ),
            (
              binding.route.endpoint.toString(),
              'GET',
              binding.route.protocol,
              binding.purpose,
              binding.connection.model,
            ),
            (
              binding.route.endpoint.toString(),
              'POST',
              CredentialProtocol.anthropic,
              binding.purpose,
              binding.connection.model,
            ),
            (
              binding.route.endpoint.toString(),
              'POST',
              binding.route.protocol,
              NativeProviderPurpose.astoria,
              binding.connection.model,
            ),
            (
              binding.route.endpoint.toString(),
              'POST',
              binding.route.protocol,
              binding.purpose,
              'override-model',
            ),
          ];
          for (final mutation in mutations) {
            expect(
              () => binding.requireFinalRequest(
                uri: Uri.parse(mutation.$1),
                method: mutation.$2,
                protocol: mutation.$3,
                purpose: mutation.$4,
                model: mutation.$5,
                stream: true,
              ),
              throwsNative(NativeProviderFailure.denied),
            );
          }
          binding.requireFinalRequest(
            uri: binding.route.endpoint,
            method: 'POST',
            protocol: binding.route.protocol,
            purpose: binding.purpose,
            model: binding.connection.model,
            stream: true,
          );
          calls++;
        },
      );
      final wrong = CredentialRoute(
        endpoint: 'https://other.example/v1/chat/completions',
        protocol: CredentialProtocol.openAiChatCompletions,
        purpose: CredentialPurpose.chat,
      );
      await expectLater(
        broker.dispatch(observation, route: wrong, isCurrent: () => true),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(calls, 0);
      await broker.dispatch(
        observation,
        route: f.route(),
        isCurrent: () => true,
      );
      expect(calls, 1);
    },
  );

  test(
    'Gemini accepts only saved-model bound one-shot/stream actions with fixed alt query',
    () async {
      final f = NativeProviderFixture(
        row: const ApiConfig(
          id: 'native-test',
          model: 'gemini-test',
          protocol: 'gemini',
          endpoint:
              'https://generativelanguage.googleapis.com/v1beta/models/gemini-test:streamGenerateContent',
        ),
      );
      await f.store();
      final observation = await f.inspect();
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (binding, key) async {
          final stream = binding.route.endpoint.path.endsWith(
            ':streamGenerateContent',
          );
          final uri = stream
              ? binding.route.endpoint.replace(query: 'alt=sse')
              : binding.route.endpoint;
          binding.requireFinalRequest(
            uri: uri,
            method: 'POST',
            protocol: CredentialProtocol.gemini,
            purpose: NativeProviderPurpose.roleplay,
            model: 'gemini-test',
            stream: stream,
          );
          for (final bad in [
            uri.replace(query: 'alt=json'),
            uri.replace(query: 'key=TEST_ONLY'),
            uri.replace(
              path: uri.path.replaceAll('gemini-test', 'other-model'),
            ),
          ]) {
            expect(
              () => binding.requireFinalRequest(
                uri: bad,
                method: 'POST',
                protocol: CredentialProtocol.gemini,
                purpose: NativeProviderPurpose.roleplay,
                model: 'gemini-test',
                stream: stream,
              ),
              throwsNative(NativeProviderFailure.denied),
            );
          }
          expect(key, nativeCanary);
          calls++;
        },
      );
      for (final route in f.policy.routesFor(
        connection: f.reference().connection,
        purpose: NativeProviderPurpose.roleplay,
      )) {
        await broker.dispatch(observation, route: route, isCurrent: () => true);
      }
      expect(calls, 2);
    },
  );

  test(
    'pause vault read then revoke owner prevents invocation and old stamp ABA revival',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final reference = f.reference();
      final observation = await f.inspect();
      final started = Completer<void>();
      final release = Completer<void>();
      f.storage.beforeRead = () async {
        if (!started.isCompleted) {
          started.complete();
          await release.future;
        }
      };
      var calls = 0;
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, _) async {
          calls++;
        },
      );
      final request = broker.dispatch(
        observation,
        route: f.route(),
        isCurrent: () => true,
      );
      final refusal = expectLater(
        request,
        throwsNative(NativeProviderFailure.stale),
      );
      await started.future;
      f.ordinaryMutation();
      f.row = f.row.copyWith(name: 'changed-name');
      f.ordinaryMutation();
      f.row = f.row.copyWith(name: '');
      release.complete();
      await refusal;
      await f.credentials.settleOrdinaryInvalidations();
      expect(calls, 0);
      expect(f.auth.isCurrent(reference), false);
      await expectLater(
        Future.sync(
          () => f.credentials.inspectSavedConnection(
            connection: reference,
            isCurrent: () => true,
          ),
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      expect((await f.inspect()).state, NativeProviderCredentialState.ready);
    },
  );

  test(
    'consumer callbacks recheck currentness and suppress secret-bearing errors',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final observation = await f.inspect();
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, key) async {
          throw StateError('wire $key');
        },
      );
      await expectLater(
        broker.dispatch(observation, route: f.route(), isCurrent: () => true),
        throwsNative(NativeProviderFailure.unavailable),
      );
      var current = true;
      final retired = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (binding, _) async {
          current = false;
          expect(binding.isCurrent, false);
        },
      );
      await expectLater(
        retired.dispatch(
          observation,
          route: f.route(),
          isCurrent: () => current,
        ),
        throwsNative(NativeProviderFailure.stale),
      );
      expect(
        jsonEncode(observation.metadata.toJson()),
        isNot(contains(nativeCanary)),
      );
    },
  );

  test(
    'same string reentry changes PRIVATE revision and invalidates original observations',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final old = await f.inspect();
      final first =
          jsonDecode(f.storage.values[f.nativeStorageKey]!)
              as Map<String, dynamic>;
      await f.store();
      final next = await f.inspect();
      final second =
          jsonDecode(f.storage.values[f.nativeStorageKey]!)
              as Map<String, dynamic>;
      expect(next.metadata, old.metadata);
      expect(second['revision'], isNot(first['revision']));
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, _) async => fail('stale must not send'),
      );
      await expectLater(
        broker.dispatch(old, route: f.route(), isCurrent: () => true),
        throwsNative(NativeProviderFailure.stale),
      );
    },
  );

  test(
    'custom binding survives restart but fresh approval can never move an existing key',
    () async {
      final f = NativeProviderFixture(
        row: const ApiConfig(
          id: 'native-test',
          model: 'test-model',
          providerId: 'custom_chat_completion',
          protocol: 'custom_chat_completion',
          endpoint: 'https://provider.example/v1/chat/completions',
        ),
      );
      final displayed = f.policy.reviewCustomDestination(
        connection: f.reference().connection,
        purposes: {NativeProviderPurpose.roleplay},
        lifetime: f.lifetime,
      );
      await f.store(
        destinationApproval: f.policy.confirmCustomDestination(displayed),
      );
      final restart = NativeProviderFixture(storage: f.storage, row: f.row);
      var sent = false;
      final broker = NativeProviderCredentialBroker(
        credentials: restart.credentials,
        transport: (binding, key) async {
          expect(binding.route.endpoint.host, 'provider.example');
          expect(key, nativeCanary);
          sent = true;
        },
      );
      await broker.dispatch(
        await restart.inspect(),
        route: restart.route(),
        isCurrent: () => true,
      );
      expect(sent, true);
      restart.row = restart.row.copyWith(
        endpoint: 'https://other.example/v1/chat/completions',
      );
      final changed = restart.policy.reviewCustomDestination(
        connection: restart.reference().connection,
        purposes: {NativeProviderPurpose.roleplay},
        lifetime: restart.lifetime,
      );
      await expectLater(
        restart.store(
          destinationApproval: restart.policy.confirmCustomDestination(changed),
        ),
        throwsNative(NativeProviderFailure.conflicting),
      );
      final record = jsonDecode(f.storage.values[f.nativeStorageKey]!) as Map;
      expect(record['secret'], nativeCanary);
      expect(
        (record['connection'] as List)[3],
        'https://provider.example/v1/chat/completions',
      );
    },
  );

  test(
    'six protocol proxy bindings restart with only their exact reviewed routes and scopes',
    () async {
      final profiles = [
        ('openai', false, 'https://proxy.example/tenant/v7/chat/completions'),
        ('openai_responses', true, 'https://proxy.example/tenant/v7/responses'),
        ('anthropic', false, 'https://proxy.example/tenant/v7/messages'),
        (
          'gemini',
          false,
          'https://proxy.example/tenant/v7/models/test-model:streamGenerateContent',
        ),
        (
          'openrouter',
          false,
          'https://proxy.example/tenant/router/api/v7/chat/completions',
        ),
        (
          'custom_chat_completion',
          false,
          'https://proxy.example/tenant/custom/v7/chat/completions',
        ),
      ];
      final scopes = NativeProviderPurpose.values.toSet();
      for (final profile in profiles) {
        final original = NativeProviderFixture(
          row: ApiConfig(
            id: 'native-test',
            model: 'test-model',
            protocol: profile.$1,
            useResponsesApi: profile.$2,
            endpoint: profile.$3,
          ),
        );
        final review = original.policy.reviewCustomDestination(
          connection: original.reference().connection,
          purposes: scopes,
          lifetime: original.lifetime,
        );
        await original.store(
          purposes: scopes,
          destinationApproval: original.policy.confirmCustomDestination(review),
        );
        final oldObservation = await original.inspect();
        final persisted = original.storage.values[original.nativeStorageKey];
        final restart = NativeProviderFixture(
          storage: original.storage,
          row: original.row,
        );
        var calls = 0;
        final broker = NativeProviderCredentialBroker(
          credentials: restart.credentials,
          transport: (binding, key) async {
            expect(key, nativeCanary);
            expect(binding.connection.protocol, profile.$1);
            expect(binding.route.endpoint.host, 'proxy.example');
            final isGemini =
                binding.route.protocol == CredentialProtocol.gemini;
            final stream = isGemini
                ? binding.route.endpoint.path.endsWith(':streamGenerateContent')
                : true;
            final finalUri = isGemini && stream
                ? binding.route.endpoint.replace(query: 'alt=sse')
                : binding.route.endpoint;
            binding.requireFinalRequest(
              uri: finalUri,
              method: 'POST',
              protocol: binding.route.protocol,
              purpose: binding.purpose,
              model: 'test-model',
              stream: stream,
            );
            // Even a same-origin different prefix is neither redirect nor probe authority.
            expect(
              () => binding.requireFinalRequest(
                uri: finalUri.replace(path: '/other${finalUri.path}'),
                method: 'POST',
                protocol: binding.route.protocol,
                purpose: binding.purpose,
                model: 'test-model',
                stream: stream,
              ),
              throwsNative(NativeProviderFailure.denied),
            );
            expect(
              () => binding.requireFinalRequest(
                uri: finalUri,
                method: 'POST',
                protocol: binding.route.protocol,
                purpose: binding.purpose,
                model: 'unbound-model',
                stream: stream,
              ),
              throwsNative(NativeProviderFailure.denied),
            );
            calls++;
          },
        );
        await expectLater(
          broker.dispatch(
            oldObservation,
            route: restart.route(),
            isCurrent: () => true,
          ),
          throwsNative(NativeProviderFailure.stale),
        );
        for (final purpose in scopes) {
          final observation = await restart.inspect(purpose);
          expect(observation.state, NativeProviderCredentialState.ready);
          final routes = restart.policy.routesFor(
            connection: restart.reference(purpose).connection,
            purpose: purpose,
          );
          expect(
            routes.any((route) => route.endpoint.toString() == profile.$3),
            true,
          );
          for (final route in routes) {
            await broker.dispatch(
              observation,
              route: route,
              isCurrent: () => true,
            );
          }
        }
        expect(
          calls,
          profile.$1 == 'gemini' ? scopes.length * 2 : scopes.length,
        );
        expect(
          restart.storage.values[restart.nativeStorageKey],
          persisted,
        ); // Observation does not rebind.
        expect(restart.storage.operations, isNot(contains('delete')));
      }
    },
  );

  test(
    'six protocol proxy changes cannot move/reactivate an old key even with fresh approval',
    () async {
      final profiles = [
        ('openai', false, 'https://proxy.example/tenant/v7/chat/completions'),
        ('openai_responses', true, 'https://proxy.example/tenant/v7/responses'),
        ('anthropic', false, 'https://proxy.example/tenant/v7/messages'),
        (
          'gemini',
          false,
          'https://proxy.example/tenant/v7/models/test-model:streamGenerateContent',
        ),
        (
          'openrouter',
          false,
          'https://proxy.example/tenant/router/api/v7/chat/completions',
        ),
        (
          'custom_chat_completion',
          false,
          'https://proxy.example/tenant/custom/v7/chat/completions',
        ),
      ];
      for (final profile in profiles) {
        final f = NativeProviderFixture(
          row: ApiConfig(
            id: 'native-test',
            model: 'test-model',
            protocol: profile.$1,
            useResponsesApi: profile.$2,
            endpoint: profile.$3,
          ),
        );
        final originalRow = f.row;
        final review = f.policy.reviewCustomDestination(
          connection: f.reference().connection,
          purposes: {NativeProviderPurpose.roleplay},
          lifetime: f.lifetime,
        );
        await f.store(
          destinationApproval: f.policy.confirmCustomDestination(review),
        );
        final originalKey = f.nativeStorageKey;
        final originalRecord = f.storage.values[originalKey];
        f.row = f.row.copyWith(
          endpoint: f.row.endpoint.replaceFirst(
            'proxy.example',
            'other.example',
          ),
        );
        final changedRow = f.row;
        final attempted = f.policy.reviewCustomDestination(
          connection: f.reference().connection,
          purposes: {NativeProviderPurpose.roleplay},
          lifetime: f.lifetime,
        );
        await expectLater(
          f.store(
            destinationApproval: f.policy.confirmCustomDestination(attempted),
          ),
          throwsNative(NativeProviderFailure.conflicting),
        );
        expect(
          f.storage.values[originalKey],
          originalRecord,
        ); // Unobserved edit cannot transport auth.
        var calls = 0;
        final broker = NativeProviderCredentialBroker(
          credentials: f.credentials,
          transport: (_, _) async {
            calls++;
          },
        );
        await expectLater(
          broker.dispatch(
            await f.inspect(),
            route: f.route(),
            isCurrent: () => true,
          ),
          throwsNative(NativeProviderFailure.stale),
        );
        expect(calls, 0);
        // Actual ordinary changes require the explicit affected-ID guard BEFORE editing.
        f.row = originalRow;
        await f.credentials.disableNativeConnectionForOrdinaryMutation(
          connectionId: f.row.id,
        );
        f.ordinaryMutation();
        f.row = changedRow;
        final changedReview = f.policy.reviewCustomDestination(
          connection: f.reference().connection,
          purposes: {NativeProviderPurpose.roleplay},
          lifetime: f.lifetime,
        );
        final changedApproval = f.policy.confirmCustomDestination(
          changedReview,
        );
        await expectLater(
          f.store(destinationApproval: changedApproval),
          throwsNative(NativeProviderFailure.conflicting),
        );
        final disabledRecord = f.storage.values[originalKey];
        final protected = jsonDecode(disabledRecord!) as Map;
        expect(protected['secret'], nativeCanary);
        expect(protected['active'], false);
        expect((protected['connection'] as List)[3], profile.$3);
        final restart = NativeProviderFixture(
          storage: f.storage,
          row: originalRow,
        );
        expect(
          (await restart.inspect()).state,
          NativeProviderCredentialState.disabled,
        );
        // A DIFFERENT fresh profile needs its own native confirmation and entry.
        f.row = changedRow.copyWith(id: 'fresh-profile');
        await expectLater(
          f.store(destinationApproval: changedApproval),
          throwsNative(NativeProviderFailure.denied),
        );
        final fresh = f.policy.reviewCustomDestination(
          connection: f.reference().connection,
          purposes: {NativeProviderPurpose.roleplay},
          lifetime: f.lifetime,
        );
        const freshSecret = 'SECOND_TEST_ONLY_🔐';
        expect(
          await f.store(
            secret: freshSecret,
            destinationApproval: f.policy.confirmCustomDestination(fresh),
          ),
          CredentialMetadata.fromSecret(freshSecret),
        );
        expect((await f.inspect()).state, NativeProviderCredentialState.ready);
        expect(f.storage.values[originalKey], disabledRecord);
        expect(
          f.storage.values.length,
          2,
        ); // No migration/copy or legacy slot creation.
        expect(f.storage.operations, isNot(contains('delete')));
      }
    },
  );

  test(
    'constructor consumer sees canary only natively; joined split echo is redacted',
    () async {
      final f = NativeProviderFixture();
      await f.store();
      final publicOutputs = <String>[];
      final broker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, key) async {
          final split = key.length ~/ 2;
          final chunks = [
            'echo:',
            key.substring(0, split),
            key.substring(split),
          ];
          // This is a fixture for the later transport-owned output fence, NOT a
          // claim that per-delta replace is safe or production streaming is wired.
          publicOutputs.add(f.redaction.redactor.redactText(chunks.join()));
        },
      );
      final observation = await f.inspect();
      await broker.dispatch(
        observation,
        route: f.route(),
        isCurrent: () => true,
      );
      expect(publicOutputs.join(), isNot(contains(nativeCanary)));
      expect(publicOutputs.join(), contains('[REDACTED]'));
    },
  );

  test(
    'chat and memory constructor consumers overlap without holding vault queue',
    () async {
      final f = NativeProviderFixture();
      await f.store(
        purposes: {
          NativeProviderPurpose.roleplay,
          NativeProviderPurpose.memoryBooks,
        },
      );
      final chat = await f.inspect();
      final memory = await f.inspect(NativeProviderPurpose.memoryBooks);
      final chatStarted = Completer<void>();
      final memoryStarted = Completer<void>();
      final finishChat = Completer<void>();
      final finishMemory = Completer<void>();
      var chatCurrent = true;
      final completed = <String>[];
      final chatBroker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, key) async {
          expect(key, nativeCanary);
          chatStarted.complete();
          await finishChat.future;
          completed.add('chat native completion');
        },
      );
      final memoryBroker = NativeProviderCredentialBroker(
        credentials: f.credentials,
        transport: (_, key) async {
          expect(key, nativeCanary);
          memoryStarted.complete();
          await finishMemory.future;
          completed.add('memory native completion');
        },
      );
      final chatJob = chatBroker.dispatch(
        chat,
        route: f.route(),
        isCurrent: () => chatCurrent,
      );
      final chatRefusal = expectLater(
        chatJob,
        throwsNative(NativeProviderFailure.stale),
      );
      final memoryJob = memoryBroker.dispatch(
        memory,
        route: f.route(NativeProviderPurpose.memoryBooks),
        isCurrent: () => true,
      );
      await Future.wait([chatStarted.future, memoryStarted.future]);
      chatCurrent = false;
      finishMemory.complete();
      await memoryJob;
      expect(completed, ['memory native completion']);
      finishChat.complete();
      await chatRefusal;
      expect(completed, ['memory native completion', 'chat native completion']);
    },
  );
}
