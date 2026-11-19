import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../models/chat_message.dart';
import '../../models/studio_config.dart';
import '../studio_activation_gate.dart';
import '../studio_stage_brief.dart';
import 'studio_context.dart';

/// The completed pre-generation phase, stored on its own outer variation.
/// Never recover this phase from the assembled/streamed reasoning string.
class StudioWriterCheckpoint {
  static const key = 'studioWriterCheckpoint';
  static const pendingSessionKey = '_studio_writer_pending_phase_v1';

  final String presetId;
  final String source;
  final List<StudioStageBrief> briefs;
  final String phaseInputs;

  /// Reproduces the canon/summary projection used when the controller phase
  /// was built. Full regeneration supplies the replaced message ID even though
  /// that message is absent from the prompt session; ordinary sends use null.
  final String? excludeSnapshotMessageId;

  StudioWriterCheckpoint({
    required this.presetId,
    required this.source,
    required List<StudioStageBrief> briefs,
    this.phaseInputs = '',
    this.excludeSnapshotMessageId,
  }) : briefs = List.unmodifiable(briefs);

  static String sourceFor(ChatSession promptSession, String? guidanceText) {
    final encoded = jsonEncode([
      promptSession.id,
      guidanceText,
      promptSession.authorsNote?.toJson(),
      promptSession.summary?.toJson(),
      for (final msg in promptSession.messages)
        [
          msg.id,
          msg.role,
          msg.content,
          msg.reasoning,
          msg.swipeId,
          msg.agentSwipeId,
          msg.isHidden,
          msg.imageHidden,
          msg.attachments,
        ],
    ]);
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  static StudioWriterCheckpoint? forMessage(ChatMessage message) {
    final index = message.swipeId;
    if (index < 0 || index >= message.swipesMeta.length) return null;
    return fromJson(message.swipesMeta[index][key]);
  }

  static StudioWriterCheckpoint? fromJson(Object? data) {
    if (data is! Map || data['version'] != 1) return null;
    final preset = data['presetId'];
    final source = data['source'];
    final outputs = data['briefs'];
    final phaseInputs = data['phaseInputs'];
    final excludeSnapshotMessageId = data['excludeSnapshotMessageId'];
    if (preset is! String || source is! String || outputs is! List) return null;
    if (phaseInputs is! String ||
        (excludeSnapshotMessageId != null &&
            excludeSnapshotMessageId is! String)) {
      return null;
    }
    final briefs = <StudioStageBrief>[];
    for (final item in outputs) {
      if (item is! Map) return null;
      final id = item['id'];
      final name = item['name'];
      final content = item['content'];
      final isThink = item['think'];
      final native = item['native'];
      final status = item['status'];
      if (id is! String ||
          name is! String ||
          content is! String ||
          isThink is! bool ||
          native is! String ||
          (status != 'ok' && status != 'cached')) {
        return null;
      }
      briefs.add(
        StudioStageBrief(
          agentId: id,
          agentName: name,
          brief: content,
          isThinkReplacement: isThink,
          nativeReasoning: native,
          status: status == 'cached' ? 'cached' : 'ok',
        ),
      );
    }
    return StudioWriterCheckpoint(
      presetId: preset,
      source: source,
      briefs: briefs,
      phaseInputs: phaseInputs,
      excludeSnapshotMessageId: excludeSnapshotMessageId as String?,
    );
  }

  /// Think audits the final prompt too, so those instructions belong to the
  /// saved phase. API/model credentials are deliberately not part of this:
  /// repairing a failed writer connection must not rerun a healthy Think.
  static String fingerprintPhase(
    StudioPreset preset,
    StudioContext trackerContext,
    StudioContext finalContext,
  ) {
    final blocks = preset.blocks
        .where(
          (block) =>
              block.enabled &&
              block.section != 'cleaner' &&
              block.section != 'ledger' &&
              block.section != 'build' &&
              block.section != 'brief_parser',
        )
        .toList();
    Object contextJson(StudioContext context) {
      final slots = context.slots.entries.toList()
        ..sort((a, b) => a.key.name.compareTo(b.key.name));
      final vars = context.sessionVars.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      final globals = context.globalVars.entries.toList()
        ..sort((a, b) => a.key.compareTo(b.key));
      return [
        for (final slot in slots)
          [slot.key.name, for (final message in slot.value) message.toApiMap()],
        [for (final message in context.history) message.toApiMap()],
        {for (final entry in vars) entry.key: entry.value},
        {for (final entry in globals) entry.key: entry.value},
        context.continueInstruction,
      ];
    }

    final encoded = jsonEncode([
      for (final block in blocks) block.toJson(),
      contextJson(trackerContext),
      contextJson(finalContext),
      preset.maxFinalHistoryMessages,
    ]);
    return sha256.convert(utf8.encode(encoded)).toString();
  }

  bool matchesTopology(String currentPresetId, AgentPhaseSplit split) {
    if (presetId != currentPresetId ||
        split.finalAgent == null ||
        briefs.length != split.preGenTrackers.length) {
      return false;
    }
    for (var i = 0; i < briefs.length; i++) {
      final agent = split.preGenTrackers[i];
      if (briefs[i].agentId != agent.id ||
          briefs[i].isThinkReplacement !=
              (agent.reasoningMode == 'think-replacement')) {
        return false;
      }
    }
    return true;
  }

  Map<String, dynamic> toJson() => {
    'version': 1,
    'presetId': presetId,
    'source': source,
    'phaseInputs': phaseInputs,
    if (excludeSnapshotMessageId != null)
      'excludeSnapshotMessageId': excludeSnapshotMessageId,
    'briefs': [
      for (final brief in briefs)
        {
          'id': brief.agentId,
          'name': brief.agentName,
          'content': brief.brief,
          'think': brief.isThinkReplacement,
          'native': brief.nativeReasoning,
          'status': brief.status,
        },
    ],
  };
}
