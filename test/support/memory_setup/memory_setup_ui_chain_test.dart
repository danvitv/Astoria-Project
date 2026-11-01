import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/embedding_repo.dart';
import 'package:glaze_flutter/core/llm/embedding_service.dart';
import 'package:glaze_flutter/core/llm/memory_draft_planner.dart';
import 'package:glaze_flutter/core/llm/memory_injection_service.dart';
import 'package:glaze_flutter/core/llm/transport/llm_capture_context.dart';
import 'package:glaze_flutter/core/models/chat_message.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/core/state/memory_book_ops_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/features/settings/api_list_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_books_tab.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';
import 'package:glaze_flutter/shared/widgets/menu_group.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_memory_setup_sheet.dart';

import 'memory_setup_native_fixture.dart';

void main() {
  memorySetupTest(
    'five native questions paint exact separate plan; only explicit native confirm commits',
    (tester, f) async {
      final beforeMemory = f.prefs.getString('memorySettings');
      final beforePipeline = f.prefs.getString('pipelineSettings');
      final context = tester.element(find.byType(SupportAssistantScreen));
      final modal = showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => SupportMemorySetupSheet(service: f.service),
      );
      await tester.pump();
      final route = ModalRoute.of<void>(
        tester.element(find.byType(SupportMemorySetupSheet)),
      )!;
      await tester.pump(route.transitionDuration);
      await tester.pump(const Duration(microseconds: 1));
      expect(route.isCurrent, isTrue);
      expect(route.animation!.status, AnimationStatus.completed);
      bool wizardBusy() {
        final list = tester.widget<ListView>(
          find.descendant(
            of: find.byType(SupportMemorySetupSheet),
            matching: find.byType(ListView),
          ),
        );
        // The trailing spinner can be outside the lazy viewport, so a finder
        // sees no spinner while metadata/SQL work is still pending. Inspect the
        // actual declared presentation, not only its mounted list children.
        final children =
            (list.childrenDelegate as SliverChildListDelegate).children;
        return children.any(
          (child) =>
              child is Center && child.child is CircularProgressIndicator,
        );
      }

      Future<void> tap(String key) async {
        final finder = find.byKey(ValueKey(key));
        if (finder.evaluate().isEmpty) {
          final scrollable = find
              .descendant(
                of: find.byType(SupportMemorySetupSheet),
                matching: find.byType(Scrollable),
              )
              .first;
          // Later Undo/overview buttons are above the long plan just read.
          // Search from a known edge, rather than scrolling past them forever.
          tester.state<ScrollableState>(scrollable).position.jumpTo(0);
          await tester.pump();
          await tester.scrollUntilVisible(
            finder,
            300,
            scrollable: scrollable,
            maxScrolls: 20,
          );
        }
        // Top alignment puts a nested plan's Confirm at y=90..129, entirely
        // behind SheetView's pinned header (y=90..152 at 800x600).
        await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
        await tester.pump();
        expect(
          finder.hitTestable(),
          findsOneWidget,
          reason: '$key must be reachable below the pinned sheet header',
        );
        expect(
          tester.widget<GlazeActionButton>(finder).onTap,
          isNotNull,
          reason: '$key must be enabled before the native gesture',
        );
        await configurationAction(tester, () => tester.tap(finder));
        // The original SQL/AEAD/metadata work runs on the real event queue;
        // advancing only FakeAsync frames strands it behind the busy spinner.
        await tester.pump();
        for (var turn = 0; turn < 128 && wizardBusy(); turn++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        expect(
          wizardBusy(),
          isFalse,
          reason: '$key must finish its native work',
        );
        // As in configurationModal: finite local frames, not global idleness.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(microseconds: 1));
        expect(
          route.isCurrent,
          key != 'memory_setup_open_books',
          reason: 'Only the explicit books action may cover the wizard route',
        );
      }

      Future<void> choose(String key) async {
        final finder = find.byKey(ValueKey(key));
        await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
        await tester.pump();
        expect(finder.hitTestable(), findsOneWidget);
        await configurationAction(tester, () => tester.tap(finder));
        await tester.pump();
      }

      String paintedPlan() {
        final painted = tester
            .widget<SelectableText>(find.byType(SelectableText).last)
            .data!;
        expect(painted, contains('ДО'));
        expect(painted, contains('ПОСЛЕ'));
        expect(painted, isNot(contains(f.secret)));
        expect(painted, isNot(contains('generationApiKey')));
        f.domain.noEgress(painted);
        return painted;
      }

      await tap('memory_setup_target_${DomainLoopFixture.session}');
      for (var n = 1; n <= 5; n++) {
        final heading = find.text('Вопрос $n из 5');
        expect(heading, findsOneWidget);
        if (n == 1) await choose('memory_setup_choice_llmDrafts');
        if (n == 5) await choose('memory_setup_choice_semantic');
        await tap('memory_setup_next');
      }
      await tap('memory_setup_plan_session');
      final painted = paintedPlan();
      expect(painted, contains('creationSettings'));
      await configurationAction(tester, () async {
        expect(
          await f.domain.screen.core.container
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session),
          isNull,
        );
      });
      await tap('memory_setup_confirm');
      await configurationAction(tester, () async {
        expect(
          (await f.domain.screen.core.container
                  .read(memoryBookRepoProvider)
                  .getBySessionId(DomainLoopFixture.session))!
              .settings
              .memoryMode,
          'balanced',
        );
        expect(
          f.prefs.getString('memorySettings'),
          contains('"autoCreateEnabled":false'),
        );
        expect(
          f.prefs.getString('pipelineSettings'),
          contains('"generationSource":"custom"'),
        );
      });
      await tap('memory_setup_readiness');
      final declared = tester.widget<ListView>(
        find.descendant(
          of: find.byType(SupportMemorySetupSheet),
          matching: find.byType(ListView),
        ),
      );
      expect(
        (declared.childrenDelegate as SliverChildListDelegate).children.any(
          (w) =>
              w is MenuGroup &&
              w.header == 'Готовность: локальные факты, не live-тест',
        ),
        isTrue,
      );
      await tap('memory_setup_undo_session');
      expect(paintedPlan(), contains('creationSettings'));
      await configurationAction(tester, () async {
        expect(
          await f.domain.screen.core.container
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session),
          isNotNull,
        );
      });
      await tap('memory_setup_confirm');
      await configurationAction(tester, () async {
        expect(
          await f.domain.screen.core.container
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session),
          isNull,
        );
      });

      // Both global scopes are native gestures on separately painted plans.
      // Preparing either plan or Undo must leave every store untouched.
      for (final scope in ['automation', 'draftConnection']) {
        await tap('memory_setup_plan_$scope');
        final painted = paintedPlan();
        expect(painted, contains('global_all_sessions'));
        expect(f.prefs.getString('memorySettings'), beforeMemory);
        expect(f.prefs.getString('pipelineSettings'), beforePipeline);
        await tap('memory_setup_confirm');
        final memory = jsonDecode(f.prefs.getString('memorySettings')!) as Map;
        final pipeline =
            jsonDecode(f.prefs.getString('pipelineSettings')!) as Map;
        if (scope == 'automation') {
          expect(memory['autoCreateEnabled'], true);
          expect(memory['autoGenerateEnabled'], true);
          expect(memory['vectorSearchEnabled'], true);
          expect(f.prefs.getString('pipelineSettings'), beforePipeline);
        } else {
          expect(
            (pipeline['memoryBookApi'] as Map)['generationSource'],
            'current',
          );
          expect(f.prefs.getString('memorySettings'), beforeMemory);
        }
        expect(memory['unknownMemory'], {'retained': f.secret});
        expect(pipeline['unknownRoot'], {'retained': f.secret});
        expect(
          (pipeline['memoryBookApi'] as Map)['generationApiKey'],
          f.secret,
        );
        expect((pipeline['memoryBookApi'] as Map)['unknownSlot'], {
          'retained': f.secret,
        });
        final savedMemory = f.prefs.getString('memorySettings');
        final savedPipeline = f.prefs.getString('pipelineSettings');
        await tap('memory_setup_undo_$scope');
        expect(paintedPlan(), contains('global_all_sessions'));
        expect(f.prefs.getString('memorySettings'), savedMemory);
        expect(f.prefs.getString('pipelineSettings'), savedPipeline);
        await tap('memory_setup_confirm');
        expect(f.prefs.getString('memorySettings'), beforeMemory);
        expect(f.prefs.getString('pipelineSettings'), beforePipeline);
        await configurationAction(tester, () async {
          expect(
            await f.domain.screen.core.container
                .read(memoryBookRepoProvider)
                .getBySessionId(DomainLoopFixture.session),
            isNull,
          );
        });
      }
      // Recreate only through a fresh painted session plan, then open the
      // ordinary books interface on the exact already-loaded native owner.
      await tap('memory_setup_plan_session');
      paintedPlan();
      await tap('memory_setup_confirm');
      f.domain.screen.core.isolation.extraAllowed.addAll({
        memoryBookOpsProvider,
        memoryDraftJobsProvider,
        embeddingRepoProvider,
        vectorSearchAvailableProvider,
        activeEmbeddingConfigProvider,
        activeEmbeddingPresetIdProvider,
        embeddingPresetListProvider,
      });
      await tap('memory_setup_open_books');
      expect(find.byType(MemorySheet), findsOneWidget);
      final sheet = tester.widget<MemorySheet>(find.byType(MemorySheet));
      expect(sheet.charId, DomainLoopFixture.character);
      expect(sheet.expectedSessionId, DomainLoopFixture.session);
      expect(sheet.initialTab, MemoryTab.books);
      expect(sheet.isOwnerCurrent!(), true);
      final booksList = find.descendant(
        of: find.byType(MemoryBooksTab),
        matching: find.byType(ListView),
      );
      for (var turn = 0; turn < 128 && booksList.evaluate().isEmpty; turn++) {
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
      }
      expect(booksList, findsOneWidget);
      expect(
        tester.widget<MemoryBooksTab>(find.byType(MemoryBooksTab)).sessionId,
        DomainLoopFixture.session,
      );
      final booksRoute = ModalRoute.of<void>(
        tester.element(find.byType(MemorySheet)),
      )!;
      Navigator.of(tester.element(find.byType(MemorySheet))).pop();
      await tester.pump();
      await tester.pump(booksRoute.reverseTransitionDuration);
      await tester.pump(const Duration(microseconds: 1));
      expect(find.byType(MemorySheet), findsNothing);
      expect(route.isCurrent, true);
      expect(f.prefs.getString('memorySettings'), beforeMemory);
      expect(f.prefs.getString('pipelineSettings'), beforePipeline);
      Navigator.of(tester.element(find.byType(SupportMemorySetupSheet))).pop();
      await tester.pump();
      await tester.pump(route.reverseTransitionDuration);
      await tester.pump(const Duration(microseconds: 1));
      expect(route.isCurrent, isFalse);
      await modal;
    },
    selectTarget: false,
  );

  memorySetupTest(
    'synthetic range to generated pending approval to approved catalog to budgeted injection never injects draft',
    (tester, f) async {
      await configurationAction(tester, () async {
        final c = f.domain.screen.core.container,
            db = f.domain.screen.core.native.db;
        final books = c.read(memoryBookRepoProvider),
            chats = c.read(chatRepoProvider);
        final session = (await chats.getById(DomainLoopFixture.session))!;
        final seeded = session.copyWith(
          messages: [
            for (var i = 0; i < 20; i++)
              ChatMessage(
                id: 'range-$i',
                role: i.isEven ? 'user' : 'assistant',
                content: 'The blue harbour',
              ),
          ],
        );
        await chats.put(
          seeded,
        ); // Synthetic seed only, before plan observation.
        final setup = (await f.service.prepare(
          const MemorySetupAnswers(tokens: 1024),
          MemorySetupScope.session,
        ))!;
        expect(
          (await f.service.apply(setup)).effect,
          MemorySetupEffect.applied,
        );
        final book = (await books.getBySessionId(DomainLoopFixture.session))!;
        final planned = MemoryDraftPlanner.plan(
          book: book,
          messages: seeded.messages,
          interval: 15,
          lagMessages: 4,
          source: 'scan_chat',
          nowMillis: 1,
        );
        expect(planned.drafts, hasLength(1));
        await books.appendDrafts(DomainLoopFixture.session, planned.drafts);
        final draft = planned.drafts.single.copyWith(
          content: 'SYNTHETIC_APPROVED_HARBOUR_FACT',
          title: 'Blue harbour',
          keys: ['harbour'],
          status: 'pending_approval',
        );
        // Synthetic generator completion; no live/paid generator is exercised.
        await books.mutateDraft(
          sessionId: DomainLoopFixture.session,
          draftId: draft.id,
          mutate: (_) => draft,
        );
        final injection = MemoryInjectionService(
          books,
          EmbeddingRepo(db),
          c.read(memoryCatalogRepoProvider),
          _NoEmbedding(),
          () => const MemoryGlobalSettings(),
        );
        Future<MemoryInjectionResult> retrieve() => injection.buildInjection(
          sessionId: DomainLoopFixture.session,
          historyText: 'harbour',
          messageCount: 20,
          currentText: 'harbour',
          contextBudgetTokens: 4096,
        );
        final unapproved = await retrieve();
        expect(unapproved.content, isEmpty);
        expect(unapproved.entries, isEmpty);
        await books.approveDraft(DomainLoopFixture.session, draft.id, draft);
        final approved = (await books.getBySessionId(
          DomainLoopFixture.session,
        ))!;
        expect(approved.entries.single.status, 'active');
        await c.read(memoryCatalogRepoProvider).rebuildForMemoryBook(approved);
        final result = await retrieve();
        expect(result.entries, isNotEmpty);
        expect(result.content, contains('SYNTHETIC_APPROVED_HARBOUR_FACT'));
        expect(result.totalTokens, lessThanOrEqualTo(1024));
        expect(result.maxInjectionTokens, lessThanOrEqualTo(1024));
      });
    },
  );
}

final class _NoEmbedding extends EmbeddingService {
  @override
  Future<List<EmbeddingChunk>> getEmbeddingsWithChunks(
    List<String> texts,
    EmbeddingConfig config, {
    CancelToken? cancelToken,
    LlmCaptureContext? captureContext,
  }) => throw StateError('Synthetic keyword route must not request embeddings');
}
