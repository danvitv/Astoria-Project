import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/features/settings/app_settings_provider.dart';
// Test-only backing store uses the already-resolved transitive interface.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'app_control_fixture.dart';

AppSettings _settings(AppControlFixture f) =>
    f.container.read(appSettingsProvider).requireValue;
AppSettingsNotifier _owner(AppControlFixture f) =>
    f.container.read(appSettingsProvider.notifier);

/// The actual SharedPreferences cache/setter runs; only the native backing store
/// is intercepted. No platform, real preference store or app graph is consulted.
final class _PreferencesBacking extends SharedPreferencesStorePlatform {
  _PreferencesBacking(AppControlFixture f) {
    for (final key in f.prefs.getKeys()) {
      values['flutter.$key'] = f.prefs.get(key)!;
    }
  }
  final values = <String, Object>{};
  final writes = <String>[];
  Future<void> Function(String key)? beforeWrite;
  String? throwAfterWrite, rejectWrite;

  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    writes.add(key);
    await beforeWrite?.call(key);
    values[key] = value;
    if (key == throwAfterWrite) throw StateError('SYNTHETIC_SECRET_CANARY');
    return key != rejectWrite;
  }

  @override
  Future<bool> remove(String key) async =>
      throw StateError('Removal outside scalar fixture.');
  @override
  Future<bool> clear() async =>
      throw StateError('Clear outside scalar fixture.');
}

