import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_agent_topology_diagnostics.dart';
import 'package:glaze_flutter/core/models/studio_preset_codec.dart';

Map<String, Object?> agent(
  String controller, {
  bool enabled = true,
  int order = 0,
  String phase = 'pre_generation',
  String reasoning = 'normal',
  String? spec,
}) => {
  'id': 'PRIVATE_$controller',
  'name': 'PRIVATE_NAME',
  'controllerId': controller,
  'specId': spec ?? controller,
  'enabled': enabled,
  'order': order,
  'phase': phase,
  'reasoningMode': reasoning,
};

Map<String, Object?> inspect(
  List<Map<String, Object?>> agents, {
  Map<String, bool> toggles = const {},
}) {
  final decoded = StudioPresetCodec.decodePreset({
    'id': 'PRIVATE_PRESET',
    'blocks': <Object?>[],
    'agents': agents,
    'agentEnabled': toggles,
  });
  return StudioAgentTopologyDiagnostics.inspect(decoded, savedAgents: agents);
}

List<Object?> codes(Map<String, Object?> result) =>
    (result['issues'] as List).map((i) => (i as Map)['code']).toList();

void main() {
  test(
    'real phase split retains original indices, not authored identities',
    () {
      final result = inspect([
        agent('agency'),
        agent('final', order: 1),
        agent('post_clean', order: 2, phase: 'post_processing'),
      ]);
      expect(result['preGenerationTrackerIndices'], [0]);
      expect(result['postProcessingIndices'], [2]);
      expect(result['selectedFinalAgentIndex'], 1);
      expect(result['status'], 'topology_observed');
      expect(
        result['preGenerationPolicy'],
        'enabled_tracker_failure_blocks_final_writer',
      );
      expect(result['executionPerformed'], false);
      expect(result['causalDiagnosis'], 'insufficient_data');
      expect(jsonEncode(result), isNot(contains('PRIVATE_')));
    },
  );
  test('Think with no writer uses the actual missing-writer phase gate', () {
    final result = inspect([agent('think', reasoning: 'think-replacement')]);
    expect(result['phaseEligibility'], 'think_without_main_writer');
    expect(result.containsKey('selectedFinalAgentIndex'), false);
    expect(codes(result), contains('think_requires_enabled_main_writer'));
    expect(result['automaticRepair'], false);
  });
  test(
    'Think with writer does not fall back to reasoning as visible answer',
    () {
      final result = inspect([
        agent('think', reasoning: 'think-replacement'),
        agent('final', order: 1),
      ]);
      expect(result['selectedFinalAgentIndex'], 1);
      expect(result['preGenerationTrackerIndices'], [0]);
      expect(codes(result), isNot(contains('legacy_final_fallback')));
    },
  );
  test(
    'legacy final fallback is reported, not removed or called Main Writer',
    () {
      final result = inspect([agent('agency')]);
      expect(result['selectedFinalAgentIndex'], 0);
      expect(codes(result), contains('legacy_final_fallback'));
      expect(result['phaseEligibility'], 'split_observed_not_executed');
    },
  );
  test(
    'ontology dependency is declared-only, not a proof of runtime failure',
    () {
      final result = inspect([
        agent('continuity'),
        agent('final', order: 1),
        agent('ledger', order: 2, enabled: false, phase: 'post_processing'),
      ]);
      final issue = (result['issues'] as List).singleWhere(
        (i) => i['code'] == 'declared_requirement_unavailable',
      );
      expect(issue['agentIndex'], 0);
      expect(issue['requiredController'], 'ledger');
      expect(result['requirements'], 'StudioControllerOntology.declared_only');
      expect(
        result['notChecked'],
        contains('runtime_normalization_and_auxiliary_lanes'),
      );
    },
  );
  test('disabled roster is distinct from an executed failing generation', () {
    final result = inspect([agent('final', enabled: false)]);
    expect(result['phaseEligibility'], 'decoded_snapshot_disabled');
    expect(codes(result), contains('declared_locked_controller_disabled'));
    expect(result['executionPerformed'], false);
  });
  test(
    'saved UI toggle does not override the actual phase runner agent state',
    () {
      final result = inspect([agent('final')], toggles: {'final': false});
      expect(result['selectedFinalAgentIndex'], 0);
      expect(
        codes(result),
        contains('saved_toggle_disagrees_with_agent_state'),
      );
    },
  );
  test('codec-disabled unknown agents are not declared healthy', () {
    final result = inspect([agent('PRIVATE_UNKNOWN')]);
    expect(result['enabledCount'], 0);
    expect(codes(result), contains('codec_disabled_saved_agent'));
    expect(codes(result), contains('unresolved_controller_identity'));
    expect(result['status'], 'topology_attention');
    expect(jsonEncode(result), isNot(contains('PRIVATE_')));
  });
  test(
    'actual spec preference, final ambiguity and order ties remain explicit',
    () {
      final result = inspect([
        agent('agency', spec: 'final'),
        agent('continuity', spec: 'final'),
      ]);
      expect(codes(result), contains('controller_identity_disagreement'));
      expect(codes(result), contains('multiple_declared_final_controllers'));
      expect(codes(result), contains('enabled_order_ties'));
    },
  );
  test('issue projection is bounded while full counts remain explicit', () {
    final result = inspect(
      List.generate(40, (i) => agent('PRIVATE_UNKNOWN_$i')),
    );
    expect(result['issueCount'], greaterThan(32));
    expect(result['issuesTruncated'], true);
    expect(result['issues'], hasLength(32));
    expect(jsonEncode(result), isNot(contains('PRIVATE_')));
  });
}
