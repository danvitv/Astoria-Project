import 'package:flutter_test/flutter_test.dart';

import 'app_control_fixture.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  appControlTest(
    'only implemented fixed operations are advertised with strict schemas',
    (f) async {
      expect(
        f.registry.definitions.map((d) => d.name),
        unorderedEquals([
          'astoria_preferences_read',
          'astoria_preferences_update',
          'astoria_battery_saver_set',
          'astoria_themes_list',
          'astoria_theme_select',
          'astoria_theme_mode_set',
          'astoria_connections_list',
          'astoria_connection_read',
          'astoria_connection_create',
          'astoria_connection_update',
          'astoria_navigate',
        ]),
      );
      for (final definition in f.registry.definitions) {
        expect(definition.parameters['additionalProperties'], isFalse);
      }
      final unknown = await f.call('astoria_execute_shell', {
        'command': 'synthetic',
      });
      expect(unknown.callId, 'synthetic-call');
      expect(unknown.name, 'astoria_execute_shell');
      expect(unknown.content['code'], 'unknownAction');
      expect(unknown.content['effect'], 'none');
    },
  );

  appControlTest(
    'unknown unsafe fields and coercion are refused without effects',
    (f) async {
      for (final arguments in <Map<String, Object?>>[
        {'enterToSend': 'false'},
        {'enterToSend': null},
        {'enterToSend': 0},
        {'lorebookBuildPrompt': 'SYNTHETIC_PRIVATE_PROMPT'},
        {'allowMessageScripts': true},
        {
          'chatMaxWidth': {'value': 900},
        },
      ]) {
        final result = await f.call('astoria_preferences_update', arguments);
        expect(result.content['code'], 'invalidArguments');
        expect(result.content['effect'], 'none');
        expect(
          result.content.toString(),
          isNot(contains('SYNTHETIC_PRIVATE_PROMPT')),
        );
      }
      final connection = await f.call('astoria_connection_create', {
        'template': 'openaiChat',
        'name': 'SYNTHETIC_CONNECTION',
        'model': 'synthetic-model',
        'endpoint': 'https://other.invalid/v1/chat/completions',
      });
      expect(connection.content['code'], 'invalidArguments');
      expect(await f.api.getConfigIds(), isEmpty);
      expect(f.prefs.getBool('enterToSend'), isNull);
    },
  );

  appControlTest(
    'known secret argument never becomes stored metadata or result content',
    (f) async {
      final result = await f.call('astoria_connection_create', {
        'template': 'openaiChat',
        'name': 'SYNTHETIC_SECRET_CANARY',
        'model': 'synthetic-model',
      });
      expect(result.content['code'], 'unsafeMetadata');
      expect(
        result.content.toString(),
        isNot(contains('SYNTHETIC_SECRET_CANARY')),
      );
      expect(await f.api.getConfigIds(), isEmpty);
    },
  );

  appControlTest(
    'navigation is finite truthful and unavailable without native port',
    (f) async {
      final noPort = await f.call('astoria_navigate', {
        'destination': 'themes',
      }, f.context(withNavigation: false));
      expect(noPort.content['code'], 'unavailable');
      expect(f.navigation.opened, isEmpty);
      final invalid = await f.call('astoria_navigate', {
        'destination': '/arbitrary/path',
      });
      expect(invalid.content['code'], 'invalidArguments');
      final opened = await f.call('astoria_navigate', {
        'destination': 'themes',
      });
      expect(opened.content['effect'], 'navigation');
      expect(f.navigation.opened, [SupportAppDestination.themes]);
      expect(f.backing.checkedWrites, 0);
    },
  );

  appControlTest('original context cannot revive after session replacement', (
    f,
  ) async {
    final original = f.context();
    f.runCurrent = false;
    final first = await f.call('astoria_preferences_update', {
      'enterToSend': false,
    }, original);
    expect(first.content['code'], 'stale');
    f.runCurrent = true;
    final replay = await f.call('astoria_preferences_update', {
      'enterToSend': false,
    }, original);
    expect(replay.content['code'], 'stale');
    expect(f.prefs.getBool('enterToSend'), isNull);
  });

  appControlTest(
    'known secret in native call identity is refused without an echoed result',
    (f) async {
      await expectLater(
        f.registry.execute(
          NativeToolCall(
            id: 'SYNTHETIC_SECRET_CANARY',
            name: 'astoria_preferences_read',
            arguments: {},
          ),
          f.context(),
        ),
        throwsA(isA<NativeToolException>()),
      );
      expect(f.prefs.getBool('enterToSend'), isNull);
    },
  );

  appControlTest(
    'underlying raw error text is not returned or treated as an effect',
    (f) async {
      f.beforeSettingsRead = () async =>
          throw StateError('SYNTHETIC_PRIVATE_EXCEPTION_BODY');
      final result = await f.call('astoria_preferences_read');
      // Readiness failed before any native write was admitted.
      expect(result.content['code'], 'unavailable');
      expect(result.content['effect'], 'none');
      expect(
        result.content.toString(),
        isNot(contains('SYNTHETIC_PRIVATE_EXCEPTION_BODY')),
      );
    },
  );
}
