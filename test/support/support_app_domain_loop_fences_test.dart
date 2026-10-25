import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/llm/transport/native_tool_types.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/db/repositories/character_repo.dart';
import 'package:glaze_flutter/core/state/global_regex_provider.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_app_control_provider.dart';
import 'package:glaze_flutter/features/support_assistant/state/support_model_ui_bridge.dart';
import 'package:glaze_flutter/features/support_assistant/widgets/support_composer_bar.dart';

import 'support_app_domain_loop_fixture.dart';

void main() {
  domainLoopTest(
    'actual combined native registry has finite definitions and no generic controls',
    (tester, f) async {
      final definitions = await configurationAction(
        tester,
        () => f.screen.core.container
            .read(supportAppActionRegistryProvider)
            .definitions,
      );
      expect(definitions, hasLength(43));
      final backup = definitions.singleWhere(
        (d) => d.name == 'astoria_database_snapshot',
      );
      expect(backup.parameters['properties'], isEmpty);
      expect(backup.parameters['additionalProperties'], isFalse);
      expect(
        definitions.length,
        lessThanOrEqualTo(NativeToolLimits.definitions),
      );
      final preparation = definitions.singleWhere(
        (d) => d.name == 'astoria_database_restore_prepare',
      );
      expect(preparation.parameters['properties'], isEmpty);
      expect(preparation.parameters['additionalProperties'], isFalse);
      final serialized = definitions
          .where((d) => d.name != preparation.name)
          .map((d) => d.name)
          .join(' ');
      for (final absent in [
        'sql',
        'eval',
        'shell',
        'credential',
        'restore',
        'memory_generate',
        'canon_rewrite',
        'character_delete',
        'image_generate',
        'file_export',
      ]) {
        expect(serialized, isNot(contains(absent)));
      }
      f.script(
        f.screen.core.call('astoria_content_catalog', {'domain': 'character'}),
        next: (_) {
          final result = f.lastResult();
          expect(result['effect'], 'none');
          final data = result['data'] as Map;
          expect(data['ids'], [DomainLoopFixture.character]);
          expect(data.keys, isNot(contains('name')));
          return f.screen.core.answer('Native ID metadata only.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(reply.status, 'complete');
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'prose JSON and unsupported tool name cannot execute real domain effects',
    (tester, f) async {
      final core = f.screen.core;
      f.script(
        core.answer(
          jsonEncode({
            'name': 'astoria_character_manage',
            'arguments': {
              'operation': 'editText',
              'id': DomainLoopFixture.character,
              'field': 'description',
              'text': 'Not executable prose',
            },
          }),
        ),
      );
      await f.start(tester, confirmation: false);
      await f.finish(tester);
      final row = await configurationAction(
        tester,
        () => core.container
            .read(characterRepoProvider)
            .getById(DomainLoopFixture.character),
      );
      expect(row!.description, DomainLoopFixture.private);
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      f.script(
        core.call('astoria_run_sql', {
          'sql': 'SELECT private_body FROM everything',
        }),
      );
      await f.start(tester, confirmation: false);
      await f.finish(tester);
      expect(core.wire, hasLength(2));
      expect(
        await configurationAction(
          tester,
          () => core.native.db
              .select(core.native.db.supportMutationJournal)
              .get(),
        ),
        isEmpty,
      );
    },
  );

  domainLoopTest(
    'local catalog private input stays unavailable without genuine SourceAccess',
    (tester, f) async {
      final core = f.screen.core;
      await configurationAction(
        tester,
        () => core.container
            .read(memoryBookRepoProvider)
            .createEmptyForControl(
              sessionId: DomainLoopFixture.session,
              enabled: false,
              isCurrent: () =>
                  core.native.rootCurrent && core.native.native.isCurrent,
            ),
      );
      f.script(
        core.call('astoria_memory_catalog_rebuild', {
          'sessionId': DomainLoopFixture.session,
        }),
        next: (_) {
          f.lastResult();
          return core.answer('Catalog is ready.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(f.results.single['code'], 'unavailable');
      expect(f.results.single['effect'], 'none');
      expect(reply.body, isNot(contains('Catalog is ready.')));
      expect(core.wire, hasLength(2));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'changed target CAS after native preview cannot overwrite latest original row',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      f.script(
        core.call('astoria_character_manage', {
          'operation': 'editText',
          'id': DomainLoopFixture.character,
          'field': 'description',
          'text': 'Stale supplied patch',
        }),
      );
      await f.start(tester);
      await configurationAction(tester, () async {
        final repo = c.read(characterRepoProvider);
        final observed = (await repo.getById(DomainLoopFixture.character))!;
        // Native setup race, not a fabricated model effect. This is the real
        // owning atomic control CAS, preserving the remaining original columns.
        await repo.controlText(
          expected: observed,
          field: CharacterControlText.description,
          value: 'Competing native edit',
          current: () =>
              core.native.rootCurrent && core.native.native.isCurrent,
        );
      });
      await f.apply(tester);
      final reply = await f.finish(tester);
      final row = await configurationAction(
        tester,
        () =>
            c.read(characterRepoProvider).getById(DomainLoopFixture.character),
      );
      expect(row!.description, 'Competing native edit');
      expect(reply.body, isNot(contains('изменение сохранено')));
      expect(core.wire, hasLength(1));
    },
  );

  domainLoopTest(
    'admitted domain write joins factual commit after original route retires, without extra POST or B paint',
    (tester, f) async {
      final core = f.screen.core;
      final gates = await configurationAction(
        tester,
        () => (f.release(), f.release()),
      );
      final entered = gates.$1, release = gates.$2;
      f.script(
        core.call('astoria_character_manage', {
          'operation': 'editText',
          'id': DomainLoopFixture.character,
          'field': 'description',
          'text': 'Admitted exact patch',
        }),
      );
      await f.start(tester);
      core.native.sql.afterWrite = (statement) async {
        if (!entered.isCompleted &&
            statement.toLowerCase().contains('characters')) {
          entered.complete();
          await release
              .future; // Actual provisional SQL in the owning transaction.
        }
      };
      await f.apply(tester);
      await f.screen.join(tester, entered.future);
      await configurationAction(
        tester,
        () => f.screen.router.go('/characters'),
      );
      await tester.pump();
      await configurationAction(tester, release.complete);
      final reply = await f.finish(tester);
      final row = await configurationAction(
        tester,
        () => core.container
            .read(characterRepoProvider)
            .getById(DomainLoopFixture.character),
      );
      expect(row!.description, 'Admitted exact patch');
      expect(reply.status, 'stopped');
      expect(reply.body, contains('изменение сохранено'));
      expect(core.wire, hasLength(1));
      expect(
        f.screen.router.routeInformationProvider.value.uri.path,
        '/characters',
      );
      expect(find.textContaining('изменение сохранено'), findsNothing);
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'actual composer Stop at terminal original ROOT refuses capsule and domain write',
    (tester, f) async {
      final core = f.screen.core;
      f.script(
        core.call('astoria_studio_preset_manage', {
          'operation': 'rename',
          'id': 'domain-collision',
          'name': 'Must not persist',
        }),
      );
      await f.start(tester);
      // The sheet covers the original composer, but its exact Stop stays bound.
      // Query the mounted original IconButton; do not manufacture a gesture.
      final originalComposer = find.byType(
        SupportComposerBar,
        skipOffstage: false,
      );
      expect(originalComposer, findsOneWidget);
      final composer = tester.widget<SupportComposerBar>(originalComposer);
      expect(composer.sessionId, core.native.session);
      expect(composer.busy, true);
      expect(composer.nativeOwner, isA<SupportModelUiEmitter>());
      expect((composer.nativeOwner! as SupportModelUiEmitter).isCurrent, true);
      final stopButton = find.descendant(
        of: originalComposer,
        matching: find.byKey(
          const ValueKey('support_composer_stop_btn'),
          skipOffstage: false,
        ),
        skipOffstage: false,
      );
      expect(stopButton, findsOneWidget);
      expect(tester.element(stopButton).mounted, true);
      final originalRoute = ModalRoute.of<void>(
        tester.element(originalComposer),
      )!;
      expect(originalRoute.isActive, true);
      expect(
        originalRoute.navigator,
        same(
          ModalRoute.of<void>(
            tester.element(
              find.byKey(const ValueKey('support_tool_confirmation_accept')),
            ),
          )!.navigator,
        ),
      );
      final stop = tester.widget<IconButton>(stopButton).onPressed;
      expect(stop, isNotNull);
      expect(identical(stop, composer.onStop), true);
      var terminalRootEntered = false, stopped = false;
      core.native.sql.afterSelect = (statement, _) async {
        if (statement.trim() == 'PRAGMA busy_timeout') {
          terminalRootEntered = true;
        }
        if (terminalRootEntered &&
            !stopped &&
            statement.contains('support_messages')) {
          stopped = true;
          stop!(); // The ACTUAL original native Stop, before capsule consumption.
        }
      };
      await f.apply(tester);
      final reply = await f.finish(tester);
      core.native.sql.afterSelect = null;
      final row = await configurationAction(
        tester,
        () => core.container
            .read(studioPresetRepoProvider)
            .getById('domain-collision'),
      );
      expect(terminalRootEntered, true);
      expect(stopped, true);
      expect(row!.name, DomainLoopFixture.private);
      expect(reply.status, 'stopped');
      expect(reply.body, isNot(contains('изменение сохранено')));
      expect(core.wire, hasLength(1));
      expect(
        await configurationAction(
          tester,
          () => core.native.db
              .select(core.native.db.supportMutationJournal)
              .get(),
        ),
        isEmpty,
      );
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'pending original native sheet survives navigator disposal only as a stopped original reply with zero effects',
    (tester, f) async {
      final core = f.screen.core;
      f.script(
        core.call('astoria_studio_preset_manage', {
          'operation': 'rename',
          'id': 'domain-collision',
          'name': 'Must not persist after disposal',
        }),
      );
      await f.start(tester);
      final sheet =
          ModalRoute.of<void>(
                tester.element(
                  find.byKey(
                    const ValueKey('support_tool_confirmation_accept'),
                  ),
                ),
              )!
              as ModalBottomSheetRoute<void>;
      final originalNavigator = sheet.navigator!;
      expect(sheet.isCurrent, true);
      expect(originalNavigator.mounted, true);

      // Dispose the ACTUAL screen and its original navigator while confirmation
      // is unresolved. No replacement root/controller, gesture, or UI port.
      await tester.pumpWidget(const SizedBox.shrink());
      await f.screen.join(tester, sheet.completed);
      final reply = await f.finish(tester);
      final row = await configurationAction(
        tester,
        () => core.container
            .read(studioPresetRepoProvider)
            .getById('domain-collision'),
      );
      expect(originalNavigator.mounted, false);
      expect(sheet.navigator, isNull);
      expect(row!.name, DomainLoopFixture.private);
      expect(reply.status, 'stopped');
      expect(reply.body, isNot(contains('изменение сохранено')));
      expect(core.wire, hasLength(1));
      expect(
        await configurationAction(
          tester,
          () => core.native.db
              .select(core.native.db.supportMutationJournal)
              .get(),
        ),
        isEmpty,
      );
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'actual Stop removes only its original pending sheet beneath a later user route',
    (tester, f) async {
      final core = f.screen.core;
      f.script(
        core.call('astoria_studio_preset_manage', {
          'operation': 'rename',
          'id': 'domain-collision',
          'name': 'Must not persist beneath user route',
        }),
      );
      await f.start(tester);
      // Capture the original mounted Stop before pushing the later user route.
      final originalComposer = find.byType(
        SupportComposerBar,
        skipOffstage: false,
      );
      expect(originalComposer, findsOneWidget);
      final composer = tester.widget<SupportComposerBar>(originalComposer);
      expect(composer.sessionId, core.native.session);
      expect(composer.busy, true);
      expect(composer.nativeOwner, isA<SupportModelUiEmitter>());
      expect((composer.nativeOwner! as SupportModelUiEmitter).isCurrent, true);
      final stopButton = find.descendant(
        of: originalComposer,
        matching: find.byKey(
          const ValueKey('support_composer_stop_btn'),
          skipOffstage: false,
        ),
        skipOffstage: false,
      );
      expect(stopButton, findsOneWidget);
      expect(tester.element(stopButton).mounted, true);
      final stop = tester.widget<IconButton>(stopButton).onPressed;
      expect(stop, isNotNull);
      expect(identical(stop, composer.onStop), true);
      final sheet =
          ModalRoute.of<void>(
                tester.element(
                  find.byKey(
                    const ValueKey('support_tool_confirmation_accept'),
                  ),
                ),
              )!
              as ModalBottomSheetRoute<void>;
      final navigator = sheet.navigator!;
      final originalRoute = ModalRoute.of<void>(
        tester.element(originalComposer),
      )!;
      expect(originalRoute.isActive, true);
      expect(originalRoute.navigator, same(navigator));
      final userRoute = MaterialPageRoute<void>(
        builder: (_) => const SizedBox.shrink(),
      );
      final navigation = await configurationAction(
        tester,
        () => (navigator.push<void>(userRoute),),
      );
      try {
        await tester.pump();
        // Flutter's interpolation completes only AFTER its duration, not at
        // the exact endpoint. A still-pushing top route defers lower removal.
        await tester.pump(
          userRoute.transitionDuration + const Duration(microseconds: 1),
        );
        expect(userRoute.animation!.status, AnimationStatus.completed);
        expect(userRoute.isCurrent, true);
        expect(sheet.isCurrent, false);
        await configurationAction(tester, stop!);
        await f.screen.join(tester, sheet.completed);
        final reply = await f.finish(tester);
        final row = await configurationAction(
          tester,
          () => core.container
              .read(studioPresetRepoProvider)
              .getById('domain-collision'),
        );
        expect(userRoute.isCurrent, true);
        expect(identical(userRoute.navigator, navigator), true);
        expect(sheet.navigator, isNull);
        expect(row!.name, DomainLoopFixture.private);
        expect(reply.status, 'stopped');
        expect(reply.body, isNot(contains('изменение сохранено')));
        expect(core.wire, hasLength(1));
        expect(
          await configurationAction(
            tester,
            () => core.native.db
                .select(core.native.db.supportMutationJournal)
                .get(),
          ),
          isEmpty,
        );
        f.noEgress(reply.body);
      } finally {
        // Join the test-owned user route too; Stop must not have popped it.
        await configurationAction(tester, () {
          if (identical(userRoute.navigator, navigator) && userRoute.isActive) {
            navigator.removeRoute(userRoute);
          }
        });
        await f.screen.join(tester, userRoute.completed);
        await f.screen.join(tester, navigation.$1);
      }
    },
  );

  domainLoopTest(
    'MODEL profile metadata uses already-loaded original regex count, never activation or private configuration',
    (tester, f) async {
      final core = f.screen.core, c = core.container;
      core.isolation.extraAllowed.add(globalRegexProvider);
      await configurationAction(tester, () async {
        await c.read(globalRegexProvider.future);
        await c
            .read(globalRegexProvider.notifier)
            .addRegex(
              const PresetRegex(
                id: 'domain-regex',
                name: DomainLoopFixture.private,
                regex: DomainLoopFixture.private,
                replacement: DomainLoopFixture.private,
              ),
            );
      });
      f.script(
        core.call('astoria_secondary_profiles_read', {'domain': 'globalRegex'}),
        next: (_) {
          final result = f.lastResult();
          expect(result['effect'], 'none');
          final data = result['data'] as Map;
          expect(data['scriptCount'], 1);
          expect(data['enabledCount'], 1);
          return core.answer('Loaded regex metadata inspected.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(core.wire, hasLength(2));
      expect(f.results, hasLength(1));
      final result = f.results.single;
      expect(result['ok'], true);
      expect(result['code'], 'completed');
      expect(result['effect'], 'none');
      final data = result['data'] as Map;
      expect(data['scriptCount'], 1);
      expect(data['enabledCount'], 1);
      expect(data.containsKey('count'), false);
      expect(reply.status, 'complete');
      final actual = c.read(globalRegexProvider).value!.single;
      expect(actual.disabled, false);
      expect(actual.regex, DomainLoopFixture.private);
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'actual post-commit native refresh fault retains persisted original fact and refreshPending',
    (tester, f) async {
      final core = f.screen.core;
      f.script(
        core.call('astoria_character_manage', {
          'operation': 'editText',
          'id': DomainLoopFixture.character,
          'field': 'description',
          'text': 'Persisted patch needing native refresh',
        }),
      );
      await f.start(tester);
      var written = false, faulted = false;
      final characterTable = core.native.db.characters.actualTableName;
      final sessionTable = core.native.db.chatSessions.actualTableName;
      core.native.sql.afterWrite = (statement) async {
        if (statement.contains(characterTable)) written = true;
      };
      core.native.sql.afterSelect = (statement, _) async {
        if (written && !faulted && statement.contains(sessionTable)) {
          faulted = true;
          throw StateError('SYNTHETIC_PRIVATE_NATIVE_REFRESH_FAULT');
        }
      };
      await f.apply(tester);
      final reply = await f.finish(tester);
      core.native.sql.afterSelect = null;
      core.native.sql.afterWrite = null;
      final row = await configurationAction(
        tester,
        () => core.container
            .read(characterRepoProvider)
            .getById(DomainLoopFixture.character),
      );
      expect(written, true);
      expect(faulted, true);
      expect(row!.description, 'Persisted patch needing native refresh');
      expect(reply.body, contains('изменение сохранено'));
      expect(
        reply.body,
        contains('обновление нативных представлений ожидается'),
      );
      expect(
        reply.body,
        isNot(contains('SYNTHETIC_PRIVATE_NATIVE_REFRESH_FAULT')),
      );
      expect(core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );
}
