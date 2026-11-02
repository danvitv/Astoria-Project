import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../../../core/db/repositories/support_repo.dart';
import '../../../../../core/models/support_models.dart';
import '../../../../../core/state/native_global_regex_port.dart';
import '../../../models/support_app_action.dart';
import '../support_app_repair_runtime.dart';
import 'support_native_domain_sources.dart';

part 'support_native_global_regex_execution.dart';
part 'support_native_global_regex_discovery.dart';
part 'support_native_global_regex_retention.dart';

/// One existing GLOBAL script disable and genuine original retained Undo.
/// No Studio, enable/import/create/delete, pattern execution or JSON authority.
final class SupportNativeGlobalRegexAdapter implements SupportAppActionAdapter {
  SupportNativeGlobalRegexAdapter({
    required this.support,
    required this.chats,
    required this.sources,
    required this.port,
    required this.metadata,
  });
  final SupportRepo support;
  final ChatRepo chats;
  final SupportNativeDomainSources sources;
  final NativeGlobalRegexPort? port;
  final SupportAppMetadataPolicy metadata;
  final _receipts = <String, _RetainedGlobalRegex>{};
  bool _disposed = false;
  bool get _current =>
      !_disposed &&
      sources.isOriginalOwnerCurrent() &&
      sources.owners.isCurrent &&
      !sources.mutations.isDisposed;
  void dispose() {
    _disposed = true;
    _receipts.clear();
  }