Future<void> _backing(
  AppControlFixture f,
  Future<void> Function(_PreferencesBacking) body,
) async {
  final previous = SharedPreferencesStorePlatform.instance;
  final store = _PreferencesBacking(f);
  SharedPreferencesStorePlatform.instance = store;
  try {
    await body(store);
  } finally {
    SharedPreferencesStorePlatform.instance = previous;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  appControlTest(
    'native preference acquisition CAS preserves competing ordinary prompt/edit',
    (f) async {
      await _backing(f, (store) async {
        final entered = Completer<void>(), release = Completer<void>();
        f.beforeSettingsPersistence = () async {
          f.beforeSettingsPersistence =
              null; // Only the model acquisition waits.
          entered.complete();
          await release.future;
        };
        final pending = f.call('astoria_preferences_update', {
          'enterToSend': false,
        });
        await entered.future;
        await _owner(f).save(
          _settings(f).copyWith(
            lorebookBuildPrompt: 'SYNTHETIC_NEW_PROMPT',
            lorebookBuildPromptJs: 'SYNTHETIC_NEW_JS_PROMPT',
            hideTokenCount: true,
            language: 'ru',
          ),
        );
        final ordinaryWrites = store.writes.length;
        release.complete();
        final result = await pending;
        expect(result.content['code'], 'completed');
        expect(result.content['effect'], 'persisted');
        expect(store.writes.skip(ordinaryWrites), ['flutter.enterToSend']);
        expect(_settings(f).enterToSend, isFalse);
        expect(_settings(f).hideTokenCount, isTrue);
        expect(_settings(f).language, 'ru');
        expect(_settings(f).lorebookBuildPrompt, 'SYNTHETIC_NEW_PROMPT');
        expect(
          f.prefs.getString('lorebookBuildPromptJs'),
          'SYNTHETIC_NEW_JS_PROMPT',
        );
        expect(result.content.toString(), isNot(contains('SYNTHETIC_NEW')));
        expect(
          result.content.toString(),
          isNot(contains('lorebookBuildPrompt')),
        );
      });
    },
  );

  appControlTest(
    'selected field changed during actual acquisition refuses even when desired now matches',
    (f) async {
      final entered = Completer<void>(), release = Completer<void>();
      f.beforeSettingsPersistence = () async {
        f.beforeSettingsPersistence = null;
        entered.complete();
        await release.future;
      };
      final pending = f.call('astoria_preferences_update', {
        'enterToSend': false,
      });
      await entered.future;
      await _owner(f).save(_settings(f).copyWith(enterToSend: false));
      release.complete();
      final result = await pending;
      expect(result.content['code'], 'conflict');
      expect(result.content['effect'], 'none');
      expect(_settings(f).enterToSend, isFalse);
    },
  );

  appControlTest(
    'cancel during notifier preference acquisition has no effect',
    (f) async {
      await _backing(f, (store) async {
        final entered = Completer<void>(), release = Completer<void>();
        f.beforeSettingsPersistence = () async {
          entered.complete();
          await release.future;
        };
        final pending = f.call('astoria_preferences_update', {
          'hideTokenCount': true,
        });
        await entered.future;
        f.cancelToken.cancel();
        release.complete();
        final result = await pending;
        expect(result.content['code'], 'cancelled');
        expect(result.content['effect'], 'none');
        expect(result.content['data'], isEmpty);
        expect(store.writes, isEmpty);
        expect(f.prefs.getBool('hideTokenCount'), isNull);
        expect(_settings(f).hideTokenCount, isFalse);
      });
    },
  );

  appControlTest(
    'unknown native or adapter readiness fails closed without poisoning owner',
    (f) async {
      f.beforeSettingsPersistence = () async =>
          throw StateError('SYNTHETIC_SECRET_CANARY');
      final failed = await f.call('astoria_preferences_update', {
        'enterToSend': false,
      });
      expect(failed.content['code'], 'unavailable');
      expect(failed.content['effect'], 'none');
      expect(
        failed.content.toString(),
        isNot(contains('SYNTHETIC_SECRET_CANARY')),
      );
      expect(f.prefs.getBool('enterToSend'), isNull);
      f.beforeSettingsPersistence = null;
      f.beforeSettingsRead = () async =>
          throw StateError('SYNTHETIC_SECRET_CANARY');
      expect(
        (await f.call('astoria_preferences_update', {
          'enterToSend': false,
        })).content['code'],
        'unavailable',
      );
      f.beforeSettingsRead = null;
      expect(
        (await f.call('astoria_preferences_update', {
          'enterToSend': false,
        })).content['code'],
        'completed',
      );
    },
  );

  appControlTest(
    'battery guarded OS await merges ordinary unrelated prompt edit',
    (f) async {
      final entered = Completer<void>(), release = Completer<bool>();
      f.readPowerSaveMode = () {
        entered.complete();
        return release.future;
      };
      final pending = f.call('astoria_battery_saver_set', {'mode': 'system'});
      await entered.future;
      await _owner(f).save(
        _settings(f).copyWith(
          lorebookBuildPrompt: 'SYNTHETIC_OS_PROMPT',
          hideContextCard: true,
        ),
      );
      release.complete(true);
      final result = await pending;
      expect(result.content['code'], 'completed');
      expect(result.content['data'], {'mode': 'system', 'resolved': true});
      expect(f.prefs.getString('batterySaverMode'), 'system');
      expect(f.prefs.getBool('batterySaver'), isTrue);
      expect(_settings(f).batterySaver, isTrue);
      expect(_settings(f).hideContextCard, isTrue);
      expect(_settings(f).lorebookBuildPrompt, 'SYNTHETIC_OS_PROMPT');
    },
  );

  appControlTest(
    'loading owner after native readiness await refuses without cached-state fallback',
    (f) async {
      await _backing(f, (store) async {
        final entered = Completer<void>(), release = Completer<void>();
        final rebuilding = Completer<void>(), finishBuild = Completer<void>();
        f.beforeSettingsPersistence = () async {
          f.beforeSettingsPersistence = null;
          entered.complete();
          await release.future;
        };
        final pending = f.call('astoria_preferences_update', {
          'enterToSend': false,
        });
        await entered.future;
        f.beforeSettingsBuild = () async {
          rebuilding.complete();
          await finishBuild.future;
        };
        f.container.invalidate(appSettingsProvider);
        final readyAgain = f.container.read(appSettingsProvider.future);
        await rebuilding.future;
        release.complete();
        final result = await pending;
        expect(result.content['code'], anyOf('unavailable', 'stale'));
        expect(result.content['effect'], 'none');
        expect(store.writes, isEmpty);
        finishBuild.complete();
        await readyAgain;
        expect(_settings(f).enterToSend, isTrue);
      });
    },
  );

  appControlTest(
    'battery selected expectation is checked after real OS barrier',
    (f) async {
      final entered = Completer<void>(), release = Completer<bool>();
      f.readPowerSaveMode = () {
        entered.complete();
        return release.future;
      };
      final pending = f.call('astoria_battery_saver_set', {'mode': 'system'});
      await entered.future;
      await _owner(f).setBatterySaverMode(BatterySaverMode.on);
      release.complete(false);
      final result = await pending;
      expect(result.content['code'], 'conflict');
      expect(result.content['effect'], 'none');
      expect(_settings(f).batterySaverMode, BatterySaverMode.on);
      expect(f.prefs.getString('batterySaverMode'), 'on');
      expect(f.prefs.getBool('batterySaver'), isTrue);
    },
  );

  appControlTest(
    'cancel during OS resolution cannot persist mode or resolved effect',
    (f) async {
      await _backing(f, (store) async {
        final entered = Completer<void>(), release = Completer<bool>();
        f.readPowerSaveMode = () {
          entered.complete();
          return release.future;
        };
        final pending = f.call('astoria_battery_saver_set', {'mode': 'system'});
        await entered.future;
        f.cancelToken.cancel();
        release.complete(true);
        final result = await pending;
        expect(result.content['code'], 'cancelled');
        expect(result.content['effect'], 'none');
        expect(store.writes, isEmpty);
        expect(_settings(f).batterySaverMode, BatterySaverMode.off);
        expect(_settings(f).batterySaver, isFalse);
        expect(f.prefs.getString('batterySaverMode'), 'off');
      });
    },
  );

  appControlTest(
    'battery resolved flag belongs to exact selected CAS dependency',
    (f) async {
      final entered = Completer<void>(), release = Completer<bool>();
      f.readPowerSaveMode = () {
        entered.complete();
        return release.future;
      };
      final pending = f.call('astoria_battery_saver_set', {'mode': 'system'});
      await entered.future;
      await _owner(f).save(_settings(f).copyWith(batterySaver: true));
      release.complete(true);
      final result = await pending;
      expect(result.content['code'], 'conflict');
      expect(result.content['effect'], 'none');
      expect(_settings(f).batterySaverMode, BatterySaverMode.off);
      expect(f.prefs.getString('batterySaverMode'), 'off');
      expect(f.prefs.getBool('batterySaver'), isTrue);
    },
  );

  appControlTest('ordinary system setter also preserves edits across OS wait', (
    f,
  ) async {
    final entered = Completer<void>(), release = Completer<bool>();
    f.readPowerSaveMode = () {
      entered.complete();
      return release.future;
    };
    final pending = _owner(f).setBatterySaverMode(BatterySaverMode.system);
    await entered.future;
    await _owner(
      f,
    ).save(_settings(f).copyWith(lorebookBuildPromptJs: 'SYNTHETIC_OS_JS'));
    release.complete(true);
    await pending;
    expect(_settings(f).batterySaverMode, BatterySaverMode.system);
    expect(_settings(f).batterySaver, isTrue);
    expect(_settings(f).lorebookBuildPromptJs, 'SYNTHETIC_OS_JS');
    expect(f.prefs.getString('lorebookBuildPromptJs'), 'SYNTHETIC_OS_JS');
  });

  appControlTest(
    'new ordinary battery choice retires old ordinary OS resolution',
    (f) async {
      final entered = Completer<void>(), release = Completer<bool>();
      f.readPowerSaveMode = () {
        entered.complete();
        return release.future;
      };
      final pending = _owner(f).setBatterySaverMode(BatterySaverMode.system);
      await entered.future;
      await _owner(f).setBatterySaverMode(BatterySaverMode.on);
      release.complete(false);
      await pending;
      expect(_settings(f).batterySaverMode, BatterySaverMode.on);
      expect(f.prefs.getBool('batterySaver'), isTrue);
    },
  );

  appControlTest(
    'admitted native patch settles facts after replacement and ordinary queued edit',
    (f) async {
      await _backing(f, (store) async {
        final entered = Completer<void>(), release = Completer<void>();
        store.beforeWrite = (_) async {
          store.beforeWrite = null;
          entered.complete();
          await release.future;
        };
        final pending = f.call('astoria_preferences_update', {
          'enterToSend': false,
          'hideTokenCount': true,
        });
        await entered.future;
        f.runCurrent = false;
        final ordinary = _owner(f).save(
          _settings(f).copyWith(
            lorebookBuildPrompt: 'SYNTHETIC_QUEUED_PROMPT',
            hideContextCard: true,
          ),
        );
        release.complete();
        final result = await pending;
        await ordinary;
        expect(result.content['code'], 'stale');
        expect(result.content['effect'], 'persisted');
        expect(
          result.content['data'],
          isEmpty,
        ); // Never paint a replacement run.
        expect(_settings(f).enterToSend, isFalse);
        expect(_settings(f).hideTokenCount, isTrue);
        expect(_settings(f).hideContextCard, isTrue);
        expect(_settings(f).lorebookBuildPrompt, 'SYNTHETIC_QUEUED_PROMPT');
        expect(store.values['flutter.enterToSend'], false);
        expect(store.values['flutter.hideTokenCount'], true);
        expect(
          store.values['flutter.lorebookBuildPrompt'],
          'SYNTHETIC_QUEUED_PROMPT',
        );
      });
    },
  );

  appControlTest(
    'ordinary acquisition queue preserves two concurrent ordinary deltas',
    (f) async {
      final entered = Completer<void>(), release = Completer<void>();
      f.beforeSettingsPersistence = () async {
        f.beforeSettingsPersistence = null;
        entered.complete();
        await release.future;
      };
      final before = _settings(f);
      final first = _owner(f).save(before.copyWith(hideTokenCount: true));
      await entered.future;
      final second = _owner(
        f,
      ).save(before.copyWith(lorebookBuildPrompt: 'SYNTHETIC_SECOND_PROMPT'));
      release.complete();
      await Future.wait([first, second]);
      expect(_settings(f).hideTokenCount, isTrue);
      expect(_settings(f).lorebookBuildPrompt, 'SYNTHETIC_SECOND_PROMPT');
      expect(f.prefs.getBool('hideTokenCount'), isTrue);
    },
  );

  appControlTest(
    'disjoint actual owner CAS patches merge while overlapping old expectation conflicts',
    (f) async {
      await _backing(f, (store) async {
        final entered = Completer<void>(), release = Completer<void>();
        store.beforeWrite = (_) async {
          store.beforeWrite = null;
          entered.complete();
          await release.future;
        };
        final before = _settings(f);
        final first = _owner(f).patchUiPreferences(
          expected: before,
          values: {'hideTokenCount': true},
          isCurrent: () => true,
        );
        await entered.future;
        final second = _owner(f).patchUiPreferences(
          expected: before,
          values: {'hideContextCard': true},
          isCurrent: () => true,
        );
        final overlapping = _owner(f).patchUiPreferences(
          expected: before,
          values: {'hideTokenCount': true},
          isCurrent: () => true,
        );
        release.complete();
        final results = await Future.wait([first, second, overlapping]);
        expect(results.map((result) => result.code), [
          AppSettingsPatchCode.completed,
          AppSettingsPatchCode.completed,
          AppSettingsPatchCode.conflict,
        ]);
        expect(results.last.effect, AppSettingsPatchEffect.none);
        expect(_settings(f).hideTokenCount, isTrue);
        expect(_settings(f).hideContextCard, isTrue);
        expect(store.writes, [
          'flutter.hideTokenCount',
          'flutter.hideContextCard',
        ]);
      });
    },
  );

  appControlTest(
    'write then throw reports actual cache with uncertainty and no replay',
    (f) async {
      await _backing(f, (store) async {
        store.throwAfterWrite = 'flutter.hideTokenCount';
        final result = await f.call('astoria_preferences_update', {
          'hideTokenCount': true,
          'hideContextCard': true,
        });
        expect(result.content['code'], 'storageUncertain');
        expect(result.content['effect'], 'uncertain');
        expect((result.content['data']! as Map)['hideTokenCount'], true);
        expect((result.content['data']! as Map)['hideContextCard'], false);
        expect(store.values['flutter.hideTokenCount'], true);
        expect(store.writes, ['flutter.hideTokenCount']);
        expect(_settings(f).hideTokenCount, isTrue);
        expect(_settings(f).hideContextCard, isFalse);
        expect(_settings(f).lorebookBuildPrompt, 'SYNTHETIC_PRIVATE_PROMPT');
        expect(result.content.toString(), isNot(contains('SYNTHETIC')));
        store.throwAfterWrite = null;
        final next = await f.call('astoria_preferences_update', {
          'hideContextCard': true,
        });
        expect(next.content['code'], 'completed');
        expect(store.writes, [
          'flutter.hideTokenCount',
          'flutter.hideContextCard',
        ]);
      });
    },
  );

  appControlTest('false native acknowledgement is not reported as persisted', (
    f,
  ) async {
    await _backing(f, (store) async {
      store.rejectWrite = 'flutter.enterToSend';
      final result = await f.call('astoria_preferences_update', {
        'enterToSend': false,
      });
      expect(result.content['code'], 'storageUncertain');
      expect(result.content['effect'], 'uncertain');
      expect(
        _settings(f).enterToSend,
        isFalse,
      ); // Actual cache, not claimed disk proof.
    });
  });

  appControlTest(
    'interrupted admitted write then throw retains uncertainty without replacement data',
    (f) async {
      await _backing(f, (store) async {
        final entered = Completer<void>(), release = Completer<void>();
        store.throwAfterWrite = 'flutter.enterToSend';
        store.beforeWrite = (_) async {
          entered.complete();
          await release.future;
        };
        final pending = f.call('astoria_preferences_update', {
          'enterToSend': false,
        });
        await entered.future;
        f.cancelToken.cancel();
        f.runCurrent = false;
        release.complete();
        final result = await pending;
        expect(result.content['code'], 'cancelled');
        expect(result.content['effect'], 'uncertain');
        expect(result.content['data'], isEmpty);
        expect(store.values['flutter.enterToSend'], false);
        expect(_settings(f).enterToSend, isFalse);
        expect(store.writes, ['flutter.enterToSend']);
      });
    },
  );

  appControlTest(
    'native finite patch refuses private and read-only fields atomically',
    (f) async {
      await _backing(f, (store) async {
        final before = _settings(f);
        for (final values in <Map<String, Object?>>[
          {'enterToSend': false, 'lorebookBuildPrompt': 'SYNTHETIC_FORBIDDEN'},
          {'batterySaver': true},
          {'allowMessageScripts': true},
          {'language': 'ru'},
          {'chatMaxWidth': double.nan},
        ]) {
          final result = await _owner(f).patchUiPreferences(
            expected: before,
            values: values,
            isCurrent: () => true,
          );
          expect(result.code, AppSettingsPatchCode.unavailable);
          expect(result.effect, AppSettingsPatchEffect.none);
        }
        expect(store.writes, isEmpty);
        expect(_settings(f), before);
      });
    },
  );
}
