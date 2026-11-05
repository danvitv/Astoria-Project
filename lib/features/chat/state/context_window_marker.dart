import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../chat_provider.dart';
import 'cached_token_breakdown.dart';
import '../../../core/llm/context_calculator.dart';
import '../../../core/llm/prompt_isolate.dart';
import '../../../core/llm/studio_controller_ontology.dart';
import '../../../core/models/studio_pregen_mode.dart';
import '../../../core/state/active_selection_provider.dart';
import '../../../core/state/active_studio_preset_provider.dart';
import '../../../core/state/studio_feature_provider.dart';
import '../../settings/api_list_provider.dart';
import '../../presets/preset_list_provider.dart';
import '../providers/prompt_build_providers.dart';

/// Id of the oldest message the next prompt still carries — the message the
/// chat draws its CONTEXT LIMIT rule above.
///
/// Read from the breakdown the last prompt build left behind, so it answers for
/// the trim that actually ran. Both modes land here: sliding reports the cut it
/// recomputed this turn, stepped the window its anchor holds open. Null while
/// nothing was cut (the whole chat is in the prompt, so there is no boundary to
/// draw) and null while no breakdown exists — a rule guessed from nothing is
/// worse than no rule.
final contextWindowStartProvider = Provider.autoDispose.family<String?, String>(
  (ref, charId) {
    final breakdown = ref.watch(cachedTokenBreakdownProvider(charId));
    // A session switch keeps the character's cached breakdown, whose boundary
    // belongs to the session that was open when it was built. Watching the id
    // re-runs this, and the membership check below drops a boundary the open
    // chat has no message for.
    ref.watch(chatProvider(charId).select((s) => s.value?.session?.id));
    final builtFor = ref.watch(cachedTokenBreakdownSessionProvider(charId));
    if (builtFor != null &&
        builtFor != ref.read(chatProvider(charId)).value?.session?.id) {
      return null;
    }
    if (breakdown == null || breakdown.cutoffIndex <= 0) return null;
    final id = breakdown.windowStartMessageId;
    if (id == null) return null;
    final messages = ref.read(chatProvider(charId)).value?.messages;
    if (messages == null) return null;
    return messages.any((message) => message.id == id) ? id : null;
  },
);

class ContextWindowBoundary {
  const ContextWindowBoundary(this.messageId, {this.afterMessage = false});
  final String messageId;
  final bool afterMessage;
  @override
  bool operator ==(Object other) =>
      other is ContextWindowBoundary &&
      messageId == other.messageId &&
      afterMessage == other.afterMessage;
  @override
  int get hashCode => Object.hash(messageId, afterMessage);
}

/// Ordinary recounts cannot describe a Studio final prompt. Wait for the mode
/// to settle and resolve the same selected/default preset generation uses, so
/// an enabled preference without a runnable preset still gets ordinary counts.
final ordinaryPromptRecountEnabledProvider = FutureProvider.autoDispose<bool>((
  ref,
) async {
  final studioEnabled = await ref.watch(studioFeatureSettledProvider.future);
  if (!ref.mounted) return false;
  if (!studioEnabled) return true;
  final preset = await ref.watch(studioPresetProvider.future);
  if (!ref.mounted) return false;
  if (preset == null) return true;
  final useThink =
      studioPregenMode(preset) == StudioPregenMode.thinkReplacement;
  // Mirror StudioTurnConfigResolver's runnable-agent gate without resolving API
  // slots or starting any preparation work merely to draw a context marker.
  return !preset.agents.any((agent) {
    final spec = StudioControllerOntology.specForAgent(agent);
    if (spec == null) return false;
    if (spec.isFinal) return true;
    if (agent.phase != spec.phase) return false;
    if (spec.id == 'think') return useThink;
    if (useThink && spec.phase == 'pre_generation') return false;
    return agent.enabled && preset.agentEnabled[spec.id] != false;
  });
});

/// Auto-disposed ordinary idle recount: stale results cannot publish elsewhere.
final contextWindowRecountProvider = FutureProvider.autoDispose
    .family<TokenBreakdown?, String>((ref, charId) async {
      final chat = ref.watch(
        chatProvider(charId).select(
          (value) => (
            session: value.value?.session,
            busy:
                value.value?.isGenerating == true ||
                value.value?.isSendPending == true ||
                value.value?.isPostGenRunning == true,
          ),
        ),
      );
      if (chat.session == null || chat.busy) return null;
      final ordinaryEnabled = await ref.watch(
        ordinaryPromptRecountEnabledProvider.future,
      );
      if (!ref.mounted || !ordinaryEnabled) return null;
      ref.watch(activeApiConfigProvider);
      ref.watch(activePresetIdProvider);
      ref.watch(presetConnectionsProvider);
      ref.watch(activePersonaIdProvider);
      ref.watch(personaConnectionsProvider);
      ref.watch(globalVarsProvider);
      ref.watch(presetListProvider);
      await Future<void>.delayed(const Duration(milliseconds: 200));
      if (!ref.mounted) return null;
      final inputs = await ref
          .read(promptPayloadBuilderProvider)
          .collectInputs(charId: charId, session: chat.session);
      if (!ref.mounted) return null;
      final built = await buildFromInputsInIsolate(
        inputs,
        debugLabel: 'context-window-recount',
      );
      return ref.mounted ? built.breakdown : null;
    });

final contextWindowBoundaryProvider = Provider.autoDispose
    .family<ContextWindowBoundary?, String>((ref, charId) {
      final recountState = ref.watch(contextWindowRecountProvider(charId));
      // Async refresh can retain the previous value, including another
      // session's common message ids. Only a completed recount is authoritative.
      final recount = recountState.isLoading ? null : recountState.value;
      final start = ref.watch(contextWindowStartProvider(charId));
      if (recount == null && start != null) return ContextWindowBoundary(start);
      final breakdown =
          recount ?? ref.watch(cachedTokenBreakdownProvider(charId));
      final sessionId = ref.watch(
        chatProvider(charId).select((s) => s.value?.session?.id),
      );
      final builtFor = ref.watch(cachedTokenBreakdownSessionProvider(charId));
      if (recount == null && builtFor != null && builtFor != sessionId) {
        return null;
      }
      final messages = ref.watch(
        chatProvider(charId).select((s) => s.value?.messages),
      );
      if (breakdown != null &&
          breakdown.cutoffIndex > 0 &&
          breakdown.windowStartMessageId != null &&
          messages?.any((m) => m.id == breakdown.windowStartMessageId) ==
              true) {
        return ContextWindowBoundary(breakdown.windowStartMessageId!);
      }
      if (breakdown == null ||
          breakdown.cutoffIndex <= 0 ||
          breakdown.trimmedHistory.isNotEmpty ||
          messages == null ||
          messages.isEmpty) {
        return null;
      }
      return ContextWindowBoundary(messages.last.id, afterMessage: true);
    });
