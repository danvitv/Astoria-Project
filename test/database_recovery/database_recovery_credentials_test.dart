import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/build_channel.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/startup/database_startup.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_entry_notice.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'database_recovery_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets(
    'Hot Android entry only shows a fixed notice after normal admission',
    (tester) async {
      const channel = MethodChannel('app.astoria.flutter/recovery_entry');
      const codec = StandardMethodCodec();
      final navigator = GlobalKey<NavigatorState>();
      var normal = false;
      final notice = AndroidRecoveryEntryNotice(
        isNormalCurrent: () => normal,
        context: () => navigator.currentContext,
      )..install();
      Completer<void> send(Object? arguments) {
        final originalReply = Completer<void>();
        tester.binding.channelBuffers.push(
          channel.name,
          codec.encodeMethodCall(MethodCall('requiresColdStart', arguments)),
          (_) => originalReply.complete(),
        );
        return originalReply;
      }

      try {
        // No ProviderScope or installed preferences/key/database graph exists.
        await tester.pumpWidget(
          MaterialApp(
            navigatorKey: navigator,
            home: const Scaffold(body: Text('Synthetic app')),
          ),
        );
        final denied = send({
          'approved': true,
          'path': 'TEST_ONLY_UNTRUSTED_PATH',
        });
        await tester.pump();
        await denied.future;
        expect(find.byType(Dialog), findsNothing);
        final early = send(null);
        await tester.pump();
        await early.future;
        expect(find.byType(Dialog), findsNothing);
        normal = true;
        final original = notice.presentPending();
        await tester.pumpAndSettle();
        expect(find.byType(Dialog), findsOneWidget);
        expect(find.textContaining('TEST_ONLY_UNTRUSTED_PATH'), findsNothing);
        final duplicate = send(null);
        await tester.pump();
        expect(
          duplicate.isCompleted,
          false,
        ); // Owns the same original modal future.
        expect(find.byType(Dialog), findsOneWidget);
        await tester.tap(find.byType(GlazeActionButton));
        await tester.pumpAndSettle();
        await original;
        await duplicate.future;
        expect(find.byType(Dialog), findsNothing);
        await notice
            .presentPending(); // Duplicate did not queue another notice.
        await tester.pump();
        expect(find.byType(Dialog), findsNothing);
        expect(tester.takeException(), isNull);
      } finally {
        channel.setMethodCallHandler(null);
        await tester.pumpWidget(const SizedBox.shrink());
      }
    },
  );

  test(
    'Android fixed startup paths and CLI payloads are pure and fail closed',
    () {
      final paths = resolveAndroidStartupPaths(
        '/data/user/0/app.astoria.fixture',
      );
      expect(paths.startupDirectory.path, '/data/user/0/app.astoria.fixture');
      expect(
        paths.target.path,
        '/data/user/0/app.astoria.fixture/app_flutter/Astoria/astoria.db',
      );
      for (final root in [
        '',
        'relative',
        '/data/../user',
        '/data//user',
        '/data/\u0000user',
      ]) {
        expect(() => resolveAndroidStartupPaths(root), throwsUnsupportedError);
      }
      expect(
        parseAndroidDatabaseStartupArguments([]),
        DatabaseStartupSelection.normal,
      );
      for (final payload in [
        ['--astoria-recovery'],
        ['candidate.db'],
        ['approved=true'],
        ['--astoria-recovery', 'candidate.db'],
      ]) {
        expect(
          parseAndroidDatabaseStartupArguments(payload),
          DatabaseStartupSelection.rejected,
        );
      }
    },
  );

  test(
    'Actual accepted capability enables SAME Android storage only for SAME startup',
    () async {
      final f = DatabaseRecoveryFixture();
      final other = DatabaseRecoveryFixture();
      await f.create();
      await other.create();
      const channel = MethodChannel(
        'plugins.it_nomads.com/flutter_secure_storage',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      final calls = <MethodCall>[];
      final previous = debugDefaultTargetPlatformOverride;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      messenger.setMockMethodCallHandler(channel, (call) async {
        calls.add(call);
        return call.method == 'readExisting' || call.method == 'read'
            ? f.keys.value
            : null;
      });
      NativeDatabaseRestoreOwner? owner;
      var retained = false;
      ProviderContainer? scope;
      try {
        final credentials = DatabaseRecoveryCredentials.android(
          storage: const FlutterSecureStorage(),
          channel: buildChannel,
        );
        final denied = DatabaseRecoveryCredentials.android(
          storage: const FlutterSecureStorage(),
          channel: buildChannel,
        );
        final sameStorage = credentials.storage;
        final sameVault = credentials.vault;
        final sameCipher = credentials.cipher;
        await credentials.cipher.requireExistingInstallationKey();
        await expectLater(
          sameStorage.write('TEST_ONLY_BEFORE', 'NO_WRITE'),
          throwsStateError,
        );
        await expectLater(
          sameStorage.delete('TEST_ONLY_BEFORE'),
          throwsStateError,
        );
        expect(calls.map((call) => call.method), everyElement('readExisting'));

        owner = NativeDatabaseRestoreOwner.fromStartup(
          startup: f.startup,
          candidate: f.candidate,
          payloadCipher: SupportPayloadCipher.readOnly(
            delegate: credentials.cipher,
            gate: (read) => read(),
          ),
        );
        final repo = DatabaseRestoreRepo(owner: owner);
        final proposal = await repo.prepare();
        final result = await repo.restore(repo.confirm(proposal));
        expect(result.code, DatabaseRestoreCode.accepted);
        final accepted =
            result.accepted!; // Genuine Core result, not an injected receipt.
        expect(calls.map((call) => call.method), everyElement('readExisting'));
        expect(
          () => denied.enableNormalStorage(accepted, other.startup),
          throwsA(isA<DatabaseRestoreException>()),
        );
        await expectLater(
          denied.storage.write('TEST_ONLY_OTHER', 'NO_WRITE'),
          throwsStateError,
        );

        f.process.retainAccepted(accepted, credentials);
        retained = true;
        scope = ProviderContainer(overrides: f.process.providerOverrides);
        expect(
          identical(scope.read(credentialStorageProvider), sameStorage),
          true,
        );
        expect(identical(scope.read(credentialVaultProvider), sameVault), true);
        expect(
          identical(scope.read(supportPayloadCipherProvider), sameCipher),
          true,
        );
        expect(identical(scope.read(appDbProvider), accepted.database), true);
        expect(
          identical(
            scope.read(llmRequestCaptureRepoProvider),
            f.process.capture,
          ),
          true,
        );
        await sameStorage.read('TEST_ONLY_AFTER');
        await sameStorage.write('TEST_ONLY_AFTER', 'TEST_ONLY_VALUE');
        await sameStorage.delete('TEST_ONLY_AFTER');
        expect(
          calls.map((call) => call.method).toList().sublist(calls.length - 3),
          ['read', 'write', 'delete'],
        );
        for (final call in calls) {
          final options =
              (call.arguments as Map<dynamic, dynamic>)['options']
                  as Map<dynamic, dynamic>;
          expect(
            options['storageNamespace'],
            'app.astoria.credentials.v1.$buildChannel',
          );
        }
        expect(
          () => credentials.enableNormalStorage(accepted, f.startup),
          throwsA(isA<DatabaseRestoreException>()),
        );
      } finally {
        scope?.dispose();
        if (!retained) await owner?.close();
        await f.close(f.controller());
        await other.close(other.controller());
        messenger.setMockMethodCallHandler(channel, null);
        debugDefaultTargetPlatformOverride = previous;
      }
    },
    skip: !Platform.isWindows,
  );
}
