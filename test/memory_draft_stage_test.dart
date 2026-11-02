import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/memory_custom_api_credentials_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/core/state/pipeline_settings_provider.dart';
import 'package:glaze_flutter/features/chat/abort_handler.dart';
import 'package:glaze_flutter/features/chat/chat_state.dart';
import 'package:glaze_flutter/features/chat/services/stages/memory_draft_stage.dart';
import 'package:glaze_flutter/features/chat/services/stages/stage_context.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_book_revision_provider.dart';

import 'credentials/fake_credential_storage.dart';
import 'custom_memory_draft_publication_sql.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final failure in [false, true]) {
    for (final change in ['rotation', 'CURRENT alias']) {
      test(
        'automatic custom draft actual second read: $change / failure=$failure',
        () async {
          const originalKey = 'SYNTHETIC_AUTO_ORIGINAL_KEY';
          const lateKey = 'SYNTHETIC_AUTO_LATE_ALIAS';
          final sql = CustomMemoryDraftPublicationSql();
          late _Harness harness;
          late MemoryBookRow before;
          harness = await _createHarness(
            autoGenerate: true,
            customApi: true,
            publicationSql: sql,
            generatedText: 'Visible $originalKey $lateKey',
            generationError: failure
                ? StateError('Failure $originalKey $lateKey')
                : null,
            beforeGenerationResult: () async {
              before =
                  (await harness.db.select(harness.db.memoryBookRows).get())
                      .single;
              sql.holdSecondRead();
            },
          );
          addTearDown(harness.dispose);
          final owner = harness.container.read(
            memoryCustomApiCredentialOwnerProvider,
          );
          final api = harness.container
              .read(pipelineSettingsProvider)
              .memoryBookApi;
          await owner.setApiKey(
            originalKey,
            settings: api,
            isCurrent: () => true,
          );
          final repo = harness.container.read(memoryBookRepoProvider);
          await repo.put(
            const MemoryBook(
              id: 'memorybook_s1',
              sessionId: 's1',
              entries: [
                MemoryEntry(id: 'history-entry', content: 'History remains'),
              ],
              pendingDrafts: [
                MemoryDraft(id: 'sibling', content: 'Sibling remains'),
              ],
            ),
          );
          final lease = harness.stage.reserveAutoGeneration(harness.session);
          final pending = harness.stage.run(
            harness.session,
            generationLease: lease,
          );
          try {
            await Future.any<void>([
              sql.entered,
              pending.then((_) => fail('Missed second read')),
            ]);
            expect(sql.writes, isEmpty);
            if (change == 'rotation') {
              await owner.setApiKey(
                'SYNTHETIC_AUTO_ROTATED_KEY',
                settings: api,
                isCurrent: () => true,
              );
            } else {
              harness.container
                  .read(secretRedactionCoordinatorProvider)
                  .registerSecret(lateKey);
            }
          } finally {
            sql.release();
          }
          await pending;
          final row =
              (await harness.db.select(harness.db.memoryBookRows).get()).single;
          expect(row.entriesJson, before.entriesJson);
          expect(row.settingsJson, before.settingsJson);
          expect(
            row.lastProcessedMessageCount,
            before.lastProcessedMessageCount,
          );
          final book = (await repo.getBySessionId('s1'))!;
          expect(book.pendingDrafts.first.content, 'Sibling remains');
          if (change == 'rotation') {
            expect(sql.writes, isEmpty);
            expect(row.pendingDraftsJson, before.pendingDraftsJson);
            expect(
              harness.container.read(memoryBookRevisionProvider),
              1,
            ); // Planned drafts only.
          } else {
            expect(sql.writes, hasLength(1));
            final submitted = sql.writes.single.args.toString();
            expect(submitted, isNot(contains(originalKey)));
            expect(submitted, isNot(contains(lateKey)));
            expect(row.pendingDraftsJson, isNot(contains(lateKey)));
            expect(
              book.pendingDrafts.last.status,
              failure ? 'needs_regeneration' : 'pending_approval',
            );
            expect(harness.container.read(memoryBookRevisionProvider), 2);
          }
          expect(harness.calls(), 1);
          expect(harness.container.read(memoryActiveDraftsProvider), isEmpty);
        },
      );
    }
  }

  test(
    'auto-generation fills newly planned drafts and releases its lease',
    () async {
      final harness = await _createHarness(autoGenerate: true);
      addTearDown(harness.dispose);
      final lease = harness.stage.reserveAutoGeneration(harness.session);
      expect(lease, isNotNull);
      expect(harness.container.read(memoryActiveDraftsProvider), {'s1'});

      await harness.stage.run(harness.session, generationLease: lease);

      final book = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId('s1');
      expect(harness.calls(), 1);
      expect(book!.pendingDrafts, hasLength(1));
      expect(book.pendingDrafts.single.content, 'Generated memory');
      expect(book.pendingDrafts.single.status, 'pending_approval');
      expect(book.pendingDrafts.single.messageIds, ['u1', 'a1']);
      expect(book.pendingDrafts.single.ledgerRange, 'range');
      expect(harness.container.read(memoryActiveDraftsProvider), isEmpty);
    },
  );

  test(
    'disabled auto-generation creates an empty draft without an LLM call',
    () async {
      final harness = await _createHarness(autoGenerate: false);
      addTearDown(harness.dispose);

      expect(harness.stage.reserveAutoGeneration(harness.session), isNull);
      await harness.stage.run(harness.session);

      final book = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId('s1');
      expect(harness.calls(), 0);
      expect(book!.pendingDrafts.single.status, 'pending_generation');
      expect(book.pendingDrafts.single.content, isEmpty);
    },
  );

  test(
    'generation failure leaves the draft retryable and releases lease',
    () async {
      final harness = await _createHarness(
        autoGenerate: true,
        generationError: StateError('provider failed'),
      );
      addTearDown(harness.dispose);
      final lease = harness.stage.reserveAutoGeneration(harness.session);

      await harness.stage.run(harness.session, generationLease: lease);

      final book = await harness.container
          .read(memoryBookRepoProvider)
          .getBySessionId('s1');
      expect(book!.pendingDrafts.single.status, 'needs_regeneration');
      expect(book.pendingDrafts.single.error, contains('provider failed'));
      expect(harness.container.read(memoryActiveDraftsProvider), isEmpty);
    },
  );
}

