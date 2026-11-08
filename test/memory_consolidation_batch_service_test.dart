import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_pack_builder.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/llm/memory_draft_api_source.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_book_api_settings.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_acceptance_service.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_batch_service.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_service.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';

const _sessionId = 'batch-consolidation-session';
const _characterId = 'batch-consolidation-character';

const _config = ApiConfig(
  id: 'batch-test-api',
  endpoint: 'https://example.invalid/v1/chat/completions',
  apiKey: 'test-only',
  model: 'test-model',
  protocol: 'custom_chat_completion',
);

bool _alwaysCurrent() => true;

/// Deterministic v2 package fixture: one promise and one result event, one
/// `fulfills` link between the two newly proposed events.
class _Transport {
  int calls = 0;
  bool failNext = false;

  Future<String> call({
    required AuxApiConfig config,
    required List<Map<String, String>> messages,
    required int maxTokens,
    required double temperature,
    required int timeoutMs,
    CancelToken? cancelToken,
  }) async {
    calls++;
    if (failNext) {
      failNext = false;
      throw Exception('synthetic transport failure');
    }
    final ids = RegExp(
      r'"proposedEventIds":\["([^"]+)","([^"]+)"\]',
    ).firstMatch(messages.last['content']!)!;
    return '''
{
  "contract":"memory_event_consolidation",
  "version":2,
  "outcome":"confirmed",
  "events":[
    {"eventId":"${ids.group(1)}","kind":"promise","description":"Mira promised to return the brass key.","state":"open","sourceRefs":["entry:batch-entry-1"],"boundary":null},
    {"eventId":"${ids.group(2)}","kind":"result","description":"Mira returned the brass key.","state":"completed","sourceRefs":["entry:batch-entry-2"],"boundary":null}
  ],
  "links":[{"linkId":"batch-link-1","fromEventId":"${ids.group(1)}","toEventId":"${ids.group(2)}","relation":"fulfills"}],
  "unverifiedSourceRefs":[],
  "unexaminedOpenObligationIds":[]
}''';
  }
}

class _Harness {
  _Harness(
    this.db,
    this.container,
    this.repo,
    this.batch,
    this.jobRepo,
    this.transport,
  );

  final AppDatabase db;
  final ProviderContainer container;
  final MemoryBookRepo repo;
  final MemoryConsolidationBatchService batch;
  final MemoryConsolidationJobRepo jobRepo;
  final _Transport transport;

  Future<int> eventCount() async =>
      (await db.select(db.memoryEventRows).get()).length;

  Future<int> linkCount() async =>
      (await db.select(db.memoryEventLinkRows).get()).length;

