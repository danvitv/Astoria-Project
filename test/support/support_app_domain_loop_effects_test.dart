import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/state/db_provider.dart';
import 'package:glaze_flutter/features/chat/chat_provider.dart';
import 'package:glaze_flutter/features/extensions/providers/extension_presets_provider.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
import 'package:glaze_flutter/shared/widgets/glaze_action_button.dart';

import 'support_app_domain_loop_fixture.dart';

void main() {
  for (final effect in [
    ('astoria_character_manage', DomainLoopFixture.character, 'description'),
    ('astoria_persona_manage', 'domain-persona', 'prompt'),
    ('astoria_lorebook_manage', 'domain-lore', 'description'),
    ('astoria_preset_manage', 'domain-collision', 'summaryPrompt'),
  ]) {
    domainLoopTest(
      'MODEL exact Apply persists ${effect.$1} through original ROOT',
      (tester, f) async {
        final core = f.screen.core, c = core.container;
        const supplied = 'New supplied content\nwith a preserved second line.';
        final call = core.call(effect.$1, {
          'operation': 'editText',
          'id': effect.$2,
          'field': effect.$3,
          'text': supplied,
        });
        // A later typed action must not inherit already-admitted native custody.
        final extra = core.call('astoria_preferences_update', {
          'hideTooltips': true,
        }, id: 'call_extra');
        final message =
            ((call['choices'] as List).single as Map)['message'] as Map;
        final extraMessage =
            ((extra['choices'] as List).single as Map)['message'] as Map;
        (message['tool_calls'] as List).addAll(
          extraMessage['tool_calls'] as List,
        );
        f.script(call);
        await f.start(tester);
        final button = find.byKey(
          const ValueKey('support_tool_confirmation_accept'),
        );
        final retainedApply = tester.widget<GlazeActionButton>(button).onTap!;
        await f.apply(tester);
        final reply = await f.finish(tester);
        final stored = await configurationAction(
          tester,
          () async => switch (effect.$1) {
            'astoria_character_manage' =>
              (await c.read(characterRepoProvider).getById(effect.$2))!
                  .description,
            'astoria_persona_manage' =>
              (await c.read(personaRepoProvider).getById(effect.$2))!.prompt,
            'astoria_lorebook_manage' =>
              (await c.read(lorebookRepoProvider).getById(effect.$2))!
                  .description,
            _ =>
              (await c.read(presetRepoProvider).getById(effect.$2))!
                  .summaryPrompt,
          },
        );
        expect(stored, supplied);
        expect(reply.status, 'stopped');
        expect(reply.body, contains('${effect.$1}:'));
        expect(reply.body, contains('изменение сохранено'));
        expect(core.wire, hasLength(1));
        expect(
          (await configurationAction(
            tester,
            () => c.read(appSettingsProvider.future),
          )).hideTooltips,
          false,
        );
        await configurationAction(tester, retainedApply);
        expect(core.wire, hasLength(1));
        f.noEgress(reply.body);
      },
    );
  }

  domainLoopTest(
    'MODEL Studio is a distinct saved domain even when ordinary ID collides',
    (tester, f) async {
      final c = f.screen.core.container;
      f.script(
        f.screen.core.call('astoria_studio_preset_manage', {
          'operation': 'rename',
          'id': 'domain-collision',
          'name': 'New Studio name',
        }),
      );
      await f.start(tester);
      await f.apply(tester);
      final reply = await f.finish(tester);
      final rows = await configurationAction(
        tester,
        () async => (
          await c.read(studioPresetRepoProvider).getById('domain-collision'),
          await c.read(presetRepoProvider).getById('domain-collision'),
        ),
      );
      expect(rows.$1!.name, 'New Studio name');
      expect(rows.$1!.blocks.single.content, DomainLoopFixture.private);
      expect(rows.$2!.name, DomainLoopFixture.private);
      expect(rows.$2!.summaryPrompt, DomainLoopFixture.private);
      expect(reply.body, contains('изменение сохранено'));
      expect(f.screen.core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL Memory create uses actual idle Chat owner queue and persists disabled automation',
    (tester, f) async {
      final c = f.screen.core.container;
      f.script(
        f.screen.core.call('astoria_memory_create', {
          'sessionId': DomainLoopFixture.session,
          'enabled': true,
        }),
      );
      await f.start(tester);
      await f.apply(tester);
      final reply = await f.finish(tester);
      final book = await configurationAction(
        tester,
        () => c
            .read(memoryBookRepoProvider)
            .observeForControl(DomainLoopFixture.session),
      );
      expect(book, isNotNull);
      expect(book!.book.settings.enabled, true);
      expect(book.book.settings.autoCreateEnabled, false);
      expect(book.book.settings.autoGenerateEnabled, false);
      expect(book.book.entries, isEmpty);
      expect(book.book.pendingDrafts, isEmpty);
      expect(
        (await configurationAction(
          tester,
          () => c.read(chatProvider(DomainLoopFixture.character).future),
        )).session!.messages.every(
          (m) => m.content == DomainLoopFixture.private,
        ),
        true,
      );
      expect(reply.status, 'stopped');
      expect(reply.body, contains('изменение сохранено'));
      expect(f.screen.core.wire, hasLength(1));
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL extension discovery then exact disable changes native next-chain owner',
    (tester, f) async {
      final core = f.screen.core;
      f.script(
        core.call('astoria_extension_controls_read', {}),
        next: (round) {
          final data = f.lastData();
          if (round == 2) {
            final handle = (data['items'] as List)
                .cast<Map<dynamic, dynamic>>()
                .single['handle'];
            return core.call('astoria_extension_controls_read', {
              'presetHandle': handle,
            }, id: 'call_2');
          }
          final handle = (data['items'] as List)
              .cast<Map<dynamic, dynamic>>()
              .single['handle'];
          return core.call('astoria_extension_block_disable', {
            'blockHandle': handle,
          }, id: 'call_3');
        },
      );
      await f.start(tester);
      await f.apply(tester);
      final reply = await f.finish(tester);
      final actual = await configurationAction(
        tester,
        () => core.container.read(extensionPresetsRepoProvider).getAll(),
      );
      expect(actual.single.blocks.single.enabled, false);
      expect(actual.single.blocks.single.script, DomainLoopFixture.private);
      expect(
        core.container
            .read(extensionPresetsProvider)
            .single
            .blocks
            .single
            .enabled,
        false,
      );
      expect(reply.body, contains('изменение сохранено'));
      expect(core.wire, hasLength(3));
      final second = core.wire[1]['messages'] as List;
      expect(
        second.cast<Map<dynamic, dynamic>>().last['tool_call_id'],
        'call_1',
      );
      f.noEgress(reply.body);
    },
  );

  domainLoopTest(
    'MODEL Cancel grants no domain effect and returned failure defeats success prose',
    (tester, f) async {
      final core = f.screen.core;
      f.script(
        core.call('astoria_studio_preset_manage', {
          'operation': 'rename',
          'id': 'domain-collision',
          'name': 'Not saved',
        }),
        next: (_) {
          f.lastResult();
          return core.answer('Everything succeeded.');
        },
      );
      await f.start(tester);
      await f.cancel(tester);
      final reply = await f.finish(tester);
      final row = await configurationAction(
        tester,
        () => core.container
            .read(studioPresetRepoProvider)
            .getById('domain-collision'),
      );
      expect(row!.name, DomainLoopFixture.private);
      expect(f.results.single['code'], 'denied');
      expect(f.results.single['effect'], 'none');
      expect(reply.body, isNot(contains('Everything succeeded.')));
      expect(core.wire, hasLength(2));
      f.noEgress(reply.body);
    },
  );
}
