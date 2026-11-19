import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../../../core/llm/studio/studio_stream_interceptor.dart';
import '../../../core/llm/studio/studio_writer_checkpoint.dart';
import '../../../core/llm/studio_agent_executor.dart';
import '../../../core/models/chat_message.dart';
import 'saved_message_writer.dart';

/// A completed controller phase waiting for its owning run to settle. The
/// target anchor includes both variation levels: a matching message ID alone
/// is not permission to append to whichever variation is currently selected.
class StudioWriterPending {
  final String ownerId;
  final String? targetId;
  final String? expectedTailId;
  final String? targetAnchor;
  final String? guidanceText;
  final String guidanceType;
  final StudioWriterCheckpoint checkpoint;

  const StudioWriterPending._({
    required this.ownerId,
    required this.targetId,
    required this.expectedTailId,
    required this.targetAnchor,
    required this.guidanceText,
    required this.guidanceType,
    required this.checkpoint,
  });

  static StudioWriterPending? capture({
    required String ownerId,
    required ChatSession baseSession,
    required String? targetId,
    required String? guidanceText,
    required String guidanceType,
    required StudioWriterCheckpoint checkpoint,
  }) {
    final tail = baseSession.messages.lastOrNull;
    if (targetId != null &&
        (tail?.id != targetId || tail?.role != 'assistant')) {
      return null;
    }
    return StudioWriterPending._(
      ownerId: ownerId,
      targetId: targetId,
      expectedTailId: tail?.id,
      targetAnchor: targetId == null ? null : _anchor(tail!),
      guidanceText: guidanceText,
      guidanceType: guidanceType,
      checkpoint: checkpoint,
    );
  }

  String encode() => jsonEncode({
    'version': 1,
    'ownerId': ownerId,
    'targetId': targetId,
    'expectedTailId': expectedTailId,
    'targetAnchor': targetAnchor,
    'guidanceText': guidanceText,
    'guidanceType': guidanceType,
    'checkpoint': checkpoint.toJson(),
  });

  static Map<String, dynamic>? _decode(String? raw) {
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw);
      return decoded is Map<String, dynamic> && decoded['version'] == 1
          ? decoded
          : null;
    } on FormatException {
      return null;
    }
  }

  static bool owns(String? raw, String ownerId) =>
      _decode(raw)?['ownerId'] == ownerId;

  static StudioWriterPending? _fromJson(Map<String, dynamic>? data) {
    if (data == null) return null;
    final owner = data['ownerId'];
    final target = data['targetId'];
    final tail = data['expectedTailId'];
    final anchor = data['targetAnchor'];
    final text = data['guidanceText'];
    final type = data['guidanceType'];
    final checkpoint = StudioWriterCheckpoint.fromJson(data['checkpoint']);
    if (owner is! String ||
        owner.isEmpty ||
        (target != null && (target is! String || target != tail)) ||
        (tail != null && tail is! String) ||
        (target == null ? anchor != null : anchor is! String) ||
        (text != null && text is! String) ||
        type is! String ||
        checkpoint == null) {
      return null;
    }
    return StudioWriterPending._(
      ownerId: owner,
      targetId: target as String?,
      expectedTailId: tail as String?,
      targetAnchor: anchor as String?,
      guidanceText: text as String?,
      guidanceType: type,
      checkpoint: checkpoint,
    );
  }

  bool matchesSource(ChatSession latest) {
    final tail = latest.messages.lastOrNull;
    if (tail?.id != expectedTailId) return false;
    var promptSession = latest;
    if (targetId != null) {
      if (tail == null ||
          tail.role != 'assistant' ||
          _anchor(tail) != targetAnchor) {
        return false;
      }
      promptSession = latest.copyWith(
        messages: latest.messages.take(latest.messages.length - 1).toList(),
      );
    }
    final promptVars = {...promptSession.sessionVars}
      ..remove(StudioWriterCheckpoint.pendingSessionKey);
    return StudioWriterCheckpoint.sourceFor(
          promptSession.copyWith(sessionVars: promptVars),
          guidanceText,
        ) ==
        checkpoint.source;
  }

  static String _anchor(ChatMessage target) =>
      sha256.convert(utf8.encode(jsonEncode(target.toJson()))).toString();

  /// Call inside a repository mutation on the latest row. A Stop supplies its
  /// exact run ID; an initializing provider with no live run can recover an
  /// orphan. Clear the slot in the same write as promotion, or discard an
  /// unsafe record without touching messages. Null means no matching slot.
  static ChatSession? recover(
    ChatSession latest, {
    String? ownerId,
    required String interruptedText,
    String partialText = '',
    String? partialReasoning,
  }) {
    final raw = latest.sessionVars[StudioWriterCheckpoint.pendingSessionKey];
    if (raw == null) return null;
    final data = _decode(raw);
    if (ownerId != null && data?['ownerId'] != ownerId) return null;
    final vars = {...latest.sessionVars}
      ..remove(StudioWriterCheckpoint.pendingSessionKey);
    final cleared = latest.copyWith(sessionVars: vars);
    final pending = _fromJson(data);
    if (pending == null || !pending.matchesSource(cleared)) return cleared;

    final think = pending.checkpoint.briefs
        .where((brief) => brief.isThinkReplacement)
        .firstOrNull;
    final checkpointReasoning = think == null
        ? null
        : StudioAgentExecutor.combineThinkingReasoning(
            StudioAgentExecutor.normalizeThinkingPrefill(think.brief),
            null,
            controllerReasoning: think.nativeReasoning,
          );
    final hasPartial = partialText.trim().isNotEmpty;
    // A stopped draft keeps its text, but remains an error variation: it was
    // never completed and should offer writer retry, not cleaner.
    final text = hasPartial ? partialText : interruptedText;
    final reasoning = hasPartial && partialReasoning?.trim().isNotEmpty == true
        ? partialReasoning
        : checkpointReasoning;
    final outputs = StudioStreamInterceptor.studioOutputsToJson(
      pending.checkpoint.briefs,
    );
    final checkpoint = pending.checkpoint.toJson();
    const writer = SavedMessageWriter();
    final targetId = pending.targetId;
    return (targetId == null
            ? writer.writeError(
                errorText: text,
                currentSession: cleared,
                studioWriterCheckpoint: checkpoint,
                studioOutputs: outputs,
                reasoning: reasoning,
                guidanceText: pending.guidanceText,
                guidanceType: pending.guidanceType,
              )
            : writer.writeRegenError(
                errorText: text,
                saveSession: cleared,
                regenTargetId: targetId,
                studioWriterCheckpoint: checkpoint,
                studioOutputs: outputs,
                reasoning: reasoning,
                guidanceText: pending.guidanceText,
                guidanceType: pending.guidanceType,
              ))
        .session;
  }
}
