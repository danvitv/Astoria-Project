import 'dart:convert';

import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../../../core/db/repositories/persona_repo.dart';
import '../../../../../core/db/repositories/preset_repo.dart';
import '../../../../../core/db/repositories/support_repo.dart';
import '../../../../../core/models/support_models.dart';
import '../../../../../core/state/native_active_selection_port.dart';
import '../../../models/support_app_action.dart';
import '../support_app_repair_runtime.dart';
import 'support_native_domain_sources.dart';

part 'support_native_active_selection_execution.dart';
part 'support_native_active_selection_retention.dart';

/// Exact original ordinary-selection owners. No raw-preferences setter, binding,
/// Studio namespace, controller bootstrap, restored JSON replay or body read.
final class SupportNativeActiveSelectionAdapter
    implements SupportAppActionAdapter {
  SupportNativeActiveSelectionAdapter({required this.support,
    required this.personas, required this.presets, required this.chats,
    required this.sources, required this.ports});
  final SupportRepo support;
  final PersonaRepo personas;
  final PresetRepo presets;
  final ChatRepo chats;
  final SupportNativeDomainSources sources;
  final Map<NativeActiveSelectionKind, NativeActiveSelectionPort> ports;
  final _receipts = <String, _RetainedSelection>{};
  bool _disposed = false;
  bool get _current => !_disposed && sources.isOriginalOwnerCurrent() &&
      sources.owners.isCurrent && !sources.mutations.isDisposed;
  void dispose() { _disposed = true; _receipts.clear(); }

  /// The wrapper must use this EXACT observation, never take a second inventory.
  SupportNativeDomainObservation? collateralFor(Object observation) =>
      observation is _SelectionPlan ? observation.collateral : null;

  bool Function()? _targetLifetime(NativeActiveSelectionKind kind, String? id) =>
      id == null || id.isEmpty ? () => true :
      kind == NativeActiveSelectionKind.persona
          ? personas.captureNativeSelectionTarget(id)
          : presets.captureNativeSelectionTarget(id);

  @override
  List<SupportAppActionDefinition> get definitions => [
    for (final kind in NativeActiveSelectionKind.values)
      SupportAppActionDefinition(
        name: kind == NativeActiveSelectionKind.persona
            ? 'astoria_active_persona_set' : 'astoria_active_preset_set',
        description: 'Select an exactly existing ordinary ${kind.name} ID, or '
            'clear only its global selection. Native confirmation precedes '
            'original ROOT/source retirement and acknowledged single-key CAS. '
            'Does not change per-chat bindings, Studio, API or embedding choices.',
        risk: SupportAppActionRisk.configuration,
        fields: {'operation': SupportAppActionField.choice(['select', 'clear']),
          'id': const SupportAppActionField.text(128,
              pattern: r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$')},
        requiredFields: {'operation'},
      ),
    SupportAppActionDefinition(name: 'astoria_active_selection_receipts',
      description: 'List genuine retained original ordinary-selection receipts '
          'in this Astoria parent. Receipt JSON or saved state never grants Undo.',
      risk: SupportAppActionRisk.metadata,
      fields: {'offset': const SupportAppActionField.integer(0, 63)}),
    SupportAppActionDefinition(name: 'astoria_active_selection_undo',
      description: 'Conditionally restore one genuine retained ordinary-selection '
          'receipt after fresh exact native confirmation. Requires the original '
          'store, controller and all-affected-session source owners unchanged.',
      risk: SupportAppActionRisk.configuration,
      fields: {'receipt': const SupportAppActionField.text(64,
          pattern: r'^repair-[a-f0-9]{32}$')}, requiredFields: {'receipt'}),
  ];

  Future<Object?> _row(NativeActiveSelectionKind kind, String? id) async {
    if (id == null || id.isEmpty) return null;
    // The ordinary preset repository is the ONLY preset resolution authority.
    return kind == NativeActiveSelectionKind.persona
        ? await personas.getById(id) : await presets.getById(id);
  }

  @override
  Future<SupportAppPreparedAction?> prepare(String action,
      Map<String, Object?> arguments, SupportAppActionContext context) async {
    if (!_current || !context.current || context.domainRoot == null) return null;
    if (action == 'astoria_active_selection_receipts') {
      return _list(arguments, context);
    }
    final undo = action == 'astoria_active_selection_undo';
    final retained = undo ? _receipts[arguments['receipt']] : null;
    final kind = switch (action) {
      'astoria_active_persona_set' => NativeActiveSelectionKind.persona,
      'astoria_active_preset_set' => NativeActiveSelectionKind.preset,
      'astoria_active_selection_undo' => retained?.receipt.owner.kind,
      _ => null,
    };
    if (kind == null) return null;
    final port = ports[kind];
    if (port == null || !port.current) return null;
    if (undo && (retained == null || retained.parent != context.sessionId ||
        !identical(retained.receipt.owner, port) || !retained.current)) return null;
    if (!undo && ((arguments['operation'] == 'select' && arguments['id'] == null) ||
        (arguments['operation'] == 'clear' && arguments.containsKey('id')))) {
      throw const SupportAppActionRefused(SupportAppActionCode.invalidArguments);
    }
    final next = undo ? retained!.receipt.before :
        arguments['operation'] == 'clear' ? null : arguments['id'] as String?;
    final observed = port.observe();
    if (observed == null) return null;
    // Capture target lifetimes BEFORE ANY read. They cannot be renewed by a
    // same-value SELECT, including a delete/reinsert before query delivery.
    final beforeTarget = undo ? retained!.targetsCurrent :
        _targetLifetime(kind, observed.value);
    final nextTarget = undo ? retained!.targetsCurrent : _targetLifetime(kind, next);
    if (beforeTarget == null || nextTarget == null) return null;
    bool targetsCurrent() => beforeTarget() && nextTarget();
    bool originalCurrent() => _current && context.current && observed.current &&
        targetsCurrent() && (!undo || retained!.current);
    final inventory = undo ? retained!.inventory :
        await chats.observeNativeSelectionInventory(originalCurrent);
    if (inventory == null || !originalCurrent() || !inventory.current) return null;
    bool readCurrent() => originalCurrent() && inventory.current;
    if (undo) {
      final inventoryCurrent = await chats.revalidateNativeSelectionInventory(
          inventory, readCurrent);
      if (!inventoryCurrent || !readCurrent()) return null;
    }
    final collateral = sources.observe(inventory.sessions,
        collateralIsCurrent: () => inventory.current);
    if (collateral == null || !readCurrent()) return null;
    final desiredRow = await _row(kind, next);
    if (!readCurrent() || (next != null && next.isNotEmpty && desiredRow == null)) {
      return null;
    }
    SupportMutationReservation? journal;
    if (undo) {
      journal = await support.readCurrentMutation(id: retained!.journal.record.id,
          sessionId: context.sessionId, domain: 'activeSelection',
          targetId: kind.key, isCurrent: readCurrent);
      if (!readCurrent() || journal == null ||
          !support.sameMutationHistoryObservation(retained.journal, journal)) return null;
    }
    final plan = _SelectionPlan(port, observed, next, desiredRow,
        inventory, collateral, targetsCurrent,
        undo ? arguments['receipt'] as String : kind.key, retained, journal);
    return SupportAppPreparedAction(target: plan.target, observation: plan,
      observationIsCurrent: readCurrent,
      preview: {'operation': undo ? 'conditionalSelectionUndo' : 'setActiveSelection',
        'selectionDomain': kind.name, 'before': _selection(observed.value),
        'after': _selection(next), 'affectedPreferenceKeys': 1,
        'ordinaryOnly': true, 'bindingsUnchanged': true,
        'sourceAuthorityRetirement': true, 'conditional': true,
        'bodyAccess': 'notGranted'},
      execute: (admitted) => _execute(plan, context, admitted));
  }

  SupportAppPreparedAction _list(Map<String, Object?> arguments,
      SupportAppActionContext context) {
    final ids = _receipts.entries.where((e) =>
        e.value.parent == context.sessionId && e.value.current)
        .map((e) => e.key).toList();
    final offset = arguments['offset'] as int? ?? 0;
    bool current() => _current && context.current;
    return SupportAppPreparedAction(target: 'native-retained-selection-receipts',
      observation: Object(), observationIsCurrent: current,
      execute: (admitted) async => SupportAppActionOutcome(
        admitted() && current() ? SupportAppActionCode.completed : SupportAppActionCode.stale,
        data: admitted() && current() ? {'records': [
          for (final id in ids.skip(offset).take(16))
            {'receipt': id, 'selectionDomain': _receipts[id]!.receipt.owner.kind.name,
              'conditional': true},
        ], 'count': ids.length, 'nextOffset': offset + 16 < ids.length ? offset + 16 : null}
            : const {}));
  }

  static Map<String, Object?> _selection(String? value) => {
    'kind': value == null ? 'absent' : value.isEmpty ? 'empty' : 'selected',
    if (value != null) 'id': value,
  };
}
