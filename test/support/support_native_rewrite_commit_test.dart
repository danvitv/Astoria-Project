import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/ledger_raw_tracker_state_reader.dart';
import 'package:glaze_flutter/core/db/repositories/manual_rewrite_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';
import 'package:glaze_flutter/core/services/card_rewriter/card_rewriter_contracts.dart';
import 'package:sqlite3/sqlite3.dart' as sqlite;

import 'helpers/support_native_input_fixture.dart';

// Direct repository execution only: no mounted review, provider/app root, model,
// files, sockets, production migrations, preferences or OS credential storage.
// Both native constructors retain their ORIGINAL send fence from construction.
const _jobId = 'synthetic-commit-rewrite-job';
const _operationId = 'synthetic-commit-rewrite-operation';
const _journalId = 'synthetic-commit-rewrite-journal';
const _unselectedId = 'synthetic-commit-unselected-operation';
const _foreignJobId = 'synthetic-commit-foreign-job';
const _foreignOperationId = 'synthetic-commit-foreign-operation';
const _boundaryTimeout = Duration(seconds: 5);
const _unknownRaw =
    '"unknownNative":{"rawNumber":1.2300e+02,"private":"SYNTHETIC_UNKNOWN_REWRITE_CANARY"},';

void main() {
  for (final undo in [false, true]) {
    for (final fault in [
      'confirmedRollback',
      'undeliveredRollback',
      'sqliteCommitHookVeto',
      'deliveredRetired',
      'deliveredAuthorityRetired',
      'deliveredThenThrow',
    ]) {
      test(
        'native ${undo ? 'Undo' : 'Reject'} $fault distinguishes fact from custody',
        () => _commitCase(undo: undo, fault: fault),
        timeout: const Timeout(Duration(seconds: 30)),
      );
    }
  }

  test(
    'original memory Reject -> fresh genuine Undo restores exact pending decision',
    () async {
      // Exercise the unchanged default nativeMemoryForTesting composition too.
      final f = NativeInputFixture();
      try {
        final repo = _repo(f);
        final initial = await _seed(f, repo);
        final before = await f.snapshot();
        final observed = await _observeReject(repo, initial);
        final result = await _reject(f, repo, observed);
        expect(result, isNotNull);
        final receipt = result!;
        expect(receipt.current, true);
        expect(
          receipt.priorDecisionRevision,
          _selected(initial).operation.decisionRevision,
        );
        expect(observed.current, false);
        final rejected = (await repo.getJobSnapshot(_jobId))!;
        final selected = _selected(rejected);
        expect(selected.operation.decision, 'rejected');
        final observation = await repo.observeNativeRejectUndo(
          receipt: receipt,
          loaded: rejected,
          selected: selected,
          isCurrent: () => true,
        );
        expect(observation, isNotNull);
        final fresh = observation!;
        expect(fresh.current, true);
        final commit = await _undo(f, repo, receipt, fresh);
        expect(commit, isNotNull);
        expect(commit!.current, true);
        expect(receipt.current, false);
        expect(fresh.current, false);
        final restored = (await repo.getJobSnapshot(_jobId))!;
        expect(
          restored.job,
          initial.job.copyWith(
            version: initial.job.version + 2,
            updatedAt: restored.job.updatedAt,
          ),
        );
        expect(
          _selected(restored).operation,
          _selected(initial).operation.copyWith(
            updatedAt: _selected(restored).operation.updatedAt,
          ),
        );
        expect(_selected(restored).operation.decision, 'pending');
        expect(
          _selected(restored).operation.decisionRevision,
          receipt.priorDecisionRevision,
        );
        expect(
          _selected(restored).currentSnapshotJson,
          _selected(initial).currentSnapshotJson,
        );
        expect(_otherRawRows(f, await f.snapshot()), _otherRawRows(f, before));
        await _journalFact(f, undo: true);
        expect(f.sql.outerSendErrors, isEmpty);
      } finally {
        await f.close();
      }
    },
    timeout: const Timeout(Duration(seconds: 30)),
  );
}

