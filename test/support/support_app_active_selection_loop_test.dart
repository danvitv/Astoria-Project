import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/chat_source_mutation_provider.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_domain_loop_fixture.dart';

/// The only additional original graph is the two actual loaded StateControllers.
/// The fixture's memory plugin was installed before its native-channel tripwire;
/// explicitly attest that synthetic producer, never hydrate a production plugin.
Future<TrackedSharedPreferences> _loadedSelections(
  WidgetTester tester,
  DomainLoopFixture f, {
  String? persona,
  String? preset,
}) async {
  final core = f.screen.core;
  core.isolation.extraAllowed.addAll({
    activePersonaIdProvider,
    activePresetIdProvider,
  });
  return configurationAction(tester, () async {
    final raw = await core.container.read(sharedPreferencesProvider.future);
    expect(raw, same(core.prefs));
    SavedPreferencesOwner.process.attach(raw, trustedPlugin: true);
    final prefs =
        TrackedSharedPreferences.wrap(raw) as TrackedSharedPreferences;
    if (persona != null) await prefs.setString('activePersonaId', persona);
    if (preset != null) await prefs.setString('activePresetId', preset);
    core.container.read(activePersonaIdProvider.notifier).state = persona;
    core.container.read(activePresetIdProvider.notifier).state = preset;
    return prefs;
  });
}

