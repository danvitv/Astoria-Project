import 'dart:convert';

import 'package:drift/native.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_reconciliation_run_repo.dart';
import 'package:glaze_flutter/core/db/repositories/character_knowledge_fact_repo.dart';
import 'package:glaze_flutter/core/models/character_knowledge_fact.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/historical_message_window.dart';
import 'package:glaze_flutter/core/models/knowledge_cleanup.dart';
import 'package:glaze_flutter/core/utils/cast_helpers.dart';

void main() {
  late AppDatabase db;
  late LedgerReconciliationRunRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    repo = LedgerReconciliationRunRepo(db);
  });
  tearDown(() => db.close());

  test('appends genesis at ordinal one, replays exactly, and chains', () async {
    await _seedSession(db);
    final first = _run();
    expect(await repo.append(first), isA<ReconciliationRunAppended>());
    expect(await repo.append(first), isA<ReconciliationRunIdempotent>());
    final second = _run(
      id: 'run-2',
      ordinal: 2,
      predecessor: first.chainHash,
      result: const {
        'facts': ['second'],
      },
    );
    expect(await repo.append(second), isA<ReconciliationRunAppended>());
    expect((await repo.readSession('session')).map((r) => r.ordinal), [1, 2]);
    expect((await repo.getHead('session'))!.id, 'run-2');
  });

  test(
    'invalidated history cannot be imported with an unrelated marker',
    () async {
      final run = _run();
      final invalidation = LedgerReconciliationRunInvalidationRow(
        id: 0,
        sessionId: 'session',
        runId: 'another-run',
        causeMessageId: 'message',
        reason: 'message_deleted',
        createdAt: 2,
      );
      expect(
        await db.transaction(
          () => repo.restoreInvalidatedRun(run, invalidation),
        ),
        isA<ReconciliationRunMalformed>(),
      );
      expect(await repo.readPhysicalSession('session'), isEmpty);
      expect(await repo.readInvalidations('session'), isEmpty);
    },
  );

  test(
    'invalidated history retains contiguous chain and shape checks',
    () async {
      final invalidation = LedgerReconciliationRunInvalidationRow(
        id: 0,
        sessionId: 'session',
        runId: 'run-1',
        causeMessageId: 'message',
        reason: 'message_deleted',
        createdAt: 2,
      );
      expect(
        await db.transaction(
          () => repo.restoreInvalidatedRun(
            _run(ordinal: 2, predecessor: 'missing'),
            invalidation,
          ),
        ),
        isA<ReconciliationRunConcurrencyConflict>(),
      );
      expect(
        await db.transaction(
          () =>
              repo.restoreInvalidatedRun(_run(anchors: const []), invalidation),
        ),
        isA<ReconciliationRunMalformed>(),
      );
      expect(await repo.readPhysicalSession('session'), isEmpty);
      expect(await repo.readInvalidations('session'), isEmpty);
    },
  );

  test('candidate replay keeps the stored legacy identity', () async {
    await _seedSession(db);
    final stored = _run(id: 'legacy-id');
    expect(await repo.append(stored), isA<ReconciliationRunAppended>());

    expect(
      await repo.appendCandidate(_run(id: 'new-draft-id')),
      isA<ReconciliationRunIdempotent>(),
    );
    expect((await repo.getHead('session'))!.id, 'legacy-id');
  });

  test(
    'branch copy rebuilds session-bound identities without replacing source',
    () async {
      await _seedSession(db);
      await db.customStatement(
        "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) "
        "SELECT 'branch', character_id, 1, messages_json FROM chat_sessions WHERE session_id = 'session'",
      );
      final source = _run();
      expect(await repo.append(source), isA<ReconciliationRunAppended>());
      // The transfer carries each run's exact effect, so the source needs a
      // valid effect record before its run can cross into the branch.
      final state = await repo.captureState('session');
      await repo.recordEffect(
        runId: source.id,
        sessionId: 'session',
        before: state,
        after: state,
        createdAt: 1,
      );

      await repo.copyForSessionBranch(
        fromSessionId: 'session',
        toSessionId: 'branch',
        messageIds: {'message', 'user'},
      );

      final sourceRows = await repo.readSession('session');
      final branchRows = await repo.readSession('branch');
      expect(sourceRows.single.id, source.id);
      expect(branchRows, hasLength(1));
      expect(branchRows.single.id, isNot(source.id));
      expect(
        branchRows.single.id,
        'reconciliation-${branchRows.single.contentHash}',
      );
      expect(branchRows.single.sessionId, 'branch');
      expect(await repo.validateChain('branch'), isA<ReconciliationRunValid>());
    },
  );

  test(
    'branch copy re-keys accepted refs with complete provenance and hashes',
    () async {
      await _seedMultiMessageSession(db);
      await _seedVariationAt(db, assistantId: 'a1', userId: 'u1');
      await _seedVariationAt(db, assistantId: 'a2', userId: 'u2');
      final refs1 = await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_multiAnchor('a1', 'one')],
      );
      final refs2 = await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_multiAnchor('a2', 'two')],
      );
      final run1 = await _appendMultiRun(db, 1, 'a1', 'one', '', refs: refs1);
      final run2 = await _appendMultiRun(
        db,
        2,
        'a2',
        'two',
        run1.chainHash,
        refs: refs2,
      );
      await _appendMultiRun(db, 3, 'a3', 'three', run2.chainHash);
      await _recordMultiRunEffect(db, run1);
      await _recordMultiRunEffect(db, run2);
      // The branch transcript keeps a1..u2; run 3 anchors a3, which leaves
      // the retained set, so the copied chain must stop after run 2.
      await _insertBranchSession(db, 'branch', _multiMessages.take(4).toList());

      final transfer = await repo.copyForSessionBranch(
        fromSessionId: 'session',
        toSessionId: 'branch',
        messageIds: const {'a1', 'u1', 'a2', 'u2'},
      );

      expect(transfer, isNotNull);
      final copied = transfer!;
      expect(copied.copiedRuns, hasLength(2));
      expect(copied.copiedRuns.first.source.id, run1.id);
      expect(copied.copiedRuns.last.source.id, run2.id);
      expect(copied.branchOrdinalBySourceOrdinal, {1: 1, 2: 2});
      final branchRows = await repo.readSession('branch');
      expect(branchRows, hasLength(2));
      expect(
        jsonDecode(branchRows[0].acceptedManifestRefsJson),
        [
          {
            'acceptanceId': 'variation:branch:a1',
            'sessionId': 'branch',
            'messageId': 'a1',
            'swipeId': 0,
            'agentSwipeId': 0,
            'manifestHash': 'manifest-a1',
            'acceptedByUserMessageId': 'u1',
          },
        ],
      );
      expect(
        jsonDecode(branchRows[1].acceptedManifestRefsJson),
        [
          {
            'acceptanceId': 'variation:branch:a2',
            'sessionId': 'branch',
            'messageId': 'a2',
            'swipeId': 0,
            'agentSwipeId': 0,
            'manifestHash': 'manifest-a2',
            'acceptedByUserMessageId': 'u2',
          },
        ],
      );

      // Complete provenance exists at the branch coordinates.
      final branchManifests =
          await (db.select(db.lorebookUseManifests)
                ..where((row) => row.sessionId.equals('branch')))
              .get();
      expect(
        branchManifests.map((row) => (row.messageId, row.manifestHash)),
        containsAll(const [('a1', 'manifest-a1'), ('a2', 'manifest-a2')]),
      );
      final branchEntries =
          await (db.select(db.lorebookUseManifestEntries)
                ..where((row) => row.sessionId.equals('branch')))
              .get();
      expect(branchEntries, hasLength(2));
      expect(
        branchEntries.every((row) => row.evidenceJson == '{}'),
        isTrue,
      );
      final branchAcceptances =
          await (db.select(db.lorebookUseAcceptanceRecords)
                ..where((row) => row.sessionId.equals('branch')))
              .get();
      expect(
        branchAcceptances
            .map(
              (row) => (
                row.acceptanceId,
                row.acceptanceKind,
                row.acceptedByUserMessageId,
              ),
            )
            .toSet(),
        {
          ('variation:branch:a1', 'variation', 'u1'),
          ('variation:branch:a2', 'variation', 'u2'),
        },
      );

      // Chain hashes recompute exactly from the branch-bound projections.
      var predecessor = '';
      for (final (index, row) in branchRows.indexed) {
        final anchors = jsonDecode(row.anchorsJson);
        final refs = jsonDecode(row.acceptedManifestRefsJson);
        final result = jsonDecode(row.canonicalResultJson);
        final ops = jsonDecode(row.opsAppliedJson);
        final rangeHash = computeHash(_canonicalJson(anchors));
        final contentHash = computeHash(
          _canonicalJson({
            'anchorSchemaVersion': 1,
            'sessionId': 'branch',
            'anchors': anchors,
            'rangeHash': rangeHash,
            'acceptedManifestRefs': refs,
            'effectiveCanonStamp': row.effectiveCanonStamp,
            'effectiveCanonRevision': row.effectiveCanonRevision,
            'effectiveCanonHash': row.effectiveCanonHash,
            'canonicalResult': result,
            'cleanupOps': ops,
            'contractVersion': row.contractVersion,
          }),
        );
        final chainHash = computeHash(
          _canonicalJson({
            'sessionId': 'branch',
            'ordinal': row.ordinal,
            'predecessorChainHash': predecessor,
            'contentHash': contentHash,
          }),
        );
        expect(row.rangeHash, rangeHash);
        expect(row.contentHash, contentHash);
        expect(row.chainHash, chainHash);
        expect(row.predecessorChainHash, predecessor);
        expect(row.id, 'reconciliation-$contentHash');
        expect(row.createdAt, index == 0 ? run1.createdAt : run2.createdAt);
        predecessor = chainHash;
      }
      expect(await repo.validateChain('branch'), isA<ReconciliationRunValid>());
      // The source session keeps its own immutable history.
      expect((await repo.readSession('session')).map((r) => r.id), [
        run1.id,
        run2.id,
        'multi-run-3',
      ]);
    },
  );

  test(
    'branch copy stops at the first run whose refs leave the branch',
    () async {
      await _seedMultiMessageSession(db);
      await _seedVariationAt(db, assistantId: 'a1', userId: 'u1');
      await _seedVariationAt(db, assistantId: 'a2', userId: 'u2');
      final refs1 = await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_multiAnchor('a1', 'one')],
      );
      final refs2 = await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_multiAnchor('a2', 'two')],
      );
      final run1 = await _appendMultiRun(db, 1, 'a1', 'one', '', refs: refs1);
      await _appendMultiRun(db, 2, 'a2', 'two', run1.chainHash, refs: refs2);
      await _recordMultiRunEffect(db, run1);
      // The branch transcript keeps a1, u1 and a2 but drops u2, the accepting
      // user message of run 2's ref: run 2 is the first run that cannot be
      // proven inside the branch.
      await _insertBranchSession(db, 'branch', _multiMessages.take(3).toList());

      final transfer = await repo.copyForSessionBranch(
        fromSessionId: 'session',
        toSessionId: 'branch',
        messageIds: const {'a1', 'u1', 'a2'},
      );

      expect(transfer, isNotNull);
      expect(transfer!.copiedRuns, hasLength(1));
      expect(transfer.copiedRuns.single.source.id, run1.id);
      final branchRows = await repo.readSession('branch');
      expect(branchRows, hasLength(1));
      expect(branchRows.single.startMessageId, 'a1');
    },
  );

  test(
    'branch copy carries exact effects and fails closed without one',
    () async {
      await _seedMultiMessageSession(db);
      await _seedVariationAt(db, assistantId: 'a1', userId: 'u1');
      final refs1 = await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_multiAnchor('a1', 'one')],
      );
      final run1 = await _appendMultiRun(db, 1, 'a1', 'one', '', refs: refs1);
      final run2 = await _appendMultiRun(db, 2, 'a2', 'two', run1.chainHash);
      final run3 = await _appendMultiRun(db, 3, 'a3', 'three', run2.chainHash);
      await _recordMultiRunEffect(db, run1);
      await _recordMultiRunEffect(db, run2);
      // run 3 has no exact effect: the whole transfer must fail closed.
      await _insertBranchSession(db, 'branch', _multiMessages);

      await expectLater(
        db.transaction(() => repo.copyForSessionBranch(
              fromSessionId: 'session',
              toSessionId: 'branch',
              messageIds: const {'a1', 'u1', 'a2', 'u2', 'a3', 'u3'},
            )),
        throwsStateError,
      );
      expect(await repo.readPhysicalSession('branch'), isEmpty);
      expect(
        await (db.select(db.lorebookUseManifests)
              ..where((row) => row.sessionId.equals('branch')))
            .get(),
        isEmpty,
      );

      // With every effect present the copies validate against their state.
      await _recordMultiRunEffect(db, run3);
      final transfer = await repo.copyForSessionBranch(
        fromSessionId: 'session',
        toSessionId: 'branch',
        messageIds: const {'a1', 'u1', 'a2', 'u2', 'a3', 'u3'},
      );
      expect(transfer, isNotNull);
      final copied = transfer!;
      expect(copied.copiedRuns, hasLength(3));
      final branchRows = await repo.readSession('branch');
      final sourceRows = await repo.readPhysicalSession('session');
      for (final (index, branchRow) in branchRows.indexed) {
        final sourceRow = sourceRows.singleWhere(
          (row) => row.id == copied.copiedRuns[index].source.id,
        );
        final sourceEffect = (await repo.readEffect(sourceRow.id))!;
        final branchEffect = await repo.readEffect(branchRow.id);
        expect(branchEffect, isNotNull);
        expect(branchEffect!.sessionId, 'branch');
        expect(branchEffect.beforeLedgerJson, sourceEffect.beforeLedgerJson);
        expect(branchEffect.afterLedgerJson, sourceEffect.afterLedgerJson);
        expect(branchEffect.beforeStateHash, sourceEffect.beforeStateHash);
        expect(branchEffect.afterStateHash, sourceEffect.afterStateHash);
        expect(branchEffect.effectsHash, sourceEffect.effectsHash);
        expect(
          await repo.validateEffect(branchRow),
          isA<ReconciliationEffectValid>(),
        );
      }
    },
  );

  test(
    'rejects anchor mutations and immutable content-hash collisions',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      expect(
        await repo.append(_run(id: 'other', createdAt: 2)),
        isA<ReconciliationRunConflict>(),
      );
      expect(
        await repo.append(
          _run(
            id: 'bad',
            anchors: [_anchor(content: 'wrong')],
          ),
        ),
        isA<ReconciliationRunMalformed>(),
      );
    },
  );

  test('content hash binds every canonical evidence projection', () {
    final baseline = _run();
    final anchor = _anchor();
    final variants = [
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: 1,
            agentSwipeId: anchor.agentSwipeId,
            role: anchor.role,
            contentHash: anchor.contentHash,
          ),
        ],
      ),
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: anchor.swipeId,
            agentSwipeId: 1,
            role: anchor.role,
            contentHash: anchor.contentHash,
          ),
        ],
      ),
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: anchor.swipeId,
            agentSwipeId: anchor.agentSwipeId,
            role: 'user',
            contentHash: anchor.contentHash,
          ),
        ],
      ),
      _run(
        anchors: [
          ReconciliationAnchor(
            messageId: anchor.messageId,
            swipeId: anchor.swipeId,
            agentSwipeId: anchor.agentSwipeId,
            role: anchor.role,
            contentHash: 'other',
          ),
        ],
      ),
      _run(
        anchors: [
          _anchor(),
          _anchor(messageId: 'later'),
        ],
      ),
      _run(
        acceptedManifestRefs: const [
          AcceptedManifestRef(
            sessionId: 'session',
            messageId: 'message',
            swipeId: 0,
            agentSwipeId: 0,
            manifestHash: 'manifest',
            acceptanceId: 'acceptance',
            acceptedByUserMessageId: 'user',
          ),
        ],
      ),
      _run(effectiveCanonStamp: 'other-stamp'),
      _run(effectiveCanonHash: 'other-canon'),
      _run(
        result: const {
          'facts': ['other'],
        },
      ),
    ];
    for (final variant in variants) {
      expect(variant.contentHash, isNot(baseline.contentHash));
    }
  });

  test(
    'stored malformed JSON and predecessor chain mismatch fail closed',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      await db.customStatement(
        'DROP TRIGGER reconciliation_successful_runs_no_update',
      );
      await db.customStatement(
        "UPDATE reconciliation_successful_runs SET anchors_json = '[]' WHERE id = 'run-1'",
      );
      expect(await repo.readSession('session'), isEmpty);

      await db.customStatement(
        "UPDATE reconciliation_successful_runs SET anchors_json = ?, range_hash = ?, content_hash = ?, chain_hash = ?, predecessor_chain_hash = 'wrong' WHERE id = 'run-1'",
        [
          first.anchorsJson,
          first.rangeHash,
          first.contentHash,
          first.chainHash,
        ],
      );
      expect(
        await repo.validateChain('session'),
        isA<ReconciliationRunChainGap>(),
      );
      expect(await repo.readSession('session'), isEmpty);
    },
  );

  test(
    'read excludes invalidations and cursor genesis fails closed on gap',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      await db.customStatement(
        "INSERT INTO reconciliation_run_invalidations "
        "(session_id, run_id, cause_message_id, reason, created_at) "
        "VALUES ('session', 'run-1', 'message', 'deleted', 1)",
      );
      expect(await repo.readSession('session'), isEmpty);
      final hash = _cursorHash(sequence: 1, predecessor: '');
      await db.customStatement(
        "INSERT INTO ledger_reconciliation_cursors VALUES "
        "('session', 1, '', 'run-1', 1, 'chain-1', '$hash', 1)",
      );
      expect(await repo.readCursors('session'), isEmpty);
      await db.customStatement(
        "INSERT INTO ledger_reconciliation_cursors VALUES "
        "('session', 3, '$hash', 'run-3', 3, 'chain-3', 'bad', 1)",
      );
      expect(await repo.readCursors('session'), isEmpty);
    },
  );

  test('serializes all seven authoritative variation-ref fields', () async {
    await _seedSession(db);
    await _seedVariationEvidence(db);
    final refs = await repo.readAcceptedManifestRefs(
      sessionId: 'session',
      anchors: [_anchor()],
    );
    expect(refs, hasLength(1));
    expect(refs.single.toJson(), {
      'acceptanceId': 'variation:session:user',
      'sessionId': 'session',
      'messageId': 'message',
      'swipeId': 0,
      'agentSwipeId': 0,
      'manifestHash': 'manifest-hash',
      'acceptedByUserMessageId': 'user',
    });
    expect(jsonDecode(_run(acceptedManifestRefs: refs).manifestsJson), [
      refs.single.toJson(),
    ]);
  });

  test('selection-only evidence emits no accepted manifest refs', () async {
    await _seedSession(db);
    await _seedVariationEvidence(db, kind: 'selection');
    // The immutable schema requires a variation before recording selection;
    // remove it after insertion to leave selection-only durable evidence.
    await db.customStatement(
      "DELETE FROM lorebook_use_acceptance_records "
      "WHERE acceptance_id = 'variation:session:user'",
    );
    expect(
      await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_anchor()],
      ),
      isEmpty,
    );
  });

  test('stored run survives deletion of its trailing accepting user', () async {
    await _seedSession(db);
    await _seedVariationEvidence(db);
    final refs = await repo.readAcceptedManifestRefs(
      sessionId: 'session',
      anchors: [_anchor()],
    );
    expect(
      await repo.append(_run(acceptedManifestRefs: refs)),
      isA<ReconciliationRunAppended>(),
    );

    await db.customStatement(
      "DELETE FROM lorebook_use_acceptance_records WHERE acceptance_id = 'variation:session:user'",
    );
    await db.customStatement(
      "UPDATE chat_sessions SET messages_json = '[{\"id\":\"message\",\"role\":\"assistant\",\"content\":\"canonical\",\"swipes\":[\"canonical\"],\"agentSwipes\":[]}]' WHERE session_id = 'session'",
    );

    expect((await repo.getHead('session'))?.id, 'run-1');
  });

  test(
    'wrong acceptance identity, accepting user, or manifest rejects append',
    () async {
      await _seedSession(db);
      await _seedVariationEvidence(db);
      final ref = (await repo.readAcceptedManifestRefs(
        sessionId: 'session',
        anchors: [_anchor()],
      )).single;
      for (final bad in [
        AcceptedManifestRef(
          acceptanceId: 'wrong',
          sessionId: 'session',
          messageId: 'message',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: 'manifest-hash',
          acceptedByUserMessageId: 'user',
        ),
        AcceptedManifestRef(
          acceptanceId: ref.acceptanceId,
          sessionId: 'session',
          messageId: 'message',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: 'manifest-hash',
          acceptedByUserMessageId: 'missing-user',
        ),
        AcceptedManifestRef(
          acceptanceId: ref.acceptanceId,
          sessionId: 'session',
          messageId: 'message',
          swipeId: 0,
          agentSwipeId: 0,
          manifestHash: 'wrong-hash',
          acceptedByUserMessageId: 'user',
        ),
      ]) {
        expect(
          await repo.append(
            _run(
              id: 'bad-${bad.acceptanceId}-${bad.manifestHash}',
              acceptedManifestRefs: [bad],
            ),
          ),
          isA<ReconciliationRunMalformed>(),
        );
      }
      expect(await repo.readSession('session'), isEmpty);
    },
  );

  test(
    'invalidated physical head allocates ordinal two with predecessor',
    () async {
      await _seedSession(db);
      final first = _run();
      expect(await repo.append(first), isA<ReconciliationRunAppended>());
      await db.customStatement(
        "INSERT INTO reconciliation_run_invalidations "
        "(session_id, run_id, cause_message_id, reason, created_at) "
        "VALUES ('session', 'run-1', 'message', 'deleted', 1)",
      );
      final candidate = _run(
        id: 'run-2',
        result: const {
          'facts': ['distinct'],
        },
      );
      expect(
        await repo.appendCandidate(candidate),
        isA<ReconciliationRunAppended>(),
      );
      final rows = await db.select(db.ledgerReconciliationSuccessfulRuns).get();
      final second = rows.singleWhere(
        (row) => row.contentHash == candidate.contentHash,
      );
      expect(second.ordinal, 2);
      expect(second.predecessorChainHash, first.chainHash);
    },
  );

  test('replacement invalidation requires the exact logical head', () async {
    await _seedSession(db);
    final first = _run();
    expect(await repo.append(first), isA<ReconciliationRunAppended>());

    expect(
      await repo.invalidateLatestForReplacement(
        sessionId: 'session',
        expectedRunId: 'other',
        expectedChainHash: first.chainHash,
        createdAt: 2,
      ),
      isA<ReconciliationHeadInvalidationConflict>(),
    );
    expect((await repo.getHead('session'))!.id, first.id);

    expect(
      await repo.invalidateLatestForReplacement(
        sessionId: 'session',
        expectedRunId: first.id,
        expectedChainHash: first.chainHash,
        createdAt: 3,
      ),
      isA<ReconciliationHeadInvalidated>(),
    );
    expect(await repo.getHead('session'), isNull);
    expect((await repo.readPhysicalSession('session')).single.id, first.id);
    final invalidation = (await repo.readInvalidations('session')).single;
    expect(invalidation.reason, 'latest_head_replaced');
    expect(invalidation.causeMessageId, first.end.messageId);
  });

  test('message mutation invalidates anchored run suffix, not trigger', () async {
    await _seedSession(db);
    final first = _run();
    expect(await repo.append(first), isA<ReconciliationRunAppended>());

    expect(
      await repo.invalidateForMessageMutation(
        sessionId: 'session',
        messageIds: {'user'},
        reason: 'message_deleted',
        createdAt: 2,
      ),
      isEmpty,
    );
    expect((await repo.getHead('session'))?.id, 'run-1');

    final invalidated = await repo.invalidateForMessageMutation(
      sessionId: 'session',
      messageIds: {'message'},
      reason: 'message_deleted',
      createdAt: 3,
    );
    expect(invalidated, ['run-1']);
    expect(await repo.getHead('session'), isNull);

    await db.customStatement(
      "UPDATE chat_sessions SET messages_json = '[{\"id\":\"user\",\"role\":\"user\",\"content\":\"accepted\"}]' WHERE session_id = 'session'",
    );
    expect(await repo.validateChain('session'), isA<ReconciliationRunValid>());
  });

  test('records immutable canonical before and after effects', () async {
    await db
        .into(db.trackerRows)
        .insert(
          TrackerRowsCompanion.insert(
            sessionId: 'session',
            name: 'world:time',
            value: const Value('before'),
            scope: const Value('ledger'),
          ),
        );
    final before = await repo.captureState('session');
    await (db.update(db.trackerRows)
          ..where((row) => row.sessionId.equals('session'))
          ..where((row) => row.name.equals('world:time')))
        .write(const TrackerRowsCompanion(value: Value('after')));
    final after = await repo.captureState('session');

    await repo.recordEffect(
      runId: 'run-1',
      sessionId: 'session',
      before: before,
      after: after,
      createdAt: 1,
    );

    final effect = await repo.readEffect('run-1');
    expect(effect, isNotNull);
    expect(effect!.beforeStateHash, before.hash);
    expect(effect.afterStateHash, after.hash);
    final diff = jsonDecode(effect.actualEffectsJson) as Map<String, dynamic>;
    final ledger = diff['ledger'] as Map<String, dynamic>;
    expect(ledger['changed'], hasLength(1));
    expect(
      ((ledger['changed'] as List).single as Map)['before']['value'],
      'before',
    );
    expect(
      ((ledger['changed'] as List).single as Map)['after']['value'],
      'after',
    );
    expect(
      () => db
          .update(db.ledgerReconciliationEffects)
          .write(
            const LedgerReconciliationEffectsCompanion(
              effectsHash: Value('changed'),
            ),
          ),
      throwsA(anything),
    );
  });

  test(
    'historical knowledge unwinds exact effects without replaying cleanup',
    () async {
      await _seedSession(db);
      final facts = CharacterKnowledgeFactRepo(db);
      await facts.insertTentative(
        const CharacterKnowledgeFact(
          id: 'known',
          chatSessionId: 'session',
          knowerKey: 'alice',
          subjectKey: 'stranger',
          factClass: CharacterKnowledgeFactClass.knowledge,
          predicate: 'met',
          object: 'at the gate',
          epistemicState: CharacterKnowledgeEpistemicState.observed,
          sourceMessageId: 'earlier',
          sourceSwipeId: 0,
          sourceAgentSwipeId: 0,
        ),
      );
      var predecessor = '';
      for (var ordinal = 1; ordinal <= 2; ordinal++) {
        final run = _run(
          id: 'run-$ordinal',
          ordinal: ordinal,
          predecessor: predecessor,
          result: {'rename': ordinal},
        );
        expect(await repo.append(run), isA<ReconciliationRunAppended>());
        final before = await repo.captureState('session');
        await facts.applyReconciliationCleanup(
          sessionId: 'session',
          endpointMessageId: 'message',
          messageIds: ['message'],
          ops: [
            KnowledgeCleanupOp.renameEntity(
              fromKey: ordinal == 1 ? 'stranger' : 'guard',
              toKey: ordinal == 1 ? 'guard' : 'prince',
              canonicalName: ordinal == 1 ? 'Guard' : 'Prince',
            ),
          ],
        );
        await repo.recordEffect(
          runId: run.id,
          sessionId: 'session',
          before: before,
          after: await repo.captureState('session'),
          createdAt: ordinal,
        );
        predecessor = run.chainHash;
      }
      final live = await repo.captureState('session');
      final historical = await facts.getForHistoricalWindow(
        'session',
        HistoricalMessageWindow([
          const ChatMessage(
            id: 'earlier',
            role: 'assistant',
            content: 'A stranger waits.',
          ),
        ]),
      );
      expect(historical.single.subjectKey, 'stranger');
      expect(
        (await facts.getReviewableForSession('session')).single.subjectKey,
        'prince',
      );
      expect(await repo.currentStateMatches('session', live), isTrue);
    },
  );

  test('validates exact effects and reconstructs anchored messages', () async {
    await _seedSession(db);
    final run = _run();
    expect(await repo.append(run), isA<ReconciliationRunAppended>());
    final before = await repo.captureState('session');
    await repo.recordEffect(
      runId: run.id,
      sessionId: run.sessionId,
      before: before,
      after: before,
      createdAt: 1,
    );

    final validation = await repo.validateEffect(
      (await repo.readPhysicalSession('session')).single,
    );
    expect(validation, isA<ReconciliationEffectValid>());
    expect(await repo.currentStateMatches('session', before), isTrue);
    final selected = await repo.reconstructSelectedMessages(
      (await repo.readPhysicalSession('session')).single,
    );
    expect(selected, hasLength(1));
    expect(selected!.single.id, 'message');
    expect(selected.single.content, 'canonical');

    await db.customStatement(
      "UPDATE chat_sessions SET messages_json = '[{\"id\":\"message\",\"role\":\"assistant\",\"content\":\"changed\",\"swipes\":[\"changed\"],\"agentSwipes\":[]},{\"id\":\"user\",\"role\":\"user\",\"content\":\"accepted\"}]' WHERE session_id = 'session'",
    );
    expect(
      await repo.reconstructSelectedMessages(
        (await repo.readPhysicalSession('session')).single,
      ),
      isNull,
    );
  });

  test('effect validation rejects tampered state hashes', () async {
    await _seedSession(db);
    final run = _run();
    expect(await repo.append(run), isA<ReconciliationRunAppended>());
    final state = await repo.captureState('session');
    await repo.recordEffect(
      runId: run.id,
      sessionId: run.sessionId,
      before: state,
      after: state,
      createdAt: 1,
    );
    await db.customStatement(
      'DROP TRIGGER ledger_reconciliation_effects_no_update',
    );
    await db.customStatement(
      "UPDATE ledger_reconciliation_effects SET after_state_hash = 'tampered' WHERE run_id = 'run-1'",
    );

    final validation = await repo.validateEffect(
      (await repo.readPhysicalSession('session')).single,
    );
    expect(validation, isA<ReconciliationEffectInvalid>());
  });

  test(
    'legacy stale evidence hides logical suffix without breaking chain',
    () async {
      await _seedSession(db);
      expect(await repo.append(_run()), isA<ReconciliationRunAppended>());
      await db.customStatement(
        "UPDATE chat_sessions SET messages_json = '[{\"id\":\"user\",\"role\":\"user\",\"content\":\"accepted\"}]' WHERE session_id = 'session'",
      );
      expect(
        await repo.validateChain('session'),
        isA<ReconciliationRunValid>(),
      );
      expect(await repo.readSession('session'), isEmpty);
      expect(await repo.getHead('session'), isNull);
    },
  );
}