Future<void> _commitCase({required bool undo, required String fault}) async {
  final raw = sqlite.sqlite3.openInMemory();
  var armed = false;
  var originalAuthority = true;
  var previousCalls = 0, nativeCommitCalls = 0;
  ManualRewriteJobRepo? originalRepo;
  // Install ONLY the previous hook, before constructing the original fence.
  // This callback changes process-local authority, never SQL/connection state.
  raw.commitFilter = () {
    previousCalls++;
    if (armed) {
      nativeCommitCalls++;
      if (fault == 'sqliteCommitHookVeto') {
        originalRepo!.retireNativeReview(_jobId);
      }
    }
    return true; // The ORIGINAL fence, not this previous hook, must veto.
  };
  final f = NativeInputFixture(originalNativeConnection: raw);
  final installedFilter = raw.commitFilter;
  Future<void> Function()? retainedRollback;
  Future<void>? rollbackCleanup;
  var beforeSends = 0, deliveredSends = 0;
  var rollbackCalls = 0, rollbackDelegations = 0, rollbackDeliveries = 0;
  final rollbackAutocommit = <bool>[];
  final rollbackErrors = <Object>[];
  ManualRewriteNativeRejectReceipt? receipt, returnedReceipt;
  ManualRewriteNativeUndoObservation? freshUndo;
  ManualRewriteNativeUndoCommit? returnedUndo;
  Object? operationError;

  // Cleanup is the retained SAME original executor, not a root ROLLBACK, a
  // replacement transaction, or a boolean claiming the failed op rolled back.
  Future<void> releaseRollback() async {
    final original = retainedRollback;
    if (original == null) return;
    rollbackCleanup ??= () async {
      rollbackDelegations++;
      await original();
      rollbackDeliveries++;
    }();
    await rollbackCleanup!.timeout(_boundaryTimeout);
  }

  try {
    final repo = _repo(f);
    originalRepo = repo;
    final initial = await _seed(f, repo);
    final observed = await _observeReject(repo, initial);
    if (undo) {
      final result = await _reject(f, repo, observed);
      expect(result, isNotNull);
      final genuineReceipt = result!;
      receipt = genuineReceipt;
      expect(genuineReceipt.current, true);
      final loaded = (await repo.getJobSnapshot(_jobId))!;
      expect(loaded.job, genuineReceipt.nativeJob);
      expect(_selected(loaded).operation, genuineReceipt.nativeOperation);
      freshUndo = await repo.observeNativeRejectUndo(
        receipt: genuineReceipt,
        loaded: loaded,
        selected: _selected(loaded),
        isCurrent: () => true,
      );
      expect(freshUndo, isNotNull);
      expect(freshUndo!.current, true);
    }
    final before = (await repo.getJobSnapshot(_jobId))!;
    final rawBefore = await f.snapshot();
    final journalsBefore = await f.db.select(f.db.supportMutationJournal).get();
    expect(raw.autocommit, true);
    expect(
      previousCalls,
      greaterThan(0),
      reason: 'Previous hook actually installed from initial construction.',
    );
    expect(raw.commitFilter, same(installedFilter));
    f.observe();

    f.sql.beforeOuterSend = () async {
      beforeSends++;
      expect(
        raw.autocommit,
        false,
        reason:
            'The provisional native writes exist inside an open transaction.',
      );
      if (fault == 'confirmedRollback' || fault == 'undeliveredRollback') {
        repo.retireNativeReview(_jobId);
      }
    };
    f.sql.afterOuterSend = () async {
      deliveredSends++;
      expect(
        raw.autocommit,
        true,
        reason: 'Original COMMIT completed before this callback.',
      );
      if (fault == 'deliveredRetired') repo.retireNativeReview(_jobId);
      if (fault == 'deliveredAuthorityRetired') originalAuthority = false;
      if (fault == 'deliveredThenThrow') {
        throw StateError('SYNTHETIC_POST_COMMIT_DELIVERY_FAILURE');
      }
    };
    f.sql.beforeRollback = (original) async {
      rollbackCalls++;
      rollbackAutocommit.add(raw.autocommit);
      if (fault == 'undeliveredRollback') {
        expect(retainedRollback, isNull);
        retainedRollback = original;
        throw StateError('SYNTHETIC_BEFORE_ORIGINAL_ROLLBACK_FAILURE');
      }
      rollbackDelegations++;
      try {
        await original();
        rollbackDeliveries++;
      } catch (error) {
        rollbackErrors.add(error);
        rethrow;
      }
    };
    armed = true;
    try {
      if (undo) {
        returnedUndo = await _undo(
          f,
          repo,
          receipt!,
          freshUndo!,
          isCurrent: () => originalAuthority,
        );
      } else {
        returnedReceipt = await _reject(
          f,
          repo,
          observed,
          isCurrent: () => originalAuthority,
        );
      }
    } catch (error) {
      operationError = error;
    }
    armed = false;
    expect(
      beforeSends,
      1,
      reason: 'Fault must reach the actual outer send boundary.',
    );
    expect(
      f.sql.writes.where(
        (sql) => sql.startsWith('UPDATE "rewrite_operations" SET '),
      ),
      hasLength(1),
    );
    expect(
      f.sql.writes.where(
        (sql) => sql.startsWith('UPDATE "rewrite_jobs" SET '),
      ),
      hasLength(1),
    );
    expect(
      raw.commitFilter,
      same(installedFilter),
      reason: 'No hook was replaced over the original fence.',
    );

    if (fault == 'confirmedRollback') {
      expect(operationError, isNull);
      expect(returnedReceipt, isNull);
      expect(returnedUndo, isNull);
      expect(
        nativeCommitCalls,
        0,
        reason: 'The inner fence vetoed before SQLite COMMIT.',
      );
      expect(deliveredSends, 0);
      expect(rollbackCalls, 1);
      expect(rollbackDelegations, 1);
      expect(
        rollbackDeliveries,
        1,
        reason: 'The original rollback result was received.',
      );
      expect(rollbackAutocommit, [false]);
      expect(rollbackErrors, isEmpty);
      expect(f.sql.outerSendErrors, hasLength(1));
      expect(
        f.sql.outerSendErrors.single,
        isNot(isA<sqlite.SqliteException>()),
      );
      expect(raw.autocommit, true);
      expect(await f.snapshot(), rawBefore);
    } else if (fault == 'undeliveredRollback') {
      expect(operationError, isA<ManualRewriteNativeStorageException>());
      expect(returnedReceipt, isNull);
      expect(returnedUndo, isNull);
      expect(nativeCommitCalls, 0);
      expect(deliveredSends, 0);
      expect(f.sql.outerSendErrors, hasLength(1));
      expect(
        f.sql.outerSendErrors.single,
        isNot(isA<sqlite.SqliteException>()),
      );
      expect(rollbackCalls, 1);
      expect(rollbackAutocommit, [false]);
      expect(rollbackDelegations, 0);
      expect(rollbackDeliveries, 0);
      expect(retainedRollback, isNotNull);
      expect(
        raw.autocommit,
        false,
        reason: 'Do not claim rollback before original delivery.',
      );
      // No root reads or close until this exact pending original rollback joins.
      await releaseRollback();
      expect(rollbackDelegations, 1);
      expect(rollbackDeliveries, 1);
      expect(raw.autocommit, true);
      expect(
        await f.snapshot(),
        rawBefore,
        reason:
            'State after explicit cleanup, NOT a fact returned by the failed operation.',
      );
    } else if (fault == 'sqliteCommitHookVeto') {
      expect(operationError, isNull);
      expect(returnedReceipt, isNull);
      expect(returnedUndo, isNull);
      expect(
        nativeCommitCalls,
        1,
        reason:
            'Previous hook ran on the real native COMMIT and retired the admission.',
      );
      expect(deliveredSends, 0);
      expect(f.sql.outerSendErrors, hasLength(1));
      expect(f.sql.outerSendErrors.single, isA<sqlite.SqliteException>());
      final nativeError =
          f.sql.outerSendErrors.single as sqlite.SqliteException;
      expect(
        nativeError.extendedResultCode,
        sqlite.SqlExtendedError.SQLITE_CONSTRAINT_COMMITHOOK,
      );
      expect(rollbackCalls, 1);
      expect(
        rollbackAutocommit,
        [true],
        reason:
            'SQLite had already auto-rolled back before Drift tried its redundant ROLLBACK.',
      );
      expect(rollbackDelegations, 1);
      expect(rollbackDeliveries, 0);
      expect(rollbackErrors, hasLength(1));
      expect(rollbackErrors.single, isA<sqlite.SqliteException>());
      expect(raw.autocommit, true);
      expect(await f.snapshot(), rawBefore);
    } else {
      expect(nativeCommitCalls, 1);
      expect(deliveredSends, 1);
      expect(
        f.sql.outerSendErrors,
        isEmpty,
        reason:
            'Original send delivered; only the outer result may be uncertain.',
      );
      if (fault == 'deliveredRetired' || fault == 'deliveredAuthorityRetired') {
        expect(operationError, isNull);
        expect(rollbackCalls, 0);
        if (undo) {
          expect(returnedUndo, isNotNull);
          expect(
            returnedUndo!.current,
            false,
            reason:
                'A persisted fact cannot adopt a successor after original authority retirement.',
          );
        } else {
          expect(returnedReceipt, isNotNull);
          final retiredReceipt = returnedReceipt!;
          expect(retiredReceipt.current, false);
          final loaded = (await repo.getJobSnapshot(_jobId))!;
          expect(
            await repo.observeNativeRejectUndo(
              receipt: retiredReceipt,
              loaded: loaded,
              selected: _selected(loaded),
              isCurrent: () => true,
            ),
            isNull,
            reason:
                'Fresh durable rows cannot renew retired original Undo custody.',
          );
        }
      } else {
        expect(operationError, isA<ManualRewriteNativeStorageException>());
        expect(returnedReceipt, isNull);
        expect(returnedUndo, isNull);
        expect(rollbackCalls, 1);
        expect(rollbackAutocommit, [true]);
        expect(rollbackDelegations, 1);
        expect(rollbackDeliveries, 0);
        expect(rollbackErrors, hasLength(1));
        expect(
          rollbackErrors.single,
          isA<StateError>(),
          reason:
              'Drift 2.33 already released this delivered executor; its redundant rollback cannot acknowledge a rollback.',
        );
      }
      expect(raw.autocommit, true);
      await _persistedFact(
        f,
        repo,
        initial: initial,
        before: before,
        undo: undo,
      );
      expect(_otherRawRows(f, await f.snapshot()), _otherRawRows(f, rawBefore));
      if (undo) {
        final oldJournal = journalsBefore.singleWhere(
          (row) => row.id == _journalId,
        );
        final journal = (await f.db.select(f.db.supportMutationJournal).get())
            .singleWhere((row) => row.id == _journalId);
        expect(journal, oldJournal.copyWith(status: 'undone'));
      }
    }
    expect(observed.current, false);
    if (undo) {
      expect(receipt!.current, false);
      expect(freshUndo!.current, false);
    }
  } finally {
    armed = false;
    f.sql.beforeOuterSend = null;
    f.sql.afterOuterSend = null;
    f.sql.beforeRollback = null;
    // If an assertion failed before the explicit cleanup block, still join the
    // retained original request FIRST. A failed join must not proceed to close
    // or disposal of the underlying connection while that request is unresolved.
    await releaseRollback();
    try {
      await f.close();
    } finally {
      raw.dispose();
    }
  }
}

