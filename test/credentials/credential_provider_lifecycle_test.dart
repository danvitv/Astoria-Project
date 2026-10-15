import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/api_config_credential_adapter.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/utils/error_format.dart';

import 'fake_credential_storage.dart';

void main() {
  ProviderContainer create({
    SecretRedactor? base,
    FakeCredentialStorage? storage,
  }) => ProviderContainer(
    overrides: [
      credentialStorageProvider.overrideWithValue(
        storage ?? FakeCredentialStorage(),
      ),
      if (base != null) baseSecretRedactorProvider.overrideWithValue(base),
    ],
  );

  setUp(() {
    final capture = LlmRequestCapture.redactor;
    final error = activeErrorRedactor;
    addTearDown(() {
      LlmRequestCapture.redactor = capture;
      activeErrorRedactor = error;
    });
  });

  test(
    'injected base coverage and limits survive initialization and registration',
    () async {
      const baseSecret = 'INJECTED_BASE_CANARY';
      const registered = 'REGISTERED_CUSTOM_CANARY';
      final base = SecretRedactor(
        knownSecrets: [baseSecret],
        maxInputLength: 12000,
        maxOutputLength: 2000,
        maxDepth: 4,
        maxNodes: 20,
      );
      final container = create(base: base);
      addTearDown(container.dispose);
      final adapter = container.read(apiConfigCredentialAdapterProvider);
      expect(formatError('failed $baseSecret'), 'failed [REDACTED]');
      expect(LlmRequestCapture.redactor!.redactText(baseSecret), '[REDACTED]');
      await adapter.syncConfigToVault(
        const ApiConfig(id: 'base', apiKey: registered),
      );
      for (final snapshot in [
        adapter.redactor,
        container.read(secretRedactorProvider),
        activeErrorRedactor!,
        LlmRequestCapture.redactor!,
      ]) {
        expect(
          snapshot.redactText('$baseSecret $registered'),
          '[REDACTED] [REDACTED]',
        );
      }
      expect(adapter.redactor.maxInputLength, 12000);
      expect(adapter.redactor.maxOutputLength, 2000);
      expect(adapter.redactor.maxDepth, 4);
      expect(adapter.redactor.maxNodes, 20);
      expect(base.redactText(registered), registered);
    },
  );

  test(
    'disposing the sole owner restores previous sinks, including null',
    () async {
      for (final previous in [
        null,
        SecretRedactor(knownSecrets: ['PREVIOUS_CANARY']),
      ]) {
        LlmRequestCapture.redactor = previous;
        activeErrorRedactor = previous;
        final container = create();
        await container
            .read(apiConfigCredentialAdapterProvider)
            .syncConfigToVault(
              const ApiConfig(id: 'owner', apiKey: 'OWNER_CANARY'),
            );
        expect(LlmRequestCapture.redactor, isNot(same(previous)));
        container.dispose();
        expect(LlmRequestCapture.redactor, same(previous));
        expect(activeErrorRedactor, same(previous));
      }
    },
  );

  for (final disposeAFirst in [true, false]) {
    test(
      'overlapping containers restore only live owners: A first=$disposeAFirst',
      () async {
        final previousCapture = SecretRedactor(
          knownSecrets: ['PREVIOUS_CAPTURE'],
        );
        final previousError = SecretRedactor(knownSecrets: ['PREVIOUS_ERROR']);
        LlmRequestCapture.redactor = previousCapture;
        activeErrorRedactor = previousError;
        // Shared injected base still gives each container a distinct owned snapshot.
        final base = SecretRedactor(knownSecrets: ['SHARED_BASE']);
        final a = create(base: base);
        final adapterA = a.read(apiConfigCredentialAdapterProvider);
        await adapterA.syncConfigToVault(
          const ApiConfig(id: 'a', apiKey: 'A_CANARY'),
        );
        final b = create(base: base);
        final adapterB = b.read(apiConfigCredentialAdapterProvider);
        await adapterB.syncConfigToVault(
          const ApiConfig(id: 'b', apiKey: 'B_CANARY'),
        );
        final bCapture = LlmRequestCapture.redactor;
        final bError = activeErrorRedactor;
        // Registration by a covered owner updates its stored snapshot, not B's sink.
        await adapterA.syncConfigToVault(
          const ApiConfig(id: 'a', apiKey: 'A_ROTATED'),
        );
        expect(LlmRequestCapture.redactor, same(bCapture));
        expect(activeErrorRedactor, same(bError));
        if (disposeAFirst) {
          a.dispose();
          expect(LlmRequestCapture.redactor, same(bCapture));
          expect(activeErrorRedactor, same(bError));
          b.dispose();
        } else {
          b.dispose();
          expect(
            LlmRequestCapture.redactor!.redactText('A_CANARY A_ROTATED'),
            '[REDACTED] [REDACTED]',
          );
          expect(activeErrorRedactor, same(adapterA.redactor));
          a.dispose();
        }
        expect(LlmRequestCapture.redactor, same(previousCapture));
        expect(activeErrorRedactor, same(previousError));
      },
    );
  }

  test('same base with no registrations still has distinct sink ownership', () {
    final previousCapture = LlmRequestCapture.redactor;
    final previousError = activeErrorRedactor;
    final base = SecretRedactor();
    final a = create(base: base);
    a.read(apiConfigCredentialAdapterProvider);
    final b = create(base: base);
    b.read(apiConfigCredentialAdapterProvider);
    final bError = activeErrorRedactor;
    a.dispose();
    expect(activeErrorRedactor, same(bError));
    b.dispose();
    expect(LlmRequestCapture.redactor, same(previousCapture));
    expect(activeErrorRedactor, same(previousError));
  });

  test(
    'external replacement is preserved independently for each static sink',
    () async {
      final previousCapture = LlmRequestCapture.redactor;
      final container = create();
      final adapter = container.read(apiConfigCredentialAdapterProvider);
      final externalError = SecretRedactor(knownSecrets: ['EXTERNAL']);
      activeErrorRedactor = externalError;
      await adapter.syncConfigToVault(
        const ApiConfig(id: 'external', apiKey: 'REGISTERED'),
      );
      expect(activeErrorRedactor, same(externalError));
      expect(
        LlmRequestCapture.redactor!.redactText('REGISTERED'),
        '[REDACTED]',
      );
      container.dispose();
      expect(activeErrorRedactor, same(externalError));
      expect(LlmRequestCapture.redactor, same(previousCapture));
    },
  );

  test(
    'late hydration after disposal cannot republish into a newer owner',
    () async {
      final storage = FakeCredentialStorage();
      final a = create(storage: storage);
      final vault = a.read(credentialVaultProvider);
      await vault.store(
        ApiConfigCredentialAdapter.llmSlot('late'),
        'LATE_VAULT_CANARY',
      );
      final entered = Completer<void>();
      final release = Completer<void>();
      storage.beforeRead = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final disposedAdapter = a.read(apiConfigCredentialAdapterProvider);
      final pending = disposedAdapter.hydrateFromVaultOrFallback(
        const ApiConfig(id: 'late'),
      );
      await entered.future;
      a.dispose();
      final b = create();
      addTearDown(b.dispose);
      b.read(apiConfigCredentialAdapterProvider);
      final captureB = LlmRequestCapture.redactor;
      final errorB = activeErrorRedactor;
      release.complete();
      await pending;
      expect(LlmRequestCapture.redactor, same(captureB));
      expect(activeErrorRedactor, same(errorB));
      expect(
        disposedAdapter.redactor.redactText('ordinary'),
        SecretRedactor.limited,
      );
    },
  );

  test(
    'raising capture budgets cannot reopen an exhausted injected base',
    () async {
      final closed = SecretRedactor(knownSecrets: List.filled(257, ''));
      final container = create(base: closed);
      addTearDown(container.dispose);
      final adapter = container.read(apiConfigCredentialAdapterProvider);
      await adapter.syncConfigToVault(
        const ApiConfig(id: 'closed', apiKey: 'CANARY'),
      );
      expect(
        container.read(secretRedactorProvider).redactText('safe'),
        SecretRedactor.limited,
      );
      expect(
        LlmRequestCapture.redactor!.redactText('safe'),
        SecretRedactor.limited,
      );
      expect(activeErrorRedactor!.redactText('safe'), SecretRedactor.limited);
    },
  );
}
