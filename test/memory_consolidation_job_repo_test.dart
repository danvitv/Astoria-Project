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
}
