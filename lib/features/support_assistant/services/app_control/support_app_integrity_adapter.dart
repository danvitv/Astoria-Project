import '../../../../core/db/models/database_maintenance.dart';
import '../../../../core/db/repositories/database_maintenance_repo.dart';
import '../../models/support_app_action.dart';
import 'support_app_repair_runtime.dart';

/// Whole registered database metadata + the THREE actual scalar owner repairs.
/// No SQL, schema installation, snapshot/reset or arbitrary row operation.
final class SupportAppIntegrityAdapter implements SupportAppActionAdapter {
  SupportAppIntegrityAdapter({
    required this.repo,
    required this.native,
    required this.isOriginalOwnerCurrent,
    required this.now,
  });
  final DatabaseMaintenanceRepo repo;
  final SupportAppRepairNativePort native;
  final bool Function() isOriginalOwnerCurrent;
  final int Function() now;
  final _targets = SupportAppRepairCustody<DatabaseMaintenanceTarget>();
  final _receipts = SupportAppRepairCustody<DatabaseMaintenanceReceipt>();
  static const _handle = SupportAppActionField.text(
    64,
    pattern: r'^repair-[a-f0-9]{32}$',
  );
  bool get current => native.isCurrent && isOriginalOwnerCurrent();

  /// Native discovery binds an ACTUAL typed target, never deserializes a plan or
  /// journal. Models may select its opaque ID only in the original parent/run.
  String bindTarget(
    DatabaseMaintenanceTarget target,
    SupportAppActionContext original,
  ) => _targets.retain(target, original);
  void dispose() {
    _targets.clear();
    _receipts.clear();
  }

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_database_health',
      description:
          'Inspect every registered DB table with bounded metadata; schema version is derived, not assumed. No universal recovery or healthy verdict.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'physical': SupportAppActionField.choice(['quick', 'integrity']),
        'rowsPerTable': const SupportAppActionField.integer(1, 1024),
        'offset': const SupportAppActionField.integer(0, 1024),
      },
    ),
    SupportAppActionDefinition(
      name: 'astoria_database_repair',
      description:
          'Apply one native-selected empty character group or dangling folder membership repair with exact confirmation and conditional Undo.',
      risk: SupportAppActionRisk.destructive,
      fields: {'target': _handle},
      requiredFields: {'target'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_database_repair_undo',
      description:
          'Conditionally restore one actual retained encrypted repair original after fresh exact native confirmation.',
      risk: SupportAppActionRisk.destructive,
      fields: {'receipt': _handle},
      requiredFields: {'receipt'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    // Native terminal custody admits only this original confirmed repair/Undo;
    // no fresh read, source or network authority survives requester retirement.
    bool original() =>
        current &&
        (context.current ||
            context.domainEffectForOperation(
              SupportAppDomainOperation.databaseRepair,
            ) ||
            context.domainEffectForOperation(
              SupportAppDomainOperation.databaseUndo,
            ));
    if (!original()) return null;
    if (action == 'astoria_database_health') {
      final observation = Object();
      return SupportAppPreparedAction(
        target: 'registered-database',
        observation: observation,
        observationIsCurrent: original,
        execute: (admitted) async {
          bool live() => original() && admitted();
          final report = await repo.inspect(
            isCurrent: live,
            physical: arguments['physical'] == 'integrity'
                ? DatabaseMaintenancePhysicalCheck.integrity
                : DatabaseMaintenancePhysicalCheck.quick,
            rowsPerTable: arguments['rowsPerTable'] as int? ?? 256,
          );
          if (!live()) {
            return SupportAppActionOutcome(SupportAppActionCode.stale);
          }
          final offset = arguments['offset'] as int? ?? 0;
          final tables = report.tables.skip(offset).take(16).toList();
          // Registry list <=32/depth <=4; the core's all61 report is deliberately
          // projected in pages, NOT truncated into an implicit all-table pass.
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            data: {
              'registeredTables': report.registeredTables,
              'expectedVersion': report.expectedVersion,
              'actualVersion': report.actualVersion,
              'physical': report.physical.name,
              'foreignKeysEnabled': report.foreignKeysEnabled,
              'foreignKeys': report.foreignKeys.name,
              'offset': offset,
              'nextOffset': offset + tables.length < report.tables.length
                  ? offset + tables.length
                  : null,
              'tables': tables.map((t) => t.toJson()).toList(),
              'issueCount': report.issues.length,
              'issues': report.issues.take(24).map((i) => i.toJson()).toList(),
              'truncated': report.truncated || report.issues.length > 24,
              'semanticValidation': 'notChecked',
              'unhashedStores': 'structural_notChecked',
              'snapshotConsistency': 'live_between_queries',
              'schemaDefinitionsAndTriggers': 'notChecked',
              'recovery': 'three_selected_scalar_repairs_not_universal',
            },
          );
        },
      );
    }
    if (action == 'astoria_database_repair_undo') {
      final handle = arguments['receipt']! as String;
      final receipt = _receipts.readForUndo(handle, context);
      if (receipt == null) return null;
      return SupportAppPreparedAction(
        target: handle,
        observation: receipt,
        observationIsCurrent: () =>
            original() &&
            identical(_receipts.readForUndo(handle, context), receipt),
        preview: _preview(receipt.kind, undo: true),
        execute: (admitted) => _effect(
          context,
          admitted,
          (live) => repo.undo(receipt: receipt, isCurrent: live),
          consumedReceipt: handle,
        ),
      );
    }
    if (action != 'astoria_database_repair') return null;
    final handle = arguments['target']! as String;
    final target = _targets.read(handle, context);
    if (target == null) return null;
    final plan = await repo.prepare(
      target: target,
      operationId: supportRepairOpaqueId('repair-op'),
      supportSessionId: context.sessionId,
      createdAt: now(),
      isCurrent: original,
    );
    if (!original() || plan == null) return null;
    return SupportAppPreparedAction(
      target: handle,
      observation: plan,
      observationIsCurrent: original,
      preview: _preview(plan.kind),
      execute: (admitted) => _effect(
        context,
        admitted,
        (live) => repo.apply(plan: plan, isCurrent: live),
      ),
    );
  }

  Future<SupportAppActionOutcome> _effect(
    SupportAppActionContext context,
    bool Function() admitted,
    Future<DatabaseMaintenanceReceipt?> Function(bool Function()) write, {
    String? consumedReceipt,
  }) async {
    var retired = false;
    bool live() {
      if (retired) return false;
      if (!current ||
          !(context.current ||
              context.domainEffectForOperation(
                SupportAppDomainOperation.databaseRepair,
              ) ||
              context.domainEffectForOperation(
                SupportAppDomainOperation.databaseUndo,
              )) ||
          !admitted()) {
        retired = true;
      }
      return !retired;
    }

    if (!live()) return SupportAppActionOutcome(SupportAppActionCode.stale);
    try {
      final receipt = await write(live);
      if (receipt == null) {
        return SupportAppActionOutcome(SupportAppActionCode.conflict);
      }
      // Do not erase actual commit when Stop lands during acknowledgement.
      if (consumedReceipt != null) _receipts.remove(consumedReceipt);
      final conflict =
          receipt.outcome == DatabaseMaintenanceMutationOutcome.undoConflict;
      var refreshed = false;
      if (!conflict && current) {
        try {
          refreshed = native.invalidateLatestDatabaseRepair();
        } catch (_) {
          /* The durable receipt remains factual. */
        }
      }
      final handle =
          receipt.outcome == DatabaseMaintenanceMutationOutcome.applied
          ? _receipts.retain(receipt, context)
          : null;
      return SupportAppActionOutcome(
        conflict
            ? SupportAppActionCode.conflict
            : SupportAppActionCode.completed,
        effect: SupportAppActionEffect.persisted,
        data: {
          'outcome': receipt.outcome.name,
          'affectedRows': conflict ? 0 : 1,
          'refreshPending': !conflict && !refreshed,
          'receipt': ?handle,
        },
      );
    } on DatabaseMaintenanceException {
      return SupportAppActionOutcome(
        SupportAppActionCode.storageUncertain,
        effect: SupportAppActionEffect.uncertain,
      );
    }
  }

  Map<String, Object?> _preview(
    DatabaseMaintenanceRepairKind kind, {
    bool undo = false,
  }) => {
    'operation': undo ? 'conditionalUndo' : kind.name,
    'affectedRows': 1,
    'conditional': true,
    'unexpectedCollateral': 'refused',
    'privateBodyAccess': 'notGranted',
    'schemaChanges': false,
    'wholeRowReplacement': false,
  };
}
