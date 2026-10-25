import 'dart:async';
import 'dart:io';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

import 'app.dart';
import 'core/app_runtime.dart';
import 'core/debug/perf_debug.dart';
import 'core/platform/desktop_window.dart';
import 'core/services/astoria_data_migration.dart';
import 'core/services/dev_mode_flag_migration.dart';
import 'core/services/preset_seeder.dart';
import 'core/db/repositories/database_restore_repo.dart';
import 'core/startup/database_startup.dart';
import 'core/startup/windows_startup_migrations.dart';
import 'core/utils/platform_paths.dart';
import 'core/navigation/router.dart' show rootNavigatorKey;
import 'features/database_recovery/database_recovery_controller.dart';
import 'features/database_recovery/database_recovery_entry_notice.dart';
import 'features/database_recovery/database_recovery_screen.dart';

final appRestartKey = GlobalKey();

// Deliberately retained until OS termination. No Dart/widget lifecycle closes
// this guard or pretends that all application writers have drained.
ProcessDatabaseStartup? _processDatabaseStartup;
AndroidRecoveryEntryNotice? _recoveryEntryNotice;

Future<void> main(List<String> args) async {
  final selection = Platform.isAndroid
      ? parseAndroidDatabaseStartupArguments(args)
      : parseDatabaseStartupArguments(args);
  await _startProcess(selection);
}

/// Android launcher recovery Activity uses a dedicated cold-process entrypoint.
/// No intent file/approval/route arguments or persisted selector are accepted.
@pragma('vm:entry-point')
Future<void> databaseRecoveryMain() => _startProcess(
  Platform.isAndroid
      ? DatabaseStartupSelection.recovery
      : DatabaseStartupSelection.rejected,
);

Future<void> _startProcess(DatabaseStartupSelection selection) async {
  WidgetsFlutterBinding.ensureInitialized();
  if (Platform.isAndroid) {
    _recoveryEntryNotice ??= AndroidRecoveryEntryNotice(
      isNormalCurrent: () =>
          _processDatabaseStartup?.storageBootstrapAdmitted == true,
      context: () => rootNavigatorKey.currentContext,
    )..install();
  }
  ProcessDatabaseStartup process;
  if (Platform.isWindows) {
    try {
      process = ProcessDatabaseStartup.acquireWindows(Platform.environment);
      _processDatabaseStartup = process;
    } catch (error) {
      await _showRecovery(
        block: error is DatabaseRestoreException
            ? error.code
            : DatabaseRestoreCode.unsupported,
      );
      return; // Fail closed: no migrations, prefs, key or ordinary providers.
    }
  } else if (Platform.isAndroid) {
    try {
      process = await ProcessDatabaseStartup.acquireAndroid();
      _processDatabaseStartup = process;
    } catch (error) {
      await _showRecovery(
        block: error is DatabaseRestoreException
            ? error.code
            : DatabaseRestoreCode.unsupported,
      );
      return;
    }
  } else {
    process = ProcessDatabaseStartup.otherPlatforms();
    _processDatabaseStartup = process;
  }
  if (selection == DatabaseStartupSelection.rejected ||
      (selection == DatabaseStartupSelection.recovery &&
          !Platform.isWindows &&
          !Platform.isAndroid) ||
      process.normalOpeningBlocked) {
    await _showRecovery(
      process: process,
      block: process.normalOpeningBlocked
          ? DatabaseRestoreCode.interruptedRequiresFreshConfirmation
          : DatabaseRestoreCode.unsupported,
    );
    return;
  }
  if (selection == DatabaseStartupSelection.recovery) {
    await _showRecovery(process: process);
    return;
  }
  try {
    await process.openNormal(() => _bootstrapNormal(process));
    _publishNormal(process);
  } catch (_) {
    if (!Platform.isWindows && !Platform.isAndroid) rethrow;
    await _showRecovery(
      process: process,
      block: DatabaseRestoreCode.recoveryRequired,
    );
  }
}

