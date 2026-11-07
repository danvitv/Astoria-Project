import 'dart:async';
import 'dart:convert';
import 'package:dio/dio.dart';
import 'package:drift/native.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/db/repositories/api_config_repo.dart';
import 'package:glaze_flutter/core/db/repositories/memory_consolidation_pack_builder.dart';
import 'package:glaze_flutter/core/db/repositories/memory_event_registry_repo.dart';
import 'package:glaze_flutter/core/llm/aux_llm_client.dart';
import 'package:glaze_flutter/core/models/api_config.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/models/memory_source_manifest.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_acceptance_service.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_coordinator.dart';
import 'package:glaze_flutter/core/services/memory_consolidation_service.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_books_tab.dart';
import 'package:glaze_flutter/features/memory/state/memory_book_revision_provider.dart';
import 'package:glaze_flutter/shared/theme/app_theme.dart';
import 'package:glaze_flutter/shared/theme/theme_preset.dart';

const _sessionId = 'consolidation-session';
const _characterId = 'consolidation-character';
const _entryId = 'memory-entry';
const _config = ApiConfig(
  id: 'test-api',
  endpoint: 'https://example.invalid/v1/chat/completions',
  apiKey: 'test-only',
  model: 'test-model',
  protocol: 'custom_chat_completion',
);

class _Harness {
  _Harness(this.db, this.container, this.requestGate);

  final AppDatabase db;
  final ProviderContainer container;
  final Completer<void>? requestGate;
  int transportCalls = 0;
  CancelToken? lastCancelToken;

  Future<int> activeEventCount() async =>
      (await db.select(db.memoryEventRows).get()).length;

  Future<void> dispose() async {
    container.dispose();
    await db.close();
  }
}

Future<_Harness> _makeHarness({Completer<void>? requestGate}) async {
  final db = AppDatabase.forTesting(NativeDatabase.memory());
  late final _Harness harness;
  final coordinator = MemoryConsolidationCoordinator(
    packBuilder: MemoryConsolidationPackBuilder(db),
    service: MemoryConsolidationService(
      call:
          ({
            required AuxApiConfig config,
            required List<Map<String, String>> messages,
            required int maxTokens,
            required double temperature,
            required int timeoutMs,
            CancelToken? cancelToken,
          }) async {
            harness.transportCalls++;
            harness.lastCancelToken = cancelToken;
            expect(config.model, 'test-model');
            expect(messages.last['content'], contains('The key was returned.'));
            if (requestGate != null) await requestGate.future;
            final proposedEventId = RegExp(
              r'"proposedEventId":"([^"]+)"',
            ).firstMatch(messages.last['content']!)!.group(1)!;
            return _response.replaceAll('event-reviewed', proposedEventId);
          },
    ),
    acceptance: MemoryConsolidationAcceptanceService(
      MemoryEventRegistryRepo(db),
    ),
  );
  final container = ProviderContainer(
    overrides: [
      appDbProvider.overrideWithValue(db),
      memoryConsolidationCoordinatorProvider.overrideWithValue(coordinator),
      apiConfigRepoProvider.overrideWithValue(ApiConfigRepo(db)),
      vectorSearchAvailableProvider.overrideWithValue(false),
    ],
  );
  harness = _Harness(db, container, requestGate);
  await container.read(apiConfigRepoProvider).put(_config);
  const sourceMessage = ChatMessage(
    id: 'message-1',
    role: 'assistant',
    content: 'The key was returned.',
    swipeId: 1,
    agentSwipeId: 2,
  );
  await db
      .into(db.chatSessions)
      .insert(
        ChatSessionsCompanion.insert(
          sessionId: _sessionId,
          characterId: _characterId,
          sessionIndex: 0,
          messagesJson: jsonEncode([sourceMessage.toJson()]),
        ),
      );
  final manifest = MemorySourceManifest.capture(
    _sessionId,
    const [sourceMessage],
    const ['message-1'],
  );
  final revision = MemoryEntryRevision(
    id: 'memory-entry:r1',
    version: 1,
    title: 'The key',
    content: 'The key was returned.',
    messageIds: const ['message-1'],
    sourceManifest: manifest,
    createdAt: 1,
  );
  await container
      .read(memoryBookRepoProvider)
      .put(
        MemoryBook(
          id: 'memorybook_$_sessionId',
          sessionId: _sessionId,
          settings: const MemoryBookSettings(
            consolidationEnabled: true,
            autoCreateEnabled: false,
            autoGenerateEnabled: false,
          ),
          entries: [
            MemoryEntry(
              id: _entryId,
              title: 'The key',
              content: 'The key was returned.',
              messageIds: const ['message-1'],
              sourceSwipeId: 1,
              sourceAgentSwipeId: 2,
              sourceManifest: manifest,
              activeRevisionId: revision.id,
              revisions: [revision],
            ),
          ],
        ),
      );
  return harness;
}

