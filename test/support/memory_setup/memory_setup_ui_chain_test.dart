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
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_memory_setup_sheet.dart';

import 'memory_setup_native_fixture.dart';

void main() {
  memorySetupTest(
    'five native questions paint exact separate plan; only explicit native confirm commits',
    (tester, f) async {
      final context = tester.element(find.byType(SupportAssistantScreen));
      final modal = showModalBottomSheet<void>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (_) => SupportMemorySetupSheet(service: f.service),
      );
      await tester.pump();
      final route = ModalRoute.of<void>(tester.element(find.byType(SupportMemorySetupSheet)))!;
      await tester.pump(route.transitionDuration);
      await tester.pump(const Duration(microseconds: 1));
      expect(route.isCurrent, isTrue);
      expect(route.animation!.status, AnimationStatus.completed);
      Future<void> tap(String key) async {
        final finder = find.byKey(ValueKey(key));
        if (finder.evaluate().isEmpty) {
          await tester.scrollUntilVisible(
            finder,
            100,
            scrollable: find.descendant(
              of: find.byType(SupportMemorySetupSheet),
              matching: find.byType(Scrollable),
            ).first,
            maxScrolls: 20,
          );
        }
        await tester.ensureVisible(finder);
        await tester.pump();
        expect(finder.hitTestable(), findsOneWidget);
        await configurationAction(tester, () => tester.tap(finder));
        // The original SQL/AEAD/metadata work runs on the real event queue;
        // advancing only FakeAsync frames strands it behind the busy spinner.
        await tester.pump();
        for (var turn = 0;
            turn < 128 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
            turn++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        expect(find.byType(CircularProgressIndicator), findsNothing);
        // As in configurationModal: finite local frames, not global idleness.
        await tester.pump(const Duration(milliseconds: 350));
        await tester.pump(const Duration(microseconds: 1));
        expect(route.isCurrent, isTrue);
      }

      await tap('memory_setup_target_${DomainLoopFixture.session}');
      for (var n = 1; n <= 5; n++) {
        final heading = find.text('Вопрос $n из 5');
        expect(heading, findsOneWidget);
        await tap('memory_setup_next');
      }
      await tap('memory_setup_plan_session');
      final painted = tester
          .widget<SelectableText>(find.byType(SelectableText).last)
          .data!;
      expect(painted, contains('ДО'));
      expect(painted, contains('ПОСЛЕ'));
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
