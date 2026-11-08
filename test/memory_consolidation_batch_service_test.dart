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

Future<MemoryBook> _seedBook(_Harness harness) async {
  final entries = <MemoryEntry>[];
  for (var i = 1; i <= 2; i++) {
    final messageId = 'batch-message-$i';
    final entryId = 'batch-entry-$i';
    final content = i == 1
        ? 'Mira promised to return the brass key.'
        : 'Mira returned the brass key.';
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
      title: i == 1 ? 'The promise' : 'The return',
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
}
