import 'package:flutter_riverpod/legacy.dart';

/// Live state for post-generation tasks (Ledger, Card Rewriter, and extension
/// blocks).
/// Surfaced to the chat UI as a floating card so the user can see what's
/// happening after the main generation + cleaner complete.
class PostGenStatusState {
  final Object? _runId;
  final String? sessionId;
  final PostGenTask task;
  final PostGenTaskPhase phase;
  final String? detail;

  const PostGenStatusState({
    Object? runId,
    this.sessionId,
    this.task = PostGenTask.none,
    this.phase = PostGenTaskPhase.idle,
    this.detail,
    // Public runId parameter intentionally feeds private legacy-compatible storage.
    // ignore: prefer_initializing_formals
  }) : _runId = runId;

  /// Stable across progress and terminal updates. Legacy const states use
  /// object identity; production starts allocate a fresh token via `startRun`.
  Object get runId => _runId ?? this;

  bool isSameRun(PostGenStatusState other) =>
      identical(runId, other.runId) &&
      sessionId == other.sessionId &&
      task == other.task;

  bool get isActive => phase == PostGenTaskPhase.running;
  bool get isDone => phase == PostGenTaskPhase.done;
  bool get isError => phase == PostGenTaskPhase.error;

  const PostGenStatusState.idle()
    : _runId = null,
      sessionId = null,
      task = PostGenTask.none,
      phase = PostGenTaskPhase.idle,
      detail = null;

  const PostGenStatusState.running({
    Object? runId,
    required this.sessionId,
    required this.task,
    this.detail,
    // ignore: prefer_initializing_formals
  }) : _runId = runId,
       phase = PostGenTaskPhase.running;

  const PostGenStatusState.done({
    Object? runId,
    required this.sessionId,
    required this.task,
    this.detail,
    // ignore: prefer_initializing_formals
  }) : _runId = runId,
       phase = PostGenTaskPhase.done;

  const PostGenStatusState.error({
    Object? runId,
    required this.sessionId,
    required this.task,
    this.detail,
    // ignore: prefer_initializing_formals
  }) : _runId = runId,
       phase = PostGenTaskPhase.error;

  PostGenStatusState _withPhase(PostGenTaskPhase phase, String? detail) =>
      PostGenStatusState(
        runId: runId,
        sessionId: sessionId,
        task: task,
        phase: phase,
        detail: detail,
      );
}

/// Ownership is tied to the started run, never to reusable session/task keys.
/// Keeping the StateProvider preserves legacy callers that publish snapshots.
extension PostGenStatusOwnership on StateController<PostGenStatusState> {
  PostGenStatusState startRun({
    required String sessionId,
    required PostGenTask task,
    String? detail,
  }) {
    final running = PostGenStatusState.running(
      runId: Object(),
      sessionId: sessionId,
      task: task,
      detail: detail,
    );
    state = running;
    return running;
  }

  bool ownsRun(PostGenStatusState expected) =>
      state.isActive && state.isSameRun(expected);

  bool updateRunDetail(PostGenStatusState expected, String detail) {
    if (!ownsRun(expected)) return false;
    state = state._withPhase(PostGenTaskPhase.running, detail);
    return true;
  }

  bool finishRun(
    PostGenStatusState expected, {
    bool isError = false,
    String? detail,
  }) {
    if (!ownsRun(expected)) return false;
    state = state._withPhase(
      isError ? PostGenTaskPhase.error : PostGenTaskPhase.done,
      detail,
    );
    return true;
  }

  bool clearRun(PostGenStatusState expected) {
    if (!ownsRun(expected)) return false;
    state = const PostGenStatusState.idle();
    return true;
  }
}

enum PostGenTask {
  none,
  ledgerReconciliation,
  cardEvolutionObservation,
  cardRewriter,
  ledger,
  extBlocks,
}

enum PostGenTaskPhase { idle, running, done, error }

final postGenStatusProvider = StateProvider<PostGenStatusState>(
  (_) => const PostGenStatusState.idle(),
);