void main() {
  for (final initial in <String?>[null, '']) {
    domainLoopTest('MODEL retained selection Undo preserves '
        '${initial == null ? 'absent' : 'empty'} original preference', (
      tester,
      f,
    ) async {
      final core = f.screen.core;
      final prefs = await _loadedSelections(tester, f, persona: initial);
      f.script(
        core.call('astoria_active_persona_set', {
          'operation': 'select',
          'id': 'domain-persona',
        }),
      );
      await f.start(tester);
      final preview = find.byKey(
        const ValueKey('support_tool_confirmation_preview'),
      );
      expect(
        find.descendant(
          of: preview,
          matching: find.textContaining(
            initial == null ? 'absent' : 'empty',
            findRichText: true,
          ),
        ),
        findsWidgets,
      );
      await f.apply(tester);
      final applied = await f.finish(tester);
      expect(prefs.getString('activePersonaId'), 'domain-persona');
      expect(core.container.read(activePersonaIdProvider), 'domain-persona');
      expect(core.wire, hasLength(1));
      expect(applied.body, contains('изменение сохранено'));
      final journal = await configurationAction(
        tester,
        () => core.native.repo.getMutationsForSession(core.native.session),
      );
      expect(journal.single.domain, 'activeSelection');
      expect(journal.single.status, 'applied');
      f.script(
        core.call('astoria_active_selection_receipts', {}),
        next: (_) {
          final records = f.lastData()['records'] as List;
          expect(records, hasLength(1));
          return core.call('astoria_active_selection_undo', {
            'receipt': (records.single as Map)['receipt'],
          }, id: 'call_undo');
        },
      );
      await f.start(
        tester,
      ); // A new actual native Undo gesture, never replayed JSON.
      await f.apply(tester);
      final undone = await f.finish(tester);
      expect(prefs.containsKey('activePersonaId'), initial != null);
      expect(prefs.getString('activePersonaId'), initial);
      expect(core.container.read(activePersonaIdProvider), initial);
      expect(
        (await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        )).single.status,
        'undone',
      );
      expect(core.wire, hasLength(3));
      f.noEgress('${applied.body}${undone.body}');
    });
  }

  domainLoopTest(
    'MODEL ordinary active preset never resolves colliding Studio row',
    (tester, f) async {
      final core = f.screen.core;
      final prefs = await _loadedSelections(tester, f);
      f.script(
        core.call('astoria_active_preset_set', {
          'operation': 'select',
          'id': 'domain-collision',
        }),
      );
      await f.start(tester);
      await f.apply(tester);
      final reply = await f.finish(tester);
      expect(prefs.getString('activePresetId'), 'domain-collision');
      expect(core.container.read(activePresetIdProvider), 'domain-collision');
      expect(prefs.containsKey('activePersonaId'), false);
      expect(prefs.containsKey('activeStudioPresetId'), false);
      final rows = await configurationAction(
        tester,
        () async => (
          await core.container
              .read(presetRepoProvider)
              .getById('domain-collision'),
          await core.container
              .read(studioPresetRepoProvider)
              .getById('domain-collision'),
        ),
      );
      expect(rows.$1!.summaryPrompt, DomainLoopFixture.private);
      expect(rows.$2!.blocks.single.content, DomainLoopFixture.private);
      expect(core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest('MODEL Studio-only ID cannot become ordinary selection', (
    tester,
    f,
  ) async {
    final core = f.screen.core;
    final prefs = await _loadedSelections(tester, f);
    await configurationAction(
      tester,
      () => core.container
          .read(studioPresetRepoProvider)
          .upsert(
            const StudioPreset(id: 'studio-only', name: 'Synthetic Studio'),
          ),
    );
    f.script(
      core.call('astoria_active_preset_set', {
        'operation': 'select',
        'id': 'studio-only',
      }),
      next: (_) {
        expect(f.lastResult()['code'], 'unavailable');
        return core.answer('Done.');
      },
    );
    await f.start(tester, confirmation: false);
    final reply = await f.finish(tester);
    expect(prefs.containsKey('activePresetId'), false);
    expect(
      find.byKey(const ValueKey('support_tool_confirmation_accept')),
      findsNothing,
    );
    f.noEgress(reply.body);
  });

  domainLoopTest('MODEL Cancel writes no selection or journal', (
    tester,
    f,
  ) async {
    final core = f.screen.core;
    final prefs = await _loadedSelections(tester, f);
    f.script(
      core.call('astoria_active_persona_set', {
        'operation': 'select',
        'id': 'domain-persona',
      }),
      next: (_) {
        expect(f.lastResult()['code'], 'denied');
        return core.answer('Done.');
      },
    );
    await f.start(tester);
    await f.cancel(tester);
    final reply = await f.finish(tester);
    expect(prefs.containsKey('activePersonaId'), false);
    expect(core.container.read(activePersonaIdProvider), isNull);
    expect(
      await configurationAction(
        tester,
        () => core.native.repo.getMutationsForSession(core.native.session),
      ),
      isEmpty,
    );
    f.noEgress(reply.body);
  });

  domainLoopTest(
    'MODEL same-value preference ABA retires old selection receipt',
    (tester, f) async {
      final core = f.screen.core;
      final prefs = await _loadedSelections(tester, f);
      f.script(
        core.call('astoria_active_preset_set', {
          'operation': 'select',
          'id': 'domain-collision',
        }),
      );
      await f.start(tester);
      await f.apply(tester);
      await f.finish(tester);
      await configurationAction(
        tester,
        () => prefs.setString('activePresetId', 'domain-collision'),
      );
      f.script(
        core.call('astoria_active_selection_receipts', {}),
        next: (_) {
          expect(f.lastData()['records'], isEmpty);
          return core.answer('No current retained receipt.');
        },
      );
      await f.start(tester, confirmation: false);
      final reply = await f.finish(tester);
      expect(prefs.getString('activePresetId'), 'domain-collision');
      expect(
        find.byKey(const ValueKey('support_tool_confirmation_accept')),
        findsNothing,
      );
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL lost journal settlement retains the acknowledged selection fact',
    (tester, f) async {
      final core = f.screen.core;
      final prefs = await _loadedSelections(tester, f);
      f.script(
        core.call('astoria_active_persona_set', {
          'operation': 'select',
          'id': 'domain-persona',
        }),
      );
      await f.start(tester);
      core.native.sql.afterWrite = (statement) async {
        final sql = statement.toLowerCase();
        if (sql.startsWith('update') &&
            sql.contains('support_mutation_journal')) {
          throw StateError('Synthetic exact journal settlement failure.');
        }
      };
      await f.apply(tester);
      final reply = await f.finish(tester);
      core.native.sql.afterWrite = null;
      expect(prefs.getString('activePersonaId'), 'domain-persona');
      expect(core.container.read(activePersonaIdProvider), 'domain-persona');
      expect(reply.body, contains('изменение сохранено'));
      expect(reply.body, isNot(contains('без изменений')));
      expect(
        (await configurationAction(
          tester,
          () => core.native.repo.getMutationsForSession(core.native.session),
        )).single.status,
        'pending',
      );
      f.script(
        core.call('astoria_active_selection_receipts', {}),
        next: (_) {
          expect(f.lastData()['records'], isEmpty);
          return core.answer('No retained Undo receipt.');
        },
      );
      await f.start(tester, confirmation: false);
      final after = await f.finish(tester);
      f.noEgress('${reply.body}${after.body}');
    },
  );

  for (final change in ['controller', 'collateralSource', 'stop']) {
    domainLoopTest(
      'MODEL $change retirement before selection Apply prevents write',
      (tester, f) async {
        final core = f.screen.core;
        final prefs = await _loadedSelections(tester, f);
        f.script(
          core.call('astoria_active_persona_set', {
            'operation': 'select',
            'id': 'domain-persona',
          }),
          next: (_) => core.answer('Nothing saved.'),
        );
        await f.start(tester);
        final button = find.byKey(
          const ValueKey('support_tool_confirmation_accept'),
        );
        final route = ModalRoute.of<void>(tester.element(button))!;
        final expiredApply = tester.widget<GlazeActionButton>(button).onTap!;
        await configurationAction(tester, () {
          if (change == 'controller') {
            core.container.invalidate(activePersonaIdProvider);
          } else if (change == 'collateralSource') {
            core.container
                .read(chatSourceMutationRegistryProvider)
                .beginMutation(sessionId: DomainLoopFixture.session)();
          } else {
            final stop = tester
                .widget<IconButton>(
                  find.byKey(const ValueKey('support_composer_stop_btn')),
                )
                .onPressed;
            expect(stop, isNotNull);
            stop!();
          }
        });
        // Exercise the original gesture after retirement. It cannot issue a
        // lease or close a still-open sheet; only native Cancel may dismiss it.
        await configurationAction(tester, expiredApply);
        await tester.pump();
        if (route.isCurrent) await f.cancel(tester);
        await tester.pump(route.reverseTransitionDuration);
        await tester.pump(const Duration(microseconds: 1));
        expect(route.isCurrent, false);
        final reply = await f.finish(tester);
        expect(prefs.containsKey('activePersonaId'), false);
        expect(
          await configurationAction(
            tester,
            () => core.native.repo.getMutationsForSession(core.native.session),
          ),
          isEmpty,
        );
        f.noEgress(reply.body);
      },
    );
  }
}
