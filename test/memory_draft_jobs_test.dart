import 'dart:async';
import 'dart:convert';
import 'package:drift/drift.dart' hide Column, isNull, isNotNull;

import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/memory_book_repo.dart';
import 'package:glaze_flutter/core/models/character.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/credential_vault_provider.dart';
import 'package:glaze_flutter/core/state/memory_custom_api_credentials_provider.dart';
import 'package:glaze_flutter/core/state/pipeline_settings_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/chat/chat_session_service.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_draft_card.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/settings/native_memory_custom_api_settings.dart';
import 'package:glaze_flutter/features/memory/state/memory_active_drafts_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_book_revision_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'credentials/fake_credential_storage.dart';
import 'custom_memory_draft_publication_sql.dart';

/// The memory sheet used to own the draft-generation lifecycle, so closing it
/// mid-request threw the finished draft away: the completion wrote through the
/// sheet's own `WidgetRef`, and a ref whose widget is gone throws instead of
/// persisting. These cover what replaced it.
const _charId = 'char-jobs';
const _sessionId = 'session-jobs';
const _draftId = 'draft-1';

class _Harness {
  _Harness(
    this.container,
    this.db,
    this.generation,
    this.sql, [
    this.credentials,
  ]);
  final FakeCredentialStorage? credentials;
  final CustomMemoryDraftPublicationSql sql;

  final ProviderContainer container;
  final AppDatabase db;

  /// Completed by the test when the "LLM" is supposed to answer.
  final Completer<MemoryDraft> generation;

  MemoryBookRepo get repo => container.read(memoryBookRepoProvider);

  bool get isRunning => container
      .read(memoryDraftJobsProvider)
      .isGenerating(_sessionId, _draftId);

  Future<MemoryDraft> get persistedDraft async => (await repo.getBySessionId(
    _sessionId,
  ))!.pendingDrafts.singleWhere((d) => d.id == _draftId);

  Future<void> startGeneration() => container
      .read(memoryDraftJobsProvider.notifier)
      .generate(sessionId: _sessionId, charId: _charId, draftId: _draftId);
}

Future<_Harness> _seed({
  String draftContent = '',
  bool customApi = false,
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
  ChatSessionService.clearCache();
  final sql = CustomMemoryDraftPublicationSql();
  final db = AppDatabase.forTesting(NativeDatabase.memory().interceptWith(sql));
  final generation = Completer<MemoryDraft>();
  final credentials = customApi ? FakeCredentialStorage() : null;
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      if (credentials != null)
        credentialStorageProvider.overrideWithValue(credentials),
      vectorSearchAvailableProvider.overrideWithValue(false),
      memoryDraftGeneratorProvider.overrideWithValue(({
        required draft,
        required settings,
        required pipeline,
        required messages,
        required charId,
        required sessionId,
        required sessionVars,
        cancelToken,
        originalCustomApi,
      }) {
        if (customApi) {
          expect(originalCustomApi, isNotNull);
          expect(originalCustomApi!.isCurrent(), true);
          expect(pipeline.memoryBookApi.generationApiKey, '');
        }
        return generation.future;
      }),
    ],
  );
  addTearDown(() async {
    sql.release();
    container.dispose();
    ChatSessionService.clearCache();
    await db.close();
  });

  if (customApi) await container.read(pipelineSettingsProvider.notifier).load();

  await container
      .read(characterRepoProvider)
      .put(Character(id: _charId, name: 'Alice'));
  await container
      .read(chatRepoProvider)
      .put(
        const ChatSession(
          id: _sessionId,
          characterId: _charId,
          sessionIndex: 0,
          messages: [
            ChatMessage(id: 'm1', role: 'user', content: 'Hello', timestamp: 1),
          ],
        ),
      );
  await container
      .read(memoryBookRepoProvider)
      .put(
        MemoryBook(
          id: 'memorybook_$_sessionId',
          sessionId: _sessionId,
          pendingDrafts: [
            MemoryDraft(
              id: _draftId,
              title: 'First night',
              messageIds: const ['m1'],
              content: draftContent,
            ),
          ],
        ),
      );
  await container.read(chatProvider(_charId).future);
  return _Harness(container, db, generation, sql, credentials);
}

