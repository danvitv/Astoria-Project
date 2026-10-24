import '../../../../core/db/models/session_repair.dart';
import '../../../../core/db/repositories/session_repair_repo.dart';
import '../../models/support_app_action.dart';
import 'support_app_repair_runtime.dart';

final class _RepairSession {
  const _RepairSession(this.id);
  final String id;
}

final class _RepairRecord {
  const _RepairRecord(this.session, this.target, this.checkpoint);
  final String session;
  final SessionRepairTarget target;
  final Object checkpoint;
}

final class _RepairReceipt {
  const _RepairReceipt(this.session, this.receipt, this.kind);
  final String session;
  final SessionRepairReceipt receipt;
  final SessionRepairTargetKind kind;
}

/// Metadata-only inspection and native exact single-record repair/Undo. No
/// message, tracker name/value, claim, stored digest or raw error is returned.
final class SupportAppSessionRepairAdapter implements SupportAppActionAdapter {
  SupportAppSessionRepairAdapter({
    required this.repo,
    required this.runtime,
    required this.now,
  });
  final SessionRepairRepo repo;
  final SupportAppRepairRuntime runtime;
  final int Function() now;
  final _sessions = SupportAppRepairCustody<_RepairSession>();
  final _targets = SupportAppRepairCustody<_RepairRecord>();
  final _receipts = SupportAppRepairCustody<_RepairReceipt>();
  static const _handle = SupportAppActionField.text(
    64,
    pattern: r'^repair-[a-f0-9]{32}$',
  );

