import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/global_variables_repo.dart';
import 'package:glaze_flutter/core/models/pipeline_settings.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_regex.dart';
import 'package:glaze_flutter/core/preferences/saved_preferences_read_port.dart';
import 'package:glaze_flutter/core/services/backup/service_prefs_writer.dart';
import 'package:glaze_flutter/core/services/preset_seeder.dart';
import 'package:glaze_flutter/core/state/active_selection_provider.dart';
import 'package:glaze_flutter/core/state/memory_settings_provider.dart';
import 'package:glaze_flutter/core/state/pipeline_settings_provider.dart';
import 'package:glaze_flutter/core/state/shared_prefs_provider.dart';
import 'package:glaze_flutter/core/state/studio_regex_provider.dart';
import 'package:glaze_flutter/shared/theme/theme_preset_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';
// Existing test-only backing-store seam, genuine legacy cache and setters.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

final class _Backing extends SharedPreferencesStorePlatform {
  _Backing(Map<String, Object> initial)
    : values = {for (final e in initial.entries) 'flutter.${e.key}': e.value};
  final Map<String, Object> values;
  final writes = <String>[];
  Future<void> Function(String)? beforeWrite;
  Future<void> Function()? afterReadCaptured;
  String? rejected, thrown;
  @override
  Future<Map<String, Object>> getAll() async {
    final captured = Map<String, Object>.of(values);
    await afterReadCaptured?.call();
    return captured;
  }

  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    await beforeWrite?.call(key);
    if (key == rejected) return false;
    if (key == thrown) throw StateError('SYNTHETIC_NATIVE_PREFERENCES_FAILURE');
    values[key] = value;
    return true;
  }

  @override
  Future<bool> remove(String key) async {
    writes.add(key);
    values.remove(key);
    return true;
  }

  @override
  Future<bool> clear() async {
    writes.add('*');
    values.clear();
    return true;
  }
}

Future<void> _backed(
  Future<void> Function(SharedPreferences, _Backing) body, {
  Map<String, Object> initial = const {
    'memorySettings': '{}',
    'glaze.global_variables': '{}',
  },
}) async {
  SharedPreferences.setMockInitialValues(initial);
  final previous = SharedPreferencesStorePlatform.instance;
  final backing = _Backing(initial);
  SharedPreferencesStorePlatform.instance = backing;
  try {
    await body(await TrackedSharedPreferences.getInstance(), backing);
  } finally {
    SharedPreferencesStorePlatform.instance = previous;
  }
}