Future<void> _seedSession(AppDatabase db) => db.customStatement(
  "INSERT INTO chat_sessions (session_id, character_id, session_index, messages_json) "
  "VALUES ('session', 'character', 0, '[{\"id\":\"message\",\"role\":\"assistant\",\"content\":\"canonical\",\"swipes\":[\"canonical\"],\"agentSwipes\":[]},{\"id\":\"user\",\"role\":\"user\",\"content\":\"accepted\"}]')",
);

/// A six-message transcript: three accepted assistant variations.
const _multiMessages = [
  {
    'id': 'a1',
    'role': 'assistant',
    'content': 'one',
    'swipes': ['one'],
    'agentSwipes': <Object>[],
  },
  {'id': 'u1', 'role': 'user', 'content': 'accept one'},
  {
    'id': 'a2',
    'role': 'assistant',
    'content': 'two',
    'swipes': ['two'],
    'agentSwipes': <Object>[],
  },
  {'id': 'u2', 'role': 'user', 'content': 'accept two'},
  {
    'id': 'a3',
    'role': 'assistant',
    'content': 'three',
    'swipes': ['three'],
    'agentSwipes': <Object>[],
  },
  {'id': 'u3', 'role': 'user', 'content': 'accept three'},
];

Future<void> _seedMultiMessageSession(AppDatabase db) => db.customStatement(
  'INSERT INTO chat_sessions (session_id, character_id, session_index, '
  'messages_json) VALUES (?, ?, 0, ?)',
  ['session', 'character', jsonEncode(_multiMessages)],
);

