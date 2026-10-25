import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';

import '../../models/support_models.dart';
import '../app_db.dart';
import '../database_transaction_guard.dart';
import '../models/database_maintenance.dart';
import 'support_repo.dart';

part 'database_maintenance/health_reader.dart';
part 'database_maintenance/health_table_reader.dart';
part 'database_maintenance/json_shapes.dart';
part 'database_maintenance/repair_contract.dart';
part 'database_maintenance/repair_store.dart';
part 'database_maintenance/repair_target_store.dart';

/// Explicit local maintenance only. No polling, opening, migration or lifecycle
/// replacement. The app supplies an already-open original database, own Astoria
/// session and a synchronous native-operation ownership checkpoint.
final class DatabaseMaintenanceRepo {
  DatabaseMaintenanceRepo(AppDatabase db, SupportRepo support)
    : _db = db,
      _support = support {
    if (!support.usesDatabase(db)) throw ArgumentError('Different database.');
    _repairs = _MaintenanceRepairStore(this);
  }
  final AppDatabase _db;
  final SupportRepo _support;
  late final _MaintenanceRepairStore _repairs;

  /// Uses executor reads directly: unlike Drift queries this never invokes the
  /// migration/open hook. A closed/unavailable executor is reported unknown.
  /// Must be called outside a caller-owned transaction, as must prepare/apply/undo.
  Future<DatabaseMaintenanceHealth> inspect({
    required bool Function() isCurrent,
    DatabaseMaintenancePhysicalCheck physical =
        DatabaseMaintenancePhysicalCheck.quick,
    int rowsPerTable = 256,
  }) => _MaintenanceHealthReader(_db, isCurrent, rowsPerTable, physical).read();

  /// Null = ineligible/stale/conflict, never authorization. No journal is written
  /// by preview. Identity binds this exact repo, target, raw guards and ORIGINAL
  /// operation; native confirmation of the returned preview is an app-layer job.
  Future<DatabaseMaintenancePlan?> prepare({
    required DatabaseMaintenanceTarget target,
    required String operationId,
    required String supportSessionId,
    required int createdAt,
    required bool Function() isCurrent,
  }) => _repairs.prepare(
    target,
    operationId,
    supportSessionId,
    createdAt,
    isCurrent,
  );

  /// Only the opaque original plan is accepted; decoded DTOs cannot execute.
  /// Fresh native confirmation is the caller's responsibility. The extra guard
  /// cannot replace or resurrect the original operation's checkpoint.
  Future<DatabaseMaintenanceReceipt?> apply({
    required DatabaseMaintenancePlan plan,
    required bool Function() isCurrent,
  }) => _repairs.apply(plan, isCurrent);

  /// Original encrypted journal custody only; no auto-replay/restored approval.
  /// Exact narrow after-state and dependencies must still match.
  Future<DatabaseMaintenanceReceipt?> undo({
    required DatabaseMaintenanceReceipt receipt,
    required bool Function() isCurrent,
  }) => _repairs.undo(receipt, isCurrent);
}

final class _MaintenanceRefused implements Exception {
  const _MaintenanceRefused();
}

void _maintenanceRequire(bool condition) {
  if (!condition) throw const _MaintenanceRefused();
}

// Names originate ONLY from registration or finite owner SQL below, never from
// row values, SQLite error strings or caller-provided table/column identifiers.
String _maintenanceIdentifier(String trusted) {
  if (!RegExp(r'^[A-Za-z_][A-Za-z0-9_]{0,127}$').hasMatch(trusted)) {
    throw const _MaintenanceRefused();
  }
  return '"$trusted"';
}
