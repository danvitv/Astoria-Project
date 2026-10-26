import 'dart:convert';
import '../../../core/credentials/secret_redactor.dart';
import '../../../core/models/support_models.dart';
import '../../../core/db/repositories/support_repo.dart';
import '../models/support_workspace_models.dart';

class SupportSettingsUnavailable extends StateError {
  SupportSettingsUnavailable(this.availability) : super('Settings unavailable');
  final SupportSettingsAvailability availability;
}

/// Dedicated encrypted context row; preferences never enter plaintext metadata.
class SupportWorkspaceSettingsCodec {
  const SupportWorkspaceSettingsCodec();
  String idFor(String sessionId) => 'workspace-settings-v1:$sessionId';
  String get globalId => SupportRepo.assistantSettingsId;
  SupportContextBlock encodeGlobal(
    SupportAssistantSettings settings,
    int now,
    SecretRedactor redactor,
  ) => encode(
    '',
    settings,
    now,
    redactor,
  ).copyWith(id: globalId, isActive: false);

  /// Copy readable legacy bytes without repairing malformed payloads or
  /// importing session permissions. Locked envelopes are refused by the repo.
  SupportContextBlock migrateGlobal(
    SupportContextBlock? legacy,
    int now,
    SecretRedactor redactor,
  ) => legacy == null
      ? encodeGlobal(const SupportAssistantSettings(), now, redactor)
      : legacy.copyWith(
          id: globalId,
          sessionId: '',
          startMessageId: '',
          endMessageId: '',
          isActive: false,
        );
  SupportContextBlock encode(
    String id,
    SupportAssistantSettings s,
    int now,
    SecretRedactor redactor,
  ) {
    if (s.maxTokens != -1 && (s.maxTokens < 1 || s.maxTokens > 0x7fffffff)) {
      throw ArgumentError('Invalid output token limit');
    }
    return SupportContextBlock(
      id: idFor(id),
      sessionId: id,
      startMessageId: '',
      endMessageId: '',
      summary: 'workspace-settings-v1',
      createdAt: now,
      protectedFactsJson: jsonEncode({
        'version': 1,
        'mode': s.mode.name,
        'apiConfigId': s.apiConfigId == null
            ? null
            : redactor.redactText(s.apiConfigId!),
        'modelId': s.modelId == null ? null : redactor.redactText(s.modelId!),
        'temperature': s.temperature,
        'maxTokens': s.maxTokens,
        'reasoningEffort': s.reasoningEffort.name,
        'dcpCompressionEnabled': s.dcpCompressionEnabled,
      }),
    );
  }

  SupportAssistantSettings decode(SupportContextBlock? block) {
    if (block == null) return const SupportAssistantSettings();
    if (block.isLocked) {
      throw SupportSettingsUnavailable(SupportSettingsAvailability.locked);
    }
    try {
      if (block.summary != 'workspace-settings-v1') {
        throw const FormatException();
      }
      final m = jsonDecode(block.protectedFactsJson) as Map<String, dynamic>;
      if (m['version'] != 1) throw const FormatException();
      final temperature = (m['temperature'] as num).toDouble();
      final tokens = m['maxTokens'] as int;
      if (!temperature.isFinite ||
          temperature < 0 ||
          temperature > 2 ||
          (tokens != -1 && (tokens < 1 || tokens > 0x7fffffff))) {
        throw const FormatException();
      }
      return SupportAssistantSettings(
        mode: SupportAssistantMode.values.byName(m['mode'] as String),
        apiConfigId: m['apiConfigId'] as String?,
        modelId: m['modelId'] as String?,
        temperature: temperature,
        maxTokens: tokens,
        reasoningEffort: SupportReasoningEffort.values.byName(
          m['reasoningEffort'] as String,
        ),
        dcpCompressionEnabled: m['dcpCompressionEnabled'] as bool,
      );
    } catch (_) {
      throw SupportSettingsUnavailable(SupportSettingsAvailability.corrupt);
    }
  }
}
