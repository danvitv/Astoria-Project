import 'package:path/path.dart' as p;
import 'package:flutter/foundation.dart';

import '../constants/build_channel.dart';
import '../services/astoria_data_migration.dart';
import '../services/windows_data_migration.dart';
import '../services/windows_preferences_migration.dart';
import 'database_startup.dart';

/// The real ordered Windows storage pipeline, using only the admitted resolver's
/// fixed APPDATA map. Fixture callers supply a synthetic process, never defaults.
Future<void> migrateWindowsStartupStorage(
  ProcessDatabaseStartup process,
) async {
  final environment = process.environment;
  final target = process.target;
  if (environment == null ||
      target == null ||
      !process.storageBootstrapAdmitted) {
    throw StateError('Windows storage startup not admitted');
  }
  await migrateAstoriaWindowsData(environment: environment);
  final oldFolder = isStableChannel
      ? 'Glaze'
      : 'Glaze-${buildChannel == 'dev' ? 'nightly' : buildChannel}';
  await migrateAstoriaData(
    dataRoot: target.parent.path,
    legacyDataRoot: p.join(environment['APPDATA']!, oldFolder),
  );
  // Keep this before the first SharedPreferences open, across both channels.
  try {
    await migrateAstoriaWindowsPreferences(environment: environment);
  } catch (_, stack) {
    // Preserve the existing best-effort preferences migration policy, without
    // allowing native path/value-bearing errors into recovery diagnostics.
    FlutterError.reportError(
      FlutterErrorDetails(
        exception: StateError('Windows preferences migration failed'),
        stack: stack,
        library: 'startup',
      ),
    );
  }
}