  /// Native discovery hook. Actual owner must bind the selected session; model
  /// input cannot create a session binding or infer private body permission.
  String bindSession(
    String targetSessionId,
    SupportAppActionContext original,
  ) => _sessions.retain(_RepairSession(targetSessionId), original);
  void dispose() {
    _sessions.clear();
    _targets.clear();
    _receipts.clear();
  }

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_session_integrity',
      description:
          'Inspect selected session structure or actual recorded hashes; never narrative truth.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'session': _handle,
        'operation': SupportAppActionField.choice([
          'inspect',
          'recordedHashes',
        ]),
        'offset': const SupportAppActionField.integer(0, 63),
      },
      requiredFields: {'session', 'operation'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_session_repair',
      description:
          'Delete one proven-unused failed Collector attempt or correct one existing world/scene Ledger value with exact native confirmation.',
      risk: SupportAppActionRisk.destructive,
      fields: {
        'target': _handle,
        'operation': SupportAppActionField.choice([
          'deleteUnusedCollector',
          'correctLedger',
        ]),
        'value': const SupportAppActionField.text(256),
      },
      requiredFields: {'target', 'operation'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_session_repair_undo',
      description:
          'Conditionally restore the original retained repair receipt after fresh exact native confirmation.',
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
    if (!runtime.current || !context.current) return null;
    if (action == 'astoria_session_integrity') {
      final session = _sessions.read(arguments['session']! as String, context);
      if (session == null) return null;
      final checkpoint = runtime.checkpoint(session.id);
      if (checkpoint == null) return null;
      bool current() => runtime.current && context.current;
      // ONLY the private target/plan retains admitted original native custody.
      // Outward metadata reads keep their unchanged requester/read guards.
      bool targetCurrent() =>
          runtime.current &&
          (runtime.ownsAdmittedEffect(session.id, context) || context.current);
      return SupportAppPreparedAction(
        target: arguments['session']! as String,
        observation: session,
        observationIsCurrent: () =>
            current() && runtime.unchanged(session.id, checkpoint),
        execute: (admitted) async {
          bool readCurrent() =>
              current() &&
              admitted() &&
              runtime.unchanged(session.id, checkpoint);
          if (arguments['operation'] == 'recordedHashes') {
            final report = await repo.inspectRecordedHashes(
              targetSessionId: session.id,
              supportSessionId: context.sessionId,
              isCurrent: readCurrent,
            );
            if (!readCurrent()) return _refused();
            return SupportAppActionOutcome(
              SupportAppActionCode.completed,
              data: report.toMetadata(),
            );
          }
          // The original opaque target retains original context/owner, not a
          // replaceable callback. Raw CAS and gateway admission fence source.
          final report = await repo.inspect(
            targetSessionId: session.id,
            supportSessionId: context.sessionId,
            isCurrent: targetCurrent,
          );
          if (!readCurrent()) return _refused();
          final records = <Map<String, Object?>>[];
          final offset = arguments['offset'] as int? ?? 0;
          for (final target in report.targets.skip(offset).take(16)) {
            final id = _targets.retain(
              _RepairRecord(session.id, target, checkpoint),
              context,
            );
            records.add({
              'id': id,
              'kind': target.kind.name,
              'issues': target.issues.map((i) => i.name).toSet().toList(),
              'availability': target.availability.name,
            });
          }
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            data: {
              'complete': report.complete,
              'count': report.targets.length,
              'offset': offset,
              'nextOffset': offset + records.length < report.targets.length
                  ? offset + records.length
                  : null,
              'truncated': !report.complete,
              'issues': report.issues.map((i) => i.name).toSet().toList(),
              'records': records,
              'narrativeTruth': 'notChecked',
              'bodyAccess': 'notGranted',
            },
          );
        },
      );
    }
    if (action == 'astoria_session_repair_undo') {
      final id = arguments['receipt']! as String;
      final saved = _receipts.readForUndo(id, context);
      if (saved == null) return null;
      if (runtime.needsQueueOwnerPreparation(saved.session) &&
          (!await runtime.prepareQueueOwner(saved.session, context) ||
              !context.current))
        return null;
      final checkpoint = runtime.checkpoint(saved.session);
      if (checkpoint == null) return null;
      final authority = SupportAppRepairAuthority(
        runtime,
        saved.session,
        context,
        checkpoint,
      );
      return SupportAppPreparedAction(
        target: id,
        observation: saved.receipt,
        observationIsCurrent: () =>
            context.current &&
            runtime.unchanged(saved.session, checkpoint) &&
            identical(_receipts.readForUndo(id, context), saved),
        preview: _preview(saved.kind, undo: true),
        execute: (admitted) => _effect(
          authority,
          context,
          admitted,
          (current) => repo.undo(receipt: saved.receipt, isCurrent: current),
          saved.kind,
          consumedReceipt: id,
        ),
      );
    }
    if (action != 'astoria_session_repair') return null;
    final operation = arguments['operation'];
    if ((operation == 'correctLedger') != arguments.containsKey('value')) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    final selected = _targets.read(arguments['target']! as String, context);
    if (selected == null) return null;
    final authority = SupportAppRepairAuthority(
      runtime,
      selected.session,
      context,
      selected.checkpoint,
    );
    final scope = authority.begin();
    if (scope == null) return null;
    SessionRepairPreparation? prepared;
    try {
      prepared = await scope.run(
        () => operation == 'correctLedger'
            ? repo.prepareCorrectExistingLedgerValue(
                target: selected.target,
                value: arguments['value']! as String,
                operationId: supportRepairOpaqueId('repair-op'),
                createdAt: now(),
                isCurrent: () => authority.current,
              )
            : repo.prepareDeleteUnusedCollectorAttempt(
                target: selected.target,
                operationId: supportRepairOpaqueId('repair-op'),
                createdAt: now(),
                isCurrent: () => authority.current,
              ),
      );
      if (!scope.current) return null;
    } finally {
      scope.close();
    }
    final plan = prepared?.plan;
    if (plan == null) {
      final issue = prepared?.issue;
      return SupportAppPreparedAction(
        target: arguments['target']! as String,
        observation: selected.target,
        observationIsCurrent: () => context.current,
        execute: (_) async => SupportAppActionOutcome(
          SupportAppActionCode.unavailable,
          data: {
            'issues': [if (issue != null) issue.name],
          },
        ),
      );
    }
    final checkpoint = runtime.checkpoint(selected.session);
    if (checkpoint == null) return null;
    return SupportAppPreparedAction(
      target: arguments['target']! as String,
      observation: plan,
      observationIsCurrent: () =>
          authority.current && runtime.unchanged(selected.session, checkpoint),
      preview: _preview(plan.kind),
      execute: (admitted) => _effect(
        authority,
        context,
        admitted,
        (current) => repo.apply(plan: plan, isCurrent: current),
        plan.kind,
      ),
    );
  }

  Future<SupportAppActionOutcome> _effect(
    SupportAppRepairAuthority authority,
    SupportAppActionContext context,
    bool Function() admitted,
    Future<SessionRepairReceipt?> Function(bool Function()) write,
    SessionRepairTargetKind kind, {
    String? consumedReceipt,
  }) async {
    if (!admitted()) return _refused();
    final scope = authority.begin();
    if (scope == null) return _refused();
    try {
      final receipt = await scope.run(
        () => write(() => authority.current && scope.current && admitted()),
      );
      if (receipt == null) return _refused();
      if (consumedReceipt != null) _receipts.remove(consumedReceipt);
      final conflict = receipt.outcome == SessionRepairOutcome.undoConflict;
      var refreshed = false;
      if (!conflict) {
        try {
          refreshed = scope.invalidateDurable();
        } catch (_) {
          /* Keep fact. */
        }
      }
      final handle = receipt.outcome == SessionRepairOutcome.applied
          ? _receipts.retain(
              _RepairReceipt(authority.session, receipt, kind),
              context,
            )
          : null;
      return SupportAppActionOutcome(
        conflict
            ? SupportAppActionCode.conflict
            : SupportAppActionCode.completed,
        effect: SupportAppActionEffect.persisted,
        data: {
          'outcome': receipt.outcome.name,
          'affectedRecords': receipt.affectedRecords,
          'refreshPending': !conflict && !refreshed,
          if (handle != null) 'receipt': handle,
        },
      );
    } on SessionRepairStorageException {
      return SupportAppActionOutcome(
        SupportAppActionCode.storageUncertain,
        effect: SupportAppActionEffect.uncertain,
      );
    } finally {
      scope.close();
    }
  }

  SupportAppActionOutcome _refused() =>
      SupportAppActionOutcome(SupportAppActionCode.conflict);
  Map<String, Object?> _preview(
    SessionRepairTargetKind kind, {
    bool undo = false,
  }) => {
    'operation': undo
        ? 'conditionalUndo'
        : kind == SessionRepairTargetKind.liveLedger
        ? 'correctExistingLedgerValue'
        : 'deleteUnusedCollectorAttempt',
    'affectedRecords': 1,
    'conditional': true,
    'manualRevisionBumps': kind == SessionRepairTargetKind.liveLedger ? 1 : 0,
    'preservesSnapshotsAndHistory': true,
    'aggregateSubtraction': false,
    'sourceAuthorityRetirement': true,
    'bodyAccess': 'notGranted',
  };
}
