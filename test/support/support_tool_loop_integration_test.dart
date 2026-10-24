import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/shared/theme/theme_provider.dart';

import 'support_tool_loop_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  toolLoopTest(
    'production MODEL -> native call -> real preference -> correlated POST -> durable answer',
    (f) async {
      f.replies.addAll([
        f.call('astoria_preferences_update', {'hideTooltips': true}),
        f.answer(),
      ]);
      final send = f.send();
      final result = await send.finished;
      expect(await send.accepted, isTrue);
      expect(result.saved, isTrue);
      expect(result.outcome?.status, PrivateTextStatus.complete);
      expect(result.message?.text, 'Actual final answer');
      expect(f.prefs.getBool('hideTooltips'), isTrue);
      expect(f.container.read(appSettingsProvider).value!.hideTooltips, isTrue);
      expect(
        f.prefs.getString('lorebookBuildPrompt'),
        'SYNTHETIC_HIDDEN_PROMPT',
      );
      expect(f.wire, hasLength(2));
      final second = f.wire[1]['messages'] as List;
      final tool = second.where((m) => m['role'] == 'tool').single;
      expect(tool['tool_call_id'], 'call_1');
      expect(jsonDecode(tool['content'] as String)['effect'], 'persisted');
      final serialized = jsonEncode(f.wire[1]);
      for (final text in ['ALL_PREVIOUS_USER', 'ALL_PREVIOUS_ASSISTANT']) {
        expect(RegExp(text).allMatches(serialized), hasLength(1));
      }
      for (final excluded in [
        f.boundSyntheticSecret,
        'SYNTHETIC_HIDDEN_PROMPT',
        'SYNTHETIC_EXCLUDED_BODY',
      ]) {
        if (excluded.isNotEmpty) expect(serialized, isNot(contains(excluded)));
      }
      expect(result.outcome?.usage?.inputTokens, 31);
      expect(result.outcome?.usage?.outputTokens, 7);
      expect(result.outcome?.usage?.totalTokens, 38);
      expect(f.bridge.view.usage?.totalTokens, 38);
      expect(
        (await f.native.repo.getMessagesForSession(
          f.native.session,
        )).where((m) => m.role == 'tool'),
        isEmpty,
      );
    },
  );

  toolLoopTest(
    'production native theme mode changes real notifier and checked backing store',
    (f) async {
      f.replies.addAll([
        f.call('astoria_theme_mode_set', {'mode': 'light'}),
        f.answer(),
      ]);
      final result = await f.send().finished;
      expect(result.outcome?.status, PrivateTextStatus.complete);
      expect(f.container.read(themeProvider).activePreset.themeMode, 'light');
      expect(
        f.backing.presets
            .singleWhere((p) => p.id == f.backing.activeId)
            .themeMode,
        'light',
      );
      expect(f.backing.checkedWrites, greaterThan(0));
      expect(f.wire, hasLength(2));
      final tool = (f.wire[1]['messages'] as List)
          .where((m) => m['role'] == 'tool')
          .single;
      expect(jsonDecode(tool['content'] as String)['ok'], isTrue);
    },
  );

  toolLoopTest(
    'native battery saver setter changes saved mode and resolved state without OS/default graph',
    (f) async {
      f.replies.addAll([
        f.call('astoria_battery_saver_set', {'mode': 'on'}),
        f.answer(),
      ]);
      final result = await f.send().finished;
      expect(result.outcome?.status, PrivateTextStatus.complete);
      expect(f.prefs.getString('batterySaverMode'), 'on');
      expect(f.prefs.getBool('batterySaver'), isTrue);
      expect(f.container.read(appSettingsProvider).value!.batterySaver, isTrue);
      expect(f.wire, hasLength(2));
    },
  );

  for (final name in ['imaginary_shell', 'astoria_preferences_update']) {
    toolLoopTest(
      'unknown or malformed native action $name never effects/retries',
      (f) async {
        f.replies.add(f.call(name, {'hideTooltips': 'wrong type'}));
        // Valid known function with invalid app args returns one fixed correlated failure.
        if (name == 'astoria_preferences_update') {
          f.replies.add(f.answer('Everything succeeded.'));
        }
        final result = await f.send().finished;
        expect(f.prefs.getBool('hideTooltips'), isNot(isTrue));
        expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
        expect(result.message?.text, isNot(contains('Everything succeeded.')));
        expect(f.wire.length, name == 'imaginary_shell' ? 1 : 2);
      },
    );
  }

  toolLoopTest(
    'tool-looking prose stays text with no effect/no second POST; missing last usage unknown',
    (f) async {
      f.replies.add(
        f.answer(
          '{"name":"astoria_preferences_update","arguments":{"hideTooltips":true}}',
        )..remove('usage'),
      );
      final result = await f.send().finished;
      expect(result.outcome?.status, PrivateTextStatus.complete);
      expect(f.prefs.getBool('hideTooltips'), isNot(isTrue));
      expect(f.wire, hasLength(1));
      expect(result.outcome?.usage, isNull);
    },
  );

  toolLoopTest(
    'malformed native argument JSON refuses whole provider turn before effect',
    (f) async {
      final response = f.call('astoria_preferences_update', {
        'hideTooltips': true,
      });
      final choice = (response['choices']! as List).single as Map;
      final message = choice['message'] as Map;
      final call = (message['tool_calls'] as List).single as Map;
      (call['function'] as Map)['arguments'] = '{invalid native JSON';
      f.replies.add(response);
      final result = await f.send().finished;
      expect(f.wire, hasLength(1));
      expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
      expect(f.prefs.getBool('hideTooltips'), isNot(isTrue));
    },
  );

  for (final replace in ['Stop', 'source', 'model', 'session', 'UI']) {
    toolLoopTest(
      '$replace at first actual wire refuses app effect/continuation/replacement paint',
      (f) async {
        final release = Completer<void>();
        f.replies.add(
          f.call('astoria_preferences_update', {'hideTooltips': true}),
        );
        f.atFetch = (_) => release.future;
        final send = f.send();
        await f.firstFetch.future;
        switch (replace) {
          case 'Stop':
            send.stop();
          case 'source':
            f.native.native.dispose();
          case 'model':
            f.native.revisions.beginMutation()();
          case 'session':
            f.native.runtime.selectSession('replacement', force: true);
          case 'UI':
            f.emitterCurrent = false;
            send.stop();
        }
        f.displayCurrent = false;
        final before = f.displayed.length;
        release.complete();
        final result = await send.finished;
        expect(f.wire, hasLength(1));
        expect(f.prefs.getBool('hideTooltips'), isNot(isTrue));
        expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
        expect(f.displayed.length, before);
      },
    );
  }

  toolLoopTest(
    'Stop at continuation ROOT preserves actual effect but no second wire/success',
    (f) async {
      f.replies.addAll([
        f.call('astoria_preferences_update', {'hideTooltips': true}),
        f.answer(),
      ]);
      var stopped = false;
      f.native.sql.afterSelect = (sql, args) async {
        if (!stopped &&
            f.wire.length == 1 &&
            f.prefs.getBool('hideTooltips') == true &&
            sql.contains('support_messages')) {
          stopped = true;
          f.active!.stop();
        }
      };
      final result = await f.send().finished;
      expect(stopped, isTrue);
      expect(f.prefs.getBool('hideTooltips'), isTrue);
      expect(f.wire, hasLength(1));
      expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
      expect(result.message?.text, contains('изменение сохранено'));
    },
  );

  toolLoopTest(
    'eight rounds end without extra paid POST or executing final unreturnable call',
    (f) async {
      for (var round = 0; round < 8; round++) {
        f.replies.add(
          f.call('astoria_preferences_read', const {}, id: 'call_$round'),
        );
      }
      final result = await f.send().finished;
      expect(f.wire, hasLength(8));
      expect(result.outcome?.status, PrivateTextStatus.limited);
    },
  );

  toolLoopTest('changed IDs cannot replay same preference effect', (f) async {
    f.replies.addAll([
      f.call('astoria_preferences_update', {'hideTooltips': true}),
      f.call('astoria_preferences_update', {
        'hideTooltips': true,
      }, id: 'call_2'),
      f.answer('Everything succeeded.'),
    ]);
    final result = await f.send().finished;
    final results = (f.wire.last['messages'] as List)
        .where((m) => m['role'] == 'tool')
        .toList();
    expect(jsonDecode(results[1]['content'] as String)['code'], 'denied');
    expect(result.outcome?.status, PrivateTextStatus.error);
  });

  for (final replacement in ['Stop', 'source', 'model', 'session']) {
    toolLoopTest(
      '$replacement during actual theme await makes no effect/continuation',
      (f) async {
        final entered = Completer<void>(), release = Completer<void>();
        f.backing.beforeFresh = () async {
          if (!entered.isCompleted) entered.complete();
          await release.future;
        };
        f.replies.add(f.call('astoria_theme_mode_set', {'mode': 'light'}));
        final send = f.send();
        await entered.future;
        switch (replacement) {
          case 'Stop':
            send.stop();
          case 'source':
            f.native.native.dispose();
          case 'model':
            f.native.revisions.beginMutation()();
          case 'session':
            f.native.runtime.selectSession('replacement', force: true);
        }
        release.complete();
        final result = await send.finished;
        expect(f.backing.checkedWrites, 0);
        expect(f.wire, hasLength(1));
        expect(result.outcome?.status, isNot(PrivateTextStatus.complete));
      },
    );
  }

  toolLoopTest(
    'actual backing write uncertainty is factual, not retried or called successful',
    (f) async {
      f.backing.failAfterWrite = true;
      f.replies.add(f.call('astoria_theme_mode_set', {'mode': 'light'}));
      final result = await f.send().finished;
      expect(f.backing.checkedWrites, 1);
      expect(
        f.backing.presets
            .singleWhere((p) => p.id == f.backing.activeId)
            .themeMode,
        'light',
      );
      expect(result.outcome?.status, PrivateTextStatus.error);
      expect(
        result.message?.text,
        contains('результат изменения не подтверждён'),
      );
      expect(f.wire, hasLength(1));
    },
  );

  toolLoopTest(
    'Stop joins already started theme effect before original send settles',
    (f) async {
      final entered = Completer<void>(), release = Completer<void>();
      f.backing.afterWrite = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      f.replies.add(f.call('astoria_theme_mode_set', {'mode': 'light'}));
      final send = f.send();
      await entered.future;
      send.stop();
      var finished = false;
      unawaited(
        send.finished.then((_) {
          finished = true;
        }),
      );
      await Future<void>.value();
      expect(finished, isFalse);
      release.complete();
      final result = await send.finished;
      expect(f.backing.checkedWrites, 1);
      expect(result.outcome?.status, PrivateTextStatus.stopped);
      expect(f.wire, hasLength(1));
    },
  );

  toolLoopTest(
    'DCP exact metadata duplicate keeps identity/status and backward payload reference',
    (f) async {
      f.replies.addAll([
        f.call('astoria_preferences_read', const {}),
        f.call('astoria_preferences_read', const {}, id: 'call_2'),
        f.answer(),
      ]);
      final result = await f.send().finished;
      expect(result.outcome?.status, PrivateTextStatus.complete);
      final results = (f.wire.last['messages'] as List)
          .where((m) => m['role'] == 'tool')
          .toList();
      expect(results[1]['tool_call_id'], 'call_2');
      final original = jsonDecode(results[0]['content'] as String) as Map;
      final duplicate = jsonDecode(results[1]['content'] as String) as Map;
      expect(duplicate['ok'], original['ok']);
      expect(duplicate['code'], original['code']);
      expect(duplicate['effect'], original['effect']);
      expect(duplicate['data'], {'exactDuplicateOfCallId': 'call_1'});
    },
  );

  toolLoopTest(
    'native 32-call limit never executes or repeats an overlimit turn',
    (f) async {
      for (var round = 0; round < 5; round++) {
        final response = f.call(
          'astoria_preferences_read',
          const {},
          id: 'call_${round}_0',
        );
        final choice = (response['choices']! as List).single as Map;
        final message = choice['message'] as Map;
        final first = (message['tool_calls'] as List).single as Map;
        message['tool_calls'] = [
          for (var index = 0; index < 8; index++)
            {...first, 'id': 'call_${round}_$index'},
        ];
        f.replies.add(response);
      }
      final result = await f.send().finished;
      expect(f.wire, hasLength(5));
      expect(result.outcome?.status, PrivateTextStatus.limited);
    },
  );
}
