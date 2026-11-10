import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_job_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_pack_builder.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_acceptance_service.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_batch_service.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_service.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_book_ops_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_consolidation_worker_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';

const _sessionId = 'worker-session';
const _characterId = 'worker-character';
const _messageId = 'worker-message';
const _content = 'Mira returned the brass key.';
const _config = ApiConfig(
  id: 'worker-api',
  endpoint: 'https://example.invalid/v1/chat/completions',
  apiKey: 'test-only',
  model: 'test-model',
  protocol: 'custom_chat_completion',
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ordinary mode approval performs no enqueue or network call', () async {
    final harness = await _Harness.create(memoryLinks: false);
    addTearDown(harness.dispose);

    await harness.approve();
    await Future<void>.delayed(const Duration(milliseconds: 50));

    expect(harness.transportCalls, 0);
    expect(await harness.jobRepo.getSessionJobs(_sessionId), isEmpty);
  });

  test(
    'approval drains one review draft and duplicate wakes do not call twice',
    () async {
      final harness = await _Harness.create(memoryLinks: true);
      addTearDown(harness.dispose);

      await harness.approve();
      await harness.waitForReview();
      harness.container
          .read(memoryConsolidationWorkerProvider)
          .notifyApproval(_sessionId);
      await harness.container
          .read(memoryConsolidationWorkerProvider)
          .recoverAndDrain();
      await Future<void>.delayed(const Duration(milliseconds: 50));

      final jobs = await harness.jobRepo.getSessionJobs(_sessionId);
      expect(jobs, hasLength(1));
      expect(jobs.single.status, 'review_pending');
      expect(harness.transportCalls, 1);
      expect(
        await harness.db.select(harness.db.memoryEventRows).get(),
        isEmpty,
      );
    },
  );

  test('approval waits for the session draft lease to settle', () async {
    final harness = await _Harness.create(memoryLinks: true);
    addTearDown(harness.dispose);
    final lease = harness.container
        .read(memoryActiveDraftsProvider.notifier)
        .acquire(_sessionId);

    await harness.approve();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(harness.transportCalls, 0);
    expect(await harness.jobRepo.getSessionJobs(_sessionId), isEmpty);

    lease.release();
    await harness.waitForReview();
    expect(harness.transportCalls, 1);
  });
}

final class _Harness {
  _Harness({
    required this.db,
    required this.container,
    required this.jobRepo,
    required this.draft,
  });

  final AppDatabase db;
  final ProviderContainer container;
  final MemoryConsolidationJobRepo jobRepo;
  final MemoryDraft draft;
  int transportCalls = 0;

  static Future<_Harness> create({required bool memoryLinks}) async {
    SharedPreferences.setMockInitialValues({});
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final jobRepo = MemoryConsolidationJobRepo(db);
    late _Harness harness;
    Future<String> transport({
      required AuxApiConfig config,
      required List<Map<String, String>> messages,
      required int maxTokens,
      required double temperature,
      required int timeoutMs,
      CancelToken? cancelToken,
    }) async {
      harness.transportCalls++;
      final prompt = messages.last['content']!;
      final eventId = RegExp(
        r'"proposedEventIds":\["([^"]+)"\]',
      ).firstMatch(prompt)!.group(1)!;
      final sourceRef = RegExp(
        r'"ref":"(entry:[^"]+)"',
      ).firstMatch(prompt)!.group(1)!;
      return jsonEncode({
        'contract': 'memory_event_consolidation',
        'version': 2,
        'outcome': 'confirmed',
        'events': [
          {
            'eventId': eventId,
            'kind': 'result',
            'description': _content,
            'state': 'completed',
            'sourceRefs': [sourceRef],
            'boundary': null,
          },
        ],
        'links': <Object>[],
        'unverifiedSourceRefs': <Object>[],
        'unexaminedOpenObligationIds': <Object>[],
      });
    }

    final batch = MemoryConsolidationBatchService(
      db: db,
      jobRepo: jobRepo,
      packBuilder: MemoryConsolidationPackBuilder(db),
      service: MemoryConsolidationService(call: transport),
      acceptance: MemoryConsolidationAcceptanceService(
        MemoryEventRegistryRepo(db),
      ),
    );
    final container = ProviderContainer(
      overrides: [
        appDbProvider.overrideWithValue(db),
        apiConfigRepoProvider.overrideWithValue(ApiConfigRepo(db)),
        memoryConsolidationJobRepoProvider.overrideWithValue(jobRepo),
        memoryConsolidationBatchProvider.overrideWithValue(batch),
      ],
    );
    final message = const ChatMessage(
      id: _messageId,
      role: 'assistant',
      content: _content,
      swipeId: 1,
      agentSwipeId: 2,
    );
    await container
        .read(chatRepoProvider)
        .put(
          ChatSession(
            id: _sessionId,
            characterId: _characterId,
            sessionIndex: 0,
            messages: [message],
          ),
        );
    await container.read(apiConfigRepoProvider).put(_config);
    final manifest = MemorySourceManifest.capture(
      _sessionId,
      [message],
      const [_messageId],
    );
    final draft = MemoryDraft(
      id: 'draft_worker',
      content: _content,
      messageIds: const [_messageId],
      sourceSwipeId: 1,
      sourceAgentSwipeId: 2,
      sourceManifest: manifest,
      status: 'pending_approval',
      source: 'scan_chat',
    );
    await container
        .read(memoryBookRepoProvider)
        .put(
          MemoryBook(
            id: 'memorybook_$_sessionId',
            sessionId: _sessionId,
            settings: MemoryBookSettings(
              memoryMode: memoryLinks ? 'memory_links' : 'fast',
              consolidationThreshold: 1,
            ),
            pendingDrafts: [draft],
          ),
        );
    if (memoryLinks) {
      await container
          .read(memoryGlobalSettingsProvider.notifier)
          .save(
            container
                .read(memoryGlobalSettingsProvider)
                .copyWith(memoryMode: 'memory_links'),
          );
    }
    harness = _Harness(
      db: db,
      container: container,
      jobRepo: jobRepo,
      draft: draft,
    );
    return harness;
  }

  Future<void> approve() async {
    final approved = await container
        .read(memoryBookOpsProvider)
        .approveDraft(_sessionId, draft.id, draft);
    expect(approved, isNotNull);
  }

  Future<void> waitForReview() async {
    for (var attempt = 0; attempt < 100; attempt++) {
      final jobs = await jobRepo.getSessionJobs(_sessionId);
      if (jobs.any((job) => job.status == 'review_pending')) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    fail('Automatic consolidation did not reach review_pending.');
  }

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}
