// Named public constructor arguments intentionally initialize private fields.
// ignore_for_file: prefer_initializing_formals

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/chat_message.dart';
import '../../../core/state/db_provider.dart';
import '../../../core/state/chat_source_mutation_provider.dart';
import '../chat_message_service.dart';
import '../chat_session_service.dart';
import '../chat_state.dart';
import '../initial_message_builder.dart';
import '../state/chat_session_write_queue.dart';

class ChatSwipeController {
  final Ref _ref;
  final String _charId;
  final void Function(AsyncValue<ChatState>) _setState;
  final AsyncValue<ChatState> Function() _getState;
  final void Function() _invalidateHistory;

  /// Shared with `ChatMessageOpsController`. Every durable write runs through
  /// it so two taps (or a tap racing a swipe gesture) cannot interleave their
  /// commit cycles, and — more importantly — so a variation switch never
  /// commits while a message deletion is still in its transaction. The commit
  /// below re-reads the *durable* row; started early it would read the
  /// pre-delete message list and write it back, which is exactly how deleted
  /// messages came back the moment you flipped a variation.
  final ChatSessionWriteQueue _writes;

  ChatSwipeController({
    required Ref ref,
    required String charId,
    required void Function(AsyncValue<ChatState>) setState,
    required AsyncValue<ChatState> Function() getState,
    required void Function() invalidateHistory,
    required ChatSessionWriteQueue writes,
  }) : _ref = ref,
       _charId = charId,
       _setState = setState,
       _getState = getState,
       _invalidateHistory = invalidateHistory,
       _writes = writes;

  ChatMessageService get _messageSvc => ChatMessageService(_ref);

  void Function() _beginMutation(ChatSession session, String messageId) => _ref
      .read(chatSourceMutationRegistryProvider)
      .beginMutation(sessionId: session.id, messageIds: {messageId});

  /// Publishes [updated] on top of the *latest* state rather than the snapshot
  /// the operation started from, so flags another path flipped mid-await
  /// (generation, session switch) are not rolled back. Drops the write when the
  /// chat moved to a different session while the commit was in flight.
  void _publish(ChatSession updated, {bool invalidateHistory = true}) {
    if (!_ref.mounted) return;
    final latest = _getState().value;
    if (latest == null || latest.session == null) return;
    if (latest.session!.id != updated.id) return;
    if (invalidateHistory) _invalidateHistory();
    _setState(AsyncData(latest.copyWith(session: updated)));
  }

  /// Paints [preview] now and commits it on the shared write queue.
  ///
  /// The commit is a Drift transaction plus a full session re-encode; on a long
  /// chat that is several frames, and awaiting it before publishing is what
  /// made the counter and the bubble lag a tap behind. The variation switch
  /// itself is computed synchronously, so the bubble can flip on the frame of
  /// the tap and reconcile with the durable row when it lands.
  Future<void> _switchVariation({
    required ChatSession snapshot,
    required int messageIndex,
    required ChatSession preview,
    required ChatSession Function(ChatSession latest, int latestIndex) mutate,
  }) async {
    if (!_ref.mounted) return;
    final settle = _beginMutation(snapshot, snapshot.messages[messageIndex].id);
    try {
      final token = _writes.beginPublication();
      // The optimistic paint changes nothing durable, so it must not churn the
      // chat list — only the committed row below does.
      _publish(preview, invalidateHistory: false);
      await _writes.run(() async {
        final durable = await _messageSvc.commitMessageMutation(
          snapshot,
          messageIndex,
          mutate,
        );
        // Something newer already owns the bubble — another switch, or a delete
        // that painted its shortened list. This row predates it, so publishing
        // would step the user backwards (and put deleted bubbles back).
        if (!_writes.isCurrentPublication(token)) return;
        _publish(durable);
      });
    } finally {
      settle();
    }
  }

  /// True when [current] cannot accept a variation switch right now.
  bool _switchBlocked(ChatState? current, int messageIndex) {
    return !_ref.mounted ||
        current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isGeneratingImage ||
        current.isPostGenRunning ||
        messageIndex < 0 ||
        messageIndex >= current.messages.length;
  }

