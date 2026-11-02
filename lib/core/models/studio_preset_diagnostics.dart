import 'studio_preset_codec.dart';
import 'studio_preset_validation.dart';

/// Runs the app's existing codec/block validator. It is neither a second
/// validator nor a historical Studio execution/connection/dependency check.
abstract final class StudioPresetDiagnostics {
  static const issueLimit = 32;

  static Map<String, Object?> inspect(StudioPresetDecodeResult decoded) {
    final preset = decoded.preset;
    final issues = StudioPresetValidator.validate(preset);
    final errors = issues
        .where((i) => i.severity == StudioPresetValidationSeverity.error)
        .length;
    final warnings = issues.length - errors;
    final indices = <String, List<int>>{};
    for (var i = 0; i < preset.blocks.length; i++) {
      indices.putIfAbsent(preset.blocks[i].id, () => []).add(i);
    }
    return {
      'validator': 'StudioPresetValidator',
      'namespace': 'studioPreset',
      'scope': 'current_saved_codec_block_rules_only',
      'status': errors > 0
          ? 'block_rule_errors'
          : decoded.warnings.isNotEmpty
          ? 'codec_warnings_present'
          : warnings > 0
          ? 'block_rule_warnings'
          : 'block_rules_passed',
      'factConfidence': 'confirmed_by_check',
      'causalDiagnosis': 'insufficient_data',
      'blockCount': preset.blocks.length,
      'errorCount': errors,
      'warningCount': warnings,
      'codecWarningCount': decoded.warnings.length,
      'ruleReportingComplete': issues.every(
        (i) => i.code != StudioPresetValidationCode.unknown,
      ),
      'issueLimit': issueLimit,
      'issuesTruncated': issues.length > issueLimit,
      'issues': [
        for (final issue in issues.take(issueLimit))
          {
            'code': issue.code.name,
            'severity': issue.severity.name,
            if (indices[issue.blockId]?.length == 1)
              'blockIndex': indices[issue.blockId]!.single,
          },
      ],
      'notChecked': [
        'historical_prompt_and_phases',
        'required_controller_execution',
        'full_agent_dependency_graph',
        'runtime_normalization',
        'connections_and_credentials',
        'prompt_semantics',
      ],
      'automaticRepair': false,
    };
  }
}
