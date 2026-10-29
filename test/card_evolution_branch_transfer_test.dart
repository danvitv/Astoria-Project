import 'dart:convert';

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_observation_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/models/card_evolution_observation.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

/// Branch-session transfer of the derived card-evolution lanes: collectors,
/// writer claims, and observations follow the reconciliation prefix that
/// [LedgerReconciliationRunRepo.copyForSessionBranch] rebuilds, mirroring the
/// sequencing `ChatSessionService.branchSession` uses inside its transaction.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => db.close());

  test(
    'branch transfer re-keys collectors and claims onto branch batches',
    () async {
      await _seedSession(db);
      final runs = await _appendChain(db, 6);
      await _recordEffects(db, runs);
      final first = await _completeCollector(db, runs.sublist(0, 3));
      final second = await _completeCollector(db, runs.sublist(3, 6));
      await _insertCompletedClaim(
        db,
        first,
        id: 'claim-1',
        inputHash: 'claim-input-1',
      );
      await _insertCompletedClaim(
        db,
        second,
        id: 'claim-2',
        inputHash: 'claim-input-2',
      );
      await _seedSession(db, sessionId: 'branch', sessionIndex: 1);

      final transfer = await db.transaction(
        () => _transferLanes(db, messageIds: _retainedIds(_messages.length)),
      );

      expect(transfer, isNotNull);
      expect(transfer!.copiedRuns, hasLength(6));
      final branchRuns = await LedgerReconciliationRunRepo(
        db,
      ).readSession('branch');
      expect(branchRuns, hasLength(6));

      final collectors = await _branchCollectors(db);
      expect(collectors, hasLength(2));
      final firstBatch = CardEvolutionCollectorBatch(branchRuns.sublist(0, 3));
      final secondBatch = CardEvolutionCollectorBatch(branchRuns.sublist(3, 6));
      expect(collectors[0].id, startsWith('evolution-collector-'));
      expect(collectors[0].collectorOrdinal, 1);
      expect(collectors[0].ownerId, 'cloud-sync');
      expect(collectors[0].status, 'completed');
      expect(collectors[0].reconciliationRunId, branchRuns[2].id);
      expect(collectors[0].reconciliationRunOrdinal, 3);
      expect(collectors[0].reconciliationChainHash, branchRuns[2].chainHash);
      expect(collectors[0].rangeHash, firstBatch.rangeHash);
      expect(collectors[0].inputHash, first.inputHash);
      expect(collectors[0].modelOutputHash, first.modelOutputHash);
      expect(collectors[0].createdAt, first.createdAt);
      expect(collectors[0].completedAt, first.completedAt);
      expect(collectors[1].id, startsWith('evolution-collector-'));
      expect(collectors[1].collectorOrdinal, 2);
      expect(collectors[1].reconciliationRunId, branchRuns[5].id);
      expect(collectors[1].reconciliationRunOrdinal, 6);
      expect(collectors[1].reconciliationChainHash, branchRuns[5].chainHash);
      expect(collectors[1].rangeHash, secondBatch.rangeHash);
      expect(collectors[1].inputHash, second.inputHash);

      final claims = await _branchClaims(db);
      expect(claims, hasLength(2));
      expect(claims[0].id, startsWith('evolution-claim-'));
      expect(claims[0].sessionId, 'branch');
      expect(claims[0].characterId, 'character');
      expect(
        claims[0].predecessorCursorHash,
        collectors[0].reconciliationChainHash,
      );
      expect(claims[0].predecessorRunOrdinal, 1);
      expect(claims[0].inputHash, 'claim-input-1');
      expect(claims[0].ownerId, 'owner');
      expect(claims[0].chatHistoryHash, 'history-1');
      expect(claims[0].status, 'completed');
      expect(
        claims[1].predecessorCursorHash,
        collectors[1].reconciliationChainHash,
      );
      expect(claims[1].predecessorRunOrdinal, 2);
      expect(claims[1].inputHash, 'claim-input-2');

      // The transferred collectors already consume their branch batches, so a
      // later collection pass (or a sync merge) fires nothing duplicate.
      expect(
        await CardEvolutionCollectorRunRepo(db).pendingValidPairs('branch'),
        isEmpty,
      );
      // The source session keeps its own immutable journal.
      final sourceCollectors = await (db.select(db.cardEvolutionCollectorRuns)
            ..where((row) => row.sessionId.equals('session')))
          .get();
      expect(
        sourceCollectors.map((row) => row.id),
        containsAll([first.id, second.id]),
      );
      final sourceClaims = await (db.select(db.cardEvolutionClaims)
            ..where((row) => row.sessionId.equals('session')))
          .get();
      expect(sourceClaims.map((row) => row.id), containsAll(['claim-1', 'claim-2']));
    },
  );

  test('derived lanes stop at the transferred reconciliation prefix', () async {
    await _seedSession(db);
    final runs = await _appendChain(db, 6);
    await _recordEffects(db, runs);
    final first = await _completeCollector(db, runs.sublist(0, 3));
    final second = await _completeCollector(db, runs.sublist(3, 6));
    await _insertCompletedClaim(
      db,
      first,
      id: 'claim-1',
      inputHash: 'claim-input-1',
    );
    await _insertCompletedClaim(
      db,
      second,
      id: 'claim-2',
      inputHash: 'claim-input-2',
    );
    // The branch transcript keeps everything through assistant-2; run 5
    // anchors user-3, which leaves the retained set, so the transferred
    // prefix stops at run 4 and the second collector stays behind.
    await _seedSession(
      db,
      sessionId: 'branch',
      sessionIndex: 1,
      messages: _messages.take(5).toList(),
    );

    final transfer = await db.transaction(
      () => _transferLanes(db, messageIds: _retainedIds(5)),
    );

    expect(transfer!.copiedRuns, hasLength(4));
    expect(transfer.branchOrdinalBySourceOrdinal, {1: 1, 2: 2, 3: 3, 4: 4});
    final branchRuns = await LedgerReconciliationRunRepo(
      db,
    ).readSession('branch');
    expect(branchRuns, hasLength(4));

    final collectors = await _branchCollectors(db);
    expect(collectors, hasLength(1));
    expect(collectors.single.collectorOrdinal, 1);
    expect(collectors.single.reconciliationRunId, branchRuns[2].id);
    expect(collectors.single.reconciliationChainHash, branchRuns[2].chainHash);
    expect(
      collectors.single.rangeHash,
      CardEvolutionCollectorBatch(branchRuns.sublist(0, 3)).rangeHash,
    );

    final claims = await _branchClaims(db);
    expect(claims, hasLength(1));
    expect(claims.single.inputHash, 'claim-input-1');
    expect(claims.single.predecessorCursorHash, branchRuns[2].chainHash);
    expect(claims.single.predecessorRunOrdinal, 1);
  });

  test('native branch collector wins its ordinal and anchors the claim', () async {
    await _seedSession(db);
    final runs = await _appendChain(db, 3);
    await _recordEffects(db, runs);
    final source = await _completeCollector(db, runs);
    await _insertCompletedClaim(
      db,
      source,
      id: 'claim-1',
      inputHash: 'claim-input-1',
    );
    await _seedSession(db, sessionId: 'branch', sessionIndex: 1);

    final transfer = await LedgerReconciliationRunRepo(
      db,
    ).copyForSessionBranch(
      fromSessionId: 'session',
      toSessionId: 'branch',
      messageIds: _retainedIds(_messages.length),
    );
    expect(transfer, isNotNull);
    final branchRuns = await LedgerReconciliationRunRepo(
      db,
    ).readSession('branch');
    final batch = CardEvolutionCollectorBatch(branchRuns);
    // A native branch collector already completed the same batch boundary.
    await db
        .into(db.cardEvolutionCollectorRuns)
        .insert(
          CardEvolutionCollectorRunsCompanion.insert(
            id: 'native-collector',
            sessionId: 'branch',
            characterId: 'character',
            collectorOrdinal: 1,
            reconciliationRunId: batch.boundary.id,
            reconciliationRunOrdinal: batch.boundary.ordinal,
            reconciliationChainHash: batch.boundary.chainHash,
            rangeHash: batch.rangeHash,
            inputHash: 'native-input',
            ownerId: 'local-owner',
            status: 'completed',
            leaseExpiresAt: 0,
            modelOutputHash: const Value('native-output'),
            createdAt: 20,
            completedAt: const Value(21),
          ),
        );

    await CardEvolutionCollectorRunRepo(db).copyForSessionBranch(
      fromSessionId: 'session',
      toSessionId: 'branch',
      toCharacterId: 'character',
      transfer: transfer!,
    );

    final collectors = await _branchCollectors(db);
    expect(collectors, hasLength(1));
    expect(collectors.single.id, 'native-collector');
    expect(collectors.single.ownerId, 'local-owner');
    final claims = await _branchClaims(db);
    expect(claims, hasLength(1));
    expect(
      claims.single.predecessorCursorHash,
      collectors.single.reconciliationChainHash,
    );
    expect(claims.single.predecessorRunOrdinal, 1);
    expect(claims.single.inputHash, 'claim-input-1');
  });

  test('an incompatible native branch collector fails the transfer closed', () async {
    await _seedSession(db);
    final runs = await _appendChain(db, 3);
    await _recordEffects(db, runs);
    final source = await _completeCollector(db, runs);
    await _insertCompletedClaim(
      db,
      source,
      id: 'claim-1',
      inputHash: 'claim-input-1',
    );
    await _seedSession(db, sessionId: 'branch', sessionIndex: 1);

    final transfer = await LedgerReconciliationRunRepo(
      db,
    ).copyForSessionBranch(
      fromSessionId: 'session',
      toSessionId: 'branch',
      messageIds: _retainedIds(_messages.length),
    );
    final branchRuns = await LedgerReconciliationRunRepo(
      db,
    ).readSession('branch');
    final batch = CardEvolutionCollectorBatch(branchRuns);
    await db
        .into(db.cardEvolutionCollectorRuns)
        .insert(
          CardEvolutionCollectorRunsCompanion.insert(
            id: 'native-collector',
            sessionId: 'branch',
            characterId: 'character',
            collectorOrdinal: 1,
            reconciliationRunId: batch.boundary.id,
            reconciliationRunOrdinal: batch.boundary.ordinal,
            reconciliationChainHash: batch.boundary.chainHash,
            rangeHash: 'tampered-range',
            inputHash: 'native-input',
            ownerId: 'local-owner',
            status: 'completed',
            leaseExpiresAt: 0,
            createdAt: 20,
            completedAt: const Value(21),
          ),
        );

    await expectLater(
      db.transaction(
        () => CardEvolutionCollectorRunRepo(db).copyForSessionBranch(
          fromSessionId: 'session',
          toSessionId: 'branch',
          toCharacterId: 'character',
          transfer: transfer!,
        ),
      ),
      throwsStateError,
    );

    final collectors = await _branchCollectors(db);
    expect(collectors.map((row) => row.id), ['native-collector']);
    expect(await _branchClaims(db), isEmpty);
  });

  test(
    'observations follow the branch with clamped ordinals and native precedence',
    () async {
      await _seedSession(db);
      final runs = await _appendChain(db, 6);
      await _recordEffects(db, runs);
      await _insertObservation(
        db,
        id: 'obs-direct',
        scopeKey: 'character.personality.trust',
        clusters: const [
          ['assistant-1'],
          ['user-2'],
        ],
        runOrdinal: 2,
        firstSeenRun: 1,
        lastConfirmedRun: 3,
        status: 'promoted',
        confidence: 0.8,
        updatedAt: 20,
      );
      await _insertObservation(
        db,
        id: 'obs-clamped',
        scopeKey: 'npc.alice.location',
        clusters: const [
          ['assistant-2'],
        ],
        runOrdinal: 5,
        firstSeenRun: 4,
        lastConfirmedRun: 6,
        updatedAt: 21,
      );
      await _insertObservation(
        db,
        id: 'obs-outside',
        scopeKey: 'npc.bob.trait',
        clusters: const [
          ['user-1'],
          ['assistant-3'],
        ],
        runOrdinal: 2,
        updatedAt: 22,
      );
      await _insertObservation(
        db,
        id: 'obs-occupied',
        scopeKey: 'npc.carol.mood',
        clusters: const [
          ['user-2'],
        ],
        runOrdinal: 3,
        updatedAt: 23,
      );
      // A legacy cloud row can carry empty evidence clusters past the schema
      // CHECK (repeat_count stays positive), so it can only arrive through a
      // raw row insert; the branch transfer must leave it for re-derivation.
      await db.customStatement(
        "INSERT INTO card_evolution_observations "
        "(id, session_id, character_id, run_ordinal, semantic_scope_key, "
        "observed_change, evidence_message_ids, evidence_clusters_json, "
        "retrieval_keys_json, confidence, status, first_seen_run, "
        "repeat_count, created_at, updated_at) VALUES "
        "('obs-empty', 'session', 'character', 2, 'npc.dan.mood', "
        "'Alice increasingly trusts the protagonist.', '[]', '[]', '[]', "
        "0.5, 'active', 1, 1, 10, 24)",
      );
      await _seedSession(
        db,
        sessionId: 'branch',
        sessionIndex: 1,
        messages: _messages.take(5).toList(),
      );
      // A native branch observation already occupies that scope key.
      await _insertObservation(
        db,
        sessionId: 'branch',
        id: 'native-obs',
        scopeKey: 'npc.carol.mood',
        clusters: const [
          ['user-2'],
        ],
        runOrdinal: 1,
        updatedAt: 5,
      );

      final transfer = await db.transaction(
        () => _transferLanes(db, messageIds: _retainedIds(5)),
      );

      expect(transfer!.copiedRuns, hasLength(4));
      final byId = {
        for (final observation
            in await CardEvolutionObservationRepo(db).getBySessionId('branch'))
          observation.id: observation,
      };
      expect(byId.keys, {
        'native-obs',
        'cloud-observation-${computeHash('branch\u001fcharacter.personality.trust')}',
        'cloud-observation-${computeHash('branch\u001fnpc.alice.location')}',
      });
      final direct =
          byId['cloud-observation-${computeHash('branch\u001fcharacter.personality.trust')}']!;
      expect(direct.sessionId, 'branch');
      expect(direct.characterId, 'character');
      expect(direct.runOrdinal, 2);
      expect(direct.firstSeenRun, 1);
      expect(direct.lastConfirmedRun, 3);
      expect(direct.status, 'promoted');
      expect(direct.confidence, 0.8);
      expect(direct.updatedAt, 20);
      expect(direct.evidenceClusters, const [
        ['assistant-1'],
        ['user-2'],
      ]);
      final clamped =
          byId['cloud-observation-${computeHash('branch\u001fnpc.alice.location')}']!;
      // Ordinals past the transferred prefix clamp to the nearest lower
      // transferred run (source 5 and 6 both clamp to the branch run 4).
      expect(clamped.runOrdinal, 4);
      expect(clamped.firstSeenRun, 4);
      expect(clamped.lastConfirmedRun, 4);
      expect(byId['native-obs']!.runOrdinal, 1);
    },
  );
}