Future<_Harness> _createHarness({
  required bool autoGenerate,
  Object? generationError,
  bool customApi = false,
  String generatedText = 'Generated memory',
  CustomMemoryDraftPublicationSql? publicationSql,
  Future<void> Function()? beforeGenerationResult,
}) async {
  SharedPreferences.setMockInitialValues(
    customApi
        ? {
            'pipelineSettings': jsonEncode({
              'studioAgent': <String, dynamic>{},
              'memoryBookApi': {
                'generationSource': 'custom',
                'generationEndpoint':
                    'https://synthetic.example/exact-operation',
                'generationModel': 'synthetic-model',
                'generationApiKey': '',
              },
            }),
          }
        : {},
  );
  final sql = publicationSql ?? CustomMemoryDraftPublicationSql();
  final db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(sql));
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      if (customApi)
        credentialStorageProvider.overrideWithValue(FakeCredentialStorage()),
    ],
  );
  if (customApi) await container.read(pipelineSettingsProvider.notifier).load();
  await container
      .read(memoryGlobalSettingsProvider.notifier)
      .save(
        MemoryGlobalSettings(
          autoGenerateEnabled: autoGenerate,
          autoCreateInterval: 2,
          autoCreateLagMessages: 0,
          batchSize: 1,
        ),
      );

  var calls = 0;
  final stageProvider = Provider<MemoryDraftStage>((ref) {
    late AsyncValue<ChatState> state = const AsyncData(ChatState());
    final abortHandler = AbortHandler(
      ref: ref,
      charId: 'c1',
      setState: (next) => state = next,
      getState: () => state,
      mutateSession: (_, _) async => null,
      loadSession: (_) async => null,
    );
    return MemoryDraftStage(
      StageContext(
        ref: ref,
        charId: 'c1',
        abortHandler: abortHandler,
        setState: (next) => state = next,
        getState: () => state,
      ),
      generate:
          ({
            required draft,
            required settings,
            required pipeline,
            required messages,
            required charId,
            required sessionId,
            required sessionVars,
            originalCustomApi,
          }) async {
            calls++;
            if (customApi) {
              expect(originalCustomApi, isNotNull);
              expect(originalCustomApi!.isCurrent(), true);
            }
            await beforeGenerationResult?.call();
            if (generationError != null) throw generationError;
            expect(messages.map((message) => message.id), ['u1', 'a1']);
            expect(charId, 'c1');
            expect(sessionId, 's1');
            expect(sessionVars, isEmpty);
            return draft.copyWith(
              content: generatedText,
              keys: ['memory'],
              ledgerRange: 'range',
              status: 'pending_approval',
              generatedAt: 100,
              updatedAt: 100,
            );
          },
    );
  });
  return _Harness(
    container: container,
    db: db,
    sql: sql,
    stage: container.read(stageProvider),
    session: const ChatSession(
      id: 's1',
      characterId: 'c1',
      sessionIndex: 0,
      sessionVars: {},
      messages: [
        ChatMessage(id: 'u1', role: 'user', content: 'User turn'),
        ChatMessage(id: 'a1', role: 'assistant', content: 'Assistant turn'),
      ],
    ),
    calls: () => calls,
  );
}

class _Harness {
  const _Harness({
    required this.container,
    required this.db,
    required this.sql,
    required this.stage,
    required this.session,
    required this.calls,
  });

  final ProviderContainer container;
  final AppDatabase db;
  final CustomMemoryDraftPublicationSql sql;
  final MemoryDraftStage stage;
  final ChatSession session;
  final int Function() calls;

  Future<void> dispose() async {
    sql.release();
    container.dispose();
    await db.close();
  }
}
