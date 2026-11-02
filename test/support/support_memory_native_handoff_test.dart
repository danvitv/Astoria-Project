import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/memory_book.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/lorebook_embedding_provider.dart';
import 'package:glaze_flutter/core/state/memory_book_ops_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_entry_card.dart';
import 'package:glaze_flutter/features/chat/widgets/memory/memory_draft_card.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_books_tab.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';
import 'package:glaze_flutter/features/memory/state/memory_native_entry_owner.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';

import 'support_app_domain_loop_fixture.dart';
import 'support_app_memory_draft_removal_fixture.dart'
    show draftRemovalArguments, startDraftRemoval, scriptRemovalUndo;
import 'support_app_memory_draft_text_fixture.dart'
    show
        allowDraftMemory,
        seedDraftText,
        draftMemoryOwner,
        draftTextId,
        draftTextBefore,
        draftTextAfter,
        draftTextArguments,
        startDraftText,
        draftTextRow,
        preservedDraftText;

void main() {
  domainLoopTest(
    'native Memory handoff retains original modal owner through actual Send edit',
    (tester, f) async {
      const before = 'SYNTHETIC_MEMORY_ENTRY_BEFORE_HANDOFF';
      const after = 'SYNTHETIC_MEMORY_ENTRY_AFTER_HANDOFF';
      const entryId = 'native-handoff-entry';
      final core = f.screen.core, c = core.container;
      core.isolation.extraAllowed.addAll({
        memoryBookOpsProvider,
        memoryDraftJobsProvider,
        memoryGlobalSettingsProvider,
        pipelineSettingsProvider,
        embeddingRepoProvider,
        vectorSearchAvailableProvider,
      });
      await configurationAction(
        tester,
        () => c
            .read(memoryBookRepoProvider)
            .put(
              const MemoryBook(
                id: 'memorybook_${DomainLoopFixture.session}',
                sessionId: DomainLoopFixture.session,
                settings: MemoryBookSettings(
                  autoCreateEnabled: false,
                  autoGenerateEnabled: false,
                  vectorSearchEnabled: false,
                ),
                entries: [
                  MemoryEntry(
                    id: entryId,
                    title: 'Native handoff',
                    content: before,
                  ),
                ],
              ),
            ),
      );
      final context = tester.element(find.byType(SupportAssistantScreen));
      final navigator = Navigator.of(context, rootNavigator: true);
      // Box the original route future: joining it before pumping would wait for
      // modal dismissal instead of letting the actual native widget initialize.
      final sheet = await configurationAction(
        tester,
        () async => (
          showMemorySheet(
            context,
            DomainLoopFixture.character,
            initialTab: MemoryTab.books,
          ),
        ),
      );
      try {
        final open = find.byKey(const ValueKey('memory_open_astoria'));
        for (var turn = 0; turn < 128 && open.evaluate().isEmpty; turn++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        // Loading does not advance the original modal's fake animation clock.
        final originalSheetRoute = ModalRoute.of<void>(tester.element(open))!;
        await tester.pump(originalSheetRoute.transitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        expect(open.hitTestable(), findsOneWidget);
        final tab = find.byType(MemoryBooksTab);
        final originalState = tester.state(tab);
        final originalContainer = ProviderScope.containerOf(
          tester.element(tab),
          listen: false,
        );
        expect(originalContainer, same(c));
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(find.byType(SupportAssistantScreen), findsOneWidget);
        expect(originalState.mounted, isTrue);
        expect(
          tester.state(find.byType(MemoryBooksTab, skipOffstage: false)),
          same(originalState),
        );
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(SupportAssistantScreen)),
            listen: false,
          ),
          same(c),
        );

        f.script(
          core.call('astoria_memory_entry_text_revise', {
            'sessionId': DomainLoopFixture.session,
            'entryId': entryId,
            'content': after,
          }),
        );
        await f.start(tester);
        await f.apply(tester);
        final reply = await f.finish(tester);
        final saved = await configurationAction(
          tester,
          () => c
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session),
        );
        expect(saved!.entries.single.content, after);
        expect(originalState.mounted, isTrue);
        f.noEgress(reply.body);
        final outward =
            '${jsonEncode(core.wire)}${jsonEncode(f.results)}${reply.body}';
        expect(outward, isNot(contains(before)));
        expect(outward, isNot(contains(after)));

        // Exercise the real Astoria header Back, not a test-only Navigator pop.
        // The standalone /support entry keeps its ordinary library destination.
        final back = find
            .descendant(
              of: find.byType(SupportAssistantScreen),
              matching: find.byIcon(Icons.arrow_back_ios_new_rounded),
            )
            .hitTestable();
        expect(back, findsOneWidget);
        await tester.tap(back);
        await tester.pumpAndSettle();
        expect(tester.state(find.byType(MemoryBooksTab)), same(originalState));
        expect(
          tester
              .widget<MemoryEntryCard>(find.byType(MemoryEntryCard))
              .entry
              .content,
          after,
        );
      } finally {
        await configurationAction(tester, () async {
          navigator.popUntil((route) => route.isFirst);
        });
        await tester.pumpAndSettle();
        await configurationAction(tester, () => sheet.$1);
      }
    },
  );
  domainLoopTest(
    'native Memory draft handoff retains same tab through Send, rendered Back and fresh Undo',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      allowDraftMemory(f);
      await seedDraftText(tester, f);
      final before = await draftTextRow(tester, f);
      final context = tester.element(find.byType(SupportAssistantScreen));
      final navigator = Navigator.of(context, rootNavigator: true);
      final sheet = await configurationAction(
        tester,
        () async => (
          showMemorySheet(
            context,
            DomainLoopFixture.character,
            initialTab: MemoryTab.books,
          ),
        ),
      );
      try {
        final open = find.byKey(const ValueKey('memory_open_astoria'));
        for (var turn = 0; turn < 128 && open.evaluate().isEmpty; turn++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        final sheetRoute = ModalRoute.of<void>(tester.element(open))!;
        await tester.pump(sheetRoute.transitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        final originalState = tester.state(find.byType(MemoryBooksTab));
        final originalOwner = draftMemoryOwner(f);
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(MemoryBooksTab)),
            listen: false,
          ),
          same(c),
        );
        final draftTab = find
            .descendant(
              of: find.byType(MemoryBooksTab),
              matching: find.byIcon(Icons.drafts_outlined),
            )
            .hitTestable();
        expect(draftTab, findsOneWidget);
        await tester.tap(draftTab);
        await tester.pumpAndSettle();
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(originalState.mounted, true);
        expect(
          ProviderScope.containerOf(
            tester.element(find.byType(SupportAssistantScreen)),
            listen: false,
          ),
          same(c),
        );
        f.script(
          core.call('astoria_memory_draft_text_edit', draftTextArguments()),
        );
        await startDraftText(tester, f);
        await f.apply(tester);
        final edited = await f.finish(tester);
        expect(edited.body, contains('изменение сохранено'));
        preservedDraftText(
          before,
          await draftTextRow(tester, f),
          draftTextAfter,
        );
        Future<void> renderedBack(String content) async {
          final back = find
              .descendant(
                of: find.byType(SupportAssistantScreen),
                matching: find.byIcon(Icons.arrow_back_ios_new_rounded),
              )
              .hitTestable();
          expect(back, findsOneWidget);
          await tester.tap(back);
          await tester.pumpAndSettle();
          expect(
            tester.state(find.byType(MemoryBooksTab)),
            same(originalState),
          );
          expect(draftMemoryOwner(f), same(originalOwner));
          final card = tester
              .widgetList<MemoryDraftCard>(find.byType(MemoryDraftCard))
              .singleWhere((card) => card.draft.id == draftTextId);
          expect(card.draft.content, content);
          expect(card.draft.status, 'pending_approval');
          expect(card.isGenerating, false);
        }

        await renderedBack(draftTextAfter);
        await tester.tap(open);
        await tester.pumpAndSettle();
        f.script(
          core.call('astoria_memory_draft_text_receipts', {}),
          next: (_) {
            final records = f.lastData()['records'] as List;
            expect(records, hasLength(1));
            return core.call('astoria_memory_draft_text_undo', {
              'receipt': (records.single as Map)['receipt'],
            }, id: 'fresh_handoff_draft_undo');
          },
        );
        await startDraftText(tester, f, undo: true);
        await f.apply(tester);
        final undone = await f.finish(tester);
        expect(undone.body, contains('изменение сохранено'));
        expect(await draftTextRow(tester, f), before);
        await renderedBack(draftTextBefore);
        f.noEgress('${edited.body}${undone.body}');
        final outward =
            '${jsonEncode(core.wire)}${jsonEncode(f.results)}'
            '${edited.body}${undone.body}';
        expect(outward, isNot(contains(draftTextBefore)));
        expect(outward, isNot(contains(draftTextAfter)));
      } finally {
        await configurationAction(tester, () async {
          navigator.popUntil((route) => route.isFirst);
        });
        await tester.pumpAndSettle();
        await configurationAction(tester, () => sheet.$1);
      }
    },
  );
  domainLoopTest(
    'native Memory removal handoff retains original modal controller through delete, header Back and exact Undo',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      allowDraftMemory(f);
      await seedDraftText(tester, f);
      final before = await draftTextRow(tester, f);
      final context = tester.element(find.byType(SupportAssistantScreen));
      final navigator = Navigator.of(context, rootNavigator: true);
      final sheet = await configurationAction(tester, () async => (
        showMemorySheet(context, DomainLoopFixture.character, initialTab: MemoryTab.books),
      ));
      try {
        final open = find.byKey(const ValueKey('memory_open_astoria'));
        for (var turn = 0; turn < 128 && open.evaluate().isEmpty; turn++) {
          await tester.runAsync(() => Future<void>.delayed(Duration.zero));
          await tester.pump();
        }
        final route = ModalRoute.of<void>(tester.element(open))!;
        await tester.pump(route.transitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        final state = tester.state(find.byType(MemoryBooksTab));
        final owner = draftMemoryOwner(f);
        final originalDrafts = owner.readBook()!.pendingDrafts;
        expect(ProviderScope.containerOf(tester.element(find.byType(MemoryBooksTab)), listen: false), same(c));
        await tester.tap(find.descendant(of: find.byType(MemoryBooksTab),
          matching: find.byIcon(Icons.drafts_outlined)).hitTestable());
        await tester.pumpAndSettle();
        Future<void> backToOriginal({required bool absent}) async {
          await tester.tap(find.descendant(of: find.byType(SupportAssistantScreen),
            matching: find.byIcon(Icons.arrow_back_ios_new_rounded)).hitTestable());
          await tester.pumpAndSettle();
          expect(state.mounted, true);
          expect(tester.state(find.byType(MemoryBooksTab)), same(state));
          expect(draftMemoryOwner(f), same(owner));
          final cards = tester.widgetList<MemoryDraftCard>(find.byType(MemoryDraftCard)).toList();
          expect(cards.any((card) => card.draft.id == draftTextId), !absent);
          if (!absent) {
            expect(cards.map((card) => card.draft.id), originalDrafts.map((d) => d.id));
            final card = cards.singleWhere((card) => card.draft.id == draftTextId);
            expect(card.draft, originalDrafts.first);
            expect(card.isGenerating, false);
          }
        }
        await tester.tap(open);
        await tester.pumpAndSettle();
        expect(ProviderScope.containerOf(tester.element(find.byType(SupportAssistantScreen)), listen: false), same(c));
        f.script(core.call('astoria_memory_draft_delete', draftRemovalArguments()));
        await startDraftRemoval(tester, f);
        await f.apply(tester);
        final deleted = await f.finish(tester);
        expect(deleted.body, contains('изменение сохранено'));
        expect(owner.cachedDraft(draftTextId), isNull);
        await backToOriginal(absent: true);
        await tester.tap(open);
        await tester.pumpAndSettle();
        scriptRemovalUndo(f);
        await startDraftRemoval(tester, f, undo: true);
        await f.apply(tester);
        final undone = await f.finish(tester);
        expect(undone.body, contains('изменение сохранено'));
        expect(await draftTextRow(tester, f), before);
        await backToOriginal(absent: false);
        f.noEgress('${deleted.body}${undone.body}');
        final outward = '${jsonEncode(core.wire)}${jsonEncode(f.results)}${deleted.body}${undone.body}';
        expect(outward, isNot(contains(draftTextBefore)));
        expect(outward, isNot(contains('unknownDraft')));
      } finally {
        await configurationAction(tester, () async { navigator.popUntil((route) => route.isFirst); });
        await tester.pumpAndSettle();
        await configurationAction(tester, () => sheet.$1);
      }
    },
  );
}