Future<void> _insertBranchSession(
  AppDatabase db,
  String sessionId,
  List<Map<String, Object?>> messages,
) => db.customStatement(
  'INSERT INTO chat_sessions (session_id, character_id, session_index, '
  'messages_json) VALUES (?, ?, 1, ?)',
  [sessionId, 'character', jsonEncode(messages)],
);

Future<void> _seedVariationAt(
  AppDatabase db, {
  required String assistantId,
  required String userId,
}) async {
  await db.customStatement(
    'INSERT INTO lorebook_use_manifests '
    '(session_id, message_id, swipe_id, agent_swipe_id, manifest_json, '
    'manifest_hash, manifest_schema_version, final_prompt_hash, '
    'preset_snapshot_hash, created_at) '
    "VALUES ('session', ?, 0, 0, '{}', ?, 1, 'prompt', 'preset', 1)",
    [assistantId, 'manifest-$assistantId'],
  );
  await db.customStatement(
    'INSERT INTO lorebook_use_manifest_entries '
    '(session_id, message_id, swipe_id, agent_swipe_id, lorebook_id, '
    'entry_id, entry_order, evidence_json) '
    "VALUES ('session', ?, 0, 0, 'book', 'entry', 0, '{}')",
    [assistantId],
  );
  await db.customStatement(
    'INSERT INTO lorebook_use_acceptance_records '
    '(acceptance_id, session_id, message_id, swipe_id, agent_swipe_id, '
    'acceptance_kind, accepted_by_user_message_id, evidence_json, '
    'accepted_at) '
    "VALUES (?, 'session', ?, 0, 0, 'variation', ?, '{}', 1)",
    ['variation:session:$userId', assistantId, userId],
  );
}