const _response = '''{
  "contract":"memory_event_consolidation",
  "version":1,
  "outcome":"confirmed",
  "event":{
    "eventId":"event-reviewed",
    "kind":"result",
    "description":"The key was returned.",
    "state":"completed",
    "sourceRefs":["entry:memory-entry"],
    "boundary":null
  },
  "links":[],
  "unverifiedSourceRefs":[],
  "unexaminedOpenObligationIds":[]
}''';

Future<void> _pumpTab(WidgetTester tester, _Harness harness) async {
  SharedPreferences.setMockInitialValues({});
  await EasyLocalization.ensureInitialized();
  await tester.binding.setSurfaceSize(const Size(700, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.runAsync(() async {
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: harness.container,
        child: EasyLocalization(
          supportedLocales: const [Locale('en')],
          path: 'assets/translations',
          fallbackLocale: const Locale('en'),
          startLocale: const Locale('en'),
          child: Builder(
            builder: (context) => MaterialApp(
              locale: context.locale,
              localizationsDelegates: context.localizationDelegates,
              supportedLocales: context.supportedLocales,
              theme: AppTheme.dark(
                const ThemePreset(id: 'default', name: 'Default'),
              ),
              home: const Scaffold(
                body: SizedBox.expand(
                  child: MemoryBooksTab(
                    sessionId: _sessionId,
                    charId: _characterId,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
    for (var i = 0; i < 128; i++) {
      await Future<void>.delayed(Duration.zero);
      await tester.pump();
      if (find.byTooltip('The key').evaluate().isNotEmpty) break;
    }
  });
  expect(find.text('The key'), findsOneWidget);
}

Future<void> _startReview(WidgetTester tester) async {
  await tester.tap(find.byTooltip('The key').first);
  await tester.pumpAndSettle();
  await tester.tap(find.text('Review related events'));
  for (var i = 0; i < 128; i++) {
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
    if (find.text('Reject').evaluate().isNotEmpty) break;
  }
  await tester.pumpAndSettle();
  expect(find.text('Reject'), findsOneWidget);
}

void main() {
  testWidgets(
    'generation is reviewed and only accepted after explicit action',
    (tester) async {
      final harness = await _makeHarness();
      addTearDown(harness.dispose);
      await _pumpTab(tester, harness);

      await _startReview(tester);

      expect(harness.transportCalls, 1);
      expect(find.text('The key was returned.'), findsWidgets);
      expect(find.text('Accept event'), findsOneWidget);
      expect(await harness.activeEventCount(), 0);

      await tester.tap(find.text('Accept event'));
      await tester.pumpAndSettle();

      expect(await harness.activeEventCount(), 1);
    },
  );

  testWidgets('rejecting a reviewed draft leaves the registry unchanged', (
    tester,
  ) async {
    final harness = await _makeHarness();
    addTearDown(harness.dispose);
    await _pumpTab(tester, harness);

    await _startReview(tester);
    await tester.tap(find.text('Reject'));
    await tester.pumpAndSettle();

    expect(await harness.activeEventCount(), 0);
  });

  testWidgets('cancel cancels the in-flight generation', (tester) async {
    final gate = Completer<void>();
    final harness = await _makeHarness(requestGate: gate);
    addTearDown(harness.dispose);
    await _pumpTab(tester, harness);

    await tester.tap(find.byTooltip('The key').first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Review related events'));
    for (var i = 0; i < 128 && harness.transportCalls == 0; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
    }
    await tester.tap(find.text('Cancel review'));
    gate.complete();
    await tester.pumpAndSettle();

    expect(harness.transportCalls, 1);
    expect(harness.lastCancelToken?.isCancelled, isTrue);
    expect(await harness.activeEventCount(), 0);
    expect(find.text('Cancel review'), findsNothing);
  });

  testWidgets('source revision change blocks acceptance from open review', (
    tester,
  ) async {
    final harness = await _makeHarness();
    addTearDown(harness.dispose);
    await _pumpTab(tester, harness);

    await _startReview(tester);
    final repo = harness.container.read(memoryBookRepoProvider);
    final book = (await repo.getBySessionId(_sessionId))!;
    final entry = book.entries.single;
    await repo.reviseEntry(
      sessionId: _sessionId,
      expected: entry,
      proposed: entry.copyWith(content: 'The key was taken back.'),
    );
    harness.container.read(memoryBookRevisionProvider.notifier).state++;
    await tester.pumpAndSettle();
    await tester.tap(find.text('Accept event'));
    for (var i = 0; i < 128; i++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump();
      if (find.text('Cancel review').evaluate().isEmpty) break;
    }
    await tester.pumpAndSettle();

    expect(await harness.activeEventCount(), 0);
  });
}
