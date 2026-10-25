import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/credential_storage.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  setUp(() {
    calls.clear();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 'TEST_ONLY_EXISTING_VALUE';
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  test(
    'existing-only sends the separate read with the same scoped namespace',
    () async {
      final adapter = FlutterSecureCredentialStorage.existingOnly(
        const FlutterSecureStorage(),
        buildChannel: 'dev',
      );
      expect(await adapter.read('synthetic_key'), 'TEST_ONLY_EXISTING_VALUE');
      expect(calls, hasLength(1));
      expect(calls.single.method, 'readExisting');
      final arguments = calls.single.arguments as Map<dynamic, dynamic>;
      expect(arguments['key'], 'synthetic_key');
      final options = arguments['options'] as Map<dynamic, dynamic>;
      expect(options['storageNamespace'], 'app.astoria.credentials.v1.dev');
      await expectLater(
        adapter.write('synthetic_key', 'NO_WRITE'),
        throwsStateError,
      );
      await expectLater(adapter.delete('synthetic_key'), throwsStateError);
      expect(calls, hasLength(1));
    },
  );

  test('ordinary adapter keeps its original channel method', () async {
    final adapter = FlutterSecureCredentialStorage(
      const FlutterSecureStorage(),
      buildChannel: 'stable',
    );
    expect(await adapter.read('synthetic_key'), 'TEST_ONLY_EXISTING_VALUE');
    expect(calls, hasLength(1));
    expect(calls.single.method, 'read');
    final arguments = calls.single.arguments as Map<dynamic, dynamic>;
    final options = arguments['options'] as Map<dynamic, dynamic>;
    expect(options['storageNamespace'], 'app.astoria.credentials.v1.stable');
    expect(options['resetOnError'], 'false');
    expect(options['migrateWithBackup'], 'true');
  });

  test(
    'existing-only backend errors are redacted and never retried normally',
    () async {
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        throw PlatformException(
          code: 'synthetic_failure',
          message: 'NATIVE_TEST_ONLY_CANARY',
        );
      });
      final adapter = FlutterSecureCredentialStorage.existingOnly(
        const FlutterSecureStorage(),
        buildChannel: 'dev',
      );
      await expectLater(
        adapter.read('synthetic_key'),
        throwsA(
          predicate((Object error) => !error.toString().contains('CANARY')),
        ),
      );
      expect(calls.map((call) => call.method), ['readExisting']);
    },
  );

  test('existing-only rejects malformed replies without ordinary fallback', () async {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return 123;
    });
    final adapter = FlutterSecureCredentialStorage.existingOnly(
      const FlutterSecureStorage(),
      buildChannel: 'dev',
    );
    await expectLater(adapter.read('synthetic_key'), throwsStateError);
    expect(calls.map((call) => call.method), ['readExisting']);
  });

  test('existing-only never falls back on unsupported platforms', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final adapter = FlutterSecureCredentialStorage.existingOnly(
      const FlutterSecureStorage(),
      buildChannel: 'dev',
    );
    await expectLater(adapter.read('synthetic_key'), throwsStateError);
    expect(calls, isEmpty);
  });
}