/// Mirrors the branch-transaction sequencing in `ChatSessionService`: the
/// reconciliation prefix transfers first, then the collector/claim lane, then
/// the observation journal.
Future<LedgerReconciliationBranchTransfer?> _transferLanes(
  AppDatabase db, {
  required Set<String> messageIds,
}) async {
  final transfer = await LedgerReconciliationRunRepo(db).copyForSessionBranch(
    fromSessionId: 'session',
    toSessionId: 'branch',
    messageIds: messageIds,
  );
  if (transfer != null) {
    await CardEvolutionCollectorRunRepo(db).copyForSessionBranch(
      fromSessionId: 'session',
      toSessionId: 'branch',
      toCharacterId: 'character',
      transfer: transfer,
    );
    await CardEvolutionObservationRepo(db).copyForSessionBranch(
      fromSessionId: 'session',
      toSessionId: 'branch',
      toCharacterId: 'character',
      messageIds: messageIds,
      transfer: transfer,
    );
  }
  return transfer;
}

Future<void> _seedSession(
  AppDatabase db, {
  String sessionId = 'session',
  int sessionIndex = 0,
  List<Map<String, Object>>? messages,
}) => db.customStatement(
  'INSERT INTO chat_sessions '
  '(session_id, character_id, session_index, messages_json) '
  'VALUES (?, ?, ?, ?)',
  [sessionId, 'character', sessionIndex, jsonEncode(messages ?? _messages)],
);

