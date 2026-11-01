import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/features/chat/state/chat_native_owner_registry.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';

import 'memory_setup_native_fixture.dart';

void main() {
  memorySetupTest(
    'held private prepare refuses original source ABA, never replacement read authority',
    (tester, f) async {
      await configurationAction(tester, () async {
        final native = f.domain.screen.core.native;
        final entered = Completer<void>(), release = f.domain.release();
        native.sql.afterSelect = (statement, _) async {
          if (statement.contains('memory_book_rows') && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final preparing = f.service.prepare(
          const MemorySetupAnswers(),
          MemorySetupScope.session,
        );
        await entered.future;
        f.service.sources.beginMutation(sessionId: DomainLoopFixture.session)();
        release.complete();
        expect(await preparing, isNull);
        native.sql.afterSelect = null;
      });
    },
  );

  for (final undo in [false, true]) {
    memorySetupTest(
      'actual native queued ${undo ? "Undo" : "apply"} cannot survive another questionnaire intent',
      (tester, f) async {
        await configurationAction(tester, () async {
          final c = f.domain.screen.core.container;
          var review = (await f.service.prepare(
            const MemorySetupAnswers(),
            MemorySetupScope.session,
          ))!;
          if (undo) {
            final applied = await f.service.apply(review);
            expect(applied.effect, MemorySetupEffect.applied);
            review = (await f.service.prepareUndo(applied.receipt!))!;
          }
          final native = c
              .read(chatNativeOwnerRegistryProvider)
              .existing(DomainLoopFixture.session)!;
          final held = f.domain.release(), began = Completer<void>();
          final blocked = native.queue.run(() => held.future);
          final stop = c.read(chatSourceMutationRegistryProvider).subscribe((
            change,
          ) {
            if (!began.isCompleted) began.complete();
          });
          final apply = f.service.apply(review);
          await began.future;
          f.service.answersChanged();
          held.complete();
          await blocked;
          expect((await apply).effect, MemorySetupEffect.conflict);
          stop();
          final book = await c
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session);
          expect(book != null, undo);
        });
      },
    );
  }

  memorySetupTest(
    'explicit read OFF is still distinct from native edit confirmation',
    (tester, f) async {
      await configurationAction(tester, () async {
        final native = f.domain.screen.core.native;
        final review = (await f.service.prepare(
          const MemorySetupAnswers(),
          MemorySetupScope.session,
        ))!;
        await native.runtime.permissions.setGrantFromNative(
          native.session,
          SupportPermission.readApplicationData,
          false,
          isCurrent: () => true,
        );
        await native.runtime.refresh(resolve: false);
        expect(
          (await f.service.apply(review)).effect,
          MemorySetupEffect.refused,
        );
        expect(
          await f.domain.screen.core.container
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session),
          isNull,
        );
      });
    },
  );
}
