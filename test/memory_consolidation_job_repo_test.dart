import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_job_repo.dart';

void main() {
  late AppDatabase db;
  late int now;
  late MemoryConsolidationJobRepo repo;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    now = 1000;
    repo = MemoryConsolidationJobRepo(db, clock: () => now);
  });

  tearDown(() => db.close());

  List<MemoryConsolidationJobItemInput> sourceItems() => [
    MemoryConsolidationJobItemInput(
      memoryEntryId: 'entry-1',
      revisionId: 'entry-1:r1',
      fingerprint: 'a' * 64,
      proposedEventId: 'event-1',
    ),
    MemoryConsolidationJobItemInput(
      memoryEntryId: 'entry-2',
      revisionId: 'entry-2:r3',
      fingerprint: 'b' * 64,
      proposedEventId: 'event-2',
    ),
  ];

  Future<MemoryConsolidationJobRow> createJob() => repo.createOrGet(
    sessionId: 'session-1',
    branchId: 'session-1',
    requestKey: 'package-sha256',
    items: sourceItems(),
  );

  test('cancel records its durable reason on the job and its items', () async {
    final job = await createJob();

    // A source-fence cancel is not a user cancel: the reason must be
    // distinguishable, otherwise the queue UI lies about what happened.
    expect(await repo.cancel(job.id, reason: 'source_context_changed'), isTrue);
    final cancelled = await (db.select(
      db.memoryConsolidationJobRows,
    )..where((row) => row.id.equals(job.id))).getSingle();
    expect(cancelled.status, 'cancelled');
    expect(cancelled.lastError, 'source_context_changed');
    final items = await repo.getItems(job.id);
    expect(items, isNotEmpty);
    for (final item in items) {
      expect(item.status, 'cancelled');
      expect(item.lastError, 'source_context_changed');
    }

    // A plain user cancel keeps its own default reason.
    final second = await repo.createOrGet(
      sessionId: 'session-2',
      branchId: 'session-2',
      requestKey: 'package-sha256-2',
      items: sourceItems(),
    );
    expect(await repo.cancel(second.id), isTrue);
    final userCancelled = await (db.select(
      db.memoryConsolidationJobRows,
    )..where((row) => row.id.equals(second.id))).getSingle();
    expect(userCancelled.lastError, 'cancelled_by_user');
  });

  test(
    'reservations are scoped to branch and exact revision fingerprint',
    () async {
      await createJob();
      final sources = await repo.getReservedSources(
        sessionId: 'session-1',
        branchId: 'session-1',
      );
      expect(sources, hasLength(2));
      expect(sources, contains(sourceItems().first.sourceIdentity));
      expect(
        sources,
        isNot(
          contains((
            memoryEntryId: 'entry-1',
            revisionId: 'entry-1:r2',
            fingerprint: 'a' * 64,
          )),
        ),
      );
      expect(
        sources,
        isNot(
          contains((
            memoryEntryId: 'entry-1',
            revisionId: 'entry-1:r1',
            fingerprint: 'c' * 64,
          )),
        ),
      );
      expect(
        await repo.getReservedSources(
          sessionId: 'session-1',
          branchId: 'other-branch',
        ),
        isEmpty,
      );
      expect(
        await repo.getReservedSources(
          sessionId: 'other-session',
          branchId: 'session-1',
        ),
        isEmpty,
      );
    },
  );

  test('request key creates one immutable source snapshot', () async {
    final first = await createJob();
    final repeated = await repo.createOrGet(
      sessionId: 'session-1',
      branchId: 'session-1',
      requestKey: 'package-sha256',
      items: sourceItems(),
    );

    expect(repeated.id, first.id);
    expect(await repo.getItems(first.id), hasLength(2));
    expect((await repo.getItems(first.id)).first.fingerprint, 'a' * 64);
    await expectLater(
      repo.createOrGet(
        sessionId: 'session-1',
        branchId: 'session-1',
        requestKey: 'package-sha256',
        items: [sourceItems().first],
      ),
      throwsStateError,
    );
  });

  test('claim lease gates item work and expired ownership is fenced', () async {
    final job = await createJob();
    await repo.createOrGet(
      sessionId: 'session-1',
      branchId: 'session-1',
      requestKey: 'second-package',
      items: [
        MemoryConsolidationJobItemInput(
          memoryEntryId: 'entry-3',
          revisionId: 'entry-3:r1',
          fingerprint: 'c' * 64,
          proposedEventId: 'event-3',
        ),
      ],
    );
    final claim = await repo.claimNext(
      ownerId: 'worker-a',
      leaseDurationSeconds: 10,
    );
    expect(claim?.id, job.id);
    expect(claim?.status, 'running');
    expect(
      await repo.claimNext(ownerId: 'worker-x', leaseDurationSeconds: 10),
      isNull,
    );
    expect(
      await repo.claimNextItem(jobId: job.id, ownerId: 'worker-b'),
      isNull,
    );

    final item = await repo.claimNextItem(jobId: job.id, ownerId: 'worker-a');
    expect(item?.status, 'running');
    now = 1011;
    expect(await repo.recoverExpiredLeases(), isTrue);
    expect(
      await repo.saveDraft(
        jobId: job.id,
        itemId: item!.id,
        ownerId: 'worker-a',
        draftJson: '{"draft":true}',
      ),
      isFalse,
    );

    final recovered = await repo.claimNext(
      ownerId: 'worker-b',
      leaseDurationSeconds: 10,
    );
    expect(recovered?.attemptCount, 2);
    expect((await repo.getItems(job.id)).map((row) => row.status), [
      'pending',
      'pending',
    ]);
  });

  test(
    'drafts become review pending, never accepted by worker completion',
    () async {
      final job = await createJob();
      await repo.claimNext(ownerId: 'worker-a', leaseDurationSeconds: 100);
      final first = await repo.claimNextItem(
        jobId: job.id,
        ownerId: 'worker-a',
      );
      expect(
        await repo.saveDraft(
          jobId: job.id,
          itemId: first!.id,
          ownerId: 'worker-a',
          draftJson: '{"event":"candidate"}',
        ),
        isTrue,
      );
      final second = await repo.claimNextItem(
        jobId: job.id,
        ownerId: 'worker-a',
      );
      expect(
        await repo.saveDraft(
          jobId: job.id,
          itemId: second!.id,
          ownerId: 'worker-a',
          draftJson: '{"event":"candidate-2"}',
        ),
        isTrue,
      );

      final stored = await repo.getItems(job.id);
      final storedJob = await (db.select(
        db.memoryConsolidationJobRows,
      )..where((row) => row.id.equals(job.id))).getSingle();
      expect(stored.map((item) => item.status), everyElement('review_pending'));
      expect(storedJob.status, 'review_pending');
      expect(storedJob.leaseOwnerId, isNull);
      await expectLater(
        repo.acceptReviewedItem(
          jobId: job.id,
          itemId: stored.first.id,
          acceptReviewed: (_) async => throw StateError('stale source'),
        ),
        throwsStateError,
      );
      expect((await repo.getItems(job.id)).first.status, 'review_pending');

      var acceptedDraft = '';
      expect(
        await repo.acceptReviewedItem(
          jobId: job.id,
          itemId: stored.first.id,
          acceptReviewed: (draft) async => acceptedDraft = draft,
        ),
        isTrue,
      );
      expect(acceptedDraft, '{"event":"candidate"}');
      expect((await repo.getItems(job.id)).first.status, 'accepted');
      final afterOne = await (db.select(
        db.memoryConsolidationJobRows,
      )..where((row) => row.id.equals(job.id))).getSingle();
      expect(afterOne.status, 'review_pending');
      expect(
        await repo.acceptReviewedItem(
          jobId: job.id,
          itemId: stored.last.id,
          acceptReviewed: (_) async {},
        ),
        isTrue,
      );
      final completed = await (db.select(
        db.memoryConsolidationJobRows,
      )..where((row) => row.id.equals(job.id))).getSingle();
      expect(completed.status, 'completed');
    },
  );

  test(
    'retry resets failed items only and cancellation fences leases',
    () async {
      final job = await createJob();
      await repo.claimNext(ownerId: 'worker-a', leaseDurationSeconds: 100);
      final failed = await repo.claimNextItem(
        jobId: job.id,
        ownerId: 'worker-a',
      );
      expect(
        await repo.failItem(
          jobId: job.id,
          itemId: failed!.id,
          ownerId: 'worker-a',
          reason: 'synthetic_failure',
        ),
        isTrue,
      );
      final untouched = (await repo.getItems(job.id)).last;
      expect(untouched.status, 'pending');
      final draftItem = await repo.claimNextItem(
        jobId: job.id,
        ownerId: 'worker-a',
      );
      expect(
        await repo.saveDraft(
          jobId: job.id,
          itemId: draftItem!.id,
          ownerId: 'worker-a',
          draftJson: '{"retained":true}',
        ),
        isTrue,
      );
      expect(
        await repo.claimNext(ownerId: 'worker-x', leaseDurationSeconds: 10),
        isNull,
      );
      final failedPackage = await (db.select(
        db.memoryConsolidationJobRows,
      )..where((row) => row.id.equals(job.id))).getSingle();
      expect(failedPackage.status, 'failed');
      expect(await repo.retryFailed(job.id), isTrue);
      final afterRetry = await repo.getItems(job.id);
      expect(afterRetry.first.status, 'pending');
      expect(afterRetry.last.status, 'review_pending');
      expect(afterRetry.last.draftJson, '{"retained":true}');

      await repo.claimNext(ownerId: 'worker-b', leaseDurationSeconds: 100);
      final runningItem = await repo.claimNextItem(
        jobId: job.id,
        ownerId: 'worker-b',
      );
      expect(await repo.cancel(job.id), isTrue);
      expect(
        await repo.saveDraft(
          jobId: job.id,
          itemId: runningItem!.id,
          ownerId: 'worker-b',
          draftJson: '{"late":true}',
        ),
        isFalse,
      );
      final cancelled = await (db.select(
        db.memoryConsolidationJobRows,
      )..where((row) => row.id.equals(job.id))).getSingle();
      expect(cancelled.status, 'cancelled');
      expect(
        await repo.claimNext(ownerId: 'worker-c', leaseDurationSeconds: 100),
        isNull,
      );
    },
  );

  test(
    'same-session lease does not block another session in the queue',
    () async {
      final first = await createJob();
      await repo.createOrGet(
        sessionId: 'session-1',
        branchId: 'session-1',
        requestKey: 'same-session-pending',
        items: [
          MemoryConsolidationJobItemInput(
            memoryEntryId: 'entry-3',
            revisionId: 'entry-3:r1',
            fingerprint: 'c' * 64,
            proposedEventId: 'event-3',
          ),
        ],
      );
      await repo.createOrGet(
        sessionId: 'session-2',
        branchId: 'session-2',
        requestKey: 'other-session-pending',
        items: [
          MemoryConsolidationJobItemInput(
            memoryEntryId: 'entry-4',
            revisionId: 'entry-4:r1',
            fingerprint: 'd' * 64,
            proposedEventId: 'event-4',
          ),
        ],
      );
      expect(
        (await repo.claimNext(
          ownerId: 'worker-a',
          leaseDurationSeconds: 100,
        ))?.id,
        first.id,
      );
      final otherSession = await repo.claimNext(
        ownerId: 'worker-b',
        leaseDurationSeconds: 100,
      );
      expect(otherSession?.sessionId, 'session-2');
    },
  );

  test('one package draft is durable and accepts atomically', () async {
    final job = await createJob();
    await repo.claimNext(ownerId: 'worker-a', leaseDurationSeconds: 100);
    final first = await repo.claimNextItem(jobId: job.id, ownerId: 'worker-a');
    final second = await repo.claimNextItem(jobId: job.id, ownerId: 'worker-a');
    expect(first, isNotNull);
    expect(second, isNotNull);
    expect(
      await repo.savePackageDraft(
        jobId: job.id,
        ownerId: 'worker-a',
        draftJson: '{"pack":{},"response":{}}',
      ),
      isTrue,
    );
    final review = await (db.select(
      db.memoryConsolidationJobRows,
    )..where((row) => row.id.equals(job.id))).getSingle();
    expect(review.status, 'review_pending');
    expect(review.packageDraftJson, '{"pack":{},"response":{}}');
    expect(review.leaseOwnerId, isNull);
    expect(
      (await repo.getItems(job.id)).map((item) => item.status),
      everyElement('review_pending'),
    );

    await expectLater(
      repo.acceptReviewedPackage(
        jobId: job.id,
        acceptReviewed: (_) async => throw StateError('stale package'),
      ),
      throwsStateError,
    );
    final afterFailure = await (db.select(
      db.memoryConsolidationJobRows,
    )..where((row) => row.id.equals(job.id))).getSingle();
    expect(afterFailure.status, 'review_pending');

    var accepted = '';
    expect(
      await repo.acceptReviewedPackage(
        jobId: job.id,
        acceptReviewed: (draft) async => accepted = draft,
      ),
      isTrue,
    );
    expect(accepted, '{"pack":{},"response":{}}');
    final completed = await (db.select(
      db.memoryConsolidationJobRows,
    )..where((row) => row.id.equals(job.id))).getSingle();
    expect(completed.status, 'completed');
    expect(completed.packageDraftJson, review.packageDraftJson);
    expect(
      (await repo.getItems(job.id)).map((item) => item.status),
      everyElement('accepted'),
    );
  });

  test(
    'revive re-queues a cancelled package and drops its rejected draft',
    () async {
      final job = await createJob();
      await repo.claimNext(ownerId: 'worker-a', leaseDurationSeconds: 100);
      await repo.claimNextItem(jobId: job.id, ownerId: 'worker-a');
      await repo.claimNextItem(jobId: job.id, ownerId: 'worker-a');
      expect(
        await repo.savePackageDraft(
          jobId: job.id,
          ownerId: 'worker-a',
          draftJson: '{"pack":{},"response":{}}',
        ),
        isTrue,
      );
      expect(await repo.cancel(job.id), isTrue);
      final cancelled = await (db.select(
        db.memoryConsolidationJobRows,
      )..where((row) => row.id.equals(job.id))).getSingle();
      expect(cancelled.status, 'cancelled');

      final revived = await repo.revive(job.id);

      expect(revived.id, job.id);
      expect(revived.status, 'pending');
      expect(revived.packageDraftJson, isNull);
      expect(revived.leaseOwnerId, isNull);
      expect(revived.version, cancelled.version + 1);
      expect(
        (await repo.getItems(job.id)).map((item) => item.status),
        everyElement('pending'),
      );
      expect(
        (await repo.getItems(job.id)).map((item) => item.draftJson),
        everyElement(isNull),
      );

      // A revived package is claimable again like a fresh one.
      final reclaimed = await repo.claimNext(
        ownerId: 'worker-b',
        leaseDurationSeconds: 100,
      );
      expect(reclaimed?.id, job.id);
      expect(reclaimed?.attemptCount, 2);

      // Reviving a live job is a no-op that returns the current row.
      final live = await repo.revive(job.id);
      expect(live.status, 'running');
      expect(live.id, job.id);
    },
  );

  test('claimNext can be scoped to one session', () async {
    final first = await createJob();
    await repo.createOrGet(
      sessionId: 'session-2',
      branchId: 'session-2',
      requestKey: 'other-session-package',
      items: [
        MemoryConsolidationJobItemInput(
          memoryEntryId: 'entry-4',
          revisionId: 'entry-4:r1',
          fingerprint: 'd' * 64,
          proposedEventId: 'event-4',
        ),
      ],
    );

    final scoped = await repo.claimNext(
      ownerId: 'worker-b',
      leaseDurationSeconds: 100,
      sessionId: 'session-2',
    );
    expect(scoped?.sessionId, 'session-2');
    expect(scoped?.id, isNot(first.id));

    // An unscoped claim still sees the oldest job from the other session.
    final unscoped = await repo.claimNext(
      ownerId: 'worker-c',
      leaseDurationSeconds: 100,
    );
    expect(unscoped?.id, first.id);

    // The scoped queue is empty for a session without work.
    expect(
      await repo.claimNext(
        ownerId: 'worker-d',
        leaseDurationSeconds: 100,
        sessionId: 'session-3',
      ),
      isNull,
    );
  });

  test('watch streams follow session jobs and their items', () async {
    final jobs = <List<MemoryConsolidationJobRow>>[];
    final jobsSub = repo.watchSessionJobs('session-1').listen(jobs.add);
    addTearDown(jobsSub.cancel);

    final job = await createJob();
    await repo.createOrGet(
      sessionId: 'session-2',
      branchId: 'session-2',
      requestKey: 'other-session-package',
      items: [
        MemoryConsolidationJobItemInput(
          memoryEntryId: 'entry-4',
          revisionId: 'entry-4:r1',
          fingerprint: 'd' * 64,
          proposedEventId: 'event-4',
        ),
      ],
    );
    await Future<void>.delayed(Duration.zero);

    expect(jobs, isNotEmpty);
    expect(jobs.last, hasLength(1));
    expect(jobs.last.first.id, job.id);

    final items = <List<MemoryConsolidationJobItemRow>>[];
    final itemsSub = repo.watchItems(job.id).listen(items.add);
    addTearDown(itemsSub.cancel);

    await repo.claimNext(ownerId: 'worker-a', leaseDurationSeconds: 100);
    await Future<void>.delayed(Duration.zero);

    expect(items, isNotEmpty);
    expect(items.last, hasLength(2));
    expect(items.last.map((item) => item.status), everyElement('pending'));
  });

  test('getSessionJobs lists one session newest first', () async {
    final first = await createJob();
    now += 10;
    await repo.createOrGet(
      sessionId: 'session-1',
      branchId: 'session-1',
      requestKey: 'second-package',
      items: [
        MemoryConsolidationJobItemInput(
          memoryEntryId: 'entry-3',
          revisionId: 'entry-3:r1',
          fingerprint: 'c' * 64,
          proposedEventId: 'event-3',
        ),
      ],
    );
    await repo.createOrGet(
      sessionId: 'session-2',
      branchId: 'session-2',
      requestKey: 'other-session-package',
      items: [
        MemoryConsolidationJobItemInput(
          memoryEntryId: 'entry-4',
          revisionId: 'entry-4:r1',
          fingerprint: 'd' * 64,
          proposedEventId: 'event-4',
        ),
      ],
    );

    final jobs = await repo.getSessionJobs('session-1');

    expect(jobs, hasLength(2));
    expect(jobs.first.requestKey, 'second-package');
    expect(jobs.last.id, first.id);
  });
}