Set<String> _retainedIds(int count) => {
  for (final message in _messages.take(count)) message['id'] as String,
};

/// Six runs whose anchors walk the transcript, so truncating the branch
/// transcript stops the transferable prefix at a chosen run.
Future<List<LedgerReconciliationRun>> _appendChain(
  AppDatabase db,
  int count,
) async {
  assert(count < _messages.length);
  final repo = LedgerReconciliationRunRepo(db);
  final runs = <LedgerReconciliationRun>[];
  var predecessor = '';
  for (var ordinal = 1; ordinal <= count; ordinal++) {
    final run = LedgerReconciliationRun(
      id: 'run-$ordinal',
      sessionId: 'session',
      ordinal: ordinal,
      anchors: [_anchorForMessage(_messages[ordinal])],
      acceptedManifestRefs: const [],
      effectiveCanonStamp: 'stamp-$ordinal',
      effectiveCanonRevision: ordinal,
      effectiveCanonHash: 'canon-$ordinal',
      canonicalResult: {'facts': ['result-$ordinal']},
      predecessorChainHash: predecessor,
      contractVersion: 1,
      opsApplied: const [],
      createdAt: ordinal,
    );
    expect(await repo.append(run), isA<ReconciliationRunAppended>());
    runs.add(run);
    predecessor = run.chainHash;
  }
  return runs;
}