ManualRewriteJobRepo _repo(NativeInputFixture f) => ManualRewriteJobRepo(
  db: f.db,
  rawTrackerStateReader: LedgerRawTrackerStateReader(f.db),
);

ManualRewriteOperationView _selected(ManualRewriteJobSnapshot loaded) =>
    loaded.operations.singleWhere((view) => view.operation.id == _operationId);

Future<ManualRewriteJobSnapshot> _seed(
  NativeInputFixture f,
  ManualRewriteJobRepo repo,
) async {
  await f.seed(); // Retained unrelated encrypted rows in the original fixture.
  final scalar = ManualRewriteOperationSnapshotCodec.encode(
    CardRewriteOperationSnapshot(
      field: CardRewriteField.description,
      patches: [
        AnchoredScalarPatch(
          scopeKey: 'character:description',
          field: CardRewriteField.description,
          anchor: 'SYNTHETIC_ORIGINAL_REWRITE_ANCHOR',
          anchorSha256: CardCanonicalizer.scalarSha256(
            'SYNTHETIC_ORIGINAL_REWRITE_ANCHOR',
          ),
          value: 'SYNTHETIC_REWRITE_MODEL_TEXT',
        ),
      ],
      transition: const CardRewriteTransitionSnapshot(
        id: 'synthetic-rewrite-transition',
        scopeKey: 'character:description',
        canonicalClaim: 'SYNTHETIC_REWRITE_CLAIM',
        promotionDestination: 'card',
        affectedTrackerKeys: [],
      ),
    ),
  );
  final snapshot = scalar.replaceFirst('"field":', '$_unknownRaw"field":');
  expect(
    ManualRewriteOperationSnapshotCodec.tryDecode(jsonDecode(snapshot)),
    isNotNull,
  );
  await f.db.transaction(() async {
    for (final (job, session, operations) in [
      (_jobId, NativeInputFixture.sessionId, [_operationId, _unselectedId]),
      (_foreignJobId, NativeInputFixture.foreignId, [_foreignOperationId]),
    ]) {
      await repo.insertPendingInTransaction(
        jobId: job,
        chatSessionId: session,
        characterId: 'synthetic-rewrite-character',
        requestJson:
            '{ "instruction":"SYNTHETIC_REWRITE_REQUEST", "unknown":1.2300e+02 }',
        requestKey: 'synthetic-request-$job',
        basisRevision: 4,
        basisRevisionHash: 'SYNTHETIC_REWRITE_BASIS',
        canonStamp: 'SYNTHETIC_REWRITE_CANON',
        operations: [
          for (final id in operations)
            ManualRewriteOperationDraft(
              id: id,
              snapshotJson: snapshot,
              evidence: [
                ManualRewriteEvidenceDraft(
                  id: 'synthetic-evidence-$id',
                  evidenceJson:
                      '{ "private":"SYNTHETIC_REWRITE_EVIDENCE", "raw":1.2300e+02 }',
                ),
              ],
            ),
        ],
        now: 11,
      );
    }
  });
  final loaded = (await repo.getJobSnapshot(_jobId))!;
  expect(loaded.job.status, 'pending');
  expect(loaded.job.version, 1);
  expect(_selected(loaded).operation.decision, 'pending');
  expect(_selected(loaded).operation.decisionRevision, 0);
  expect(_selected(loaded).operation.validationStatus, 'valid');
  expect(_selected(loaded).currentSnapshotJson, snapshot);
  expect(_selected(loaded).operation.operationJson, snapshot);
  return loaded;
}

