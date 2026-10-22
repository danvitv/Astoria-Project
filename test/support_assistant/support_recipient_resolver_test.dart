import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_protocol.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/extra_request_parameter.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_scope.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_recipient_resolution.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';

import 'recipient_resolution_fixture.dart';

void main() {
  late RecipientResolutionFixture f;
  setUp(() async {
    f = RecipientResolutionFixture();
    await f.repo.put(RecipientResolutionFixture.config);
  });
  tearDown(() => f.db.close());

  Future<SupportResolvedRecipient> resolved() async =>
      await f.resolver.resolve('support-a') as SupportResolvedRecipient;
  Future<void> unavailable(SupportRecipientUnavailableReason reason) async {
    final result = await f.resolver.resolve('support-a');
    expect(
      result,
      isA<SupportRecipientUnavailable>().having(
        (r) => r.reason,
        'reason',
        reason,
      ),
    );
  }

  test(
    'exact support selected model, durable row, safe binding and stable rereads',
    () async {
      final a = await resolved();
      final b = await resolved();
      expect(a.context.supportSessionId, 'support-a');
      expect(a.recipient.modelId, 'selected-model');
      expect(a.recipient.connectionId, 'api-a');
      expect(
        a.recipient.nativeRoute,
        'https://recipient.example/v1/chat/completions',
      );
      expect(a.recipient.sameAs(b.recipient), isTrue);
      expect(f.settingsReads, 4);
      expect(f.repo.rowReads, 2);
      expect(a.recipient.configurationRevision, f.revisions.revision);
      expect(
        '${a.connectionLabel} ${a.protocolLabel} ${a.routingLabel}',
        isNot(contains('STATIC_CANARY')),
      );
    },
  );

  test('no selection or saved default/first-entry fallback', () async {
    await f.repo.put(const ApiConfig(id: 'first', model: 'roleplay-model'));
    f.settings = const SupportAssistantSettings();
    await unavailable(SupportRecipientUnavailableReason.selectionMissing);
    f.settings = const SupportAssistantSettings(apiConfigId: 'api-a');
    await unavailable(SupportRecipientUnavailableReason.selectionMissing);
    f.settings = const SupportAssistantSettings(
      apiConfigId: 'missing',
      modelId: 'chosen',
    );
    await unavailable(SupportRecipientUnavailableReason.connectionMissing);
  });

  test('embedding and unknown mode/protocol fail closed', () async {
    for (final config in [
      RecipientResolutionFixture.config.copyWith(mode: 'embedding'),
      RecipientResolutionFixture.config.copyWith(mode: 'unknown'),
      RecipientResolutionFixture.config.copyWith(protocol: 'legacy_unknown'),
    ]) {
      await f.repo.put(config);
      await unavailable(
        SupportRecipientUnavailableReason.unsupportedConfiguration,
      );
    }
  });

  test(
    'support/session ownership missing or deleted has no substitute',
    () async {
      f.bumpContext('support-b');
      await unavailable(SupportRecipientUnavailableReason.staleContext);
      f.bumpContext();
      f.sessionExists = false;
      await unavailable(SupportRecipientUnavailableReason.settingsUnavailable);
      f.sessionExists = true;
      await f.repo.delete('api-a');
      await unavailable(SupportRecipientUnavailableReason.connectionMissing);
    },
  );

  test(
    'pending mutation refuses immediately before any settings read',
    () async {
      final write = f.repo.put(
        RecipientResolutionFixture.config.copyWith(name: 'changed'),
      );
      expect(f.revisions.isStable, isFalse);
      await unavailable(SupportRecipientUnavailableReason.mutationPending);
      expect(f.settingsReads, 0);
      await write;
      expect(f.revisions.isStable, isTrue);
    },
  );

  test('awaited row mutation cannot publish stale recipient', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    f.repo.afterRead = () {
      entered.complete();
      return release.future;
    };
    final reading = f.resolver.resolve('support-a');
    await entered.future;
    await f.repo.put(
      RecipientResolutionFixture.config.copyWith(
        endpoint: 'https://new.example/v1/chat/completions',
      ),
    );
    release.complete();
    expect(await reading, isA<SupportRecipientUnavailable>());
    f.repo.afterRead = null;
    expect(
      (await resolved()).recipient.nativeRoute,
      'https://new.example/v1/chat/completions',
    );
  });

  test('API and selected model ABA revoke old same-target binding', () async {
    final before = await resolved();
    await f.repo.delete('api-a');
    await f.repo.put(RecipientResolutionFixture.config);
    final after = await resolved();
    expect(before.recipient.sameAs(after.recipient), isFalse);
    expect(
      after.recipient.configurationRevision,
      greaterThan(before.recipient.configurationRevision),
    );

    f.bumpContext();
    f.settings = f.settings.copyWith(modelId: 'other-model');
    f.bumpContext();
    f.settings = f.settings.copyWith(modelId: 'selected-model');
    expect((await resolved()).context.sameAs(before.context), isFalse);
  });

  test(
    'credential-only mutation revokes without credential fingerprints',
    () async {
      final before = await resolved();
      await f.repo.put(
        RecipientResolutionFixture.config.copyWith(
          apiKey: 'STATIC_ROTATED_CANARY_684193',
        ),
      );
      final after = await resolved();
      expect(after.recipient.nativeRoute, before.recipient.nativeRoute);
      expect(after.recipient.modelId, before.recipient.modelId);
      expect(
        after.recipient.configurationRevision,
        before.recipient.configurationRevision + 2,
      );
      expect(after.recipient.sameAs(before.recipient), isFalse);
    },
  );

  test(
    'late durable selected model and API change caught by settings reread',
    () async {
      f.repo.afterRead = () async {
        f.settings = f.settings.copyWith(modelId: 'late-model');
      };
      await unavailable(SupportRecipientUnavailableReason.staleContext);
      f.repo.afterRead = () async {
        f.settings = f.settings.copyWith(apiConfigId: 'late-api');
      };
      await unavailable(SupportRecipientUnavailableReason.staleContext);
    },
  );

  test('settings await ABA and session change cannot publish', () async {
    final entered = Completer<void>();
    final release = Completer<void>();
    final selected = f.settings;
    f.settingsPort = (_) async {
      entered.complete();
      await release.future;
      return selected;
    };
    final reading = f.resolver.resolve('support-a');
    await entered.future;
    f.bumpContext('support-b');
    f.bumpContext();
    release.complete();
    expect(await reading, isA<SupportRecipientUnavailable>());
    expect(f.repo.rowReads, 0);
  });

  test(
    'late session deletion during final settings read cannot publish',
    () async {
      f.settingsPort = (_) async => f.settingsReads == 1 ? f.settings : null;
      await unavailable(SupportRecipientUnavailableReason.staleContext);
    },
  );

  test('OpenRouter fixed actual route ignores stale saved endpoint', () async {
    await f.repo.put(
      RecipientResolutionFixture.config.copyWith(
        protocol: LlmProtocol.openrouter,
      ),
    );
    await f.rawEndpoint(
      'https://old-saved.example/v1/chat/completions?token=STATIC_CANARY_KEY_734291',
    );
    final result = await resolved();
    expect(
      result.recipient.nativeRoute,
      'https://openrouter.ai/api/v1/chat/completions',
    );
    expect(result.recipient.protocol, SupportRecipientProtocol.openrouter);
    expect(result.routingLabel, contains('не подтверждён'));
  });

  const rawWhitespaceEndpoints = [
    ' https://recipient.example/v1/chat/completions',
    'https://recipient.example/v1/chat/completions ',
    '\thttps://recipient.example/v1/chat/completions',
    'https://recipient.example/v1/chat/completions\t',
    '\nhttps://recipient.example/v1/chat/completions',
    'https://recipient.example/v1/chat/completions\n',
    '\r\nhttps://recipient.example/v1/chat/completions',
    'https://recipient.example/v1/chat/completions\r\n',
  ];
  for (var i = 0; i < rawWhitespaceEndpoints.length; i++) {
    test('raw restored endpoint whitespace case $i unavailable', () async {
      // Normal repo.put would clean this spelling. Seed the raw imported row.
      final endpoint = rawWhitespaceEndpoints[i];
      await f.rawEndpoint(endpoint);
      expect((await f.repo.getById('api-a'))?.endpoint, endpoint);
      await unavailable(
        SupportRecipientUnavailableReason.unsupportedConfiguration,
      );
    });
  }

  test(
    'OpenRouter fixed route ignores raw saved endpoint whitespace',
    () async {
      await f.repo.put(
        RecipientResolutionFixture.config.copyWith(
          protocol: LlmProtocol.openrouter,
        ),
      );
      for (final endpoint in rawWhitespaceEndpoints) {
        await f.rawEndpoint(endpoint);
        final result = await resolved();
        expect(
          result.recipient.nativeRoute,
          'https://openrouter.ai/api/v1/chat/completions',
        );
        expect(result.recipient.protocol, SupportRecipientProtocol.openrouter);
      }
    },
  );

  test(
    'custom Responses protocol reflects actual factory mode and route',
    () async {
      await f.repo.put(
        RecipientResolutionFixture.config.copyWith(
          protocol: LlmProtocol.customChatCompletion,
          useResponsesApi: true,
        ),
      );
      final response = await resolved();
      expect(
        response.recipient.protocol,
        SupportRecipientProtocol.openaiResponses,
      );
      expect(response.protocolLabel, 'Custom (Responses)');
      expect(
        response.recipient.nativeRoute,
        'https://recipient.example/v1/responses',
      );
      await f.repo.put(
        RecipientResolutionFixture.config.copyWith(
          protocol: LlmProtocol.openaiResponses,
        ),
      );
      expect(
        (await resolved()).recipient.protocol,
        SupportRecipientProtocol.openaiResponses,
      );
    },
  );

  test('Anthropic exact Messages route', () async {
    await f.repo.put(
      RecipientResolutionFixture.config.copyWith(
        protocol: LlmProtocol.anthropic,
      ),
    );
    expect(
      (await resolved()).recipient.nativeRoute,
      'https://recipient.example/v1/messages',
    );
  });

  test(
    'Gemini stored model/operation route must match selected model and stream',
    () async {
      const endpoint = 'https://generativelanguage.googleapis.com';
      f.settings = f.settings.copyWith(modelId: 'gemini-test');
      for (final stream in [false, true]) {
        await f.repo.put(
          RecipientResolutionFixture.config.copyWith(
            protocol: LlmProtocol.gemini,
            endpoint: endpoint,
            model: 'gemini-test',
            stream: stream,
          ),
        );
        final result = await resolved();
        expect(
          result.recipient.nativeRoute,
          '$endpoint/v1beta/models/gemini-test:${stream ? 'streamGenerateContent' : 'generateContent'}',
        );
        expect(result.recipient.nativeRoute, isNot(contains('?')));
      }
      f.settings = f.settings.copyWith(modelId: 'gemini-other');
      await unavailable(
        SupportRecipientUnavailableReason.unsupportedConfiguration,
      );
    },
  );

  test(
    'authentication query/fragment/userinfo including empty suffix denied',
    () async {
      for (final endpoint in [
        'https://recipient.example/v1/chat/completions?key=STATIC_CANARY_KEY_734291',
        'https://recipient.example/v1/chat/completions?',
        'https://recipient.example/v1/chat/completions#',
        'https://recipient.example/v1/chat/completions#private',
        'https://user:password@recipient.example/v1/chat/completions',
        'https://@recipient.example/v1/chat/completions',
      ]) {
        await f.rawEndpoint(endpoint);
        await unavailable(
          SupportRecipientUnavailableReason.unsupportedConfiguration,
        );
      }
    },
  );

  test(
    'unknown paths and path/host/model credential tokens cannot be native routes',
    () async {
      for (final endpoint in [
        'https://recipient.example/STATIC_CANARY_KEY_734291/v1/chat/completions',
        'https://recipient.example/private-deployment/v1/chat/completions',
        'https://STATIC_CANARY_KEY_734291.example/v1/chat/completions',
        'https://recipient.example/v1/../chat/completions',
        'https://recipient.example/v1//chat/completions',
        'https://recipient.example/v1/chat/%63ompletions',
      ]) {
        await f.rawEndpoint(endpoint);
        await unavailable(
          SupportRecipientUnavailableReason.unsupportedConfiguration,
        );
      }
      await f.rawEndpoint(RecipientResolutionFixture.config.endpoint);
      f.settings = f.settings.copyWith(
        modelId: 'model-STATIC_CANARY_KEY_734291',
      );
      await unavailable(
        SupportRecipientUnavailableReason.unsupportedConfiguration,
      );
    },
  );

  test(
    'current redactor can reject an otherwise grammatical fixed path',
    () async {
      f.redactor = SecretRedactor(knownSecrets: ['completions']);
      await unavailable(
        SupportRecipientUnavailableReason.unsupportedConfiguration,
      );
      f.redactor = SecretRedactor(knownSecrets: ['recipient.example']);
      await unavailable(
        SupportRecipientUnavailableReason.unsupportedConfiguration,
      );
    },
  );

  test(
    'active unreviewed routing extras denied, disabled extras inert',
    () async {
      for (final key in ['provider', 'provider_options', 'seed', 'model']) {
        await f.repo.put(
          RecipientResolutionFixture.config.copyWith(
            extraRequestParameters: [
              ExtraRequestParameter(key: key, value: 'unreviewed'),
            ],
          ),
        );
        await unavailable(
          SupportRecipientUnavailableReason.unsupportedConfiguration,
        );
      }
      await f.repo.put(
        RecipientResolutionFixture.config.copyWith(
          extraRequestParameters: const [
            ExtraRequestParameter(
              key: 'provider',
              value: 'private',
              enabled: false,
            ),
          ],
        ),
      );
      await resolved();
    },
  );

  test(
    'display sanitizes credentials/control chars and stays bounded',
    () async {
      await f.repo.put(
        RecipientResolutionFixture.config.copyWith(
          name: 'Name\nSTATIC_CANARY_KEY_734291',
        ),
      );
      final result = await resolved();
      expect(result.connectionLabel, isNot(contains('STATIC_CANARY')));
      expect(result.connectionLabel, isNot(contains('\n')));
      await f.repo.put(
        RecipientResolutionFixture.config.copyWith(name: 'x' * 400),
      );
      expect((await resolved()).connectionLabel.length, lessThanOrEqualTo(96));
    },
  );

  test('untrusted errors never formatted or echoed', () async {
    final error = _NeverFormatError();
    f.settingsPort = (_) async => throw error;
    await unavailable(SupportRecipientUnavailableReason.settingsUnavailable);
    expect(error.formatted, isFalse);
  });

  test(
    'raw DB bypass is not a revision proof; immediate target reread still differs',
    () async {
      final before = await resolved();
      await f.rawEndpoint('https://raw.example/v1/chat/completions');
      final after = await resolved();
      expect(
        after.recipient.configurationRevision,
        before.recipient.configurationRevision,
      );
      expect(after.recipient.sameAs(before.recipient), isFalse);
      // Unobserved raw ABA deliberately demonstrates the limit, not coverage.
      await f.rawEndpoint(RecipientResolutionFixture.config.endpoint);
      expect((await resolved()).recipient.sameAs(before.recipient), isTrue);
    },
  );
}

final class _NeverFormatError {
  bool formatted = false;
  @override
  String toString() {
    formatted = true;
    throw StateError('Error formatting forbidden');
  }
}
