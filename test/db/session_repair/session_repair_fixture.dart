import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/models/session_repair.dart';
import 'package:glaze_flutter/core/db/repositories/card_evolution_collector_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/session_repair_repo.dart';
import 'package:glaze_flutter/core/db/repositories/tracker_repo.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/tracker.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

import '../database_maintenance/maintenance_fixture.dart';

/// Reuses the production memory-SQLite/FakeVault/real XChaCha20 AEAD fixture's
/// I/O tripwires. No app startup, real preferences, network, files or key store.
void repairTest(String name, Future<void> Function(RepairFixture) body) {
  maintenanceTest(name, (base) async {
    final f = RepairFixture(base);
    await f.seed();
    await body(f);
  });
}

final class RepairFixture {
  RepairFixture(this.base) : repo = SessionRepairRepo(base.db, base.support);
  final MaintenanceFixture base;
  final SessionRepairRepo repo;
  AppDatabase get db => base.db;
  static const session = 'synthetic-repair-target';
  static const canary = 'SYNTHETIC_PRIVATE_REPAIR_ORIGINAL';
  bool get current => base.current;
  set current(bool value) => base.current = value;
  bool isCurrent() => current;
  Future<void> seed() async {
    await db
        .into(db.chatSessions)
        .insert(
          ChatSessionsCompanion.insert(
            sessionId: session,
            characterId: 'legacy',
            sessionIndex: 0,
            messagesJson: '[]',
          ),
        );
    for (final name in ['world:location', 'world:active_threats']) {
      await TrackerRepo(db).upsert(
        Tracker(
          sessionId: session,
          name: name,
          value: canary,
          scope: 'ledger',
          provenance: 'manual_session_repair',
          updatedAt: 3,
        ),
      );
    }
    await db
        .into(db.trackerSnapshots)
        .insert(
          TrackerSnapshotsCompanion.insert(
            sessionId: session,
            messageId: '',
            committed: const Value(1),
            trackersJson: const Value('[]'),
            createdAt: const Value(1),
          ),
        );
    base.events.clear();
  }

  Future<SessionRepairInspection> inspect({
    String parent = MaintenanceFixture.sessionId,
  }) => repo.inspect(
    targetSessionId: session,
    supportSessionId: parent,
    isCurrent: isCurrent,
  );
  Future<SessionRepairTarget> ledgerTarget() async =>
      (await inspect()).targets.firstWhere(
        (t) =>
            t.kind == SessionRepairTargetKind.liveLedger &&
            t.availability == SessionRepairAvailability.correctExistingValue,
      );
  Future<SessionRepairPlan?> correction({
    String value = 'SYNTHETIC_NATIVE_CORRECTION',
    String operation = 'synthetic-session-repair',
  }) async => (await repo.prepareCorrectExistingLedgerValue(
    target: await ledgerTarget(),
    value: value,
    operationId: operation,
    createdAt: 20,
    isCurrent: isCurrent,
  )).plan;
  Future<SessionRepairReceipt?> apply(SessionRepairPlan plan) =>
      repo.apply(plan: plan, isCurrent: isCurrent);
  Future<SessionRepairReceipt?> undo(SessionRepairReceipt receipt) =>
      repo.undo(receipt: receipt, isCurrent: isCurrent);
  Future<Map<String, Object?>> row(String name) async =>
      (await db
              .customSelect(
                'SELECT * FROM tracker_rows WHERE session_id=? AND name=?',
                variables: [Variable<String>(session), Variable<String>(name)],
              )
              .getSingle())
          .data;
  Future<Map<String, Object?>> snapshotExcept(Set<String> excluded) async =>
      Map<String, Object?>.from(jsonDecode(await base.snapshot()) as Map)
        ..removeWhere((key, _) => excluded.contains(key));