SavedPreferencesReadPort _port(
  SharedPreferences prefs, {
  bool Function()? alive,
}) => SavedPreferencesReadPort(
  original: Future.value(prefs),
  loaded: prefs,
  producerCurrent: alive ?? () => true,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final rawThemeReload in [false, true]) {
    test(
      'pre-existing setter cannot be certified by ${rawThemeReload ? 'raw theme' : 'tracked'} reload',
      () async {
        await _backed((prefs, backing) async {
          final entered = Completer<void>(), release = Completer<void>();
          backing.beforeWrite = (key) async {
            if (key == 'flutter.memorySettings') {
              entered.complete();
              await release.future;
            }
          };
          final port = _port(prefs);
          final write = prefs.setString('memorySettings', '{"enabled":false}');
          await entered.future;
          try {
            if (rawThemeReload) {
              await ThemePresetStorage(
                (prefs as TrackedSharedPreferences).delegate,
              ).readSelectionFresh();
            } else {
              await prefs.reload();
            }
            expect(prefs.getString('memorySettings'), '{}');
            expect(backing.values['flutter.memorySettings'], '{}');
          } finally {
            release.complete();
          }
          expect(await write, true);
          expect(backing.values['flutter.memorySettings'], '{"enabled":false}');
          expect(prefs.getString('memorySettings'), '{}');
          final fresh = port.capture('savedMemoryPreferences');
          expect(port.isCurrent(fresh), false);
          await expectLater(
            port.read('savedMemoryPreferences', fresh),
            throwsA(isA<SavedPreferencesUnavailable>()),
          );
          expect(port.capture('savedPipelinePreferences').current, true);
        });
      },
    );
    test(
      'overlapping ${rawThemeReload ? 'raw theme' : 'tracked'} reload cannot certify stale saved cache',
      () async {
        await _backed((prefs, backing) async {
          final captured = Completer<void>(), release = Completer<void>();
          backing.afterReadCaptured = () async {
            captured.complete();
            await release.future;
          };
          final port = _port(prefs);
          final original = port.capture('savedMemoryPreferences');
          final reload = rawThemeReload
              ? ThemePresetStorage(
                  (prefs as TrackedSharedPreferences).delegate,
                ).readSelectionFresh()
              : prefs.reload();
          await captured.future;
          expect(port.isCurrent(original), false);
          expect(
            await prefs.setString('memorySettings', '{"enabled":false}'),
            true,
          );
          release.complete();
          await reload;
          expect(backing.values['flutter.memorySettings'], '{"enabled":false}');
          expect(prefs.getString('memorySettings'), '{}');
          final fresh = port.capture('savedMemoryPreferences');
          expect(port.isCurrent(fresh), false);
          await expectLater(
            port.read('savedMemoryPreferences', fresh),
            throwsA(isA<SavedPreferencesUnavailable>()),
          );
          // The reload's own revision does not quarantine unrelated saved keys.
          expect(port.capture('savedPipelinePreferences').current, true);
        });
      },
    );
  }
  test(
    'original cached future cannot adopt replacement store after await; raw producer is explicitly untrusted',
    () async {
      await _backed((prefs, backing) async {
        final retained = Completer<SharedPreferences>();
        var calls = 0;
        final original = Future<SharedPreferences>.sync(() async {
          calls++;
          return retained.future;
        });
        final port = SavedPreferencesReadPort(
          original: original,
          producerCurrent: () => true,
        );
        final lease = port.capture('savedMemoryPreferences');
        final pending = port.read('savedMemoryPreferences', lease);
        SharedPreferences.setMockInitialValues({
          'memorySettings': '{"enabled":false}',
        });
        final replacement = await TrackedSharedPreferences.getInstance();
        retained.complete(replacement);
        await expectLater(pending, throwsA(isA<SavedPreferencesUnavailable>()));
        expect(calls, 1);
        expect(port.isCurrent(lease), false);
        final raw = (replacement as TrackedSharedPreferences).delegate;
        final rawPort = SavedPreferencesReadPort(
          original: Future.value(raw),
          loaded: raw,
          producerCurrent: () => true,
        );
        await expectLater(
          rawPort.read(
            'savedMemoryPreferences',
            rawPort.capture('savedMemoryPreferences'),
          ),
          throwsA(isA<SavedPreferencesUnavailable>()),
        );
        expect(
          _port(replacement).capture('savedMemoryPreferences').current,
          true,
        );
        // Retired A retains its old writer behavior, but cannot prove B's cache.
        await prefs.setString('memorySettings', '{"enabled":true}');
        expect(
          _port(replacement).capture('savedMemoryPreferences').current,
          false,
        );
      });
    },
  );
  test(
    'cold saved read acquires original future once; missing/wrong saved values without setter/default hydration',
    () async {
      await _backed((prefs, store) async {
        var loaded = 0;
        final producer = Future<SharedPreferences>.sync(() {
          loaded++;
          return prefs;
        });
        final port = SavedPreferencesReadPort(
          original: producer,
          producerCurrent: () => true,
        );
        final lease = port.capture('savedMemoryPreferences');
        expect(await port.read('savedMemoryPreferences', lease), {
          'memorySettings': 'not-json',
        });
        expect(
          await port.read(
            'savedRegexPreferences',
            port.capture('savedRegexPreferences'),
          ),
          {'gz_global_regex_scripts': null, 'gz_studio_regex_scripts': null},
        );
        expect(loaded, 1);
        expect(store.writes, isEmpty);
      }, initial: {'memorySettings': 'not-json'});
    },
  );

  test(
    'genuine facade A -> B -> A is terminal; unrelated keys are not falsely fenced',
    () async {
      await _backed((prefs, store) async {
        final port = _port(prefs),
            original = _port(prefs).capture('savedMemoryPreferences');
        await prefs.setString('unrelated_settings_key', 'harmless');
        expect(port.isCurrent(original), true);
        await prefs.setString('memorySettings', '{"enabled":false}');
        await prefs.setString('memorySettings', '{}');
        expect(prefs.getString('memorySettings'), '{}');
        expect(port.isCurrent(original), false);
        expect(port.isCurrent(original), false);
        expect(
          await port.read(
            'savedMemoryPreferences',
            port.capture('savedMemoryPreferences'),
          ),
          {'memorySettings': '{}'},
        );
      });
    },
  );

  for (final throws in [false, true]) {
    test(
      'actual ${throws ? 'throw' : 'false'} acknowledgement settles but optimistic cache is never saved evidence',
      () async {
        await _backed((prefs, store) async {
          final port = _port(prefs),
              old = _port(prefs).capture('savedMemoryPreferences');
          if (throws) {
            store.thrown = 'flutter.memorySettings';
          } else {
            store.rejected = 'flutter.memorySettings';
          }
          final write = prefs.setString('memorySettings', '{"enabled":false}');
          if (throws) {
            await expectLater(write, throwsStateError);
          } else {
            expect(await write, false);
          }
          expect(store.values['flutter.memorySettings'], '{}');
          expect(prefs.getString('memorySettings'), '{"enabled":false}');
          expect(port.isCurrent(old), false);
          await expectLater(
            port.read(
              'savedMemoryPreferences',
              port.capture('savedMemoryPreferences'),
            ),
            throwsA(isA<SavedPreferencesUnavailable>()),
          );
          final unrelated = SavedPreferencesOwner.process.capture([
            'globalVars',
          ]);
          expect(unrelated.current, true);
        });
      },
    );
  }

  test(
    'queued variable repo intents precede then admission; second container and repo keep actual old pending owner',
    () async {
      await _backed((prefs, store) async {
        final first = GlobalVariablesRepo.withPrefsLoader(
          () => Future.value(prefs),
        );
        final second = GlobalVariablesRepo.withPrefsLoader(
          () => Future.value(prefs),
        );
        final entered = Completer<void>(), release = Completer<void>();
        store.beforeWrite = (key) async {
          if (key == 'flutter.glaze.global_variables' && !entered.isCompleted) {
            entered.complete();
            await release.future;
          }
        };
        final port = _port(prefs),
            old = _port(prefs).capture('savedGlobalVariables');
        final a = first.update((root) => {...root, 'first': true});
        expect(port.isCurrent(old), false); // before queued task begins
        await entered.future;
        final b = first.replaceAll({'queued': true});
        final container = ProviderContainer();
        try {
          final attachment = await container.read(
            sharedPreferencesProvider.future,
          );
          expect(
            (attachment as TrackedSharedPreferences).store,
            same((prefs as TrackedSharedPreferences).store),
          );
          final newPort = _port(attachment);
          await expectLater(
            newPort.read(
              'savedGlobalVariables',
              newPort.capture('savedGlobalVariables'),
            ),
            throwsA(isA<SavedPreferencesUnavailable>()),
          );
          final c = second.replaceAll({'secondRepo': true});
          expect(_port(prefs).capture('savedGlobalVariables').current, false);
          release.complete();
          await Future.wait([a, b, c]);
          expect(port.isCurrent(old), false);
          expect(
            (await port.read(
              'savedGlobalVariables',
              port.capture('savedGlobalVariables'),
            ))['glaze.global_variables'],
            isA<String>(),
          );
        } finally {
          if (!release.isCompleted) release.complete();
          await Future.wait([a, b]);
          container.dispose();
        }
      });
    },
  );

  test(
    'rejected oversized queued variable payload finally settles and never calls actual setter',
    () async {
      await _backed((prefs, store) async {
        final repo = GlobalVariablesRepo.withPrefsLoader(
          () => Future.value(prefs),
        );
        final port = _port(prefs),
            old = _port(prefs).capture('savedGlobalVariables');
        final write = repo.replaceAll({'oversized': 'x' * 70000});
        expect(port.isCurrent(old), false);
        await expectLater(write, throwsArgumentError);
        expect(store.writes, isEmpty);
        expect(port.capture('savedGlobalVariables').current, true);
        expect(port.isCurrent(old), false);
      });
    },
  );

  test(
    'actual Memory/pipeline notifier intents precede optimistic state publication and provider acquisition await',
    () async {
      await _backed((prefs, store) async {
        final delayed = Completer<SharedPreferences>();
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) => delayed.future),
          ],
        );
        try {
          final memoryPort = _port(prefs),
              memory = memoryPort.capture('savedMemoryPreferences');
          final pipelinePort = _port(prefs),
              pipeline = pipelinePort.capture('savedPipelinePreferences');
          final a = container
              .read(memoryGlobalSettingsProvider.notifier)
              .save(const MemoryGlobalSettings(enabled: false));
          final b = container
              .read(pipelineSettingsProvider.notifier)
              .save(const PipelineSettings());
          expect(memoryPort.isCurrent(memory), false);
          expect(pipelinePort.isCurrent(pipeline), false);
          expect(container.read(memoryGlobalSettingsProvider).enabled, false);
          expect(store.writes, isEmpty);
          delayed.complete(prefs);
          await Future.wait([a, b]);
          expect(
            store.writes,
            containsAll(['flutter.memorySettings', 'flutter.pipelineSettings']),
          );
          expect(memoryPort.isCurrent(memory), false);
        } finally {
          if (!delayed.isCompleted) delayed.complete(prefs);
          container.dispose();
        }
      });
    },
  );

  test(
    'direct Memory import + first-run seeder + Studio regex bulk + Ref variable writer retire their own finite families',
    () async {
      await _backed((prefs, store) async {
        final port = _port(prefs),
            memory = _port(prefs).capture('savedMemoryPreferences');
        final imported = writeMemoryBooksPrefs({
          'endpoint': 'https://example.invalid',
          'apiKey': 'PRIVATE',
        }, false);
        expect(port.isCurrent(memory), false);
        await imported;
        final selected = port.capture('savedSelectionPreferences');
        final seeded = applyFirstRunPresetChoice(preferences: prefs);
        expect(port.isCurrent(selected), false);
        await seeded;
        final container = ProviderContainer(
          overrides: [
            sharedPreferencesProvider.overrideWith((ref) async => prefs),
          ],
        );
        try {
          await container.read(studioRegexProvider.future);
          final regex = port.capture('savedRegexPreferences');
          final bulk = container
              .read(studioRegexProvider.notifier)
              .addRegexes(const [
                StudioRegex(
                  script: PresetRegex(id: 'a', name: 'A', regex: 'a'),
                ),
                StudioRegex(
                  script: PresetRegex(id: 'b', name: 'B', regex: 'b'),
                ),
              ]);
          expect(port.isCurrent(regex), false);
          await bulk;
          expect(
            jsonDecode(prefs.getString('gz_studio_regex_scripts')!) as List,
            hasLength(2),
          );
          late Ref originalRef;
          container.read(
            Provider<void>((ref) {
              originalRef = ref;
            }),
          );
          final vars = port.capture('savedGlobalVariables');
          updateGlobalVarsRef(originalRef, {'authored': 'saved'});
          expect(port.isCurrent(vars), false);
          // Keep the real setter future joined through the native backing hook.
          await Future<void>.delayed(Duration.zero);
          expect(prefs.getString('globalVars'), '{"authored":"saved"}');
        } finally {
          container.dispose();
        }
      });
    },
  );

  test(
    'retired original future/producer and actual preferences store replacement never rebind or revive old lease',
    () async {
      await _backed((prefs, store) async {
        var alive = true;
        final held = Completer<SharedPreferences>();
        final port = SavedPreferencesReadPort(
          original: held.future,
          producerCurrent: () => alive,
        );
        final lease = port.capture('savedMemoryPreferences');
        final pending = port.read('savedMemoryPreferences', lease);
        alive = false;
        held.complete(prefs);
        await expectLater(pending, throwsA(isA<SavedPreferencesUnavailable>()));
        alive = true;
        expect(port.isCurrent(lease), false);
        final oldPort = _port(prefs),
            old = _port(prefs).capture('savedMemoryPreferences');
        SharedPreferences.setMockInitialValues({'memorySettings': '{}'});
        final replacement = await TrackedSharedPreferences.getInstance();
        expect(oldPort.isCurrent(old), false);
        expect((prefs as TrackedSharedPreferences).store.current, false);
        expect(
          _port(replacement).capture('savedMemoryPreferences').current,
          true,
        );
        // Re-wrapping A after B cannot manufacture A's stability.
        TrackedSharedPreferences.wrap(prefs);
        expect(oldPort.isCurrent(old), false);
      });
    },
  );
}
