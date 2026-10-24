import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/applied_canon_transition_repo.dart';
import 'package:glaze_flutter/core/db/repositories/canon_transition_fact_ref_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_revision_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_session_baseline_repo.dart';
import 'package:glaze_flutter/core/db/repositories/chat_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_snapshot_repo.dart';
import 'package:glaze_flutter/core/llm/game_time.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_canon_authority.dart';
import 'package:glaze_flutter/core/llm/ledger/ledger_op_applier.dart' as core;
import 'package:glaze_flutter/core/llm/ledger/ledger_turn_committer.dart';
import 'package:glaze_flutter/core/llm/studio_ledger_export_parser.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/models/tracker_snapshot.dart';
import 'package:glaze_flutter/core/services/card_rewriter/effective_canon_context_loader.dart';

/// Parser/persistence only: real native in-memory repos, authority and committer.
/// No provider call, permissive authority double, socket, or runtime data access.
final class LedgerClockPersistenceFixture {
  LedgerClockPersistenceFixture() {
    final facts = CharacterKnowledgeFactRepo(db);
    authority = LedgerCanonAuthority(
      characterRepo: characters,
      chatRepo: chats,
      snapshotRepo: snapshots,
      trackerRepo: trackers,
      canonContextLoader: EffectiveCanonContextLoader(
        db: db,
        characterRepo: characters,
        characterRevisionRepo: CharacterRevisionRepo(db),
        baselineRepo: CharacterSessionBaselineRepo(db),
        factRepo: facts,
        transitionRepo: AppliedCanonTransitionRepo(db),
        transitionFactRefRepo: CanonTransitionFactRefRepo(db),
        loadRawTrackerState: LedgerRawTrackerStateReader(db).read,
      ),
    );
    committer = LedgerTurnCommitter(
      trackerRepo: trackers,
      snapshotRepo: snapshots,
      knowledgeFactRepo: facts,
      canonAuthority: authority,
      opApplier: const core.LedgerOpApplier(),
    );
  }

  static const sessionId = 'synthetic-clock-session';
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  late final characters = CharacterRepo(db);
  late final chats = ChatRepo(db);
  late final trackers = TrackerRepo(db);
  late final snapshots = TrackerSnapshotRepo(db);
  late final LedgerCanonAuthority authority;
  late final LedgerTurnCommitter committer;

  Future<void> seed(GameTimeState clock) async {
    await characters.put(
      const Character(id: 'synthetic-clock-character', name: 'Clock fixture'),
    );
    await chats.put(
      ChatSession(
        id: sessionId,
        characterId: 'synthetic-clock-character',
        sessionIndex: 0,
        messages: [
          for (var turn = 1; turn <= 3; turn++) ...[
            ChatMessage(
              id: 'u$turn',
              role: 'user',
              content: 'Synthetic U$turn',
            ),
            ChatMessage(
              id: 'a$turn',
              role: 'assistant',
              content: 'Synthetic A$turn',
            ),
          ],
        ],
      ),
    );
    await trackers.seedInitialGameTime(
      sessionId: sessionId,
      time: clock.time!,
      date: clock.date!,
      day: '${clock.day!}',
    );
    await snapshots.upsert(
      TrackerSnapshot(
        sessionId: sessionId,
        messageId: '',
        trackers: await trackers.getBySessionAndScope(sessionId, 'ledger'),
        committed: true,
        createdAt: 1,
      ),
    );
  }

  Future<({LedgerParseResult parsed, LedgerTurnCommitRequest request})> prepare(
    String raw,
    int turn,
  ) async {
    final canon = await authority.load(sessionId);
    final promptTrackers = authority.projectPromptTrackers(canon.context);
    final parsed = const StudioLedgerExportParser().parse(
      raw,
      clockPolicy: LedgerClockPolicy.turn(
        current: GameTimeState.fromTrackers(promptTrackers),
      ),
    );
    return (
      parsed: parsed,
      request: LedgerTurnCommitRequest(
        sessionId: sessionId,
        messageId: 'a$turn',
        swipeId: 0,
        agentSwipeId: 0,
        finalAssistantText: 'Synthetic A$turn',
        canon: canon,
        promptTrackers: promptTrackers,
        export: parsed.export!,
        cleanupOps: const [],
        facts: const [],
        token: CancelToken(),
        isStillCurrent: null,
        commitSnapshot: false,
      ),
    );
  }

  Future<TrackerSnapshot?> snapshot(int turn) => snapshots.getByAnchor(
    sessionId: sessionId,
    messageId: 'a$turn',
    swipeId: 0,
    agentSwipeId: 0,
  );

  Future<void> accept(int turn) async {
    await snapshots.commit(
      sessionId: sessionId,
      messageId: 'a$turn',
      swipeId: 0,
      agentSwipeId: 0,
    );
  }

  Future<GameTimeState> currentClock() async {
    final state = await LedgerRawTrackerStateReader(db).read(sessionId);
    return GameTimeState.fromTrackers(state.committedTrackers);
  }

  Future<List<Tracker>> clockRows() => trackers.getCompleteGameTime(sessionId);
}
