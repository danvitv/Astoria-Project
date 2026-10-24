import '../../../../../core/db/repositories/studio_preset_repo.dart';
import '../../../models/support_app_action.dart';
import 'support_content_mutation.dart';

enum SupportStudioRuntimeLane { cleaner, ledger }

final class SupportStudioRuntimeControlAdapter
    implements SupportAppActionAdapter {
  const SupportStudioRuntimeControlAdapter({
    required this.repo,
    required this.mutations,
    required this.clock,
    required this.refresh,
  });
  final StudioPresetRepo repo;
  final SupportContentMutation mutations;
  final int Function() clock;
  final void Function() refresh;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_studio_runtime_manage',
      description:
          'Patch supplied safe runtime scalars in an already configured Studio cleaner/ledger lane for the next turn; no prompts, endpoints, keys or live generation.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'id': SupportContentArguments.id,
        'lane': SupportAppActionField.choice(
          SupportStudioRuntimeLane.values.map((l) => l.name),
        ),
        'temperature': const SupportAppActionField.number(0, 2),
        'maxTokens': const SupportAppActionField.integer(0, 1000000),
        'historyMessages': const SupportAppActionField.integer(0, 200),
        'enabled': const SupportAppActionField.boolean(),
        'interval': const SupportAppActionField.integer(1, 1000),
      },
      requiredFields: {'id', 'lane'},
    ),
  ];

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> a,
    SupportAppActionContext context,
  ) async {
    if (action != definitions.single.name) return null;
    SupportContentArguments.validate(definitions.single, a);
    if (!context.current) return null;
    final cleaner = a['lane'] == SupportStudioRuntimeLane.cleaner.name;
    SupportContentArguments.shape(
      a,
      cleaner
          ? {
              'id',
              'lane',
              'temperature',
              'maxTokens',
              'historyMessages',
              'enabled',
            }
          : {'id', 'lane', 'temperature', 'maxTokens', 'interval'},
      {'id', 'lane'},
    );
    if (a.length < 3)
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    final before = await repo.getById(a['id']! as String);
    if (!context.current || before == null) return null;
    if (cleaner
        ? before.runtime.cleaner == null
        : before.runtime.ledger == null) {
      throw const SupportAppActionRefused(SupportAppActionCode.unavailable);
    }
    return mutations.prepare(
      domain: SupportContentDomain.studioPreset,
      target: before.id,
      observation: before,
      context: context,
      preview: {'lane': a['lane'], 'nextTurnOnly': true},
      persist: (current) => repo.controlRuntime(
        expected: before,
        cleaner: cleaner,
        temperature: (a['temperature'] as num?)?.toDouble(),
        maxTokens: a['maxTokens'] as int?,
        historyMessages: a['historyMessages'] as int?,
        enabled: a['enabled'] as bool?,
        interval: a['interval'] as int?,
        timestamp: clock(),
        current: current,
      ),
      refresh: refresh,
    );
  }
}
