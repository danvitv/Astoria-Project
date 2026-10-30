import '../../models/chat_message.dart';
import '../../models/historical_message_window.dart';
import '../../models/tracker.dart';
import '../../models/tracker_snapshot.dart';
import '../app_db.dart';
import 'chat_repo.dart';
import 'session_canon_checkpoint_repo.dart';
import 'session_canon_rollback_repo.dart';
import 'tracker_repo.dart';
import 'tracker_snapshot_repo.dart';

/// Restores derived session state after cloud entities have finished applying.
class SyncSessionConsistencyRepo {
  const SyncSessionConsistencyRepo(this.db);

  final AppDatabase db;

  Future<void> reconcile(Set<String> sessionIds) async {
    for (final sessionId in sessionIds) {
      await db.transaction(() => _reconcileSession(sessionId));
    }
  }

  Future<void> _reconcileSession(String sessionId) async {
    final chat = await ChatRepo(db).getById(sessionId);
    if (chat == null) return;

    final checkpoints = SessionCanonCheckpointRepo(db);
    final timeline = await checkpoints.getForSession(sessionId);
    final survivingEpochs = SessionCanonCheckpointRepo.survivingHistory(
      timeline,
      HistoricalMessageWindow(chat.messages),
    );
    await SessionCanonRollbackRepo(db).reconcileInTransaction(
      sessionId: sessionId,
      survivingMessages: chat.messages,
    );
    final canonHash = (await checkpoints.getLatest(
      sessionId,
    ))?.characterRevisionHash;
    final survivingHashes = {
      for (final epoch in survivingEpochs) epoch.characterRevisionHash,
      ?canonHash,
    };
    // Delete only revisions explicitly discarded by this session's timeline,
    // not every revision different from its newest checkpoint. Older inherited
    // snapshots can predate the root and are valid historical evidence.
    final discardedHashes = {
      for (final epoch in timeline)
        if (epoch.characterRevisionHash.isNotEmpty &&
            !survivingHashes.contains(epoch.characterRevisionHash))
          epoch.characterRevisionHash,
    };

    final snapshots = TrackerSnapshotRepo(db);
    final all = await snapshots.getBySessionId(sessionId);
    final messagesById = {
      for (final message in chat.messages) message.id: message,
    };
    final retained = <(String, int, int), TrackerSnapshot>{};
    for (final snapshot in all) {
      final message = messagesById[snapshot.messageId];
      final hasDiscardedCanon = _basisHashes(
        snapshot,
      ).any(discardedHashes.contains);
      if (message == null ||
          !_variationExists(message, snapshot) ||
          hasDiscardedCanon) {
        await snapshots.deleteAnchor(
          sessionId: sessionId,
          messageId: snapshot.messageId,
          swipeId: snapshot.swipeId,
          agentSwipeId: snapshot.agentSwipeId,
        );
      } else {
        retained[(
              snapshot.messageId,
              snapshot.swipeId,
              snapshot.agentSwipeId,
            )] =
            snapshot;
      }
    }

    List<Tracker> committedBase = const [];
    for (final message in chat.messages.reversed) {
      final snapshot =
          retained[(message.id, message.swipeId, message.agentSwipeId)];
      if (snapshot != null &&
          snapshot.committed &&
          _matchesLiveCanon(snapshot, canonHash)) {
        committedBase = snapshot.trackers;
        break;
      }
    }

    final trackers = TrackerRepo(db);
    if (committedBase.isEmpty) {
      committedBase = await trackers.getInitialGameTimeSeed(sessionId);
      if (committedBase.isEmpty) {
        committedBase = await trackers.getCompleteGameTime(sessionId);
      }
    }
    await trackers.replaceLedgerState(sessionId, committedBase);
  }

  static Set<String> _basisHashes(TrackerSnapshot snapshot) => {
    for (final tracker in snapshot.trackers)
      if (tracker.basisRevisionHash.isNotEmpty) tracker.basisRevisionHash,
  };

  static bool _matchesLiveCanon(TrackerSnapshot snapshot, String? canonHash) {
    final basis = _basisHashes(snapshot);
    return canonHash == null ||
        canonHash.isEmpty ||
        basis.isEmpty ||
        (basis.length == 1 && basis.single == canonHash);
  }

  /// Inactive variations remain switchable history, not orphan snapshots.
  /// Only the exact currently selected coordinates can become the live base.
  static bool _variationExists(ChatMessage message, TrackerSnapshot snapshot) {
    final swipe = snapshot.swipeId;
    final agent = snapshot.agentSwipeId;
    if (swipe < 0 || agent < 0) return false;
    if (swipe != message.swipeId && swipe >= message.swipes.length) {
      return false;
    }
    if (agent == 0) return true;
    if (swipe == message.swipeId) {
      return agent == message.agentSwipeId ||
          agent <= message.agentSwipes.length;
    }
    if (swipe >= message.swipesMeta.length) return false;
    final variants = message.swipesMeta[swipe]['agentSwipes'];
    return variants is List && agent <= variants.length;
  }
}
