import 'dart:async';
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_owner.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'memory_setup_native_fixture.dart';
import 'memory_setup_preferences_backing.dart';

void main() {
  memorySetupTest('global lease retirement during journal settlement cannot mint a reusable Undo', (tester, f) async {
    await configurationAction(tester, () async {
      final native = f.domain.screen.core.native;
      final review = (await f.service.prepare(const MemorySetupAnswers(
        automation: MemorySetupAutomation.llmDrafts), MemorySetupScope.automation))!;
      final entered = Completer<void>(), release = f.domain.release();
      native.sql.afterWrite = (statement) async {
        if (statement.startsWith('UPDATE') &&
            statement.contains('support_mutation_journal') &&
            !entered.isCompleted) {
          entered.complete();
          await release.future;
        }
      };
      final applying = f.service.apply(review);
      await entered.future;
      expect(f.backing.values['flutter.memorySettings'].toString(), contains('"autoGenerateEnabled":true'));
      SavedPreferencesOwner.process.begin(['memorySettings']).settle();
      release.complete();
      final result = await applying;
      native.sql.afterWrite = null;
      expect(result.effect, MemorySetupEffect.reconciliationRequired);
      expect(result.receipt, isNull);
    });
  });
  memorySetupTest('malformed global before fields do not bypass nested secret-field redaction', (tester, f) async {
    await configurationAction(tester, () async {
      final raw = jsonDecode(f.prefs.getString('memorySettings')!) as Map<String, dynamic>;
      raw['autoCreateEnabled'] = {'apiKey': 'unregistered-private-value'};
      await f.prefs.setString('memorySettings', jsonEncode(raw));
      expect(await f.service.prepare(const MemorySetupAnswers(), MemorySetupScope.automation), isNull);
      expect(f.backing.values['flutter.memorySettings'], jsonEncode(raw));
    });
  });
  memorySetupTest('original plugin producer retirement cannot revive on backend ABA after an ack', (tester, f) async {
    await configurationAction(tester, () async {
      final review = (await f.service.prepare(const MemorySetupAnswers(
        automation: MemorySetupAutomation.llmDrafts), MemorySetupScope.automation))!;
      f.backing.beforeWrite = (_) async {
        SharedPreferencesStorePlatform.instance = MemorySetupPreferencesBacking({});
        expect(f.prefs.store.current, false);
        SharedPreferencesStorePlatform.instance = f.backing;
      };
      final result = await f.service.apply(review);
      expect(result.effect, MemorySetupEffect.reconciliationRequired);
      expect(result.receipt, isNull);
      expect(f.prefs.store.current, false);
      expect(f.backing.values['flutter.memorySettings'].toString(), contains('"autoGenerateEnabled":true'));
      f.backing.beforeWrite = null;
    });
  });
  memorySetupTest(
    'global independent plans use acknowledged raw changed-fields and encrypted journal; fresh Undo preserves private unknowns',
    (tester, f) async {
      await configurationAction(tester, () async {
        final beforePipeline = f.prefs.getString('pipelineSettings');
        final automation = (await f.service.prepare(
          const MemorySetupAnswers(
            automation: MemorySetupAutomation.llmDrafts,
            semantic: true,
          ),
          MemorySetupScope.automation,
        ))!;
        final applied = await f.service.apply(automation);
        expect(applied.effect, MemorySetupEffect.applied);
        expect(f.prefs.getString('pipelineSettings'), beforePipeline);
        expect(
          await f.domain.screen.core.container
              .read(memoryBookRepoProvider)
              .getBySessionId(DomainLoopFixture.session),
          isNull,
        );
        final saved = jsonDecode(f.prefs.getString('memorySettings')!) as Map;
        expect(saved['unknownMemory'], {'retained': f.secret});
        expect(
          f.domain.screen.core.container
              .read(memoryGlobalSettingsProvider)
              .autoGenerateEnabled,
          true,
        );
        final undo = (await f.service.prepareUndo(applied.receipt!))!;
        expect((await f.service.apply(undo)).effect, MemorySetupEffect.undone);
        final connections = await f.service.savedConnections();
        expect(connections, isNotEmpty);
        final draft = (await f.service.prepare(
          MemorySetupAnswers(connection: connections.first),
          MemorySetupScope.draftConnection,
        ))!;
        expect(jsonEncode(draft.before), isNot(contains(f.secret)));
        expect(jsonEncode(draft.after), isNot(contains('generationApiKey')));
        final slotApplied = await f.service.apply(draft);
        expect(slotApplied.effect, MemorySetupEffect.applied);
        final pipeline =
            jsonDecode(f.prefs.getString('pipelineSettings')!) as Map;
        expect(
          (pipeline['memoryBookApi'] as Map)['generationApiKey'],
          f.secret,
        );
        expect((pipeline['memoryBookApi'] as Map)['unknownSlot'], {
          'retained': f.secret,
        });
        expect(pipeline['unknownRoot'], {'retained': f.secret});
        expect(
          f.domain.screen.core.container
              .read(pipelineSettingsProvider)
              .memoryBookApi
              .generationSource,
          'current',
        );
        final slotUndo = (await f.service.prepareUndo(slotApplied.receipt!))!;
        expect(
          (await f.service.apply(slotUndo)).effect,
          MemorySetupEffect.undone,
        );
        expect(f.prefs.getString('pipelineSettings'), beforePipeline);
      });
    },
  );

  for (final throws in [false, true]) {
    memorySetupTest(
      'global ${throws ? "throw" : "false"} after persist is reconciliation and quarantines saved reads',
      (tester, f) async {
        await configurationAction(tester, () async {
          final review = (await f.service.prepare(
            const MemorySetupAnswers(
              automation: MemorySetupAutomation.llmDrafts,
            ),
            MemorySetupScope.automation,
          ))!;
          if (throws) {
            f.backing.thrown = 'flutter.memorySettings';
          } else {
            f.backing.rejected = 'flutter.memorySettings';
          }
          final result = await f.service.apply(review);
          expect(result.effect, MemorySetupEffect.reconciliationRequired);
          expect(result.receipt, isNull);
          expect(
            f.backing.values['flutter.memorySettings'].toString(),
            contains('"autoGenerateEnabled":true'),
          );
          expect(
            f.prefs.store.owner.capture([
              'memorySettings',
            ], store: f.prefs.store).current,
            false,
          );
          expect(
            f.domain.screen.core.container
                .read(memoryGlobalSettingsProvider)
                .autoGenerateEnabled,
            false,
          );
        });
      },
    );
  }

  memorySetupTest(
    'global held ack overlap invalidates own revision and quarantines an optimistic cache',
    (tester, f) async {
      await configurationAction(tester, () async {
        final review = (await f.service.prepare(
          const MemorySetupAnswers(automation: MemorySetupAutomation.llmDrafts),
          MemorySetupScope.automation,
        ))!;
        final entered = Completer<void>(), release = f.domain.release();
        f.backing.beforeWrite = (key) async {
          if (key == 'flutter.memorySettings') {
            entered.complete();
            await release.future;
          }
        };
        final apply = f.service.apply(review);
        await entered.future;
        final other = SavedPreferencesOwner.process.begin(['memorySettings']);
        other.settle();
        release.complete();
        expect((await apply).effect, MemorySetupEffect.reconciliationRequired);
        f.backing.beforeWrite = null;
        expect(
          f.prefs.store.owner.capture([
            'memorySettings',
          ], store: f.prefs.store).current,
          false,
        );
      });
    },
  );
  memorySetupTest('global same-value ABA cannot renew retained Undo', (
    tester,
    f,
  ) async {
    await configurationAction(tester, () async {
      final next = (await f.service.prepare(
        const MemorySetupAnswers(automation: MemorySetupAutomation.emptyDrafts),
        MemorySetupScope.automation,
      ))!;
      final applied = await f.service.apply(next);
      expect(applied.effect, MemorySetupEffect.applied);
      final identicalRaw = f.prefs.getString('memorySettings')!;
      await f.prefs.setString('memorySettings', identicalRaw);
      expect(await f.service.prepareUndo(applied.receipt!), isNull);
    });
  });

  memorySetupTest(
    'acknowledged global write survives journal delivery failure as reconciliation, never pretend cross-store atomicity',
    (tester, f) async {
      await configurationAction(tester, () async {
        final native = f.domain.screen.core.native;
        final review = (await f.service.prepare(
          const MemorySetupAnswers(automation: MemorySetupAutomation.llmDrafts),
          MemorySetupScope.automation,
        ))!;
          native.sql.afterWrite = (statement) async {
          if (statement.startsWith('UPDATE') &&
              statement.contains('support_mutation_journal')) {
            throw StateError('SYNTHETIC_WIZARD_JOURNAL_DELIVERY_FAILURE');
          }
        };
        final result = await f.service.apply(review);
        native.sql.afterWrite = null;
        expect(result.effect, MemorySetupEffect.reconciliationRequired);
        expect(result.receipt, isNull);
        expect(
          f.backing.values['flutter.memorySettings'].toString(),
          contains('"autoGenerateEnabled":true'),
        );
      });
    },
  );
}