Future<void> _showRecovery({
  ProcessDatabaseStartup? process,
  DatabaseRestoreCode? block,
}) async {
  var recoveryAvailable = false;
  if (block == null && process != null) {
    try {
      recoveryAvailable = process.recoveryTargetAvailable;
    } catch (_) {
      block = DatabaseRestoreCode.unsupported;
    }
  }
  try {
    await initDesktopWindow(persistGeometry: false);
  } catch (_) {
    // Fixed blocked surface, never fall back to preference-backed startup.
  }
  runApp(
    DatabaseRecoveryApp(
      targetPath: process?.target?.path,
      controller: DatabaseRecoveryController(
        process: process,
        initialBlock: block,
        recoveryAvailable: recoveryAvailable,
        bootstrap: () => _bootstrapNormal(process!),
        publishNormal: _publishNormal,
      ),
    ),
  );
}

Future<void> _bootstrapNormal(ProcessDatabaseStartup process) async {
  AppRuntime.markStarted();
  PerfDebug.installFrameLoggerIfEnabled();
  try {
    if (Platform.isWindows) {
      await migrateWindowsStartupStorage(process);
    } else if (Platform.isAndroid || Platform.isIOS) {
      final dataRoot = await getAppDataDir();
      await migrateAstoriaData(
        dataRoot: dataRoot,
        legacyDataRoot: p.join(p.dirname(dataRoot), 'Glaze'),
      );
    } else {
      await migrateAstoriaData();
    }
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: Platform.isWindows
            ? StateError('Windows startup storage migration failed')
            : error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('Astoria data migration failed'),
      ),
    );
    rethrow;
  }
  // After the Windows migration: that one rewrites the preferences file on
  // disk, so it has to land before SharedPreferences is first opened here.
  try {
    await resetLegacyDevModeFlag();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('dev mode flag reset failed'),
      ),
    );
  }
  // Choose the bundled first-run preset before providers read the active id.
  try {
    await applyFirstRunPresetChoice();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('first-run preset choice failed'),
      ),
    );
  }
  await EasyLocalization.ensureInitialized();
  try {
    await initDesktopWindow();
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('desktop window setup failed'),
      ),
    );
  }
  try {
    await SystemChrome.setPreferredOrientations([
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
    ]);
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('orientation lock failed'),
      ),
    );
  }
  // Draw the app's own background behind the system status/navigation bars and
  // keep those bars transparent. Without this the OS paints the navigation bar
  // with the Android *window* background, which follows the system light/dark
  // setting (see android/.../values*/styles.xml). On a device whose OS is in
  // light mode while the app is forced dark (e.g. MIUI/HyperOS on Poco), that
  // left a light strip behind the navigation bar; some OEMs additionally force
  // a contrast scrim there. `edgeToEdge` + transparent bars + contrast disabled
  // lets [GlazeBackground] paint edge-to-edge instead. The floating nav bar and
  // other bottom UI already offset themselves by MediaQuery.padding.bottom.
  try {
    await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        systemNavigationBarContrastEnforced: false,
        systemStatusBarContrastEnforced: false,
      ),
    );
  } catch (error, stackTrace) {
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: error,
        stack: stackTrace,
        library: 'startup',
        context: ErrorDescription('system UI overlay setup failed'),
      ),
    );
  }
}

void _publishNormal(ProcessDatabaseStartup process) {
  // Keep process storage through all keyed normal scopes and recovery disposal.
  _processDatabaseStartup = process;
  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('en'), Locale('ru')],
      path: 'assets/translations',
      fallbackLocale: const Locale('en'),
      child: _RestartableApp(process: _processDatabaseStartup!),
    ),
  );
  WidgetsBinding.instance.addPostFrameCallback((_) {
    final notice = _recoveryEntryNotice;
    if (notice != null) {
      // The original notice owns its route future; this is not a storage action.
      final original = notice.presentPending();
      unawaited(
        original.then<void>((_) {}, onError: (Object _, StackTrace _) {}),
      );
    }
  });
}

class _RestartableApp extends StatefulWidget {
  const _RestartableApp({required this.process});
  final ProcessDatabaseStartup process;

  @override
  State<_RestartableApp> createState() => _RestartableAppState();
}

class _RestartableAppState extends State<_RestartableApp> {
  Key _key = UniqueKey();

  void restart() => setState(() => _key = UniqueKey());

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: _key,
      child: ProcessDatabaseScope(
        process: widget.process,
        child: GlazeApp(restart: restart),
      ),
    );
  }
}
