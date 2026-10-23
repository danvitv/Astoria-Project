import 'dart:async';

import 'package:flutter_test/flutter_test.dart';

import 'native_provider_fixture.dart';

void main() {
  late NativeProviderFixture f;
  setUp(() => f = NativeProviderFixture());
  tearDown(() {
    f.mutations.dispose();
    f.redaction.dispose();
  });

  Future<NativeProviderConfigurationMetadata> read() =>
      NativeProviderCredentialMetadataReader(
        credentials: f.credentials,
      ).readConfiguration(connectionId: f.row.id, isCurrent: () => f.uiCurrent);

  test(
    'real absence versus protected preparation never fabricates a key',
    () async {
      final absent = await read();
      expect(absent.nativeManaged, isFalse);
      expect(absent.presence, NativeProviderCredentialPresence.absent);
      expect(absent.metadata, CredentialMetadata.absent);
      await f.markPrepared();
      final writes = f.storage.writeKeys.length;
      final prepared = await read();
      expect(prepared.nativeManaged, isTrue);
      expect(prepared.presence, NativeProviderCredentialPresence.prepared);
      expect(prepared.metadata?.configured, isFalse);
      expect(prepared.metadata?.characterCount, 0);
      expect(f.storage.writeKeys.length, writes);
      expect(f.storage.deleteKeys, isEmpty);
    },
  );

  test('actual Unicode key count, not envelope or purpose readiness', () async {
    await f.store();
    final writes = f.storage.writeKeys.length;
    final metadata = await read();
    expect(metadata.presence, NativeProviderCredentialPresence.present);
    expect(metadata.metadata?.configured, isTrue);
    expect(metadata.metadata?.characterCount, nativeCanary.runes.length);
    expect(metadata.toString(), 'NativeProviderConfigurationMetadata');
    expect(f.storage.writeKeys.length, writes);
    expect(
      (await f.inspect(NativeProviderPurpose.studio)).state,
      NativeProviderCredentialState.conflicting,
    );
    expect((await read()).metadata?.configured, isTrue);
    expect(f.storage.deleteKeys, isEmpty);
  });

  test('disabled key remains saved but metadata grants no dispatch', () async {
    await f.store();
    await f.credentials.disableNativeConnectionForOrdinaryMutation(
      connectionId: f.row.id,
    );
    final writes = f.storage.writeKeys.length;
    final metadata = await read();
    expect(metadata.metadata?.configured, isTrue);
    expect(metadata.metadata?.characterCount, nativeCanary.runes.length);
    expect((await f.inspect()).state, NativeProviderCredentialState.disabled);
    expect(f.storage.writeKeys.length, writes);
    expect(f.storage.deleteKeys, isEmpty);
  });

  test('cold metadata registers secret before any name projection', () async {
    await f.store();
    final cold = NativeProviderFixture(
      storage: f.storage,
      row: f.row.copyWith(name: nativeCanary),
    );
    try {
      final metadata = await NativeProviderCredentialMetadataReader(
        credentials: cold.credentials,
      ).readConfiguration(connectionId: cold.row.id, isCurrent: () => true);
      expect(metadata.metadata?.configured, isTrue);
      expect(metadata.metadata?.characterCount, nativeCanary.runes.length);
      expect(
        cold.redaction.redactor.redactText(cold.row.name),
        isNot(contains(nativeCanary)),
      );
      expect(cold.row.apiKey, isEmpty);
      expect(cold.row.name, nativeCanary); // No clandestine row rewrite.
      expect(cold.storage.deleteKeys, isEmpty);
    } finally {
      cold.mutations.dispose();
      cold.redaction.dispose();
    }
  });

  for (final bad in ['', 'not-a-native-record']) {
    test(
      'invalid actual key slot blocks prepared fallback: ${bad.isEmpty}',
      () async {
        await f.markPrepared();
        f.storage.values[f.nativeStorageKey] = bad;
        final metadata = await read();
        expect(metadata.presence, NativeProviderCredentialPresence.corrupt);
        expect(metadata.nativeManaged, isTrue);
        expect(metadata.metadata, isNull);
        expect(f.storage.deleteKeys, isEmpty);
      },
    );
  }

  test('read failure is unknown, not absent/configured false', () async {
    f.storage.readError = StateError(nativeCanary);
    final metadata = await read();
    expect(metadata.presence, NativeProviderCredentialPresence.unavailable);
    expect(metadata.metadata, isNull);
    expect(metadata.toString(), isNot(contains(nativeCanary)));
    expect(f.storage.writeKeys, isEmpty);
    expect(f.storage.deleteKeys, isEmpty);
  });

  test('retirement after native read cannot return even metadata', () async {
    final entered = Completer<void>(), release = Completer<void>();
    f.storage.beforeRead = () async {
      if (!entered.isCompleted) entered.complete();
      await release.future;
    };
    final job = read();
    final expectation = expectLater(
      job,
      throwsNative(NativeProviderFailure.stale),
    );
    try {
      await entered.future;
      f.uiCurrent = false;
    } finally {
      release.complete();
      await expectation;
    }
    expect(f.storage.writeKeys, isEmpty);
    expect(f.storage.deleteKeys, isEmpty);
  });
}