Future<ManualRewriteNativeObservation> _observeReject(
  ManualRewriteJobRepo repo,
  ManualRewriteJobSnapshot loaded,
) async {
  final ticket = repo.bindNativeLoadedReview(loaded);
  expect(ticket.current, true);
  final observed = await repo.observeNativeReject(
    loaded: loaded,
    selected: _selected(loaded),
    ticket: ticket,
    isCurrent: () => true,
  );
  expect(observed, isNotNull);
  final genuine = observed!;
  expect(genuine.current, true);
  return genuine;
}

Future<ManualRewriteNativeRejectReceipt?> _reject(
  NativeInputFixture f,
  ManualRewriteJobRepo repo,
  ManualRewriteNativeObservation observed, {
  bool Function()? isCurrent,
}) => repo
    .rejectNativeReview(
      observed: observed,
      support: f.repo,
      parentSession: NativeInputFixture.sessionId,
      journalId: _journalId,
      isCurrent: isCurrent ?? () => true,
    )
    .timeout(_boundaryTimeout);

Future<ManualRewriteNativeUndoCommit?> _undo(
  NativeInputFixture f,
  ManualRewriteJobRepo repo,
  ManualRewriteNativeRejectReceipt receipt,
  ManualRewriteNativeUndoObservation observed, {
  bool Function()? isCurrent,
}) => repo
    .undoNativeReject(
      receipt: receipt,
      observed: observed,
      support: f.repo,
      parentSession: NativeInputFixture.sessionId,
      isCurrent: isCurrent ?? () => true,
    )
    .timeout(_boundaryTimeout);

