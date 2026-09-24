import '../llm/studio_controller_ontology.dart';
import 'studio_config.dart';

/// The two mutually exclusive pre-generation controller sets. Existing
/// per-controller toggles are retained while the Think set is selected.
enum StudioPregenMode { normal, thinkReplacement }

StudioPregenMode studioPregenMode(StudioPreset preset) =>
    preset.agentEnabled['think'] == true
    ? StudioPregenMode.thinkReplacement
    : StudioPregenMode.normal;

StudioPreset applyStudioPregenMode(StudioPreset preset, StudioPregenMode mode) {
  final useThink = mode == StudioPregenMode.thinkReplacement;
  final enabled = Map<String, bool>.from(preset.agentEnabled)
    ..['think'] = useThink;
  var agents = preset.agents;
  if (useThink) {
    // Older presets predate the Think lane. Create it only when selected so
    // their ordinary controller settings are left intact for switching back.
    final hasThink = agents.any(
      (agent) => StudioControllerOntology.specForAgent(agent)?.id == 'think',
    );
    if (!hasThink) {
      final spec = StudioControllerOntology.specs.firstWhere(
        (spec) => spec.id == 'think',
      );
      agents = [
        ...agents,
        StudioAgent(
          id: 'agent_${preset.id}_think_${DateTime.now().millisecondsSinceEpoch}',
          controllerId: 'think',
          specId: 'think',
          name: spec.name,
          role: 'system',
          order: agents.isEmpty
              ? 0
              : agents
                        .map((agent) => agent.order)
                        .reduce((max, order) => order > max ? order : max) +
                    1,
          refreshPolicy: spec.refreshPolicy,
          reasoningMode: 'think-replacement',
        ),
      ];
    }
  }
  return preset.copyWith(
    agentEnabled: enabled,
    agents: [
      for (final agent in agents)
        if (StudioControllerOntology.specForAgent(agent)?.id == 'think')
          agent.copyWith(
            enabled: useThink,
            reasoningMode: 'think-replacement',
          )
        else
          agent,
    ],
  );
}
