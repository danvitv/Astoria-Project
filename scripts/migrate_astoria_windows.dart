import 'dart:io';

import 'package:glaze_flutter/core/services/windows_data_migration.dart';
import 'package:glaze_flutter/core/services/astoria_data_migration.dart';
import 'package:glaze_flutter/core/services/windows_preferences_migration.dart';

Future<void> main() async {
  if (!Platform.isWindows) {
    stderr.writeln('Windows data import only runs on Windows.');
    exitCode = 1;
    return;
  }
  await migrateAstoriaWindowsData();
  await migrateAstoriaData();
  await migrateAstoriaWindowsPreferences();
  stdout.writeln('Astoria Windows data import finished.');
}
