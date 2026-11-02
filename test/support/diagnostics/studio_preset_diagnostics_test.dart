import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/studio/studio_context.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/models/studio_preset_codec.dart';
import 'package:glaze_flutter/core/models/studio_preset_diagnostics.dart';
import 'package:glaze_flutter/core/models/studio_preset_validation.dart';

Map<String, dynamic> input(List<Map<String, dynamic>> blocks) => {
  'id': 'PRIVATE_PRESET_ID',
  'name': 'PRIVATE_PRESET_NAME',
  'blocks': blocks,
  'agents': <Object?>[],
};
Map<String, dynamic> block(
  String id, {
  String? target,
  String content = 'PRIVATE_PROMPT',
}) => {
  'id': id,
  'type': 'instruction',
  'content': content,
  'targetAgentId': ?target,
};

void main() {
  test(
    'passed block rules never attest execution, dependencies or a connection',
    () {
      final result = StudioPresetDiagnostics.inspect(
        StudioPresetCodec.decodePreset(
          input([block('PRIVATE_BLOCK_ID', target: 'continuity')]),
        ),
      );
      expect(result['status'], 'block_rules_passed');
      expect(result['issues'], isEmpty);
      expect(result['validator'], 'StudioPresetValidator');
      expect(result['namespace'], 'studioPreset');
      expect(result['causalDiagnosis'], 'insufficient_data');
      expect(result['automaticRepair'], false);
      expect(
        result['notChecked'],
        containsAll([
          'historical_prompt_and_phases',
          'full_agent_dependency_graph',
          'connections_and_credentials',
        ]),
      );
      expect(jsonEncode(result), isNot(contains('PRIVATE_')));
    },
  );

  test(
    'native errors and warnings report codes and indices, never issue prose',
    () {
      final decoded = StudioPresetCodec.decodePreset(
        input([
          block(
            'PRIVATE_BLOCK_ID',
            target: 'PRIVATE_UNKNOWN_TARGET',
            content: '',
          ),
        ]),
      );
      final issues = StudioPresetValidator.validate(decoded.preset);
      expect(
        issues.map((i) => i.message).join(),
        contains('PRIVATE_UNKNOWN_TARGET'),
      );
      final result = StudioPresetDiagnostics.inspect(decoded);
      expect(result['status'], 'block_rule_errors');
      expect(result['errorCount'], 1);
      expect(result['warningCount'], 1);
      expect(result['issues'], [
        {'code': 'unknownTargetAgent', 'severity': 'error', 'blockIndex': 0},
        {
          'code': 'emptyInstructionContent',
          'severity': 'warning',
          'blockIndex': 0,
        },
      ]);
      expect(jsonEncode(result), isNot(contains('PRIVATE_')));
    },
  );

  test('codec recovery warnings cannot become a clean validator verdict', () {
    final decoded = StudioPresetCodec.decodePreset({
      ...input([block('private')]),
      'runtime': ['malformed'],
    });
    final result = StudioPresetDiagnostics.inspect(decoded);
    expect(result['codecWarningCount'], greaterThan(0));
    expect(result['status'], 'codec_warnings_present');
    expect(result['errorCount'], 0);
  });

  test(
    'legacy input is interpreted by the real app codec, not a second decoder',
    () {
      final decoded = StudioPresetCodec.decodePreset(
        input([
          {
            'id': 'private',
            'kind': 'previous_agents',
            'section': 'final',
            'content': '',
          },
        ]),
      );
      expect(decoded.preset.blocks.single.type, StudioBlockType.priorBriefs);
      final issues = StudioPresetValidator.validate(decoded.preset);
      final result = StudioPresetDiagnostics.inspect(decoded);
      expect(
        result['errorCount'],
        issues
            .where((i) => i.severity == StudioPresetValidationSeverity.error)
            .length,
      );
      expect(
        result['warningCount'],
        issues
            .where((i) => i.severity == StudioPresetValidationSeverity.warning)
            .length,
      );
    },
  );

  test('issue truncation retains full counts, scope and no authored names', () {
    final decoded = StudioPresetCodec.decodePreset(
      input([
        for (var i = 0; i < 40; i++)
          block('PRIVATE_$i', target: 'PRIVATE_TARGET', content: ''),
      ]),
    );
    final result = StudioPresetDiagnostics.inspect(decoded);
    expect(result['errorCount'], 40);
    expect(result['warningCount'], 40);
    expect(result['issues'], hasLength(32));
    expect(result['issuesTruncated'], true);
    expect(result['ruleReportingComplete'], true);
    expect(jsonEncode(result), isNot(contains('PRIVATE_')));
  });

  test(
    'ambiguous duplicate block IDs do not acquire a guessed block index',
    () {
      final result = StudioPresetDiagnostics.inspect(
        StudioPresetCodec.decodePreset(
          input([block('PRIVATE_DUP'), block('PRIVATE_DUP')]),
        ),
      );
      expect(result['issues'], [
        {'code': 'duplicateBlockId', 'severity': 'error'},
      ]);
    },
  );

  test(
    'every existing validator rule has a native code without changing messages',
    () {
      final preset = StudioPreset(
        id: 'private',
        blocks: const [
          StudioPresetBlock(id: ''),
          StudioPresetBlock(id: 'duplicate', content: 'text'),
          StudioPresetBlock(id: 'duplicate', content: 'text'),
          StudioPresetBlock(
            id: 'instruction',
            section: 'unknown',
            insertionMode: 'unknown',
            role: 'unknown',
            targetAgentId: 'PRIVATE_TARGET',
            contextSlot: StudioContextSlot.characterCard,
          ),
          StudioPresetBlock(id: 'missing-depth', insertionMode: 'depth'),
          StudioPresetBlock(id: 'extra-depth', depth: 1),
          StudioPresetBlock(
            id: 'history',
            type: StudioBlockType.history,
            content: 'PRIVATE_CONTENT',
            insertionMode: 'depth',
            depth: 1,
            contextSlot: StudioContextSlot.characterCard,
            targetAgentId: 'private',
          ),
          StudioPresetBlock(
            id: 'context',
            type: StudioBlockType.context,
            targetAgentId: 'private',
          ),
          StudioPresetBlock(id: 'brief', type: StudioBlockType.priorBriefs),
        ],
      );
      final issues = StudioPresetValidator.validate(preset);
      expect(
        issues.map((i) => i.code).toSet(),
        StudioPresetValidationCode.values
            .where((c) => c != StudioPresetValidationCode.unknown)
            .toSet(),
      );
      expect(
        issues
            .where((i) => i.code == StudioPresetValidationCode.emptyBlockId)
            .single
            .message,
        'Block id must not be empty.',
      );
    },
  );
}
