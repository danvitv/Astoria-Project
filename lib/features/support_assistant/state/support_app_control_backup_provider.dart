import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/app_db.dart';
import '../../../core/state/db_provider.dart';
import '../models/support_app_action.dart';
import '../services/app_control/backup/support_backup_file_host.dart';
import '../services/app_control/backup/support_database_backup_adapter.dart';

export '../services/app_control/backup/support_backup_file_host.dart';
export '../services/app_control/backup/support_backup_native_ui.dart';
export '../services/app_control/backup/support_database_backup_adapter.dart';

/// Original-screen composition supplies SupportBackupNativeUi + file host.
/// Missing UI is unavailable, never default approval or default DB discovery.
final supportAppBackupNativeFileHostProvider =
    Provider<SupportBackupNativeFileHost?>((ref) => null);

/// Adapters only: the shared registry/run/UI integrator owns composition.
final supportAppControlBackupAdaptersProvider =
    Provider<List<SupportAppActionAdapter>>((ref) {
      final host = ref.watch(supportAppBackupNativeFileHostProvider);
      // Do NOT instantiate a default runtime database when no native host exists.
      final AppDatabase? originalDb = host == null
          ? null
          : ref.watch(appDbProvider);
      var alive = true;
      bool current() =>
          alive &&
          ref.mounted &&
          (host?.isCurrent ?? true) &&
          (originalDb == null ||
              identical(ref.read(appDbProvider), originalDb));
      NativeDataSourceIdentity? source() {
        if (!current() || originalDb == null) return null;
        final identity = originalDb.nativeDataSourceIdentity;
        return identity?.belongsTo(originalDb) == true && current()
            ? identity
            : null;
      }

      final adapter = SupportDatabaseBackupAdapter(
        native: host,
        originalSource: source,
        isOriginalOwnerCurrent: current,
      );
      ref.onDispose(() {
        alive = false;
        adapter.dispose();
      });
      return List.unmodifiable([adapter]);
    });
