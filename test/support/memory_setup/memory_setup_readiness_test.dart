import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';

import 'memory_setup_native_fixture.dart';

void main() {
  for (final edge in [
    'sourceABA',
    'bookABA',
    'ownerABA',
    'readOff',
    'database',
    'connectionABA',
  ]) {
    memorySetupTest(
      'held readiness refuses $edge rather than publishing stale local facts',
      (tester, f) async {
        await configurationAction(tester, () async {
          final review = (await f.service.prepare(
            const MemorySetupAnswers(),
            MemorySetupScope.session,
          ))!;
          expect(
            (await f.service.apply(review)).effect,
            MemorySetupEffect.applied,
          );
          final native = f.domain.screen.core.native;
          final entered = Completer<void>(), release = f.domain.release();
          native.sql.afterSelect = (statement, _) async {
            if (statement.contains('memory_catalog_rows') &&
                !entered.isCompleted) {
              entered.complete();
              await release.future;
            }
          };
          final reading = f.service.readiness();
          await entered.future;
          switch (edge) {
            case 'sourceABA':
              f.service.sources.beginMutation(
                sessionId: DomainLoopFixture.session,
              )();
            case 'bookABA':
              final book = (await f.service.books.getBySessionId(
                DomainLoopFixture.session,
              ))!;
              await f.service.books.updateSettings(
                DomainLoopFixture.session,
                book.settings,
              );
            case 'ownerABA':
              await f.service.owners.beforeSessionSelection();
            case 'readOff':
              await native.runtime.permissions.setGrantFromNative(
                native.session,
                SupportPermission.readApplicationData,
                false,
                isCurrent: () => true,
              );
              await native.runtime.refresh(resolve: false);
            case 'database':
              f.alive = false;
            case 'connectionABA':
              f.service.connections.beginMutation()();
          }
          release.complete();
          expect(await reading, isNull);
          native.sql.afterSelect = null;
        });
      },
    );
  }

  memorySetupTest(
    'readiness observes fresh saved globals after SQL instead of the old wizard answers',
    (tester, f) async {
      await configurationAction(tester, () async {
        final review = (await f.service.prepare(
          const MemorySetupAnswers(),
          MemorySetupScope.session,
        ))!;
        expect(
          (await f.service.apply(review)).effect,
          MemorySetupEffect.applied,
        );
        final native = f.domain.screen.core.native;
        final entered = Completer<void>(), release = f.domain.release();
        native.sql.afterSelect = (statement, _) async {
          if (statement.contains('memory_catalog_rows') &&
              !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final reading = f.service.readiness();
        await entered.future;
        final global =
            jsonDecode(f.prefs.getString('memorySettings')!)
                as Map<String, dynamic>;
        global['autoCreateEnabled'] = true;
        global['autoGenerateEnabled'] = true;
        await f.prefs.setString('memorySettings', jsonEncode(global));
        release.complete();
        final result = await reading;
        native.sql.afterSelect = null;
        expect(result, isNotNull);
        final text = result!.steps.join('\n');
        expect(text, contains('могут создавать платные LLM-черновики'));
        expect(text, isNot(contains('Автоматика: ручной режим')));
        expect(text, contains('Сетевые проверки не запускались'));
        expect(text, isNot(contains(f.secret)));
        f.domain.noEgress(text);
      });
    },
  );
}