/// Opens the memory sheet on the Books tab and switches to Scan drafts, which
/// is the list the rows under test live on.
Future<void> _openSheet(WidgetTester tester, _Harness harness) async {
  await tester.binding.setSurfaceSize(const Size(412, 1000));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: EasyLocalization(
          supportedLocales: const [Locale('en'), Locale('ru')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('ru'),
          child: Builder(
            builder: (context) => MaterialApp(
              debugShowCheckedModeBanner: false,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              locale: context.locale,
              theme: AppTheme.dark(const ThemePreset(id: 'd', name: 'D')),
              home: const Scaffold(
                body: MemorySheet(charId: _charId, initialTab: MemoryTab.books),
              ),
            ),
          ),
        ),
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 50));
    for (var i = 0; i < 10; i++) {
      await tester.pump(const Duration(milliseconds: 80));
    }
  });
  await tester.tap(find.byIcon(Icons.drafts_outlined).last);
  await tester.pump(const Duration(milliseconds: 500));
  await tester.pump(const Duration(milliseconds: 500));
}

Future<void> _closeSheet(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox());
  await tester.pump();
}

/// Settles the harness's futures outside the fake clock the widget binding
/// uses, so the generation's own awaits can finish.
Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 10; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  await tester.pump();
}

Future<void> _settleGeneration(WidgetTester tester, _Harness harness) async {
  for (var i = 0; i < 10 && harness.isRunning; i++) {
    await _settle(tester);
  }
  expect(harness.isRunning, isFalse);
}

