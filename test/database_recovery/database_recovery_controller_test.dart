import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/build_channel.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/startup/database_startup.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_controller.dart';
import 'package:sqlite3/sqlite3.dart';

import '../startup/startup_memory_keys.dart';
import 'database_recovery_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final value in <String?>[
    null,
    '',
    'not-a-key',
    base64UrlEncode(List.filled(31, 7)),
  ]) {
    test(
      'D2 injected missing/empty/invalid key fails before native RW including empty encrypted candidate ($value)',
      () async {
        final f = DatabaseRecoveryFixture();
        await f.create();
        final controller = f.controller(picker: () async => f.selection());
        final scope = ProviderContainer(
          overrides: [
            databaseRecoveryControllerProvider.overrideWith(() => controller),
          ],
        );
        Future<void>? seedClose;
        try {
          // Candidate is synthetic. Remove encrypted rows through its real repo;
          // preflight must still read the installation key before Core prepare.
          expect(f.process.storageBootstrapAdmitted, false);
          final native = _openSynthetic(f.candidate);
          try {
            await SupportRepo(
              native,
              f.credentials.cipher,
            ).deleteSession('recovery-support');
          } finally {
            seedClose = native.close();
            await seedClose;
          }
          f.keys = StartupMemoryKeys(value);
          f.credentials = DatabaseRecoveryCredentials(
            storage: f.keys,
            channel: buildChannel,
          );
          scope.read(databaseRecoveryControllerProvider);
          await controller.chooseFile();
          final state = scope.read(databaseRecoveryControllerProvider);
          expect(state.phase, DatabaseRecoveryPhase.ready);
          expect(state.keyFailure, isNotNull);
          expect(f.keys.reads, 1);
          expect(f.keys.writes, 0);
          expect(f.keys.deletes, 0);
          expect(f.operations.single.owner, isNull);
          expect(f.normalOpens, 0);
          expect(f.bootstraps, 0);
          expect(f.publications, 0);
          f.expectBusy();
        } finally {
          scope.dispose();
          await f.close(
            controller,
            extraJoin: () async {
              await seedClose;
            },
          );
        }
      },
      skip: !Platform.isWindows,
    );
  }
}

// Explicit test-only synthetic candidate, never getAppDataDir/default AppDatabase.
AppDatabase _openSynthetic(File file) =>
    AppDatabase.openedNative(sqlite3.open(file.path));
