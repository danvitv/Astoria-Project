import 'package:flutter_test/flutter_test.dart';

import 'support_provider_action_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final routes = <String, String>{
    'openai': 'https://synthetic-custom.invalid/v1/chat/completions',
    'openai_responses': 'https://synthetic-custom.invalid/v1/responses',
    'anthropic': 'https://synthetic-custom.invalid/v1/messages',
    'gemini':
        'https://synthetic-custom.invalid/v1beta/models/synthetic-model:streamGenerateContent',
    'openrouter': 'https://synthetic-custom.invalid/api/v1/chat/completions',
    'custom_chat_completion':
        'https://synthetic-custom.invalid/v1/chat/completions',
  };
  for (final entry in routes.entries) {
    providerActionTest(
      'custom HTTPS ${entry.key} needs independent opaque once gesture',
      (f) async {
        final before = await f.snapshotRows();
        final original = f.intent();
        final review = (await f.service.prepareCreate(
          original,
          f.input(protocol: entry.key, endpoint: entry.value),
        ))!;
        expect(
          review.destinationKind,
          SupportProviderDestinationKind.customHttps,
        );
        expect(f.service.approve(review), isNull);
        expect(await f.snapshotRows(), before);
        final foreign = f.newService();
        try {
          expect(foreign.confirmCustomDestination(review), isNull);
          expect(foreign.approve(review), isNull);
          expect(f.service.confirmCustomDestination(review), isNotNull);
          expect(f.service.confirmCustomDestination(review), isNull);
          final approval = f.service.approve(review)!;
          expect(
            (await foreign.execute(approval)).code,
            SupportProviderActionCode.refused,
          );
          expect(
            (await f.service.execute(approval)).code,
            SupportProviderActionCode.applied,
          );
        } finally {
          foreign.dispose();
        }
        expect(
          f.storage.values.keys.any((k) => k.contains('native_llm')),
          isFalse,
        );
      },
    );
  }
  providerActionTest(
    'known provider host with non-default prefix is still custom',
    (f) async {
      final review = (await f.service.prepareCreate(
        f.intent(),
        f.input(
          endpoint: 'https://api.openai.com/alternative/v1/chat/completions',
        ),
      ))!;
      expect(
        review.destinationKind,
        SupportProviderDestinationKind.customHttps,
      );
      expect(f.service.approve(review), isNull);
    },
  );
  providerActionTest(
    'another compatible protocol default is CUSTOM, not a host allowlist bypass',
    (f) async {
      final review = (await f.service.prepareCreate(
        f.intent(),
        f.input(
          protocol: 'openrouter',
          endpoint: 'https://api.openai.com/v1/chat/completions',
        ),
      ))!;
      expect(
        review.destinationKind,
        SupportProviderDestinationKind.customHttps,
      );
      expect(f.service.approve(review), isNull);
      expect(f.service.confirmCustomDestination(review), isNotNull);
      expect(
        (await f.service.execute(f.service.approve(review)!)).code,
        SupportProviderActionCode.applied,
      );
    },
  );
  providerActionTest(
    'service custom receipt cannot approve native key entry destination',
    (f) async {
      final result = await f.create(draft: f.input(endpoint: routes['openai']));
      final id = result.applied!.value!.connectionId;
      // The native core requires its OWN fresh view/review/gesture. Keyless setup
      // confirmation is not accepted by the native secret issuer in any form.
      await expectLater(
        f.saveSyntheticNativeKey(id, ProviderActionFixture.secret),
        throwsA(anything),
      );
      expect(
        f.storage.values.keys.any((k) => k.contains('native_llm')),
        isFalse,
      );
    },
  );
  for (final endpoint in [
    'http://synthetic-custom.invalid/v1/chat/completions',
    'https://127.0.0.1/v1/chat/completions',
    'https://[::1]/v1/chat/completions',
    'https://localhost/v1/chat/completions',
    'https://synthetic.local/v1/chat/completions',
    'https://synthetic.internal/v1/chat/completions',
    'https://user:password@synthetic.invalid/v1/chat/completions',
    'https://synthetic.invalid/v1/chat/completions?key=SYNTHETIC',
    'https://synthetic.invalid/v1/chat/completions#SYNTHETIC',
    'https://synthetic.invalid/v1/%2e/chat/completions',
    'https://synthetic.invalid/v1/../chat/completions',
  ]) {
    providerActionTest(
      'unsupported or ambiguous route is unavailable: $endpoint',
      (f) async {
        final before = await f.snapshotRows();
        expect(
          await f.service.prepareCreate(
            f.intent(),
            f.input(endpoint: endpoint),
          ),
          isNull,
        );
        expect(await f.snapshotRows(), before);
      },
    );
  }
  providerActionTest(
    'retained custom confirmation callback cannot revive a retired view',
    (f) async {
      final review = (await f.service.prepareCreate(
        f.intent(),
        f.input(endpoint: routes['openai']),
      ))!;
      SupportProviderCustomDestinationConfirmation? callback() =>
          f.service.confirmCustomDestination(review);
      f.screenCurrent = false;
      expect(callback(), isNull);
      f.service.retireIntents();
      f.screenCurrent = true;
      expect(callback(), isNull);
      expect(f.service.approve(review), isNull);
    },
  );
}
