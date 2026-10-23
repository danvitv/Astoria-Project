import 'package:flutter_test/flutter_test.dart';

import 'support_provider_action_fixture.dart' show ProviderActionFixture;
import 'support_provider_vertical_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  providerVerticalTest(
    'actual root keyless review -> native entry -> one fake wire',
    (f) async {
      final binding = f.bind();
      expect(binding.current, isTrue);
      final review = (await binding.prepare(f.input()))!;
      expect(binding.preview(review)?.before, isNull);
      expect(binding.preview(review)?.after?.name, 'Synthetic provider');
      expect(await f.api.getConfigIds(), isEmpty);
      expect(f.requests, isEmpty);
      final original = binding.confirm(review)!;
      expect(binding.confirm(review), isNull);
      final result = await original;
      expect(result.code, SupportProviderActionCode.applied);
      final applied = result.applied!;
      expect(
        binding.resultView(result)?.code,
        SupportProviderActionCode.applied,
      );
      final saved = (await f.api.getById(applied.value!.connectionId))!;
      expect(saved.apiKey, isEmpty);
      expect(saved.embeddingApiKey, isEmpty);
      expect((await binding.readiness(applied))?.credentialConfigured, isFalse);
      expect(f.requests, isEmpty);
      final key = (await binding.prepareKeyEntry(applied))!;
      expect(key.readyForInput, isTrue);
      final write = key.submitNativeSecret(ProviderActionFixture.secret)!;
      expect(key.submitNativeSecret(ProviderActionFixture.secret), isNull);
      final metadata = await write;
      expect(metadata.configured, isTrue);
      expect(
        metadata.characterCount,
        ProviderActionFixture.secret.runes.length,
      );
      expect(binding.current, isTrue); // Its own fence did not cancel the UI.
      expect((await binding.readiness(applied))?.credentialConfigured, isTrue);
      expect(f.requests, isEmpty); // Key entry is not a connection test.
      expect(await f.send(applied), 'Synthetic reply');
      expect(f.requests, hasLength(1));
      expect(f.requests.single.method, 'POST');
      expect(
        f.requests.single.headers['Authorization'],
        'Bearer ${ProviderActionFixture.secret}',
      ); // Only declared native fake wire.
      expect((await f.api.getById(saved.id))?.apiKey, isEmpty);
      final rows = await f.backing.support.getMutationsForSession(
        ProviderActionFixture.sessionId,
      );
      expect(rows, hasLength(1));
      expect(rows.single.domain, 'provider.setup');
      key.dispose();
    },
  );

  providerVerticalTest(
    'foreign actual UI cannot use reviews or native key handles',
    (f) async {
      final first = f.bind(), other = f.bind();
      final review = (await first.prepare(f.input()))!;
      expect(other.preview(review), isNull);
      expect(other.confirm(review), isNull);
      final applied = (await first.confirm(review)!).applied!;
      final id = applied.value!.connectionId;
      expect(await other.prepareKeyEntry(applied), isNull);
      expect(await other.readiness(applied), isNull);
      first.dispose();
      expect(await first.prepareKeyEntry(applied), isNull);
      expect(f.requests, isEmpty);
      expect((await f.api.getById(id))?.apiKey, isEmpty);
    },
  );

  providerVerticalTest(
    'real local permission revocation denies retained final callbacks',
    (f) async {
      final binding = f.bind();
      final review = (await binding.prepare(f.input()))!;
      final consent = (await f.controller.prepareReview(
        resolveRecipient: false,
      ))!;
      expect(
        await f.controller.setGrant(
          consent,
          SupportPermission.confirmedSettingsChanges,
          false,
        ),
        isTrue,
      );
      expect(binding.current, isFalse);
      expect(binding.confirm(review), isNull);
      expect(await f.api.getConfigIds(), isEmpty);
      expect(f.requests, isEmpty);
    },
  );
}
