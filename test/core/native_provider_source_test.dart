import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';

import 'native_provider_source_fixture.dart';

void main() {
  test(
    'ready source is keyless and name projected before prompt capture',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store();
      f.repo.row = f.repo.row.copyWith(name: 'Connection $nativeCanary');
      final source = await f.prepare();
      expect(source.isNative, isTrue);
      expect(source.savedConnectionId, f.repo.row.id);
      expect(
        source.savedConnectionAuth!.purpose,
        NativeProviderPurpose.roleplay,
      );
      expect(f.promptConfig!.apiKey, isEmpty);
      expect(f.promptConfig!.embeddingApiKey, isEmpty);
      expect(f.promptConfig!.name, contains(SecretRedactor.removed));
      expect(f.promptConfig!.name, isNot(contains(nativeCanary)));
      expect(f.wire.wires, isEmpty);
      expect(f.wire.adapters, isEmpty);
      expect(f.wire.legacy.requests, isEmpty);
    },
  );

  test(
    'physical absence retains the ORIGINAL legacy config object and key',
    () async {
      final row = const ApiConfig(
        id: 'legacy',
        apiKey: 'SYNTHETIC_LEGACY_KEY',
        model: 'legacy-model',
        name: 'Original',
        endpoint: 'http://legacy.invalid',
      );
      final f = NativeSourceConsumerFixture(row: row);
      final source = await f.prepare();
      expect(source.isNative, isFalse);
      expect(identical(source.configuration, row), isTrue);
      expect(source.configuration.apiKey, 'SYNTHETIC_LEGACY_KEY');
      expect(source.savedConnectionAuth, isNull);
      expect(f.wire.adapters, isEmpty);
    },
  );

  for (final malformed in ['', '{}', 'not a record']) {
    test(
      'physical native corruption never becomes legacy ($malformed)',
      () async {
        final f = NativeSourceConsumerFixture();
        f.wire.core.storage.values[f.wire.core.nativeStorageKey] = malformed;
        f.repo.row = f.repo.row.copyWith(
          apiKey: 'SYNTHETIC_LEGACY_KEY',
          model: '',
        );
        await expectLater(
          f.prepare(),
          throwsNative(NativeProviderFailure.corrupt),
        );
        expect(f.promptBuilds, 0);
        expect(f.wire.legacy.requests, isEmpty);
        expect(f.wire.wires, isEmpty);
      },
    );
  }

  test(
    'unavailable presence cannot fall back to a nonempty legacy row key',
    () async {
      final f = NativeSourceConsumerFixture();
      f.wire.core.storage.readError = StateError(nativeCanary);
      f.repo.row = f.repo.row.copyWith(apiKey: 'SYNTHETIC_LEGACY_KEY');
      await expectLater(
        f.prepare(),
        throwsNative(NativeProviderFailure.unavailable),
      );
      expect(f.promptBuilds, 0);
      expect(f.wire.wires, isEmpty);
    },
  );

  test(
    'native purpose does not grant Studio or Memory automatically',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store();
      for (final purpose in [
        NativeProviderPurpose.studio,
        NativeProviderPurpose.memoryBooks,
      ]) {
        await expectLater(
          f.prepare(purpose: purpose),
          throwsNative(NativeProviderFailure.denied),
        );
      }
      expect(f.promptBuilds, 0);
      expect(f.wire.wires, isEmpty);
    },
  );

  test(
    'native key/embedding/extras contamination refuses before prompt',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store();
      f.repo.row = f.repo.row.copyWith(apiKey: nativeCanary);
      await expectLater(
        f.prepare(),
        throwsNative(NativeProviderFailure.denied),
      );
      expect(f.promptBuilds, 0);
      expect(f.wire.wires, isEmpty);
    },
  );

  for (final change in [
    'ordinary',
    'ABA',
    'rotation',
    'stop',
    'session',
    'dispose',
  ]) {
    test(
      'held saved-source read preserves original ownership: $change',
      () async {
        final f = NativeSourceConsumerFixture();
        await f.wire.store();
        final gate = NativeSourceHeldGate();
        f.repo.beforeRead = gate.hold;
        final pending = f.prepare();
        pending.ignore();
        await gate.entered.future;
        switch (change) {
          case 'ordinary':
            f.wire.core.ordinaryMutation();
          case 'ABA':
            f.wire.core.ordinaryMutation();
            f.wire.core.ordinaryMutation();
          case 'rotation':
            await f.wire.store();
          case 'stop':
            f.runCurrent = false;
          case 'session':
            f.sessionId = 'replacement-session';
          case 'dispose':
            f.wire.core.mutations.dispose();
        }
        gate.release();
        await expectLater(pending, throwsNative(NativeProviderFailure.stale));
        expect(f.promptBuilds, 0);
        expect(f.wire.wires, isEmpty);
      },
    );
  }

  test(
    'source gate followed by restart registration needs a NEW prepare',
    () async {
      final first = NativeProviderFixture();
      await first.store();
      final restarted = NativeProviderFixture(
        storage: first.storage,
        row: first.row,
      );
      final sources = NativeSavedConnectionSourceResolver(
        mutations: restarted.mutations,
        auth: restarted.auth,
        credentials: restarted.credentials,
        currentRedactor: () => restarted.redaction.redactor,
      );
      Future<NativePreparedSavedConnection> prepare() => sources.prepare(
        originalStamp: sources.captureOriginalStamp(),
        configuration: restarted.row,
        purpose: NativeProviderPurpose.roleplay,
        isCurrent: () => true,
      );
      await expectLater(prepare(), throwsNative(NativeProviderFailure.stale));
      final fresh = await prepare();
      expect(fresh.isNative, isTrue);
      expect(fresh.isCurrent, isTrue);
      expect(first.storage.operations.where((op) => op == 'write').length, 1);
    },
  );

  test(
    'current redactor replacement retires a prepared source, not executable URL',
    () async {
      final f = NativeSourceConsumerFixture();
      await f.wire.store();
      final source = await f.prepare();
      f.wire.core.redaction.registerSecret('SYNTHETIC_ADDITIONAL_SECRET');
      expect(source.isCurrent, isFalse);
      expect(source.configuration.endpoint, f.repo.row.endpoint);
      expect(source.requireCurrent, throwsNative(NativeProviderFailure.stale));
    },
  );
}
