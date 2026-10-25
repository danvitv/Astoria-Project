import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/constants/build_channel.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/database_restore_repo.dart';
import 'package:glaze_flutter/core/llm/transport/llm_call_event.dart';
import 'package:glaze_flutter/core/llm/transport/llm_request_capture.dart';
import 'package:glaze_flutter/core/services/dev_mode_flag_migration.dart';
import 'package:glaze_flutter/core/services/preset_seeder.dart';
import 'package:glaze_flutter/core/startup/database_startup.dart';
import 'package:glaze_flutter/core/startup/windows_startup_migrations.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/utils/platform_paths.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_controller.dart';
import 'package:glaze_flutter/features/database_recovery/database_recovery_screen.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test(
    'D2 CLI selects only a surface and rejects payload/approval/unknown arguments',
    () {
      expect(
        parseDatabaseStartupArguments([]),
        DatabaseStartupSelection.normal,
      );
      expect(
        parseDatabaseStartupArguments(['--astoria-recovery']),
        DatabaseStartupSelection.recovery,
      );
      for (final args in [
        ['--astoria-recovery=synthetic.db'],
        ['--astoria-recovery', 'synthetic.db'],
        ['--astoria-recovery', '--approve'],
        ['--astoria-recovery', '--target=synthetic.db'],
        ['--astoria-recovery', '--automatic'],
        ['--astoria-recovery', '--unknown'],
        ['--astoria-recovery', '--astoria-recovery'],
      ]) {
        expect(
          parseDatabaseStartupArguments(args),
          DatabaseStartupSelection.rejected,
        );
      }
    },
  );

  test(
    'D2 Windows cannot use missing/default startup composition for ordinary opening',
    () {
      expect(
        () => ProcessDatabaseStartup.otherPlatforms(),
        throwsA(isA<DatabaseRestoreException>()),
      );
    },
    skip: !Platform.isWindows,
  );

  test(
    'D2 actual guarded Windows migrations precede first-run and normal DB/scope restart',
    () async {
      final anchor = _anchor();
      final paths = resolveWindowsStartupPaths({'APPDATA': anchor.path});
      final oldName = isStableChannel
          ? 'Glaze'
          : 'Glaze-${buildChannel == 'dev' ? 'nightly' : buildChannel}';
      final old = Directory('${anchor.path}\\$oldName')..createSync();
      final oldDb = sqlite3.open('${old.path}\\glaze.db');
      oldDb.execute('CREATE TABLE synthetic_startup_witness (value TEXT)');
      oldDb.execute(
        "INSERT INTO synthetic_startup_witness VALUES ('synthetic-migration')",
      );
      oldDb.close();
      final oldPrefs = File(
        '${anchor.path}\\com.glaze\\Glaze\\shared_preferences.json',
      );
      oldPrefs.parent.createSync(recursive: true);
      oldPrefs.writeAsStringSync(
        jsonEncode({'flutter.synthetic_setting': 'from-legacy'}),
      );
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      final process = ProcessDatabaseStartup.acquireWindows({
        'APPDATA': anchor.path,
      });
      var bootstrapCalls = 0;
      try {
        expect(paths.target.parent.existsSync(), false);
        expect(paths.target.existsSync(), false);
        await process.openNormal(() async {
          bootstrapCalls++;
          expect(process.storageBootstrapAdmitted, true);
          _expectBusy(anchor, paths.target);
          await migrateWindowsStartupStorage(process);
          expect(paths.target.existsSync(), true);
          expect(
            File('${paths.target.parent.path}\\glaze.db').existsSync(),
            true,
          );
          expect(
            File(
              '${anchor.path}\\Astoria Project\\Astoria\\shared_preferences.json',
            ).existsSync(),
            true,
          );
          await resetLegacyDevModeFlag(preferences: prefs);
          await applyFirstRunPresetChoice(preferences: prefs);
        });
        expect(bootstrapCalls, 1);
        expect(prefs.getString('activePresetId'), defaultPresetId);
        expect(await ChatRepo(process.database).countByCharacterId(''), 0);
        expect(identical(process.capture.db, process.database), true);
        final first = ProviderContainer(overrides: process.providerOverrides);
        final db = first.read(appDbProvider);
        final capture = first.read(llmRequestCaptureRepoProvider);
        first.read(llmRequestCaptureInstallationProvider);
        final second = ProviderContainer(overrides: process.providerOverrides);
        try {
          second.read(llmRequestCaptureInstallationProvider);
          first.dispose(); // Old scope may retire after the new scope installs.
          expect(identical(second.read(appDbProvider), db), true);
          expect(
            identical(second.read(llmRequestCaptureRepoProvider), capture),
            true,
          );
          expect(LlmRequestCapture.sink, same(capture));
          expect(LlmCallEventCapture.sink, same(capture));
        } finally {
          second.dispose();
        }
        expect(LlmRequestCapture.sink, isNull);
        expect(LlmCallEventCapture.sink, isNull);
        _expectBusy(anchor, paths.target);
        await expectLater(
          process.closeForTesting(() async {
            throw StateError('Synthetic known-work join failure');
          }),
          throwsStateError,
        );
        _expectBusy(anchor, paths.target); // Failed join is NOT drain evidence.
        expect(identical(process.database, db), true);
        expect(
          () => process.openNormal(() async {
            bootstrapCalls++;
          }),
          throwsA(isA<DatabaseRestoreException>()),
        );
        expect(bootstrapCalls, 1);
      } finally {
        await process.closeForTesting(() async {});
        _removeBoundedFixture(anchor);
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'D2 process marker admission blocks all migrations and ordinary DB construction',
    () async {
      final anchor = _anchor();
      final process = ProcessDatabaseStartup.acquireWindows({
        'APPDATA': anchor.path,
      });
      var migrationCalls = 0;
      try {
        process.target!.parent.createSync();
        File(
          '${process.target!.parent.path}\\.astoria-restore-interrupted',
        ).writeAsStringSync('synthetic-marker');
        expect(
          () => process.openNormal(() async {
            migrationCalls++;
          }),
          throwsA(isA<DatabaseRestoreException>()),
        );
        expect(migrationCalls, 0);
        expect(process.storageBootstrapAdmitted, false);
        expect(() => process.database, throwsStateError);
        expect(process.target!.existsSync(), false);
        _expectBusy(anchor, process.target!);
      } finally {
        await process.closeForTesting(() async {});
        _removeBoundedFixture(anchor);
      }
    },
    skip: !Platform.isWindows,
  );

  testWidgets(
    'D2 absent installation requires production Continue tap for guarded first-run',
    (tester) async {
      final anchor = _anchor();
      final process = ProcessDatabaseStartup.acquireWindows({
        'APPDATA': anchor.path,
      });
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      var bootstrapCalls = 0, publications = 0;
      final controller = DatabaseRecoveryController(
        process: process,
        recoveryAvailable: false,
        bootstrap: () async {
          bootstrapCalls++;
          await migrateWindowsStartupStorage(process);
          await resetLegacyDevModeFlag(preferences: prefs);
          await applyFirstRunPresetChoice(preferences: prefs);
        },
        publishNormal: (value) {
          expect(identical(value, process), true);
          publications++;
        },
      );
      try {
        await tester.pumpWidget(
          DatabaseRecoveryApp(
            controller: controller,
            targetPath: process.target!.path,
          ),
        );
        expect(bootstrapCalls, 0);
        expect(process.target!.parent.existsSync(), false);
        expect(process.target!.existsSync(), false);
        _expectBusy(anchor, process.target!);
        final continueButton = find.byKey(const ValueKey('recovery-continue'));
        await tester.ensureVisible(continueButton);
        await tester.runAsync(() async {
          await tester.tap(continueButton);
        });
        await tester.runAsync(controller.joinForTesting);
        await tester.pump();
        // continueNormally's original work is retained on the process opening seam.
        await tester.runAsync(() async {
          expect(await ChatRepo(process.database).countByCharacterId(''), 0);
        });
        expect(bootstrapCalls, 1);
        expect(publications, 1);
        expect(prefs.getString('activePresetId'), defaultPresetId);
        _expectBusy(anchor, process.target!);
        await tester.pumpWidget(const SizedBox.shrink());
        _expectBusy(anchor, process.target!);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.runAsync(
          () => process.closeForTesting(controller.joinForTesting),
        );
        _removeBoundedFixture(anchor);
      }
    },
    skip: !Platform.isWindows,
  );
}

Directory _anchor() => Directory(
  r'C:\Users\Даниил\AppData\Local\Temp\opencode',
).createTempSync('d2-process-startup-');

void _expectBusy(Directory anchor, File target) => expect(
  () => NativeDatabaseStartupOwner.acquire(
    existingStartupDirectory: anchor,
    target: target,
  ),
  throwsA(
    isA<DatabaseRestoreException>().having(
      (error) => error.code,
      'process guard survives scope restart',
      DatabaseRestoreCode.busy,
    ),
  ),
);

/// Bounded descendants of this newly created fixture only, after genuine close.
void _removeBoundedFixture(Directory root) {
  final children = root.listSync(followLinks: false);
  expect(children.length <= 16, true);
  for (final child in children) {
    if (child is Directory) {
      _removeBoundedFixture(child);
    } else {
      expect(child is File, true);
      (child as File).deleteSync();
    }
  }
  root.deleteSync();
}