ReconciliationAnchor _multiAnchor(String messageId, String content) =>
    ReconciliationAnchor(
      messageId: messageId,
      swipeId: 0,
      agentSwipeId: 0,
      role: 'assistant',
      contentHash: computeHash(content),
    );

Future<LedgerReconciliationRun> _appendMultiRun(
  AppDatabase db,
  int ordinal,
  String anchorId,
  String content,
  String predecessor, {
  List<AcceptedManifestRef>? refs,
}) async {
  final run = LedgerReconciliationRun(
    id: 'multi-run-$ordinal',
    sessionId: 'session',
    ordinal: ordinal,
    anchors: [_multiAnchor(anchorId, content)],
    acceptedManifestRefs: refs ?? const [],
    effectiveCanonStamp: 'stamp-$ordinal',
    effectiveCanonRevision: 1,
    effectiveCanonHash: 'canon-$ordinal',
    canonicalResult: {'facts': ['fact-$ordinal']},
    predecessorChainHash: predecessor,
    contractVersion: 1,
    opsApplied: const [],
    createdAt: ordinal,
  );
  expect(
    await LedgerReconciliationRunRepo(db).append(run),
    isA<ReconciliationRunAppended>(),
  );
  return run;
}

Future<void> _recordMultiRunEffect(
  AppDatabase db,
  LedgerReconciliationRun run,
) async {
  final repo = LedgerReconciliationRunRepo(db);
  final before = await repo.captureState('session');
  await db
      .into(db.trackerRows)
      .insert(
        TrackerRowsCompanion.insert(
          sessionId: 'session',
          name: 'world:entry-${run.ordinal}',
          value: Value('value-${run.ordinal}'),
          scope: const Value('ledger'),
        ),
      );
  await repo.recordEffect(
    runId: run.id,
    sessionId: 'session',
    before: before,
    after: await repo.captureState('session'),
    createdAt: run.createdAt,
  );
}