  Future<MemoryConsolidationJobRow?> job(String id) => (db.select(
    db.memoryConsolidationJobRows,
  )..where((row) => row.id.equals(id))).getSingleOrNull();

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Future<_Harness> _makeHarness({int Function()? clock}) async {
  SharedPreferences.setMockInitialValues({});
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  final container = ProviderContainer(
    overrides: [appDbProvider.overrideWithValue(db)],
  );
  addTearDown(() async {
    container.dispose();
    await db.close();
  });
  await container
      .read(chatRepoProvider)
      .put(
        ChatSession(
          id: _sessionId,
          characterId: _characterId,
          sessionIndex: 0,
          messages: [
            for (var i = 1; i <= 2; i++)
              ChatMessage(
                id: 'batch-message-$i',
                role: 'assistant',
                content: i == 1
                    ? 'Mira promised to return the brass key.'
                    : 'Mira returned the brass key.',
                swipeId: 1,
                agentSwipeId: 2,
              ),
          ],
        ),
      );
  final repo = container.read(memoryBookRepoProvider);
  final transport = _Transport();
  final jobRepo = MemoryConsolidationJobRepo(db, clock: clock);
  final batch = MemoryConsolidationBatchService(
    db: db,
    jobRepo: jobRepo,
    packBuilder: MemoryConsolidationPackBuilder(db),
    service: MemoryConsolidationService(call: transport.call),
    acceptance: MemoryConsolidationAcceptanceService(
      MemoryEventRegistryRepo(db),
    ),
  );
  return _Harness(db, container, repo, batch, jobRepo, transport);
}

Future<MemoryBook> _seedBook(
  _Harness harness, {
  int count = 2,
  int contentSize = 0,
}) async {
  final entries = <MemoryEntry>[];
  for (var i = 1; i <= count; i++) {
    final messageId = 'batch-message-$i';
    final entryId = 'batch-entry-$i';
    final baseContent = i == 1
        ? 'Mira promised to return the brass key.'
        : (i == 2
              ? 'Mira returned the brass key.'
              : 'Mira noted the brass key again.');
    final content = contentSize > 0
        ? '$baseContent${'x' * contentSize}'
        : baseContent;
    final manifest = MemorySourceManifest.capture(
      _sessionId,
      [
        ChatMessage(
          id: messageId,
          role: 'assistant',
          content: content,
          swipeId: 1,
          agentSwipeId: 2,
        ),
      ],
      [messageId],
    );
    final revision = MemoryEntryRevision(
      id: '$entryId:r1',
      version: 1,
      title: i == 1 ? 'The promise' : (i == 2 ? 'The return' : 'Memory $i'),
      content: content,
      messageIds: [messageId],
      sourceManifest: manifest,
      createdAt: 1,
    );
    entries.add(
      MemoryEntry(
        id: entryId,
        title: revision.title,
        content: content,
        messageIds: [messageId],
        sourceSwipeId: 1,
        sourceAgentSwipeId: 2,
        sourceManifest: manifest,
        activeRevisionId: revision.id,
        revisions: [revision],
      ),
    );
  }
  final book = MemoryBook(
    id: 'memorybook_$_sessionId',
    sessionId: _sessionId,
    settings: const MemoryBookSettings(memoryMode: 'memory_links'),
    entries: entries,
  );
  await harness.repo.put(book);
  return book;
}

/// A structurally valid entry whose manifest was captured by another
/// session: everything is present, but the provenance root is foreign.
MemoryEntry _foreignEntry() {
  const messageId = 'batch-message-3';
  const content = 'A memory captured by another session.';
  final manifest = MemorySourceManifest.capture(
    'other-session',
    const [
      ChatMessage(
        id: messageId,
        role: 'assistant',
        content: content,
        swipeId: 1,
        agentSwipeId: 2,
      ),
    ],
    const [messageId],
  );
  final revision = MemoryEntryRevision(
    id: 'batch-entry-3:r1',
    version: 1,
    title: 'Foreign memory',
    content: content,
    messageIds: const [messageId],
    sourceManifest: manifest,
    createdAt: 1,
  );
  return MemoryEntry(
    id: 'batch-entry-3',
    title: revision.title,
    content: content,
    messageIds: const [messageId],
    sourceSwipeId: 1,
    sourceAgentSwipeId: 2,
    sourceManifest: manifest,
    activeRevisionId: revision.id,
    revisions: [revision],
  );
}

MemoryDraftApiSourceResolver _resolver() => MemoryDraftApiSourceResolver(
  loadApiConfigs: () async => [_config],
  readActiveApiConfig: () => _config,
);

Future<bool> _run(_Harness harness, String ownerId) => harness.batch.runOnce(
  ownerId: ownerId,
  leaseDurationSeconds: 60,
  settings: const MemoryBookApiSettings(),
  apiResolver: _resolver(),
  originalStamp: null,
  isCurrent: _alwaysCurrent,
);

void main() {
  test('package makes one network call and reaches explicit review', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);

    final job = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    expect(job.status, 'pending');

    expect(await _run(harness, 'runner-1'), isTrue);
    expect(harness.transport.calls, 1);

    final stored = (await harness.job(job.id))!;
    expect(stored.status, 'review_pending');
    expect(stored.packageDraftJson, isNotNull);
    final items = await harness.jobRepo.getItems(job.id);
    expect(items, hasLength(2));
    expect(items.every((item) => item.status == 'review_pending'), isTrue);
    expect(await harness.eventCount(), 0);

    final review = (await harness.batch.loadReview(job.id))!;
    expect(review.response.events, hasLength(2));
    expect(review.response.links, hasLength(1));
    expect(review.pack.proposedEventIds, hasLength(2));

    expect(
      await harness.batch.acceptReviewed(
        jobId: job.id,
        isCurrent: _alwaysCurrent,
      ),
      isTrue,
    );
    expect(await harness.eventCount(), 2);
    expect(await harness.linkCount(), 1);
    expect((await harness.job(job.id))!.status, 'completed');
    expect(
      (await harness.jobRepo.getItems(
        job.id,
      )).every((item) => item.status == 'accepted'),
      isTrue,
    );

    // The accepted package is gone from the review flow.
    expect(await harness.batch.loadReview(job.id), isNull);
  });

  test('re-enqueueing the same sources returns the existing job', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);

    final first = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    final second = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    expect(second.id, first.id);
    final jobs = await harness.db
        .select(harness.db.memoryConsolidationJobRows)
        .get();
    expect(jobs, hasLength(1));
  });

  test('expired lease crash recovery resumes the package run', () async {
    var now = 1000;
    final harness = await _makeHarness(clock: () => now);
    final book = await _seedBook(harness);
    final job = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );

    // Simulate a crashed worker: it claimed the job and died mid-run.
    final crashed = await harness.jobRepo.claimNext(
      ownerId: 'crashed-runner',
      leaseDurationSeconds: 60,
    );
    expect(crashed!.id, job.id);
    now += 61;

    expect(await _run(harness, 'runner-2'), isTrue);
    expect(harness.transport.calls, 1);
    final stored = (await harness.job(job.id))!;
    expect(stored.status, 'review_pending');
    expect(stored.leaseOwnerId, isNull);
  });

  test('stale source blocks acceptance and rolls the package back', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);
    final job = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    expect(await _run(harness, 'runner-1'), isTrue);
    expect(await harness.eventCount(), 0);

    // The reviewed entry changes while the draft sits in review.
    final stored = (await harness.repo.getBySessionId(_sessionId))!;
    final changed = stored.entries.first;
    await harness.repo.reviseEntry(
      sessionId: _sessionId,
      expected: changed,
      proposed: changed.copyWith(content: 'The promise was rewritten.'),
    );

    await expectLater(
      harness.batch.acceptReviewed(jobId: job.id, isCurrent: _alwaysCurrent),
      throwsStateError,
    );
    expect(await harness.eventCount(), 0);
    expect(await harness.linkCount(), 0);
    expect((await harness.job(job.id))!.status, 'review_pending');
    expect(
      (await harness.jobRepo.getItems(
        job.id,
      )).every((item) => item.status == 'review_pending'),
      isTrue,
    );
  });

  test(
    'rejecting a reviewed package cancels it without registry writes',
    () async {
      final harness = await _makeHarness();
      final book = await _seedBook(harness);
      final job = await harness.batch.enqueue(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
      );
      expect(await _run(harness, 'runner-1'), isTrue);

      expect(await harness.batch.reject(job.id), isTrue);
      expect((await harness.job(job.id))!.status, 'cancelled');
      expect(await harness.eventCount(), 0);
      expect(await harness.batch.loadReview(job.id), isNull);
    },
  );

  test(
    'failed generation marks the package retryable and retry succeeds',
    () async {
      final harness = await _makeHarness();
      final book = await _seedBook(harness);
      final job = await harness.batch.enqueue(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
      );

      harness.transport.failNext = true;
      await expectLater(_run(harness, 'runner-1'), throwsException);
      expect((await harness.job(job.id))!.status, 'failed');
      expect(
        (await harness.jobRepo.getItems(
          job.id,
        )).every((item) => item.status == 'failed'),
        isTrue,
      );

      expect(await harness.jobRepo.retryFailed(job.id), isTrue);
      expect(await _run(harness, 'runner-2'), isTrue);
      expect(harness.transport.calls, 2);
      expect((await harness.job(job.id))!.status, 'review_pending');
    },
  );

  test('stale gate aborts the run before any network call', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);
    final job = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );

    await expectLater(
      harness.batch.runOnce(
        ownerId: 'runner-1',
        leaseDurationSeconds: 60,
        settings: const MemoryBookApiSettings(),
        apiResolver: _resolver(),
        originalStamp: null,
        isCurrent: () => false,
      ),
      throwsException,
    );
    expect(harness.transport.calls, 0);
    final stored = (await harness.job(job.id))!;
    expect(stored.status, 'failed');
    expect(stored.packageDraftJson, isNull);
    expect(
      (await harness.jobRepo.getItems(
        job.id,
      )).every((item) => item.status == 'failed'),
      isTrue,
    );
  });

  test('enqueuePending is gated by threshold and covered sources', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);

    // Below the threshold nothing is enqueued.
    expect(
      await harness.batch.enqueuePending(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
        minCount: 3,
      ),
      isNull,
    );

    // At the threshold the eligible uncovered entries form one package.
    final job = await harness.batch.enqueuePending(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
      minCount: 2,
    );
    expect(job, isNotNull);
    expect(job!.status, 'pending');
    expect(await harness.jobRepo.getItems(job.id), hasLength(2));

    expect(await _run(harness, 'runner-1'), isTrue);
    expect(
      await harness.batch.acceptReviewed(
        jobId: job.id,
        isCurrent: _alwaysCurrent,
      ),
      isTrue,
    );
    expect(
      await harness.batch.coveredEntryIds(
        sessionId: _sessionId,
        branchId: _sessionId,
      ),
      {'batch-entry-1', 'batch-entry-2'},
    );

    // Both sources are covered now, so no new package is pending.
    expect(
      await harness.batch.enqueuePending(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
        minCount: 1,
      ),
      isNull,
    );
  });

  test('enqueuePending drops sources without eligible provenance', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);
    final foreign = _foreignEntry();
    await harness.repo.put(book.copyWith(entries: [...book.entries, foreign]));

    final job = await harness.batch.enqueuePending(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: [...book.entries, foreign],
    );

    expect(job, isNotNull);
    final items = await harness.jobRepo.getItems(job!.id);
    expect(items, hasLength(2));
    expect(
      items.map((item) => item.memoryEntryId),
      isNot(contains(foreign.id)),
    );
  });

  test('isEligibleSource mirrors the single-entry provenance bar', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);

    expect(
      MemoryConsolidationBatchService.isEligibleSource(
        book.entries.first,
        _sessionId,
      ),
      isTrue,
    );
    expect(
      MemoryConsolidationBatchService.isEligibleSource(
        _foreignEntry(),
        _sessionId,
      ),
      isFalse,
    );
    expect(
      MemoryConsolidationBatchService.isEligibleSource(
        book.entries.first.copyWith(activeRevisionId: 'missing-revision'),
        _sessionId,
      ),
      isFalse,
    );
  });

  test('re-enqueuing a cancelled package revives it for redraft', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);

    final job = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    expect(await _run(harness, 'runner-1'), isTrue);
    expect(await harness.batch.reject(job.id), isTrue);
    expect((await harness.job(job.id))!.status, 'cancelled');

    final revived = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    expect(revived.id, job.id);
    expect(revived.status, 'pending');
    expect(revived.packageDraftJson, isNull);
    expect(
      (await harness.jobRepo.getItems(
        job.id,
      )).every((item) => item.status == 'pending'),
      isTrue,
    );

    // The revived package redrafts and reaches review again.
    expect(await _run(harness, 'runner-2'), isTrue);
    expect((await harness.job(job.id))!.status, 'review_pending');
  });

  test('planScan slices eligible sources into bounded packages', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness, count: 5);

    final plan = await harness.batch.planScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
      maxEntriesPerPackage: 2,
    );

    expect(plan.eligibleCount, 5);
    expect(plan.coveredCount, 0);
    expect(plan.ineligibleCount, 0);
    expect(plan.packages, hasLength(3));
    expect(plan.packages.map((p) => p.entries.map((e) => e.id).toList()), [
      ['batch-entry-1', 'batch-entry-2'],
      ['batch-entry-3', 'batch-entry-4'],
      ['batch-entry-5'],
    ]);
    expect(plan.packages.every((p) => p.estimatedChars > 0), isTrue);
  });

  test(
    'planScan respects the character budget without dropping sources',
    () async {
      final harness = await _makeHarness();
      final book = await _seedBook(harness, count: 3, contentSize: 3000);

      final plan = await harness.batch.planScan(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
        maxPackageChars: 5000,
      );

      expect(plan.packages, hasLength(3));
      expect(
        plan.packages.every((package) => package.entries.length == 1),
        isTrue,
      );
      expect(
        plan.packages
            .expand((package) => package.entries)
            .map((entry) => entry.id)
            .toSet(),
        {'batch-entry-1', 'batch-entry-2', 'batch-entry-3'},
      );
    },
  );

  test('planScan treats accepted sources as covered', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);

    final job = await harness.batch.enqueue(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    expect(await _run(harness, 'runner-1'), isTrue);
    expect(
      await harness.batch.acceptReviewed(
        jobId: job.id,
        isCurrent: _alwaysCurrent,
      ),
      isTrue,
    );

    final plan = await harness.batch.planScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );

    expect(plan.eligibleCount, 0);
    expect(plan.coveredCount, 2);
    expect(plan.packages, isEmpty);
  });

  test('enqueueScan is idempotent and revives cancelled packages', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness, count: 4);

    Future<MemoryConsolidationScanPlan> plan() => harness.batch.planScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
      maxEntriesPerPackage: 2,
    );

    final rows = await harness.batch.enqueueScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      plan: await plan(),
    );
    expect(rows, hasLength(2));
    expect(rows.every((row) => row.status == 'pending'), isTrue);

    final again = await harness.batch.enqueueScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      plan: await plan(),
    );
    // The existing queue owns these snapshots; the repeated scan adds no jobs.
    expect(again, isEmpty);
    expect(await harness.jobRepo.getSessionJobs(_sessionId), hasLength(2));

    // A rejected package is revived by the next scan of the same sources.
    expect(await harness.batch.reject(rows.first.id), isTrue);
    final revived = await harness.batch.enqueueScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      plan: await plan(),
    );
    expect(revived.first.id, rows.first.id);
    expect(revived.first.status, 'pending');
    expect(await harness.jobRepo.getSessionJobs(_sessionId), hasLength(2));
  });

  test('threshold counts only sources not already queued', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness, count: 4);
    Future<MemoryConsolidationJobRow?> enqueue(int count) =>
        harness.batch.enqueuePending(
          sessionId: _sessionId,
          branchId: _sessionId,
          entries: book.entries.take(count).toList(),
          minCount: 2,
        );

    final first = await enqueue(2);
    expect(first, isNotNull);
    expect(await enqueue(3), isNull);
    final second = await enqueue(4);
    expect(second, isNotNull);
    expect(second!.id, isNot(first!.id));
    expect(
      (await harness.jobRepo.getItems(
        second.id,
      )).map((item) => item.memoryEntryId),
      ['batch-entry-3', 'batch-entry-4'],
    );
    final plan = await harness.batch.planScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    expect(plan.reservedCount, 4);
    expect(plan.eligibleCount, 0);
    expect(plan.packages, isEmpty);
  });

  test('stale scan drops only snapshots reserved after its dry run', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness, count: 4);
    final plan = await harness.batch.planScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
      maxEntriesPerPackage: 2,
    );
    await harness.batch.enqueuePending(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries.take(3).toList(),
    );
    final rows = await harness.batch.enqueueScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      plan: plan,
    );
    expect(rows, hasLength(1));
    expect(
      (await harness.jobRepo.getItems(rows.single.id)).single.memoryEntryId,
      'batch-entry-4',
    );
    expect(
      await harness.batch.enqueueScan(
        sessionId: _sessionId,
        branchId: _sessionId,
        plan: plan,
      ),
      isEmpty,
    );
    expect(await harness.jobRepo.getSessionJobs(_sessionId), hasLength(2));
  });

  test('concurrent threshold and scan reserve each snapshot once', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness, count: 4);
    final plan = await harness.batch.planScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
      maxEntriesPerPackage: 2,
    );
    await Future.wait<Object?>([
      harness.batch.enqueuePending(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
      ),
      harness.batch.enqueueScan(
        sessionId: _sessionId,
        branchId: _sessionId,
        plan: plan,
      ),
    ]);
    final items = <MemoryConsolidationJobItemRow>[];
    for (final job in await harness.jobRepo.getSessionJobs(_sessionId)) {
      items.addAll(await harness.jobRepo.getItems(job.id));
    }
    expect(items, hasLength(4));
    expect(items.map((item) => item.memoryEntryId).toSet(), hasLength(4));
  });

  test('stale scan rechecks coverage after reviewed acceptance', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);
    final plan = await harness.batch.planScan(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    final job = await harness.batch.enqueuePending(
      sessionId: _sessionId,
      branchId: _sessionId,
      entries: book.entries,
    );
    await _run(harness, 'runner-1');
    await harness.batch.acceptReviewed(
      jobId: job!.id,
      isCurrent: _alwaysCurrent,
    );
    expect(
      await harness.batch.enqueueScan(
        sessionId: _sessionId,
        branchId: _sessionId,
        plan: plan,
      ),
      isEmpty,
    );
    expect(await harness.jobRepo.getSessionJobs(_sessionId), hasLength(1));
  });

  for (final status in ['running', 'review_pending', 'failed']) {
    test('$status sources stay reserved until cancellation', () async {
      final harness = await _makeHarness();
      final book = await _seedBook(harness);
      final job = await harness.batch.enqueuePending(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
      );
      if (status == 'running') {
        await harness.jobRepo.claimNext(
          ownerId: 'runner-1',
          leaseDurationSeconds: 60,
        );
      } else if (status == 'failed') {
        harness.transport.failNext = true;
        await expectLater(_run(harness, 'runner-1'), throwsException);
      } else {
        await _run(harness, 'runner-1');
      }
      expect((await harness.job(job!.id))!.status, status);
      expect(
        await harness.batch.enqueuePending(
          sessionId: _sessionId,
          branchId: _sessionId,
          entries: book.entries,
        ),
        isNull,
      );
      expect(
        (await harness.batch.planScan(
          sessionId: _sessionId,
          branchId: _sessionId,
          entries: book.entries,
        )).reservedCount,
        2,
      );
      await harness.batch.reject(job.id);
      final revived = await harness.batch.enqueuePending(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
      );
      expect(revived?.id, job.id);
      expect(revived?.status, 'pending');
    });
  }

  test('planScan validates its bounds', () async {
    final harness = await _makeHarness();
    final book = await _seedBook(harness);

    await expectLater(
      harness.batch.planScan(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
        maxEntriesPerPackage: 0,
      ),
      throwsArgumentError,
    );
    await expectLater(
      harness.batch.planScan(
        sessionId: _sessionId,
        branchId: _sessionId,
        entries: book.entries,
        maxPackageChars: 999,
      ),
      throwsArgumentError,
    );
  });
}
