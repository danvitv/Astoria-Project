import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/credentials/secret_redactor.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_workspace_models.dart';
import 'package:glaze_flutter/features/support_assistant/services/support_workspace_settings_codec.dart';

void main() {
  const codec = SupportWorkspaceSettingsCodec();
  final redactor = SecretRedactor();
  for (final tokens in [-1, 1, 2048, 8192, 16384, 131072, 0x7fffffff]) {
    test('v1 settings preserve $tokens without schema change or clamping', () {
      final block = codec.encode(
        'synthetic-session',
        SupportAssistantSettings(maxTokens: tokens),
        1,
        redactor,
      );
      final payload = jsonDecode(block.protectedFactsJson) as Map;
      expect(block.id, 'workspace-settings-v1:synthetic-session');
      expect(block.summary, 'workspace-settings-v1');
      expect(payload['version'], 1);
      expect(payload['maxTokens'], tokens);
      expect(
        payload.keys,
        unorderedEquals([
          'version',
          'mode',
          'apiConfigId',
          'modelId',
          'temperature',
          'maxTokens',
          'reasoningEffort',
          'dcpCompressionEnabled',
        ]),
      );
      final restored = codec.decode(block);
      expect(restored.maxTokens, tokens);
      expect(restored.temperature, 0.35);
      expect(restored.reasoningEffort, SupportReasoningEffort.medium);
    });
  }

  for (final tokens in [0, -2, 0x80000000]) {
    test('invalid $tokens cannot be encoded for persistence', () {
      expect(
        () => codec.encode(
          'synthetic-session',
          SupportAssistantSettings(maxTokens: tokens),
          1,
          redactor,
        ),
        throwsArgumentError,
      );
    });
  }
  for (final invalid in [0, -2, 0x80000000, 1.5, '-1', null]) {
    test('v1 decode rejects invalid $invalid instead of replacing it', () {
      final block = codec.encode(
        'synthetic-session',
        const SupportAssistantSettings(),
        1,
        redactor,
      );
      final payload = jsonDecode(block.protectedFactsJson) as Map;
      payload['maxTokens'] = invalid;
      expect(
        () => codec.decode(
          block.copyWith(protectedFactsJson: jsonEncode(payload)),
        ),
        throwsA(
          isA<SupportSettingsUnavailable>().having(
            (error) => error.availability,
            'availability',
            SupportSettingsAvailability.corrupt,
          ),
        ),
      );
    });
  }
}