/// Independently mirrors the repo's canonical JSON: sorted keys recursively,
/// compact separators, so hash recomputation in tests does not reuse the
/// production implementation.
String _canonicalJson(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return '{${keys.map((key) => '${jsonEncode(key)}:${_canonicalJson(value[key])}').join(',')}}';
  }
  if (value is List) {
    return '[${value.map(_canonicalJson).join(',')}]';
  }
  return jsonEncode(value);
}

Future<void> _seedVariationEvidence(
  AppDatabase db, {
  String kind = 'variation',
}) async {
  await db.customStatement(
    "INSERT INTO lorebook_use_manifests "
    "(session_id,message_id,swipe_id,agent_swipe_id,manifest_json,manifest_hash,manifest_schema_version,final_prompt_hash,preset_snapshot_hash,created_at) "
    "VALUES ('session','message',0,0,'{}','manifest-hash',1,'prompt','preset',1)",
  );
  final selection = kind == 'selection';
  if (selection) {
    await db.customStatement(
      "INSERT INTO lorebook_use_manifest_entries "
      "(session_id,message_id,swipe_id,agent_swipe_id,lorebook_id,entry_id,entry_order,evidence_json) "
      "VALUES ('session','message',0,0,'book','entry',0,'{}')",
    );
    await db.customStatement(
      "INSERT INTO lorebook_use_acceptance_records "
      "(acceptance_id,session_id,message_id,swipe_id,agent_swipe_id,acceptance_kind,accepted_by_user_message_id,evidence_json,accepted_at) "
      "VALUES ('variation:session:user','session','message',0,0,'variation','user','{}',1)",
    );
  }
  await db.customStatement(
    "INSERT INTO lorebook_use_acceptance_records "
    "(acceptance_id,session_id,message_id,swipe_id,agent_swipe_id,acceptance_kind,accepted_by_user_message_id,selected_lorebook_id,selected_entry_id,selected_entry_order,evidence_json,accepted_at) VALUES "
    "('${selection ? 'selection:session:message' : 'variation:session:user'}','session','message',0,0,'$kind',${selection ? 'NULL' : "'user'"},${selection ? "'book'" : 'NULL'},${selection ? "'entry'" : 'NULL'},${selection ? '0' : 'NULL'},'{}',1)",
  );
}