void main() {
  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await EasyLocalization.ensureInitialized();
  });

  for (final change in ['rotation', 'ordinary']) {
    testWidgets(
      'actual draft job rejects late custom-key publication: $change',
      (tester) async {
        final h = await _seed(customApi: true, draftContent: 'ORIGINAL');
        final owner = h.container.read(memoryCustomApiCredentialOwnerProvider);
        final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
        await owner.setApiKey(
          'SYNTHETIC_CUSTOM_JOB_KEY',
          settings: api,
          isCurrent: () => true,
        );
        final pending = h.startGeneration();
        await _settle(tester);
        expect(h.isRunning, true);
        if (change == 'rotation') {
          await owner.setApiKey(
            'SYNTHETIC_ROTATED_JOB_KEY',
            settings: api,
            isCurrent: () => true,
          );
        } else {
          final pipeline = h.container.read(pipelineSettingsProvider);
          await h.container
              .read(pipelineSettingsProvider.notifier)
              .save(
                pipeline.copyWith(
                  memoryBookApi: api.copyWith(generationTemperature: 0.9),
                ),
              );
        }
        h.generation.complete(
          const MemoryDraft(id: _draftId, content: 'LATE_RESULT', updatedAt: 5),
        );
        await pending;
        final durable = await h.persistedDraft;
        expect(durable.content, 'ORIGINAL');
        expect(durable.error, isNull);
        expect(h.container.read(memoryDraftJobsProvider).lastFailure, isNull);
        expect(h.container.read(memoryBookRevisionProvider), 0);
        expect(h.isRunning, false);
        expect(h.container.read(memoryActiveDraftsProvider), isEmpty);
      },
    );
  }

  for (final failure in [false, true]) {
    for (final change in ['rotation', 'CURRENT alias']) {
      testWidgets(
        'manual custom draft actual second read: $change / failure=$failure',
        (tester) async {
          final h = await _seed(customApi: true, draftContent: 'ORIGINAL');
          final owner = h.container.read(
            memoryCustomApiCredentialOwnerProvider,
          );
          final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
          const originalKey = 'SYNTHETIC_ORIGINAL_SECOND_READ_KEY';
          const lateKey = 'SYNTHETIC_LATE_SECOND_READ_ALIAS';
          await owner.setApiKey(
            originalKey,
            settings: api,
            isCurrent: () => true,
          );
          await h.repo.appendDrafts(_sessionId, const [
            MemoryDraft(id: 'sibling', content: 'Sibling remains'),
          ]);
          await h.repo.appendApprovedEntries(_sessionId, const [
            MemoryEntry(id: 'history-entry', content: 'History remains'),
          ]);
          final before = (await h.db.select(h.db.memoryBookRows).get()).single;
          final pending = h.startGeneration();
          await _settle(tester);
          h.sql.holdSecondRead();
          if (failure) {
            h.generation.completeError(
              StateError('Failure $originalKey $lateKey'),
            );
          } else {
            h.generation.complete(
              const MemoryDraft(
                id: _draftId,
                content: 'Visible $originalKey $lateKey',
                keys: [originalKey, lateKey],
                keyParagraphs: {
                  originalKey: [1],
                  lateKey: [1],
                },
                ledgerRange: lateKey,
              ),
            );
          }
          try {
            await Future.any<void>([
              h.sql.entered,
              pending.then((_) => fail('Missed second read')),
            ]);
            expect(h.sql.writes, isEmpty);
            if (change == 'rotation') {
              await owner.setApiKey(
                'SYNTHETIC_ROTATED_SECOND_READ_KEY',
                settings: api,
                isCurrent: () => true,
              );
            } else {
              h.container
                  .read(secretRedactionCoordinatorProvider)
                  .registerSecret(lateKey);
            }
          } finally {
            h.sql.release();
          }
          await pending;
          final row = (await h.db.select(h.db.memoryBookRows).get()).single;
          expect(row.entriesJson, before.entriesJson);
          expect(row.settingsJson, before.settingsJson);
          expect(
            row.lastProcessedMessageCount,
            before.lastProcessedMessageCount,
          );
          final durable = await h.persistedDraft;
          if (change == 'rotation') {
            expect(h.sql.writes, isEmpty);
            expect(row.pendingDraftsJson, before.pendingDraftsJson);
            expect(
              h.container.read(memoryDraftJobsProvider).lastFailure,
              isNull,
            );
            expect(h.container.read(memoryBookRevisionProvider), 0);
          } else {
            expect(h.sql.writes, hasLength(1));
            // These are actual SQL arguments, not a later UI/redactor observation.
            final submitted = h.sql.writes.single.args.toString();
            expect(submitted, isNot(contains(originalKey)));
            expect(submitted, isNot(contains(lateKey)));
            expect(row.pendingDraftsJson, isNot(contains(lateKey)));
            expect(
              durable.status,
              failure ? 'needs_regeneration' : 'pending_approval',
            );
            expect(
              (await h.repo.getBySessionId(
                _sessionId,
              ))!.pendingDrafts.last.content,
              'Sibling remains',
            );
            expect(
              h.container.read(memoryDraftJobsProvider).lastFailure?.message ??
                  '',
              isNot(contains(lateKey)),
            );
          }
          expect(h.isRunning, false);
          expect(h.container.read(memoryActiveDraftsProvider), isEmpty);
        },
      );
    }
  }

  testWidgets(
    'manual custom draft retirement after SQL rolls publication back',
    (tester) async {
      final h = await _seed(customApi: true, draftContent: 'ORIGINAL');
      final owner = h.container.read(memoryCustomApiCredentialOwnerProvider);
      final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(
        'SYNTHETIC_POSTWRITE_ORIGINAL',
        settings: api,
        isCurrent: () => true,
      );
      final before = (await h.db.select(h.db.memoryBookRows).get()).single;
      final pending = h.startGeneration();
      await _settle(tester);
      h.sql.afterWrite = () async {
        h.sql.afterWrite = null;
        await owner.setApiKey(
          'SYNTHETIC_POSTWRITE_ROTATED',
          settings: api,
          isCurrent: () => true,
        );
      };
      h.generation.complete(
        const MemoryDraft(id: _draftId, content: 'LATE_RESULT'),
      );
      await pending;
      final after = (await h.db.select(h.db.memoryBookRows).get()).single;
      expect(after.toJson(), before.toJson());
      expect(h.container.read(memoryDraftJobsProvider).lastFailure, isNull);
      expect(h.container.read(memoryBookRevisionProvider), 0);
    },
  );

  testWidgets(
    'manual custom draft CURRENT alias after SQL rolls publication back without retiring custody',
    (tester) async {
      final h = await _seed(customApi: true, draftContent: 'ORIGINAL');
      final owner = h.container.read(memoryCustomApiCredentialOwnerProvider);
      final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(
        'SYNTHETIC_POST_SQL_ORIGINAL_KEY',
        settings: api,
        isCurrent: () => true,
      );
      await h.repo.appendDrafts(_sessionId, const [
        MemoryDraft(id: 'sibling', content: 'Sibling remains'),
      ]);
      await h.repo.appendApprovedEntries(_sessionId, const [
        MemoryEntry(id: 'history-entry', content: 'History remains'),
      ]);
      final original = owner.capture(api, isCurrent: () => true);
      final before = (await h.db.select(h.db.memoryBookRows).get()).single;
      final pending = h.startGeneration();
      await _settle(tester);
      h.sql.writes.clear();
      const lateAlias = 'SYNTHETIC_POLICY_ONLY_AFTER_SQL_ALIAS';
      h.sql.afterWrite = () async {
        h.sql.afterWrite = null;
        h.container
            .read(secretRedactionCoordinatorProvider)
            .registerSecret(lateAlias);
        expect(original.isCurrent(), true);
      };
      h.generation.complete(
        const MemoryDraft(
          id: _draftId,
          content: 'Visible $lateAlias',
          keys: [lateAlias],
          keyParagraphs: {
            lateAlias: [1],
          },
          ledgerRange: lateAlias,
        ),
      );
      await pending;
      expect(h.sql.writes, hasLength(1));
      expect(h.sql.writes.single.args.toString(), contains(lateAlias));
      final after = (await h.db.select(h.db.memoryBookRows).get()).single;
      expect(after.toJson(), before.toJson());
      expect(after.pendingDraftsJson, isNot(contains(lateAlias)));
      expect(original.isCurrent(), true);
      expect(h.container.read(memoryDraftJobsProvider).lastFailure, isNull);
      expect(h.container.read(memoryBookRevisionProvider), 0);
      expect(h.isRunning, false);
      expect(h.container.read(memoryActiveDraftsProvider), isEmpty);
    },
  );

  testWidgets(
    'native settings key entry/set/clear never publishes plaintext DTO',
    (tester) async {
      final h = await _seed(customApi: true);
      final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.dark(const ThemePreset(id: 'd', name: 'D')),
            home: Scaffold(
              body: SingleChildScrollView(
                child: NativeMemoryCustomApiSettings(
                  api: api,
                  onChanged: (_) =>
                      fail('Key entry must not update ordinary settings'),
                ),
              ),
            ),
          ),
        ),
      );
      final keyField = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.obscureText,
      );
      await tester.enterText(keyField, 'SYNTHETIC_UI_MEMORY_KEY');
      await tester.pump();
      await tester.ensureVisible(find.text('Set key'));
      await tester.tap(find.text('Set key'));
      await _settle(tester);
      expect(
        h.credentials!.values.values.single,
        contains('SYNTHETIC_UI_MEMORY_KEY'),
      );
      expect(
        h.container
            .read(pipelineSettingsProvider)
            .memoryBookApi
            .generationApiKey,
        '',
      );
      expect(find.text('SYNTHETIC_UI_MEMORY_KEY'), findsNothing);
      await tester.tap(find.text('Clear key'));
      await _settle(tester);
      expect(h.credentials!.values.values.single, '');
      expect(
        h.container
            .read(pipelineSettingsProvider)
            .memoryBookApi
            .generationApiKey,
        '',
      );
      expect(find.text('Key cleared in secure storage.'), findsOneWidget);
    },
  );

  testWidgets(
    'native existing key: blank Set is disabled and retained callback writes nothing; Clear is explicit',
    (tester) async {
      final h = await _seed(customApi: true);
      final owner = h.container.read(memoryCustomApiCredentialOwnerProvider);
      final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
      await owner.setApiKey(
        'SYNTHETIC_EXISTING_UI_KEY',
        settings: api,
        isCurrent: () => true,
      );
      final original = owner.capture(api, isCurrent: () => true);
      final before = Map<String, String>.of(h.credentials!.values);
      final writesBefore = h.credentials!.operations
          .where((op) => op == 'write')
          .length;
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: h.container,
          child: MaterialApp(
            theme: AppTheme.dark(const ThemePreset(id: 'd', name: 'D')),
            home: Scaffold(
              body: SingleChildScrollView(
                child: NativeMemoryCustomApiSettings(
                  api: api,
                  onChanged: (_) =>
                      fail('Blank key must not change ordinary settings'),
                ),
              ),
            ),
          ),
        ),
      );
      GlazeActionButton button(String label) =>
          tester.widget<GlazeActionButton>(
            find.byWidgetPredicate(
              (widget) => widget is GlazeActionButton && widget.label == label,
            ),
          );
      final field = find.byWidgetPredicate(
        (widget) => widget is TextField && widget.obscureText,
      );
      expect(button('Set key').onTap, isNull);
      expect(button('Clear key').onTap, isNotNull);
      await tester.enterText(field, 'SYNTHETIC_NOT_SUBMITTED');
      await tester.pump();
      final retainedSet = button('Set key').onTap!;
      for (final blank in ['', '   \t  ']) {
        await tester.enterText(field, blank);
        await tester.pump();
        expect(button('Set key').onTap, isNull);
        expect(button('Clear key').onTap, isNotNull);
        retainedSet();
        await _settle(tester);
        expect(
          h.credentials!.operations.where((op) => op == 'write').length,
          writesBefore,
        );
        expect(h.credentials!.values, before);
        expect(original.isCurrent(), true);
        expect((await owner.load()).configured, true);
        expect(
          find.text('Key stored for this exact connection.'),
          findsNothing,
        );
        expect(find.text('Key cleared in secure storage.'), findsNothing);
      }
      button('Clear key').onTap!();
      await _settle(tester);
      expect(h.credentials!.values.values.single, '');
      expect((await owner.load()).configured, false);
      expect(find.text('Key cleared in secure storage.'), findsOneWidget);
      expect(button('Set key').onTap, isNull);
    },
  );

  testWidgets(
    'actual custom draft transaction sanitizes CURRENT and original aliases',
    (tester) async {
      final h = await _seed(customApi: true);
      final owner = h.container.read(memoryCustomApiCredentialOwnerProvider);
      final api = h.container.read(pipelineSettingsProvider).memoryBookApi;
      const original = 'SYNTHETIC_ORIGINAL_JOB_KEY';
      const current = 'SYNTHETIC_LATE_OTHER_JOB_KEY';
      await owner.setApiKey(original, settings: api, isCurrent: () => true);
      final pending = h.startGeneration();
      await _settle(tester);
      h.container
          .read(secretRedactionCoordinatorProvider)
          .registerSecret(current);
      h.generation.complete(
        const MemoryDraft(
          id: _draftId,
          content: 'Visible $original $current',
          keys: [original, current],
          keyParagraphs: {
            original: [1],
            current: [1],
          },
          updatedAt: 5,
        ),
      );
      await pending;
      final durable = await h.persistedDraft;
      expect(durable.status, 'pending_approval');
      expect(durable.content, contains('Visible'));
      expect(durable.content, isNot(contains(original)));
      expect(durable.content, isNot(contains(current)));
      expect(durable.keys.join(), isNot(contains(original)));
      expect(durable.keys.join(), isNot(contains(current)));
      expect(durable.keyParagraphs.keys.join(), isNot(contains(original)));
      expect(durable.keyParagraphs.keys.join(), isNot(contains(current)));
    },
  );

  testWidgets('a generation started from the sheet outlives closing it', (
    tester,
  ) async {
    final harness = await _seed();
    await _openSheet(tester, harness);
    unawaited(harness.startGeneration());
    await _settle(tester);
    expect(harness.isRunning, isTrue);

    await _closeSheet(tester);
    harness.generation.complete(
      const MemoryDraft(
        id: _draftId,
        content: 'GENERATED',
        keys: ['night'],
        generatedAt: 5,
        updatedAt: 5,
      ),
    );
    await _settle(tester);

    final draft = await harness.persistedDraft;
    expect(draft.content, 'GENERATED');
    expect(draft.status, 'pending_approval');
    expect(harness.isRunning, isFalse);
    // And the session lease is handed back, so auto-generation is not blocked
    // out of the session for the rest of the app's life.
    expect(harness.container.read(memoryActiveDraftsProvider), isEmpty);
  });

  testWidgets('reopening the sheet finds the generation still running', (
    tester,
  ) async {
    final harness = await _seed();
    await _openSheet(tester, harness);
    unawaited(harness.startGeneration());
    await _settle(tester);

    await _closeSheet(tester);
    await _openSheet(tester, harness);

    // The row is back on its generating face: Stop, not Generate — and it
    // still counts from when the request actually went out.
    final row = find.byType(MemoryDraftCard);
    expect(
      find.descendant(of: row, matching: find.byIcon(Icons.stop_rounded)),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: row,
        matching: find.byIcon(Icons.auto_awesome_rounded),
      ),
      findsNothing,
    );
    expect(
      harness.container
          .read(memoryDraftJobsProvider)
          .startedAt(_sessionId, _draftId),
      isNotNull,
    );

    harness.generation.complete(
      const MemoryDraft(id: _draftId, content: 'GENERATED', updatedAt: 5),
    );
    await _settleGeneration(tester, harness);
  });

  testWidgets('a generation that lands while the sheet is open shows up', (
    tester,
  ) async {
    final harness = await _seed();
    await _openSheet(tester, harness);
    unawaited(harness.startGeneration());
    await _settle(tester);
    expect(harness.isRunning, isTrue);

    harness.generation.complete(
      const MemoryDraft(id: _draftId, content: 'GENERATED', updatedAt: 5),
    );
    await _settleGeneration(tester, harness);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('GENERATED'), findsOneWidget);
  });

  testWidgets('drafts written from outside reach an open sheet', (
    tester,
  ) async {
    // What the auto-create stage does during a chat turn: it writes to the
    // repository and publishes the change. The sheet holds the book it read
    // when it opened, so without that it showed neither.
    final harness = await _seed();
    await _openSheet(tester, harness);
    expect(find.text('Auto draft'), findsNothing);

    await tester.runAsync(() async {
      await harness.repo.appendDrafts(_sessionId, const [
        MemoryDraft(id: 'draft-2', title: 'Auto draft', messageIds: ['m1']),
      ]);
    });
    harness.container.read(memoryBookRevisionProvider.notifier).state++;
    await _settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    expect(find.text('Auto draft'), findsOneWidget);

    harness.generation.complete(
      const MemoryDraft(id: _draftId, content: 'x', updatedAt: 5),
    );
  });
}
