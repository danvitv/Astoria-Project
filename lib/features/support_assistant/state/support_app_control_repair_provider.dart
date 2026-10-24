import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/db/repositories/database_maintenance_repo.dart';
import '../../../core/db/repositories/session_repair_repo.dart';
import '../../../core/state/chat_source_mutation_provider.dart';
import '../../../core/state/db_provider.dart';
import '../models/support_app_action.dart';
import '../services/app_control/support_app_integrity_adapter.dart';
import '../services/app_control/support_app_repair_runtime.dart';
import '../services/app_control/support_app_session_repair_adapter.dart';
import 'support_app_control_native_repair_provider.dart';

export '../services/app_control/support_app_integrity_adapter.dart';
export '../services/app_control/support_app_repair_runtime.dart';
export '../services/app_control/support_app_session_repair_adapter.dart';

/// Required shared integration hook. Supply the real target-controller queues
/// and latest-state invalidation port, not fresh queues or unconditional guards.
/// Missing native integration is honestly unavailable; no default app startup.
final supportAppRepairNativePortProvider =
    Provider<SupportAppRepairNativePort?>(
      (ref) => ref.watch(supportAppNativeRepairPortProvider),
    );

final supportAppControlRepairAdaptersProvider =
    Provider<List<SupportAppActionAdapter>>((ref) {
      final native = ref.watch(supportAppRepairNativePortProvider);
      if (native == null) return const [];
      final db = ref.watch(appDbProvider);
      final support = ref.watch(supportRepoProvider);
      final mutations = ref.watch(chatSourceMutationRegistryProvider);
      var alive = true;
      bool current() =>
          alive && ref.mounted && native.isCurrent && !mutations.isDisposed;
      int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final integrity = SupportAppIntegrityAdapter(
        repo: DatabaseMaintenanceRepo(db, support),
        native: native,
        isOriginalOwnerCurrent: current,
        now: now,
      );
      final sessions = SupportAppSessionRepairAdapter(
        repo: SessionRepairRepo(db, support),
        now: now,
        runtime: SupportAppRepairRuntime(
          mutations: mutations,
          native: native,
          isOriginalOwnerCurrent: current,
        ),
      );
      ref.onDispose(() {
        alive = false;
        integrity.dispose();
        sessions.dispose();
      });
      return List.unmodifiable([integrity, sessions]);
    });
