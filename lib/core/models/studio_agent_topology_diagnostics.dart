import '../llm/studio_activation_gate.dart';
import '../llm/studio_controller_ontology.dart';
import 'studio_config.dart';
import 'studio_preset_codec.dart';

/// Observes the saved codec result with the SAME phase splitter as Studio.
/// Declared ontology requirements are not a full execution/dependency validator.
/// No configuration changes, prompt execution, repository or model calls.
abstract final class StudioAgentTopologyDiagnostics {
  static const issueLimit = 32;

  static Map<String, Object?> inspect(
    StudioPresetDecodeResult decoded, {
    required List<Map<String, Object?>> savedAgents,
  }) {
    final preset = decoded.preset;
    final agents = preset.agents;
    final enabled = agents.where((a) => a.enabled).toList()
      ..sort((a, b) => a.order.compareTo(b.order));
    final split = StudioActivationGate.splitAgentsByPhase(enabled);
    final issues = <Map<String, Object?>>[];
    void note(String code, {int? agentIndex, String? requirement}) {
      issues.add({
        'code': code,
        'agentIndex': ?agentIndex,
        'requiredController': ?requirement,
      });
    }

    int? indexOf(StudioAgent agent) {
      final matches = agents.indexed.where((e) => identical(e.$2, agent));
      return matches.length == 1 ? matches.single.$1 : null;
    }

    final aligned = savedAgents.length == agents.length;
    if (!aligned) note('codec_agent_roster_changed');
    for (var i = 0; i < agents.length; i++) {
      final agent = agents[i];
      final spec = StudioControllerOntology.specForAgent(agent);
      if (aligned &&
          (savedAgents[i]['enabled'] ?? true) == true &&
          !agent.enabled) {
        note('codec_disabled_saved_agent', agentIndex: i);
      }
      if (spec == null) {
        note('unresolved_controller_identity', agentIndex: i);
        continue;
      }
      if (agent.controllerId.isNotEmpty && agent.controllerId != spec.id) {
        note('controller_identity_disagreement', agentIndex: i);
      }
      if (preset.agentEnabled.containsKey(spec.id) &&
          preset.agentEnabled[spec.id] != agent.enabled) {
        // The actual phase runner reads agent.enabled, not this restore/UI map.
        note('saved_toggle_disagrees_with_agent_state', agentIndex: i);
      }
      if (spec.lockedOn && !agent.enabled) {
        note('declared_locked_controller_disabled', agentIndex: i);
      }
      final requirement = spec.requiresSpecId;
      if (agent.enabled &&
          requirement != null &&
          !enabled.any(
            (a) => StudioControllerOntology.specForAgent(a)?.id == requirement,
          )) {
        note(
          'declared_requirement_unavailable',
          agentIndex: i,
          requirement: requirement,
        );
      }
    }

    final tiedOrder =
        enabled.map((a) => a.order).toSet().length != enabled.length;
    if (tiedOrder) note('enabled_order_ties');
    final finalCandidates = enabled
        .where(
          (a) => StudioControllerOntology.specForAgent(a)?.isFinal ?? false,
        )
        .length;
    if (finalCandidates > 1) note('multiple_declared_final_controllers');
    final missingThinkWriter =
        enabled.isNotEmpty &&
        split.finalAgent == null &&
        enabled.any((a) => a.reasoningMode == 'think-replacement');
    if (enabled.isEmpty) note('no_enabled_agents');
    if (missingThinkWriter) note('think_requires_enabled_main_writer');
    final finalAgent = split.finalAgent;
    if (finalAgent != null &&
        !(StudioControllerOntology.specForAgent(finalAgent)?.isFinal ??
            false)) {
      note('legacy_final_fallback', agentIndex: indexOf(finalAgent));
    }

    return {
      'namespace': 'studioPreset',
      'scope': 'current_saved_agent_topology_only',
      'phaseSplitter': 'StudioActivationGate.splitAgentsByPhase',
      'requirements': 'StudioControllerOntology.declared_only',
      'phaseEligibility': enabled.isEmpty
          ? 'decoded_snapshot_disabled'
          : missingThinkWriter
          ? 'think_without_main_writer'
          : 'split_observed_not_executed',
      'status': issues.isNotEmpty || decoded.warnings.isNotEmpty
          ? 'topology_attention'
          : 'topology_observed',
      'factConfidence': 'confirmed_by_check',
      'causalDiagnosis': 'insufficient_data',
      'agentCount': agents.length,
      'enabledCount': enabled.length,
      'codecWarningCount': decoded.warnings.length,
      'savedRosterAligned': aligned,
      'preGenerationTrackerIndices': [
        for (final a in split.preGenTrackers) ?indexOf(a),
      ],
      'postProcessingIndices': [
        for (final a in split.postGenTrackers) ?indexOf(a),
      ],
      if (finalAgent != null && indexOf(finalAgent) != null)
        'selectedFinalAgentIndex': indexOf(finalAgent),
      'preGenerationPolicy': 'enabled_tracker_failure_blocks_final_writer',
      'issueCount': issues.length,
      'issueLimit': issueLimit,
      'issuesTruncated': issues.length > issueLimit,
      'issues': issues.take(issueLimit).toList(growable: false),
      'notChecked': [
        'historical_prompt_and_phases',
        'actual_controller_outputs_and_retries',
        'full_agent_dependency_graph',
        'runtime_normalization_and_auxiliary_lanes',
        'connections_and_credentials',
        'block_and_prompt_semantics',
      ],
      'executionPerformed': false,
      'automaticRepair': false,
    };
  }
}