  SupportNativeDomainObservation? collateralFor(Object observation) =>
      observation is _GlobalRegexPlan ? observation.collateral : null;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_global_regex_scripts_list',
      description:
          'Read at most the first 32 already-loaded original GLOBAL scripts: '
          'exact safe existing id, optional safe name and disabled state only. '
          'Reports total, inspected, returned, omitted and unlisted counts. '
          'Unsafe fields are omitted whole, never clipped or masked. No patterns, '
          'replacements, bodies, raw JSON or preference reads. Unavailable until '
          'the original same-origin owner is loaded. IDs are not grants: disable '
          'still needs its separate exact native confirmation and original CAS. '
          'Not a Source4 source grant; discovery never mutates or retires sources.',
      risk: SupportAppActionRisk.metadata,
    ),
    SupportAppActionDefinition(
      name: 'astoria_global_regex_disable',
      description:
          'Disable exactly one existing unique GLOBAL regex ID in an '
          'already-loaded original controller. Native confirmation shows exact '
          'before/after disabled states before ROOT/source retirement and original '
          'plugin CAS. The complete saved JSON document is bounded to 8192 bytes '
          'for encrypted private evidence. Content and unknown fields stay inert '
          'and unchanged. Never touches Studio, imports, enables or executes regex.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'id': const SupportAppActionField.text(
          128,
          pattern: r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$',
        ),
      },
      requiredFields: {'id'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_global_regex_receipts',
      description:
          'List genuine retained original global-regex receipts in this '
          'Astoria parent, without pattern, replacement, script or private JSON. '
          'Saved/imported receipt JSON never grants Undo.',
      risk: SupportAppActionRisk.metadata,
      fields: {'offset': const SupportAppActionField.integer(0, 63)},
    ),
    SupportAppActionDefinition(
      name: 'astoria_global_regex_undo',
      description:
          'Conditionally Undo one genuine retained global-regex disable '
          'after fresh exact native confirmation. Requires the original store, '
          'controller, raw document and all-session source inventory unchanged. '
          'Restores only the original exact raw JSON; never imports or enables '
          'an arbitrary script.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'receipt': const SupportAppActionField.text(
          64,
          pattern: r'^repair-[a-f0-9]{32}$',
        ),
      },
      requiredFields: {'receipt'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (!_current || !context.current || context.domainRoot == null)
      return null;
    if (action == 'astoria_global_regex_scripts_list')
      return _scripts(context);
    if (action == 'astoria_global_regex_receipts')
      return _list(arguments, context);
    final undo = action == 'astoria_global_regex_undo';
    if (!undo && action != 'astoria_global_regex_disable') return null;
    final original = port;
    if (original == null || !original.current) return null;
    final retained = undo ? _receipts[arguments['receipt']] : null;
    if (undo &&
        (retained == null ||
            retained.parent != context.sessionId ||
            !identical(retained.receipt.owner, original) ||
            !retained.current))
      return null;
    final id = undo ? retained!.receipt.id : arguments['id'] as String;
    final observed = original.observe(id);
    if (observed == null ||
        (undo && observed.raw != retained!.receipt.afterRaw))
      return null;
    final next = undo ? retained!.receipt.beforeRaw : observed.disabledRaw;
    String beforeEvidence, afterEvidence;
    try {
      // Full private raw JSON is encrypted ONLY in the native journal. Its exact
      // bytes also remain in genuine in-memory custody, never tool output/preview.
      beforeEvidence = SupportMutationEvidence.encode(observed.raw);
      afterEvidence = SupportMutationEvidence.encode(next);
    } catch (_) {
      return null;
    }
    bool originalCurrent() =>
        _current &&
        context.current &&
        observed.current &&
        (!undo || retained!.current);
    final inventory = undo
        ? retained!.inventory
        : await chats.observeNativeSelectionInventory(originalCurrent);
    if (inventory == null || !originalCurrent() || !inventory.current)
      return null;
    bool readCurrent() => originalCurrent() && inventory.current;
    if (undo) {
      final valid = await chats.revalidateNativeSelectionInventory(
        inventory,
        readCurrent,
      );
      if (!valid || !readCurrent()) return null;
    }
    final collateral = sources.observe(
      inventory.sessions,
      collateralIsCurrent: () => inventory.current,
    );
    if (collateral == null || !readCurrent()) return null;
    SupportMutationReservation? journal;
    if (undo) {
      journal = await support.readCurrentMutation(
        id: retained!.journal.record.id,
        sessionId: context.sessionId,
        domain: 'globalRegex',
        targetId: id,
        isCurrent: readCurrent,
      );
      if (!readCurrent() ||
          journal == null ||
          !support.sameMutationHistoryObservation(retained.journal, journal))
        return null;
    }
    final plan = _GlobalRegexPlan(
      original,
      observed,
      inventory,
      collateral,
      undo ? arguments['receipt'] as String : id,
      retained,
      journal,
      beforeEvidence,
      afterEvidence,
    );
    final afterDisabled = undo
        ? retained!.receipt.beforeScripts[observed.index].disabled
        : true;
    return SupportAppPreparedAction(
      target: plan.target,
      observation: plan,
      observationIsCurrent: readCurrent,
      preview: {
        'operation': undo ? 'conditionalGlobalRegexUndo' : 'disableGlobalRegex',
        'regexDomain': 'global',
        'id': id,
        'before': {'disabled': observed.disabled},
        'after': {'disabled': afterDisabled},
        'affectedScripts': 1,
        'affectedPreferenceKeys': 1,
        'preservesRawJsonAndUnknownFields': true,
        'contentExecuted': false,
        'sourceAuthorityRetirement': true,
        'conditional': true,
        'bodyAccess': 'notGranted',
      },
      execute: (admitted) => _execute(plan, context, admitted),
    );
  }

  SupportAppPreparedAction _list(
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) {
    final ids = _receipts.entries
        .where((e) => e.value.parent == context.sessionId && e.value.current)
        .map((e) => e.key)
        .toList();
    final offset = arguments['offset'] as int? ?? 0;
    bool current() => _current && context.current;
    return SupportAppPreparedAction(
      target: 'native-retained-global-regex-receipts',
      observation: Object(),
      observationIsCurrent: current,
      execute: (admitted) async {
        if (!admitted() || !current())
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        return SupportAppActionOutcome(
          SupportAppActionCode.completed,
          data: {
            'records': [
              for (final id in ids.skip(offset).take(16))
                if (_receipts[id]?.current == true)
                  {'receipt': id, 'regexDomain': 'global', 'conditional': true},
            ],
            'count': ids.length,
            'nextOffset': offset + 16 < ids.length ? offset + 16 : null,
          },
        );
      },
    );
  }
}