ReconciliationAnchor _anchor({
  String messageId = 'message',
  String content = 'canonical',
}) => ReconciliationAnchor(
  messageId: messageId,
  swipeId: 0,
  agentSwipeId: 0,
  role: 'assistant',
  contentHash: computeHash(content),
);

LedgerReconciliationRun _run({
  String id = 'run-1',
  int ordinal = 1,
  String predecessor = '',
  List<ReconciliationAnchor>? anchors,
  List<AcceptedManifestRef>? acceptedManifestRefs,
  String effectiveCanonStamp = 'stamp',
  String effectiveCanonHash = 'canon',
  Map<String, dynamic> result = const {'facts': <String>[]},
  int createdAt = 1,
}) => LedgerReconciliationRun(
  id: id,
  sessionId: 'session',
  ordinal: ordinal,
  anchors: anchors ?? [_anchor()],
  acceptedManifestRefs: acceptedManifestRefs ?? const [],
  effectiveCanonStamp: effectiveCanonStamp,
  effectiveCanonRevision: 1,
  effectiveCanonHash: effectiveCanonHash,
  canonicalResult: result,
  predecessorChainHash: predecessor,
  contractVersion: 1,
  opsApplied: const [],
  createdAt: createdAt,
);

String _cursorHash({required int sequence, required String predecessor}) =>
    computeHash(
      jsonEncode({
        'predecessorHash': predecessor,
        'sequence': sequence,
        'sessionId': 'session',
        'throughRunChainHash': 'chain-$sequence',
        'throughRunId': 'run-$sequence',
        'throughRunOrdinal': sequence,
      }),
    );