Future<void> _recordEffects(
  AppDatabase db,
  List<LedgerReconciliationRun> runs,
) async {
  final repo = LedgerReconciliationRunRepo(db);
  final state = await repo.captureState('session');
  for (final run in runs) {
    await repo.recordEffect(
      runId: run.id,
      sessionId: 'session',
      before: state,
      after: state,
      createdAt: run.createdAt,
    );
  }
}

Future<LedgerReconciliationSuccessfulRunRow> _storedRun(
  AppDatabase db,
  String id,
) => (db.select(
  db.ledgerReconciliationSuccessfulRuns,
)..where((row) => row.id.equals(id))).getSingle();

Future<CardEvolutionCollectorRunRow> _completeCollector(
  AppDatabase db,
  List<LedgerReconciliationRun> runs,
) async {
  final storedRuns = [for (final run in runs) await _storedRun(db, run.id)];
  final repo = CardEvolutionCollectorRunRepo(db);
  final claim = await repo.claim(
    reconciliationRun: storedRuns.last,
    characterId: 'character',
    inputHash: 'collector-input-${storedRuns.last.ordinal}',
    ownerId: 'owner',
    now: 10,
    leaseSeconds: 30,
    rangeHash: CardEvolutionCollectorBatch(storedRuns).rangeHash,
  );
  expect(
    await repo.complete(
      id: claim.row!.id,
      ownerId: 'owner',
      modelOutputHash: 'output-${storedRuns.last.ordinal}',
      now: 11,
    ),
    isTrue,
  );
  return (db.select(
    db.cardEvolutionCollectorRuns,
  )..where((row) => row.id.equals(claim.row!.id))).getSingle();
}

