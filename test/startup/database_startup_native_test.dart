import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/build_channel.dart';
import 'package:glaze_flutter/core/credentials/credential_vault.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/support/support_payload_cipher.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';

import 'startup_memory_keys.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('Startup resolver is pure and has no missing APPDATA fallback', () {
    final before = cachedAppDataDir;
    final paths = resolveWindowsStartupPaths({
      'APPDATA': r'C:\synthetic-anchor',
    });
    expect(paths.startupDirectory.path, r'C:\synthetic-anchor');
    expect(
      paths.target.path,
      'C:\\synthetic-anchor\\$astoriaDataFolderName\\astoria.db',
    );
    expect(cachedAppDataDir, before);
    expect(() => resolveWindowsStartupPaths({}), throwsUnsupportedError);
    expect(
      () => resolveWindowsStartupPaths({'APPDATA': ''}),
      throwsUnsupportedError,
    );
  });

  test(
    'Startup real second guard is busy before target root or key exists',
    () async {
      final anchor = Directory(
        r'C:\Users\Даниил\AppData\Local\Temp\opencode',
      ).createTempSync('startup-keyless-');
      final paths = resolveWindowsStartupPaths({'APPDATA': anchor.path});
      NativeDatabaseStartupOwner? startup;
      try {
        startup = NativeDatabaseStartupOwner.acquire(
          existingStartupDirectory: paths.startupDirectory,
          target: paths.target,
        );
        expect(paths.target.parent.existsSync(), false);
        expect(paths.target.existsSync(), false);
        expect(
          () => NativeDatabaseStartupOwner.acquire(
            existingStartupDirectory: paths.startupDirectory,
            target: paths.target,
          ),
          throwsA(_restoreCode(DatabaseRestoreCode.busy)),
        );
        // The shared anchor lock excludes another channel, too.
        expect(
          () => NativeDatabaseStartupOwner.acquire(
            existingStartupDirectory: anchor,
            target: File('${anchor.path}\\other-channel\\astoria.db'),
          ),
          throwsA(_restoreCode(DatabaseRestoreCode.busy)),
        );
        final keys = StartupMemoryKeys(null);
        final cipher = SupportPayloadCipher(
          vault: CredentialVault(
            storage: keys,
            buildChannel: 'startup_synthetic',
          ),
        );
        expect(
          () => NativeDatabaseRestoreOwner.fromStartup(
            startup: startup!,
            candidate: File('${anchor.path}\\absent.db'),
            payloadCipher: cipher,
          ),
          throwsA(_restoreCode(DatabaseRestoreCode.unavailable)),
        );
        expect(keys.reads, 0);
        expect(keys.writes, 0);
        expect(keys.deletes, 0);
        expect(paths.target.parent.existsSync(), false);
        startup.claimNormalOpening();
        expect(startup.normalOpeningBlocked, true); // one-use admission spent
        expect(
          () => startup!.claimNormalOpening(),
          throwsA(_restoreCode(DatabaseRestoreCode.stale)),
        );
        expect(
          () => NativeDatabaseRestoreOwner.fromStartup(
            startup: startup!,
            candidate: File('${anchor.path}\\absent.db'),
            payloadCipher: cipher,
          ),
          throwsA(_restoreCode(DatabaseRestoreCode.stale)),
        );
        expect(
          () => NativeDatabaseStartupOwner.acquire(
            existingStartupDirectory: anchor,
            target: paths.target,
          ),
          throwsA(_restoreCode(DatabaseRestoreCode.busy)),
        );
      } finally {
        startup?.closeForTesting();
        final lock = File('${anchor.path}\\.astoria-restore-startup.lock');
        if (lock.existsSync()) lock.deleteSync();
        anchor.deleteSync();
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'Startup marker before or after acquisition blocks normal admission',
    () {
      for (final markerBeforeAcquisition in [true, false]) {
        final anchor = Directory(
          r'C:\Users\Даниил\AppData\Local\Temp\opencode',
        ).createTempSync('startup-marker-');
        final paths = resolveWindowsStartupPaths({'APPDATA': anchor.path});
        paths.target.parent.createSync();
        final marker = File(
          '${paths.target.parent.path}\\.astoria-restore-interrupted',
        );
        NativeDatabaseStartupOwner? startup;
        try {
          if (markerBeforeAcquisition)
            marker.writeAsStringSync('fixture marker');
          startup = NativeDatabaseStartupOwner.acquire(
            existingStartupDirectory: anchor,
            target: paths.target,
          );
          if (!markerBeforeAcquisition)
            marker.writeAsStringSync('fixture marker');
          expect(
            () => startup!.claimNormalOpening(),
            throwsA(
              _restoreCode(
                DatabaseRestoreCode.interruptedRequiresFreshConfirmation,
              ),
            ),
          );
          // Removing the fixture marker does not un-latch a blocked owner.
          marker.deleteSync();
          expect(
            () => startup!.claimNormalOpening(),
            throwsA(
              _restoreCode(
                DatabaseRestoreCode.interruptedRequiresFreshConfirmation,
              ),
            ),
          );
          expect(paths.target.existsSync(), false);
          expect(
            () => NativeDatabaseStartupOwner.acquire(
              existingStartupDirectory: anchor,
              target: paths.target,
            ),
            throwsA(_restoreCode(DatabaseRestoreCode.busy)),
          );
        } finally {
          startup?.closeForTesting();
          if (marker.existsSync()) marker.deleteSync();
          File('${anchor.path}\\.astoria-restore-startup.lock').deleteSync();
          paths.target.parent.deleteSync();
          anchor.deleteSync();
        }
      }
    },
    skip: !Platform.isWindows,
  );

  for (final entry in <(String, String?, SupportCipherFailure?)>[
    ('missing', null, SupportCipherFailure.keyMissing),
    ('empty', '', SupportCipherFailure.keyMissing),
    ('invalid', 'not-a-key', SupportCipherFailure.invalidKey),
    ('valid', base64UrlEncode(List<int>.filled(32, 17)), null),
  ]) {
    test(
      'Existing-key preflight ${entry.$1} reads only through read gate',
      () async {
        final storage = StartupMemoryKeys(entry.$2);
        final base = SupportPayloadCipher(
          vault: CredentialVault(
            storage: storage,
            buildChannel: 'startup_synthetic',
          ),
        );
        var gates = 0;
        final cipher = SupportPayloadCipher.readOnly(
          delegate: base,
          gate: (read) async {
            gates++;
            return read();
          },
        );
        if (entry.$3 == null) {
          await cipher.requireExistingInstallationKey();
        } else {
          await expectLater(
            cipher.requireExistingInstallationKey(),
            throwsA(
              isA<SupportCipherException>().having(
                (e) => e.failure,
                'failure',
                entry.$3,
              ),
            ),
          );
        }
        expect(gates, 1);
        expect(storage.reads, 1);
        expect(storage.writes, 0);
        expect(storage.deletes, 0);
        expect(storage.value, entry.$2);
        await expectLater(
          cipher.encrypt(
            plaintext: 'fixture',
            table: 'fixture',
            rowId: 'one',
            field: 'body',
          ),
          throwsA(isA<SupportCipherException>()),
        );
        expect(storage.reads, 1);
        expect(storage.writes, 0);
      },
    );
  }

  test(
    'Existing-key preflight backend read failure cannot create or delete key',
    () async {
      final storage = StartupMemoryKeys(null, failRead: true);
      final cipher = SupportPayloadCipher.readOnly(
        delegate: SupportPayloadCipher(
          vault: CredentialVault(
            storage: storage,
            buildChannel: 'startup_synthetic',
          ),
        ),
        gate: (read) => read(),
      );
      await expectLater(
        cipher.requireExistingInstallationKey(),
        throwsA(
          isA<SupportCipherException>().having(
            (e) => e.failure,
            'failure',
            SupportCipherFailure.vaultUnavailable,
          ),
        ),
      );
      expect(storage.reads, 1);
      expect(storage.writes, 0);
      expect(storage.deletes, 0);
    },
  );
}

Matcher _restoreCode(DatabaseRestoreCode code) =>
    isA<DatabaseRestoreException>().having((e) => e.code, 'code', code);
