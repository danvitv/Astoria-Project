import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_memory_setup_controller.dart';

import 'memory_setup_native_fixture.dart';

void main() {
  memorySetupTest(
    'original controller questions prepare exact session review; confirmation and fresh Undo own only that store',
    (tester, f) async {
      final c = SupportMemorySetupController(f.service);
      final books = f.domain.screen.core.container.read(memoryBookRepoProvider);
      final beforeMemory = f.prefs.getString('memorySettings');
      final beforePipeline = f.prefs.getString('pipelineSettings');
      try {
        await configurationAction(tester, () async {
          expect(c.service.current, true);
          await c.selectTarget(
            f.service.targets.singleWhere(
              (t) => t.sessionId == DomainLoopFixture.session,
            ),
          );
          expect(c.selected, true);
          expect(c.busy, false);
          expect(c.service.current, true);
          expect(await books.getBySessionId(DomainLoopFixture.session), isNull);

          for (var question = 0; question < 5; question++) {
            expect(c.question, question);
            expect(c.finished, false);
            c.next();
          }
          expect(c.finished, true);
          c.back();
          expect(c.question, 4);
          expect(c.finished, false);
          c.next();
          expect(c.finished, true);

          await c.prepare(MemorySetupScope.session);
          final reviewed = c.review;
          expect(reviewed, isNotNull);
          expect(reviewed!.current, true);
          expect(reviewed.scope, MemorySetupScope.session);
          expect(jsonEncode(reviewed.after), contains('creationSettings'));
          expect(
            jsonEncode([reviewed.before, reviewed.after]),
            isNot(contains(f.secret)),
          );
          expect(await books.getBySessionId(DomainLoopFixture.session), isNull);
          expect(c.receipts, isEmpty);

          await c.confirm(reviewed);
          expect(c.review, isNull);
          expect(c.busy, false);
          expect(c.status, startsWith('Этот план сохранён.'));
          final book = await books.getBySessionId(DomainLoopFixture.session);
          expect(book, isNotNull);
          expect(book!.settings.memoryMode, 'balanced');
          expect(book.settings.maxInjectedTokens, 2048);
          expect(c.receipts.keys, [MemorySetupScope.session]);
          expect(f.prefs.getString('memorySettings'), beforeMemory);
          expect(f.prefs.getString('pipelineSettings'), beforePipeline);

          // A consumed review cannot replace the fresh native Undo gesture.
          await c.confirm(reviewed);
          expect(await books.getBySessionId(DomainLoopFixture.session), book);
          await c.checkReadiness();
          expect(c.readiness, isNotNull);
          expect(
            c.readiness!.steps,
            contains(
              'Утверждение: 0 ожидают явного Approve. Генерация не активирует запись.',
            ),
          );
          await c.prepareUndo(MemorySetupScope.session);
          final undo = c.review;
          expect(undo, isNotNull);
          expect(undo!.isUndo, true);
          expect(undo.current, true);
          // Preparing Undo alone never removes the created book.
          expect(await books.getBySessionId(DomainLoopFixture.session), book);
          await c.confirm(undo);
          expect(c.status, 'Изменения этого плана отменены.');
          expect(c.receipts, isEmpty);
          expect(await books.getBySessionId(DomainLoopFixture.session), isNull);
          expect(f.prefs.getString('memorySettings'), beforeMemory);
          expect(f.prefs.getString('pipelineSettings'), beforePipeline);
        });
      } finally {
        c.dispose();
      }
    },
    selectTarget: false,
  );
}
