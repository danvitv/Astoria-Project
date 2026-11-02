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
import 'package:glaze_flutter/features/chat/widgets/memory_books_tab.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/memory/state/memory_draft_jobs_provider.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';

import 'support_app_domain_loop_fixture.dart';

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
}