Future<void> _insertCompletedClaim(
  AppDatabase db,
  CardEvolutionCollectorRunRow collector, {
  required String id,
  required String inputHash,
}) => db
    .into(db.cardEvolutionClaims)
    .insert(
      CardEvolutionClaimsCompanion.insert(
        id: id,
        sessionId: 'session',
        characterId: 'character',
        ownerId: 'owner',
        status: 'completed',
        leaseExpiresAt: 0,
        chatHistoryHash: 'history-${collector.collectorOrdinal}',
        effectiveCanonIdentity: 'canon',
        predecessorCursorHash: collector.reconciliationChainHash,
        predecessorRunOrdinal: collector.collectorOrdinal,
        inputHash: inputHash,
        rewriteJobId: Value('rewrite-job-${collector.collectorOrdinal}'),
        createdAt: 12,
        completedAt: const Value(13),
      ),
    );

Future<void> _insertObservation(
  AppDatabase db, {
  required String id,
  required String scopeKey,
  required List<List<String>> clusters,
  String sessionId = 'session',
  int runOrdinal = 1,
  int firstSeenRun = 1,
  int? lastConfirmedRun,
  String status = 'active',
  double confidence = 0.5,
  int createdAt = 10,
  int updatedAt = 10,
}) => CardEvolutionObservationRepo(db).insertObservation(
  CardEvolutionObservation(
    id: id,
    sessionId: sessionId,
    characterId: 'character',
    runOrdinal: runOrdinal,
    semanticScopeKey: scopeKey,
    observedChange: 'Alice increasingly trusts the protagonist.',
    canonicalClaim: 'Alice trusts the protagonist.',
    evidenceClusters: clusters,
    retrievalKeys: const ['npc:Alice'],
    targetKind: 'main_character_card',
    cardFieldPath: 'personality',
    confidence: confidence,
    status: status,
    firstSeenRun: firstSeenRun,
    repeatCount: clusters.length,
    lastConfirmedRun: lastConfirmedRun,
    createdAt: createdAt,
    updatedAt: updatedAt,
  ),
);

