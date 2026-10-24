import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';

import 'app_control_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  appControlTest(
    'safe preference patch changes actual notifier and memory persistence',
    (f) async {
      f.confirmation.accept = false; // Reversible preferences need no modal.
      final result = await f.call('astoria_preferences_update', {
        'enterToSend': false,
        'hideTokenCount': true,
        'chatMaxWidth': 1000,
      });
      expect(result.callId, 'synthetic-call');
      expect(result.name, 'astoria_preferences_update');
      expect(result.content['code'], 'completed');
      expect(result.content['effect'], 'persisted');
      expect(f.confirmation.last, isNull);
      final state = f.container.read(appSettingsProvider).requireValue;
      expect(state.enterToSend, isFalse);
      expect(state.hideTokenCount, isTrue);
      expect(state.chatMaxWidth, 1000);
      expect(f.prefs.getBool('enterToSend'), isFalse);
      expect(f.prefs.getDouble('gz_chat_max_width'), 1000);
      expect(
        f.prefs.getString('lorebookBuildPrompt'),
        'SYNTHETIC_PRIVATE_PROMPT',
      );
      expect(
        result.content.toString(),
        isNot(contains('SYNTHETIC_PRIVATE_PROMPT')),
      );
      final read = await f.call('astoria_preferences_read');
      expect((read.content['data']! as Map)['enterToSend'], isFalse);
      expect(read.content.toString(), isNot(contains('lorebookBuildPrompt')));
    },
  );

  appControlTest(
    'battery mode uses actual setter and persists resolved state',
    (f) async {
      final result = await f.call('astoria_battery_saver_set', {'mode': 'on'});
      expect(result.content['code'], 'completed');
      expect(f.prefs.getString('batterySaverMode'), 'on');
      expect(f.prefs.getBool('batterySaver'), isTrue);
      expect(
        f.container.read(appSettingsProvider).requireValue.batterySaverMode,
        BatterySaverMode.on,
      );
    },
  );

  appControlTest(
    'cancel during readiness read prevents exact preference effect',
    (f) async {
      final entered = Completer<void>(), release = Completer<void>();
      f.beforeSettingsRead = () async {
        entered.complete();
        await release.future;
      };
      final pending = f.call('astoria_preferences_update', {
        'enterToSend': false,
      });
      await entered.future;
      f.cancelToken.cancel();
      release.complete();
      final result = await pending;
      expect(result.content['code'], 'cancelled');
      expect(result.content['effect'], 'none');
      expect(f.prefs.getBool('enterToSend'), isNull);
      expect(
        f.container.read(appSettingsProvider).requireValue.enterToSend,
        isTrue,
      );
    },
  );

  appControlTest(
    'replaced original session during readiness prevents persistence',
    (f) async {
      f.beforeSettingsRead = () async => f.runCurrent = false;
      final result = await f.call('astoria_preferences_update', {
        'hideTokenCount': true,
      });
      expect(result.content['code'], 'stale');
      expect(f.prefs.getBool('hideTokenCount'), isNull);
    },
  );

  appControlTest(
    'missing delegated reversible authority does not mutate settings',
    (f) async {
      final result = await f.call('astoria_preferences_update', {
        'enterToSend': false,
      }, f.context(allowChanges: false));
      expect(result.content['code'], 'denied');
      expect(f.prefs.getBool('enterToSend'), isNull);
    },
  );
}