  Future<void> collector() async {
    final messages = [
      for (var i = 1; i <= 3; i++)
        ChatMessage(
          id: 'synthetic-message-$i',
          role: 'user',
          content: '$canary-$i',
        ),
    ];
    await (db.update(
      db.chatSessions,
    )..where((r) => r.sessionId.equals(session))).write(
      ChatSessionsCompanion(
        messagesJson: Value(
          jsonEncode(messages.map((m) => m.toJson()).toList()),
        ),
      ),
    );
    final runs = LedgerReconciliationRunRepo(db);
    var predecessor = '';
    final saved = <LedgerReconciliationSuccessfulRunRow>[];
    for (var i = 0; i < messages.length; i++) {
      final run = LedgerReconciliationRun(
        id: 'synthetic-reconciliation-${i + 1}',
        sessionId: session,
        ordinal: i + 1,
        anchors: [
          ReconciliationAnchor(
            messageId: messages[i].id,
            swipeId: messages[i].swipeId,
            agentSwipeId: messages[i].agentSwipeId,
            role: 'user',
            contentHash: computeHash(messages[i].content),
          ),
        ],
        acceptedManifestRefs: const [],
        effectiveCanonStamp: 'synthetic-canon',
        effectiveCanonRevision: 0,
        effectiveCanonHash: 'synthetic-canon-hash',
        canonicalResult: const {'ops': []},
        predecessorChainHash: predecessor,
        contractVersion: 1,
        opsApplied: const [],
        createdAt: 10 + i,
      );
      await db.transaction(() async {
        expect(await runs.append(run), isA<ReconciliationRunAppended>());
        final state = await runs.captureState(session);
        await runs.recordEffect(
          runId: run.id,
          sessionId: session,
          before: state,
          after: state,
          createdAt: 10 + i,
        );
      });
      predecessor = run.chainHash;
      saved.add((await runs.getByContentHash(session, run.contentHash))!);
    }
    await db
        .into(db.cardEvolutionCollectorRuns)
        .insert(
          CardEvolutionCollectorRunsCompanion.insert(
            id: 'synthetic-failed-collector',
            sessionId: session,
            characterId: 'legacy',
            collectorOrdinal: 1,
            reconciliationRunId: saved.last.id,
            reconciliationRunOrdinal: 3,
            reconciliationChainHash: saved.last.chainHash,
            rangeHash: CardEvolutionCollectorBatch(saved).rangeHash,
            inputHash: 'synthetic-input',
            ownerId: 'synthetic-owner',
            status: 'failed',
            leaseExpiresAt: 0,
            createdAt: 15,
            failedAt: const Value(16),
            failureCode: const Value('synthetic-parser'),
            failureDetail: const Value(canary),
          ),
        );
  }

  Future<void> observation({
    String status = 'active',
    bool malformed = false,
  }) => db
      .into(db.cardEvolutionObservations)
      .insert(
        CardEvolutionObservationsCompanion.insert(
          id: 'synthetic-observation',
          sessionId: session,
          characterId: 'legacy',
          runOrdinal: 1,
          semanticScopeKey: canary,
          observedChange: canary,
          evidenceMessageIds: '["synthetic-message-1"]',
          evidenceClustersJson: Value(
            malformed
                ? '{PRIVATE_MALFORMED_$canary'
                : '[["synthetic-message-1"]]',
          ),
          retrievalKeysJson: const Value('["world:location"]'),
          targetKind: const Value('main_character_card'),
          confidence: 0.5,
          status: status,
          firstSeenRun: 1,
          createdAt: 18,
          updatedAt: 18,
        ),
      )
      .then((_) {});

  Future<void> advanceHead() async {
    final runs = LedgerReconciliationRunRepo(db);
    final existing = await runs.readPhysicalSession(session);
    final head = existing.last;
    final run = LedgerReconciliationRun(
      id: 'synthetic-new-head',
      sessionId: session,
      ordinal: head.ordinal + 1,
      anchors: [
        // A distinct range of existing source messages, not a replay of run 1.
        // Native contentHash excludes id/ordinal/predecessor/createdAt: changing
        // only those cannot turn the first run's payload into a new append.
        // Keep the transcript unchanged so these cases exercise a head-only race.
        for (var i = 2; i <= 3; i++)
          ReconciliationAnchor(
            messageId: 'synthetic-message-$i',
            swipeId: 0,
            agentSwipeId: 0,
            role: 'user',
            contentHash: computeHash('$canary-$i'),
          ),
      ],
      acceptedManifestRefs: const [],
      effectiveCanonStamp: 'synthetic-canon',
      effectiveCanonRevision: 0,
      effectiveCanonHash: 'synthetic-canon-hash',
      canonicalResult: const {'ops': []},
      predecessorChainHash: head.chainHash,
      contractVersion: 1,
      opsApplied: const [],
      createdAt: 19,
    );
    expect(existing.any((row) => row.contentHash == run.contentHash), isFalse);
    await db.transaction(() async {
      expect(await runs.append(run), isA<ReconciliationRunAppended>());
      final state = await runs.captureState(session);
      await runs.recordEffect(
        runId: run.id,
        sessionId: session,
        before: state,
        after: state,
        createdAt: 19,
      );
      final audit = await runs.readSessionAudit(session);
      expect(audit.integrity, isA<ReconciliationRunValid>());
      expect(audit.physical.last.id, run.id);
      expect(audit.logical.last.id, run.id);
      expect(
        await runs.validateEffect(audit.logical.last),
        isA<ReconciliationEffectValid>(),
      );
    });
  }
}