Future<void> _persistedFact(
  NativeInputFixture f,
  ManualRewriteJobRepo repo, {
  required ManualRewriteJobSnapshot initial,
  required ManualRewriteJobSnapshot before,
  required bool undo,
}) async {
  final after = (await repo.getJobSnapshot(_jobId))!;
  expect(
    after.job,
    before.job.copyWith(
      version: before.job.version + 1,
      updatedAt: after.job.updatedAt,
    ),
  );
  final operation = _selected(after).operation;
  expect(
    operation,
    _selected(before).operation.copyWith(
      decision: undo ? 'pending' : 'rejected',
      decisionRevision: undo
          ? _selected(initial).operation.decisionRevision
          : _selected(before).operation.currentRevision,
      updatedAt: operation.updatedAt,
    ),
  );
  expect(
    _selected(after).currentSnapshotJson,
    _selected(initial).currentSnapshotJson,
  );
  expect(operation.operationJson, _selected(initial).operation.operationJson);
  expect(operation.operationJson, contains(_unknownRaw));
  await _journalFact(f, undo: undo);
}

Future<void> _journalFact(NativeInputFixture f, {required bool undo}) async {
  final journals = await f.db.select(f.db.supportMutationJournal).get();
  expect(
    journals,
    hasLength(2),
    reason: 'The unrelated original journal row is retained.',
  );
  final journal = journals.singleWhere((row) => row.id == _journalId);
  expect(journal.status, undo ? 'undone' : 'applied');
  expect(journal.domain, 'rewrite.reject');
  expect(journal.targetId, _operationId);
  expect(journal.sessionId, NativeInputFixture.sessionId);
  final decrypted = (await f.repo.getMutationById(_journalId))!;
  final beforeEvidence = SupportMutationEvidence.decode(decrypted.beforeJson)!;
  final afterEvidence = SupportMutationEvidence.decode(decrypted.afterJson)!;
  final before = jsonDecode(beforeEvidence) as Map;
  final after = jsonDecode(afterEvidence) as Map;
  expect(before['decision'], 'pending');
  expect(before['decisionRevision'], 0);
  expect(after['decision'], 'rejected');
  expect(after['decisionRevision'], 1);
  expect(journal.beforeCiphertext, isNot(contains(beforeEvidence)));
  expect(journal.afterCiphertext, isNot(contains(afterEvidence)));
  for (final canary in [
    'SYNTHETIC_REWRITE_MODEL_TEXT',
    'SYNTHETIC_UNKNOWN_REWRITE_CANARY',
    'SYNTHETIC_REWRITE_EVIDENCE',
  ]) {
    expect('$beforeEvidence$afterEvidence', isNot(contains(canary)));
  }
}

// Preserve ALL other raw rows, ciphertext, unknown JSON spelling, revision and
// evidence rows, empty canonical tables and table ordering. Only the exact job,
// selected operation and owned journal are compared separately as changed rows.
String _otherRawRows(NativeInputFixture f, String snapshot) {
  final tables = jsonDecode(snapshot) as Map<String, dynamic>;
  for (final (table, id) in [
    (f.db.rewriteJobs.actualTableName, _jobId),
    (f.db.rewriteOperations.actualTableName, _operationId),
    (f.db.supportMutationJournal.actualTableName, _journalId),
  ]) {
    tables[table] = (tables[table] as List)
        .where((row) => (row as Map)['id'] != id)
        .toList();
  }
  return jsonEncode(tables);
}