  Future<void> setSwipe(int messageIndex, int swipeId) {
    if (!_ref.mounted) return Future<void>.value();
    // Direct selection is not gated on the generation flags (unlike
    // [changeSwipe]) — it keeps the original contract of "apply it if the
    // message service accepts it", and bails out below when nothing moved.
    final snapshot = _getState().value?.session;
    if (snapshot == null) return Future<void>.value();
    if (messageIndex >= 0 &&
        messageIndex < snapshot.messages.length &&
        snapshot.messages[messageIndex].swipeId == swipeId) {
      return Future<void>.value();
    }
    final preview = _messageSvc.setSwipe(snapshot, messageIndex, swipeId);
    if (identical(preview, snapshot)) return Future<void>.value();
    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview,
      mutate: (latest, latestIndex) =>
          _messageSvc.setSwipe(latest, latestIndex, swipeId),
    );
  }

  Future<void> setAgentSwipe(int messageIndex, int agentSwipeId) {
    if (!_ref.mounted) return Future<void>.value();
    final snapshot = _getState().value?.session;
    if (snapshot == null) return Future<void>.value();
    if (messageIndex >= 0 &&
        messageIndex < snapshot.messages.length &&
        snapshot.messages[messageIndex].agentSwipeId == agentSwipeId) {
      return Future<void>.value();
    }
    final preview = _messageSvc.setAgentSwipe(
      snapshot,
      messageIndex,
      agentSwipeId,
    );
    if (identical(preview, snapshot)) return Future<void>.value();
    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview,
      mutate: (latest, latestIndex) =>
          _messageSvc.setAgentSwipe(latest, latestIndex, agentSwipeId),
    );
  }

  Future<void> deleteActiveSwipe(int messageIndex) {
    return _deleteVariation(messageIndex, deleteAgentSwipe: false);
  }

  Future<void> deleteActiveAgentSwipe(int messageIndex) {
    return _deleteVariation(messageIndex, deleteAgentSwipe: true);
  }

  Future<void> _deleteVariation(
    int messageIndex, {
    required bool deleteAgentSwipe,
  }) async {
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (_switchBlocked(current, messageIndex)) return;
    final accepted = current!.session!;
    final message = accepted.messages[messageIndex];
    if (message.role != 'assistant' || message.id.isEmpty) return;
    final replacement = deleteAgentSwipe
        ? ChatMessageService.removeActiveAgentSwipe(message)
        : ChatMessageService.removeActiveSwipe(message);
    if (replacement == null) return;
    final messageId = message.id;
    final settle = _beginMutation(accepted, messageId);
    try {
      final token = _writes.beginPublication();
      await _writes.run(() async {
        if (!_ref.mounted) return;
        final current = _getState().value;
        if (current?.session?.id != accepted.id) return;
        final snapshot = current!.session!;
        // A prior queued deletion/move may have shifted indices. Never act on the
        // different message now occupying the accepted action's old position.
        final latestIndex = snapshot.messages.indexWhere(
          (m) => m.id == messageId,
        );
        if (_switchBlocked(current, latestIndex)) return;
        if (snapshot.messages[latestIndex].role != 'assistant') return;
        final updated = deleteAgentSwipe
            ? await _messageSvc.deleteActiveAgentSwipe(snapshot, latestIndex)
            : await _messageSvc.deleteActiveSwipe(snapshot, latestIndex);
        if (identical(updated, snapshot)) return;
        if (!_writes.isCurrentPublication(token)) return;
        _publish(updated);
      });
    } finally {
      settle();
    }
  }

  Future<void> changeSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) {
    if (!_ref.mounted || dir == 0) return Future<void>.value();
    final current = _getState().value;
    if (_switchBlocked(current, messageIndex)) return Future<void>.value();
    final snapshot = current!.session!;

    final isLast = messageIndex == current.messages.length - 1;
    final preview = _messageSvc.changeSwipe(
      snapshot,
      messageIndex,
      dir,
      fromSwipe: fromSwipe,
      isLastMessage: isLast,
    );

    // This will be handled by the parent provider calling
    // regenerateLastAssistant.
    if (preview.needsRegen || !preview.isUpdated) return Future<void>.value();

    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview.session!,
      mutate: (latest, latestIndex) =>
          _messageSvc
              .changeSwipe(
                latest,
                latestIndex,
                dir,
                fromSwipe: fromSwipe,
                isLastMessage: latestIndex == latest.messages.length - 1,
              )
              .session ??
          latest,
    );
  }

  /// Navigate blue sub-swipes (agentSwipes). Right-edge on the last message
  /// → needsRegen, which the caller resolves via a full regeneration.
  Future<void> changeAgentSwipe(
    int messageIndex,
    int dir, {
    bool fromSwipe = false,
  }) {
    if (!_ref.mounted || dir == 0) return Future<void>.value();
    final current = _getState().value;
    if (_switchBlocked(current, messageIndex)) return Future<void>.value();
    final snapshot = current!.session!;

    final isLast = messageIndex == current.messages.length - 1;
    final preview = _messageSvc.changeAgentSwipe(
      snapshot,
      messageIndex,
      dir,
      fromSwipe: fromSwipe,
      isLastMessage: isLast,
    );

    if (preview.needsRegen || !preview.isUpdated) return Future<void>.value();

    return _switchVariation(
      snapshot: snapshot,
      messageIndex: messageIndex,
      preview: preview.session!,
      mutate: (latest, latestIndex) =>
          _messageSvc
              .changeAgentSwipe(
                latest,
                latestIndex,
                dir,
                fromSwipe: fromSwipe,
                isLastMessage: latestIndex == latest.messages.length - 1,
              )
              .session ??
          latest,
    );
  }

  Future<void> setGreeting(int messageIndex, int direction) async {
    // Unlike a swipe switch this cannot be previewed synchronously — the
    // greeting list comes from the character row and the resolved persona — so
    // it stays entirely on the write queue.
    if (!_ref.mounted) return;
    final current = _getState().value;
    if (current == null ||
        current.session == null ||
        current.isGenerating ||
        current.isPostGenRunning) {
      return;
    }
    if (messageIndex != 0 || current.messages.isEmpty || direction == 0) return;
    final accepted = current.session!;
    final msg = accepted.messages[0];
    if (msg.role != 'assistant' || msg.id.isEmpty) return;
    final newGreetingIndex = (msg.greetingIndex ?? 0) + direction;
    if (newGreetingIndex < 0) return;
    final settle = _beginMutation(accepted, msg.id);
    try {
      final token = _writes.beginPublication();
      await _writes.run(() async {
        if (!_ref.mounted) return;
        final latest = _getState().value;
        if (latest?.session?.id != accepted.id ||
            latest!.isGenerating ||
            latest.isPostGenRunning) {
          return;
        }
        final latestIndex = latest.messages.indexWhere((m) => m.id == msg.id);
        if (latestIndex != 0 || latest.messages[0].role != 'assistant') return;

        final character = await _ref
            .read(characterRepoProvider)
            .getById(_charId);
        if (!_ref.mounted || character == null) return;
        final persona = await ChatSessionService(_ref).resolvePersona(_charId);
        if (!_ref.mounted) return;
        final greetings = InitialMessageBuilder.resolveGreetings(
          character: character,
          persona: persona,
          sessionId: accepted.id,
        );
        if (greetings.length <= 1) return;

        final updated = await _messageSvc.commitMessageMutation(
          accepted,
          0,
          (latest, latestIndex) => _messageSvc.setGreeting(
            latest,
            latestIndex,
            newGreetingIndex,
            greetings,
          ),
        );
        if (!_writes.isCurrentPublication(token)) return;
        _publish(updated);
      });
    } finally {
      settle();
    }
  }
}
