import '../../../../../core/db/repositories/extension_presets_repository.dart';
import '../../../../extensions/providers/extension_presets_provider.dart';
import '../../../models/support_app_action.dart';

/// Registry metadata and exact native deactivation, not a JavaScript runner.
/// Model handles are run-local aliases, never user-authored DB/block IDs.
final class SupportAppExtensionControlsAdapter
    implements SupportAppActionAdapter {
  SupportAppExtensionControlsAdapter({
    required this.repo,
    required this.notifier,
  });
  final ExtensionPresetsRepository repo;
  final ExtensionPresetsNotifier notifier;
  SupportAppActionContext? _owner;
  int _sequence = 0;
  final _presets = <String, ExtensionControlObservation>{};
  final _blocks =
      <String, (ExtensionControlObservation, ExtensionBlockControl)>{};

  static const _handle = SupportAppActionField.text(
    64,
    pattern: r'^secondary-(preset|block)-[0-9]+$',
  );
  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_extension_controls_read',
      description:
          'Read bounded opaque extension registry handles and counts; '
          'supply a returned preset handle to inspect finite block controls.',
      risk: SupportAppActionRisk.metadata,
      fields: {'presetHandle': _handle},
    ),
    SupportAppActionDefinition(
      name: 'astoria_extension_block_disable',
      description:
          'Disable one observed extension block after exact native '
          'confirmation and latest-row CAS. Never run or enable scripts.',
      risk: SupportAppActionRisk.configuration,
      fields: {'blockHandle': _handle},
      requiredFields: {'blockHandle'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    final definition = definitions.where((d) => d.name == action).firstOrNull;
    if (definition == null || !context.current) return null;
    if (!definition.accepts(arguments)) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    if (!identical(_owner, context)) {
      _owner = context;
      _presets.clear();
      _blocks.clear();
    }
    bool current() => identical(_owner, context) && context.current;
    if (action == 'astoria_extension_controls_read') {
      final handle = arguments['presetHandle'] as String?;
      if (handle == null) {
        final rows = await repo.inspectControls();
        if (!current()) return null;
        _presets.clear();
        _blocks.clear();
        final items = <Map<String, Object?>>[];
        for (final row in rows.take(32)) {
          final key = 'secondary-preset-${++_sequence}';
          _presets[key] = row;
          final blocks = row.blocks;
          items.add({
            'handle': key,
            'controlsAvailable': blocks != null,
            'blockCount': blocks?.length,
            'enabledCount': blocks?.where((b) => b.enabled).length,
            'scriptCount': blocks?.where((b) => b.kind == 'script').length,
          });
        }
        return _read(context, rows, {
          'items': items,
          'hasMore': rows.length > 32,
        });
      }
      final observed = _presets[handle];
      if (observed == null) {
        throw const SupportAppActionRefused(SupportAppActionCode.unavailable);
      }
      final latest = await repo.inspectControl(observed.nativeId);
      if (!current()) return null;
      if (latest == null || !observed.sameState(latest)) {
        throw const SupportAppActionRefused(SupportAppActionCode.conflict);
      }
      final controls = latest.blocks;
      if (controls == null) return null;
      _blocks.clear();
      final items = <Map<String, Object?>>[];
      for (final block in controls.take(32)) {
        final key = 'secondary-block-${++_sequence}';
        _blocks[key] = (latest, block);
        items.add({
          'handle': key,
          'kind': block.kind,
          'enabled': block.enabled,
        });
      }
      return _read(context, latest, {
        'items': items,
        'blockCount': controls.length,
        'hasMore': controls.length > 32,
      });
    }
    // The shared terminal ROOT port currently accepts connection plans only.
    // Never write this domain inside a held read-only model ROOT or substitute
    // an unbound callback. Native standalone confirmation remains supported.
    if (context.terminalRoot != null && context.domainRoot == null) return null;
    final handle = arguments['blockHandle'] as String;
    final selected = _blocks[handle];
    if (selected == null) return null;
    final (observed, block) = selected;
    if (block.kind == 'unknown') return null;
    final latest = await repo.inspectControl(observed.nativeId);
    if (!current()) return null;
    if (latest == null || !observed.sameState(latest)) {
      throw const SupportAppActionRefused(SupportAppActionCode.conflict);
    }
    return SupportAppPreparedAction(
      target: handle,
      observation: latest,
      observationIsCurrent: () =>
          current() && identical(_blocks[handle], selected),
      preview: {
        'blockHandle': handle,
        'kind': block.kind,
        'enabledBefore': block.enabled,
        'enabledAfter': false,
        'affectedBlocks': 1,
        'executesCode': false,
        'networkRequests': 0,
        'doesNotCancelRunningJobs': true,
        'doesNotEraseStoredOutput': true,
        'nextChainMayChange': true,
      },
      execute: (admitted) async {
        final result = await repo.disableControlBlock(
          expected: latest,
          blockId: block.nativeId,
          isCurrent: admitted,
        );
        final effect = result == ExtensionControlMutation.persisted
            ? SupportAppActionEffect.persisted
            : SupportAppActionEffect.none;
        if (effect == SupportAppActionEffect.persisted &&
            admitted() &&
            notifier.mounted) {
          try {
            // The original existing owner re-reads durable state; no full-row
            // optimistic model snapshot is installed in its runtime registry.
            await notifier.refresh();
          } catch (_) {
            return SupportAppActionOutcome(
              SupportAppActionCode.completed,
              effect: effect,
              data: const {'refreshPending': true},
            );
          }
        }
        return SupportAppActionOutcome(
          switch (result) {
            ExtensionControlMutation.persisted =>
              SupportAppActionCode.completed,
            ExtensionControlMutation.noChange => SupportAppActionCode.noChange,
            ExtensionControlMutation.conflict => SupportAppActionCode.conflict,
            ExtensionControlMutation.stale => SupportAppActionCode.stale,
          },
          effect: effect,
          data:
              effect == SupportAppActionEffect.persisted ||
                  result == ExtensionControlMutation.noChange
              ? {'blockHandle': handle, 'enabled': false}
              : const {},
        );
      },
    );
  }

  SupportAppPreparedAction _read(
    SupportAppActionContext context,
    Object observation,
    Map<String, Object?> data,
  ) => SupportAppPreparedAction(
    target: 'secondary-extension-registry',
    observation: observation,
    observationIsCurrent: () => identical(_owner, context) && context.current,
    execute: (current) async => SupportAppActionOutcome(
      current() ? SupportAppActionCode.completed : SupportAppActionCode.stale,
      data: current() ? data : const {},
    ),
  );
}