Future<List<CardEvolutionCollectorRunRow>> _branchCollectors(
  AppDatabase db,
) async {
  final rows = await (db.select(db.cardEvolutionCollectorRuns)
        ..where((row) => row.sessionId.equals('branch')))
      .get();
  rows.sort((a, b) => a.collectorOrdinal.compareTo(b.collectorOrdinal));
  return rows;
}

Future<List<CardEvolutionClaimRow>> _branchClaims(AppDatabase db) async {
  final rows = await (db.select(db.cardEvolutionClaims)
        ..where((row) => row.sessionId.equals('branch')))
      .get();
  rows.sort((a, b) => a.predecessorRunOrdinal.compareTo(b.predecessorRunOrdinal));
  return rows;
}

ReconciliationAnchor _anchorForMessage(Map<String, Object> message) =>
    ReconciliationAnchor(
      messageId: message['id'] as String,
      swipeId: 0,
      agentSwipeId: 0,
      role: message['role'] as String,
      contentHash: computeHash(message['content'] as String),
    );

const _messages = [
  {
    'id': 'opening-assistant',
    'role': 'assistant',
    'content': 'Welcome to the story.',
    'swipes': ['Welcome to the story.'],
    'agentSwipes': <Object>[],
  },
  {'id': 'user-1', 'role': 'user', 'content': 'Begin.'},
  {
    'id': 'assistant-1',
    'role': 'assistant',
    'content': 'Assistant 1',
    'swipes': ['Assistant 1'],
    'agentSwipes': <Object>[],
  },
  {'id': 'user-2', 'role': 'user', 'content': 'Continue.'},
  {
    'id': 'assistant-2',
    'role': 'assistant',
    'content': 'Assistant 2',
    'swipes': ['Assistant 2'],
    'agentSwipes': <Object>[],
  },
  {'id': 'user-3', 'role': 'user', 'content': 'Continue again.'},
  {
    'id': 'assistant-3',
    'role': 'assistant',
    'content': 'Assistant 3',
    'swipes': ['Assistant 3'],
    'agentSwipes': <Object>[],
  },
];
