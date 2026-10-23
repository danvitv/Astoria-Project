import 'package:flutter_test/flutter_test.dart';

import 'native_provider_fixture.dart';

void main() {
  test(
    'standard routes are fixed exact protocol templates for all four purposes',
    () {
      final templates = [
        (
          'openai',
          false,
          'https://api.openai.com/v1/chat/completions',
          CredentialProtocol.openAiChatCompletions,
        ),
        (
          'openai_responses',
          true,
          'https://api.openai.com/v1/responses',
          CredentialProtocol.openAiResponses,
        ),
        (
          'anthropic',
          false,
          'https://api.anthropic.com/v1/messages',
          CredentialProtocol.anthropic,
        ),
        (
          'openrouter',
          false,
          'https://openrouter.ai/api/v1/chat/completions',
          CredentialProtocol.openAiChatCompletions,
        ),
        (
          'custom_chat_completion',
          false,
          'https://api.openai.com/v1/chat/completions',
          CredentialProtocol.openAiChatCompletions,
        ),
        (
          'custom_chat_completion',
          true,
          'https://api.openai.com/v1/responses',
          CredentialProtocol.openAiResponses,
        ),
      ];
      for (final template in templates) {
        final f = NativeProviderFixture(
          row: ApiConfig(
            id: 'native-test',
            model: 'test-model',
            protocol: template.$1,
            useResponsesApi: template.$2,
            endpoint: template.$3,
          ),
        );
        for (final purpose in NativeProviderPurpose.values) {
          final route = f.route(purpose);
          expect(route.endpoint.toString(), template.$3);
          expect(route.protocol, template.$4);
          expect(
            f.policy.standardEndpointFor(
              template.$1,
              f.row.model,
              useResponsesApi: template.$2,
            ),
            template.$3,
          );
          expect(
            f.policy.requiresCustomDestinationApproval(
              f.reference(purpose).connection,
            ),
            false,
          );
        }
      }
    },
  );

  test('Gemini binds saved model and explicitly describes both exact actions', () {
    final f = NativeProviderFixture(
      row: const ApiConfig(
        id: 'native-test',
        model: 'gemini-test',
        protocol: 'gemini',
        endpoint:
            'https://generativelanguage.googleapis.com/v1beta/models/gemini-test:streamGenerateContent',
      ),
    );
    final routes = f.policy.routesFor(
      connection: f.reference().connection,
      purpose: NativeProviderPurpose.roleplay,
    );
    expect(routes.map((r) => r.endpoint.path), [
      '/v1beta/models/gemini-test:generateContent',
      '/v1beta/models/gemini-test:streamGenerateContent',
    ]);
    expect(
      f.policy.standardEndpointFor('gemini', 'gemini-test'),
      f.row.endpoint,
    );
    expect(
      f.policy.standardEndpointFor('gemini', 'gemini-test', stream: false),
      'https://generativelanguage.googleapis.com/v1beta/models/gemini-test:generateContent',
    );
    expect(
      f.policy.requiresCustomDestinationApproval(f.reference().connection),
      false,
    );
    f.row = f.row.copyWith(model: 'different-model');
    expect(() => f.route(), throwsNative(NativeProviderFailure.denied));
  });

  test(
    'known host or compatible path is route data, not entry or wire authority',
    () async {
      for (final endpoint in [
        'https://api.groq.com/openai/v1/chat/completions',
        'https://api.openai.com/proxy/v1/chat/completions',
      ]) {
        final f = NativeProviderFixture();
        f.row = f.row.copyWith(endpoint: endpoint);
        final route = f.route();
        expect(route.endpoint.toString(), endpoint);
        expect(
          f.policy.requiresCustomDestinationApproval(f.reference().connection),
          true,
        );
        await expectLater(
          f.permit(),
          throwsNative(NativeProviderFailure.denied),
        );
        final observation = await f.inspect();
        var calls = 0;
        final broker = NativeProviderCredentialBroker(
          credentials: f.credentials,
          transport: (_, _) async {
            calls++;
          },
        );
        await expectLater(
          broker.dispatch(observation, route: route, isCurrent: () => true),
          throwsNative(NativeProviderFailure.stale),
        );
        expect(calls, 0);
        expect(f.storage.operations, isNot(contains('write')));
        expect(f.storage.values, isEmpty);
      }
    },
  );

  test(
    'model-list/probe/embedding and incompatible protocol paths remain refused',
    () {
      for (final endpoint in [
        'https://api.openai.com/v1/models',
        'https://api.openai.com/v1/embeddings',
        'https://api.openai.com/v1/chat/completions/other',
      ]) {
        final f = NativeProviderFixture();
        f.row = f.row.copyWith(endpoint: endpoint);
        expect(() => f.route(), throwsNative(NativeProviderFailure.denied));
      }
    },
  );

  test(
    'ambiguous/raw encoded/dot/query/userinfo and insecure/local spellings fail',
    () {
      for (final endpoint in [
        'https://user@api.openai.com/v1/chat/completions',
        'https://api.openai.com/v1/chat/completions#x',
        'https://api.openai.com/v1/chat/completions?alt=sse',
        'https://api.openai.com/v1/%63hat/completions',
        'https://api.openai.com/v1/../v1/chat/completions',
        'https://api.openai.com/v1/./chat/completions',
        'https://api.openai.com/v1//chat/completions',
        'https://api.openai.com:99999/v1/chat/completions',
        'https://api.openai.com/v1\\chat/completions',
        ' https://api.openai.com/v1/chat/completions',
        'http://api.openai.com/v1/chat/completions',
        'https://127.0.0.1/v1/chat/completions',
        'https://[::1]/v1/chat/completions',
        'https://localhost/v1/chat/completions',
        'https://provider.local/v1/chat/completions',
      ]) {
        final f = NativeProviderFixture();
        f.row = f.row.copyWith(endpoint: endpoint);
        expect(
          f.auth.referenceFor(f.row, NativeProviderPurpose.roleplay),
          isNull,
        );
      }
    },
  );

  test(
    'custom route description alone is not authority; opaque native approval is',
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
      final ref = f.reference();
      expect(f.route().endpoint.host, 'provider.example');
      await expectLater(f.permit(), throwsNative(NativeProviderFailure.denied));
      final displayed = f.policy.reviewCustomDestination(
        connection: ref.connection,
        purposes: {ref.purpose},
        lifetime: f.lifetime,
      );
      final approval = f.policy.confirmCustomDestination(displayed);
      expect(
        await f.store(destinationApproval: approval),
        CredentialMetadata.fromSecret(nativeCanary),
      );
      expect(displayed.routes.single.endpoint.toString(), f.row.endpoint);
      expect(approval.toString(), isNot(contains(nativeCanary)));
    },
  );

  test(
    'custom approval is exact route/protocol/purpose/view, not a DTO bool',
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
      final approval = f.policy.confirmCustomDestination(displayed);
      await expectLater(
        f.permit(
          purposes: {NativeProviderPurpose.studio},
          destinationApproval: approval,
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      f.row = f.row.copyWith(
        endpoint: 'https://other.example/v1/chat/completions',
      );
      await expectLater(
        f.permit(destinationApproval: approval),
        throwsNative(NativeProviderFailure.denied),
      );
      f.lifetime.retire();
      expect(
        () => f.policy.confirmCustomDestination(displayed),
        throwsNative(NativeProviderFailure.stale),
      );
      // Arbitrary tool JSON cannot have the opaque approval type or its private constructor.
      expect(<String, Object>{
        'confirmed': true,
      }, isNot(isA<NativeProviderDestinationApproval>()));
    },
  );

  test(
    'custom Responses is explicit and incompatible flags never infer a protocol',
    () async {
      final f = NativeProviderFixture(
        row: const ApiConfig(
          id: 'native-test',
          model: 'test-model',
          providerId: 'custom_chat_completion',
          protocol: 'custom_chat_completion',
          useResponsesApi: true,
          endpoint: 'https://provider.example/v1/responses',
        ),
      );
      expect(f.route().protocol, CredentialProtocol.openAiResponses);
      f.row = f.row.copyWith(
        protocol: 'openai',
        endpoint: 'https://api.openai.com/v1/chat/completions',
      );
      expect(() => f.route(), throwsNative(NativeProviderFailure.denied));
    },
  );

  test(
    'all six selected protocols need exact native confirmation for compatible HTTPS proxy URLs',
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
        final ref = f.reference();
        final routes = f.policy.routesFor(
          connection: ref.connection,
          purpose: ref.purpose,
        );
        expect(
          f.policy.requiresCustomDestinationApproval(ref.connection),
          true,
        );
        expect(
          routes.every((route) => route.endpoint.host == 'proxy.example'),
          true,
        );
        expect(
          routes.any((route) => route.endpoint.toString() == profile.$3),
          true,
        );
        await expectLater(
          f.store(),
          throwsNative(NativeProviderFailure.denied),
        );
        expect(
          f.storage.operations,
          isEmpty,
        ); // Pure description/review does not write or probe.
        final review = f.policy.reviewCustomDestination(
          connection: ref.connection,
          purposes: {ref.purpose},
          lifetime: f.lifetime,
        );
        expect(review.routes, routes);
        final approval = f.policy.confirmCustomDestination(review);
        final metadata = await f.store(destinationApproval: approval);
        expect(metadata, CredentialMetadata.fromSecret(nativeCanary));
        expect((await f.inspect()).state, NativeProviderCredentialState.ready);
        expect(f.storage.values.length, 1);
      }
    },
  );

  test(
    'Gemini custom origin and arbitrary chosen prefix are preserved for both saved actions',
    () {
      for (final stream in [true, false]) {
        final action = stream ? 'streamGenerateContent' : 'generateContent';
        final f = NativeProviderFixture(
          row: ApiConfig(
            id: 'native-test',
            model: 'test-model',
            protocol: 'gemini',
            stream: stream,
            endpoint:
                'https://proxy.example/unknown/api-version/tenant/models/test-model:$action',
          ),
        );
        final routes = f.policy.routesFor(
          connection: f.reference().connection,
          purpose: NativeProviderPurpose.roleplay,
        );
        expect(routes.map((route) => route.endpoint.toString()), [
          'https://proxy.example/unknown/api-version/tenant/models/test-model:generateContent',
          'https://proxy.example/unknown/api-version/tenant/models/test-model:streamGenerateContent',
        ]);
        expect(
          f.policy.requiresCustomDestinationApproval(f.reference().connection),
          true,
        );
        f.row = f.row.copyWith(stream: !stream);
        expect(() => f.route(), throwsNative(NativeProviderFailure.denied));
        f.row = f.row.copyWith(stream: stream, model: 'unbound-model');
        expect(() => f.route(), throwsNative(NativeProviderFailure.denied));
      }
      final f = NativeProviderFixture();
      expect(
        () => f.policy.standardEndpointFor('unknown', 'test-model'),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(
        () => f.policy.standardEndpointFor('gemini', 'org/unbound-model'),
        throwsNative(NativeProviderFailure.denied),
      );
    },
  );

  test(
    'custom receipts cannot cross policy/view/purpose/protocol or be replaced by JSON authority',
    () async {
      final f = NativeProviderFixture(
        row: const ApiConfig(
          id: 'native-test',
          model: 'test-model',
          protocol: 'openai',
          endpoint: 'https://proxy.example/v9/chat/completions',
        ),
      );
      final ref = f.reference();
      final review = f.policy.reviewCustomDestination(
        connection: ref.connection,
        purposes: {ref.purpose},
        lifetime: f.lifetime,
      );
      final approval = f.policy.confirmCustomDestination(review);
      final other = NativeProviderFixture(row: f.row);
      expect(
        () => other.policy.confirmCustomDestination(review),
        throwsNative(NativeProviderFailure.denied),
      );
      await expectLater(
        other.permit(destinationApproval: approval),
        throwsNative(NativeProviderFailure.denied),
      );
      final otherView = NativeProviderViewLifetime(isCurrent: () => true);
      await expectLater(
        f.entry.review(
          connection: ref,
          purposes: {ref.purpose},
          lifetime: otherView,
          destinationApproval: approval,
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      await expectLater(
        f.permit(
          purposes: {NativeProviderPurpose.studio},
          destinationApproval: approval,
        ),
        throwsNative(NativeProviderFailure.denied),
      );
      f.row = f.row.copyWith(
        protocol: 'openrouter',
      ); // Same wire format/path is still another identity.
      await expectLater(
        f.permit(destinationApproval: approval),
        throwsNative(NativeProviderFailure.denied),
      );
      final dynamic toolJson = {
        'confirmed': true,
        'endpoint': ref.connection.endpoint,
        'protocol': ref.connection.protocol,
        'purposes': ['roleplay'],
      };
      await expectLater(
        Future.sync(
          () => f.entry.review(
            connection: f.reference(),
            purposes: {ref.purpose},
            lifetime: f.lifetime,
            destinationApproval: toolJson as NativeProviderDestinationApproval?,
          ),
        ),
        throwsA(isA<TypeError>()),
      );
      expect(f.storage.operations, isEmpty);
      expect(other.storage.operations, isEmpty);
    },
  );

  test(
    'known secret contamination in identity/URL/model is rejected not redacted into authority',
    () {
      final f = NativeProviderFixture();
      const key = 'TEST_ONLY_MODEL_CANARY';
      f.redaction.registerSecret(key);
      expect(
        f.auth.referenceFor(
          f.row.copyWith(model: key),
          NativeProviderPurpose.roleplay,
        ),
        isNull,
      );
      expect(
        f.auth.referenceFor(
          f.row.copyWith(id: key),
          NativeProviderPurpose.roleplay,
        ),
        isNull,
      );
      expect(
        f.auth.referenceFor(
          f.row.copyWith(
            endpoint: 'https://provider.example/$key/chat/completions',
          ),
          NativeProviderPurpose.roleplay,
        ),
        isNull,
      );
    },
  );
}
