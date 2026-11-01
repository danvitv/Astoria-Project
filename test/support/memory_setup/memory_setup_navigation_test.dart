import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_books_tab.dart';
import 'package:glaze_flutter/features/chat/widgets/memory_sheet.dart';
import 'package:glaze_flutter/features/support_assistant/support_assistant_screen.dart';

import 'memory_setup_native_fixture.dart';

void main() {
  for (final retired in [true, false]) {
    memorySetupTest(
      'native memory navigation refuses ${retired ? "same-session owner ABA before mount" : "another actual session"}',
      (tester, f) async {
        final target = f.service.activeTarget!;
        expect(target.sessionId, DomainLoopFixture.session);
        expect(target.characterId, DomainLoopFixture.character);
        expect(target.isActiveOwner, true);
        if (retired) {
          // The actual owner still points at the same id. A session-selection
          // revision must retire the captured navigation even for A -> B -> A.
          await f.service.owners.beforeSessionSelection();
          expect(target.isActiveOwner, false);
          expect(f.service.activeTarget, isNull);
        }
        final modal = showModalBottomSheet<void>(
          context: tester.element(find.byType(SupportAssistantScreen)),
          useRootNavigator: true,
          isScrollControlled: true,
          builder: (_) => MemorySheet(
            charId: target.characterId,
            initialTab: MemoryTab.books,
            expectedSessionId: retired
                ? target.sessionId
                : 'unselected-session',
            isOwnerCurrent: () => target.isActiveOwner,
          ),
        );
        await tester.pump();
        final route = ModalRoute.of<void>(
          tester.element(find.byType(MemorySheet)),
        )!;
        await tester.pump(route.transitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        expect(
          find.text(
            'Выбранная сессия больше не активна. Открой Memory Books из нужного чата.',
          ),
          findsOneWidget,
        );
        // Ops/jobs/embedding providers are deliberately absent from this finite
        // graph: a rejected navigation may not mount a books workflow at all.
        expect(find.byType(MemoryBooksTab), findsNothing);
        Navigator.of(tester.element(find.byType(MemorySheet))).pop();
        await tester.pump();
        await tester.pump(route.reverseTransitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        await modal;
        await configurationAction(tester, () async {
          expect(
            await f.service.books.getBySessionId(DomainLoopFixture.session),
            isNull,
          );
        });
        if (retired) expect(target.isActiveOwner, false);
      },
    );
  }
}
