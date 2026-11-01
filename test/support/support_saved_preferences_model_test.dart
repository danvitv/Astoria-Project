import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/services/backup/service_prefs_writer.dart';
// Existing genuine preferences backing-store setter seam, no plugin replacement class.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'support_saved_preferences_fixture.dart';

final class _ReadOnlyBacking extends SharedPreferencesStorePlatform {
  _ReadOnlyBacking(Map<String, Object> initial)
    : values = {for (final e in initial.entries) 'flutter.${e.key}': e.value};
  final Map<String, Object> values;
  final writes = <String>[];
  @override
  Future<Map<String, Object>> getAll() async => Map.of(values);
  @override
  Future<bool> setValue(String type, String key, Object value) async {
    writes.add(key);
    throw TestFailure('Assistant read invoked actual preferences setter');
  }

  @override
  Future<bool> remove(String key) async {
    writes.add(key);
    throw TestFailure('Assistant read removed preferences');
  }

  @override
  Future<bool> clear() async {
    writes.add('*');
    throw TestFailure('Assistant read cleared preferences');
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  for (final saved in [
    <String, Object>{},
    <String, Object>{'memorySettings': '{"customPrompts":[null]}'},
  ]) {
    test(
      'actual cold/malformed saved read uses pure codec and zero native setters (${saved.isEmpty ? 'missing' : 'malformed'})',
      () async {
        final previous = SharedPreferencesStorePlatform.instance;
        final spy = _ReadOnlyBacking(saved);
        try {
          await savedPreferencesModelTest(
            (f, prefs) async {
              String? source;
              final expected = saved.isEmpty ? 'missing' : 'malformed';
              f.script = (round) {
                if (round == 1)
                  return AutomaticSourcesFixture.calls([
                    (
                      'list',
                      'astoria_sources_list',
                      {'domain': 'applicationData'},
                    ),
                  ]);
                if (round == 2) {
                  source =
                      (f.result('list')['data']['pieces'] as List)
                              .last['source']
                          as String;
                  return AutomaticSourcesFixture.calls([
                    ('contents', 'astoria_source_contents', {'source': source}),
                  ]);
                }
                if (round == 3)
                  return AutomaticSourcesFixture.calls([
                    (
                      'search',
                      'astoria_source_search',
                      {'source': source, 'literal': expected},
                    ),
                  ]);
                if (round == 4) {
                  expect(f.body('search')['pieces'], isNotEmpty);
                  return AutomaticSourcesFixture.calls([
                    (
                      'read',
                      'astoria_source_read',
                      {
                        'source': source,
                        'selector': (f.body('search')['pieces'] as List)
                            .first['selector'],
                      },
                    ),
                  ]);
                }
                expect(round, 5);
                expect(jsonEncode(f.body('read')), contains(expected));
                expect(spy.writes, isEmpty);
                return AutomaticSourcesFixture.answer();
              };
              final result = await (await f.start()).finished.timeout(
                const Duration(seconds: 25),
              );
              expect(result.message?.status, 'complete');
              expect(spy.writes, isEmpty);
            },
            saved: saved,
            onPreferencesStoreInitialized: () =>
                SharedPreferencesStorePlatform.instance = spy,
          );
        } finally {
          SharedPreferencesStorePlatform.instance = previous;
        }
      },
      skip: !Platform.isWindows,
    );
  }

  test(
    'pipeline finite numeric parameters survive, disabled credential containers and JSON-string headers do not',
    () async {
      await savedPreferencesModelTest((f, prefs) async {
        String? source;
        f.script = (round) {
          if (round == 1)
            return AutomaticSourcesFixture.calls([
              ('list', 'astoria_sources_list', {'domain': 'applicationData'}),
            ]);
          if (round == 2)
            return AutomaticSourcesFixture.calls([
              (
                'next',
                'astoria_sources_list',
                {
                  'domain': 'applicationData',
                  'cursor': f.result('list')['data']['nextCursor'],
                },
              ),
            ]);
          if (round == 3) {
            source =
                (f.result('next')['data']['pieces'] as List).first['source']
                    as String;
            return AutomaticSourcesFixture.calls([
              (
                'numeric',
                'astoria_source_search',
                {'source': source, 'literal': '0.42'},
              ),
            ]);
          }
          expect(round, 4);
          expect(
            f.result('numeric')['data']['sourceText'],
            isA<String>(),
            reason: jsonEncode(f.result('numeric')),
          );
          expect(jsonEncode(f.body('numeric')), contains('0.42'));
          noPreferencesSecrets(f);
          return AutomaticSourcesFixture.answer();
        };
        final result = await (await f.start()).finished.timeout(
          const Duration(seconds: 25),
        );
        expect(result.message?.status, 'complete');
        expect(f.wire, hasLength(4));
      });
    },
    skip: !Platform.isWindows,
  );
  test(
    'actual FILE Send: each of five saved families has a fresh bounded catalog -> contents/search/issued read; encrypted BEFORE every POST',
    () async {
      // Every original run retains the unchanged 64-repository-operation budget.
      // Exercise all families without combining fourteen body disclosures into
      // one artificial request that cannot fit that production budget.
      for (final family in preferenceNeedles.keys) {
        await savedPreferencesModelTest((f, prefs) async {
          final before = {
            for (final key in prefs.getKeys()) key: prefs.get(key),
          };
          final sources = <String, String>{};
          void catalog(String call) {
            final pieces = f.result(call)['data']['pieces'] as List;
            for (final piece in pieces) {
              final label = piece['label'] as String;
              final family = switch (label) {
                'Saved global Memory preferences and prompts' =>
                  'savedMemoryPreferences',
                'Saved global pipeline settings' => 'savedPipelinePreferences',
                'Saved global and Studio regex scripts (inert)' =>
                  'savedRegexPreferences',
                'Saved global selections and bindings' =>
                  'savedSelectionPreferences',
                'Saved legacy and extension global variables' =>
                  'savedGlobalVariables',
                _ => null,
              };
              if (family != null) sources[family] = piece['source'] as String;
            }
          }

          f.script = (round) async {
            if (round == 1)
              return AutomaticSourcesFixture.calls([
                (
                  'prefs-catalog-first',
                  'astoria_sources_list',
                  {'domain': 'applicationData'},
                ),
              ]);
            if (round == 2) {
              await preferencesEncryptedBeforePost(f, 1);
              catalog('prefs-catalog-first');
              expect(
                f.result('prefs-catalog-first')['data']['nextCursor'],
                isNotNull,
              );
              return AutomaticSourcesFixture.calls([
                (
                  'prefs-catalog-next',
                  'astoria_sources_list',
                  {
                    'domain': 'applicationData',
                    'cursor': f.result(
                      'prefs-catalog-first',
                    )['data']['nextCursor'],
                  },
                ),
              ]);
            }
            if (round == 3) {
              await preferencesEncryptedBeforePost(f, 2);
              catalog('prefs-catalog-next');
              expect(sources.keys.toSet(), preferenceNeedles.keys.toSet());
              expect(
                jsonEncode(f.wire),
                isNot(contains('memory preference needle')),
              );
              return AutomaticSourcesFixture.calls([
                (
                  'contents-$family',
                  'astoria_source_contents',
                  {'source': sources[family]},
                ),
              ]);
            }
            if (round == 4) {
              await preferencesEncryptedBeforePost(f, 3);
              expect(f.body('contents-$family')['pieces'], isNotEmpty);
              return AutomaticSourcesFixture.calls([
                (
                  'search-$family',
                  'astoria_source_search',
                  {
                    'source': sources[family],
                    'literal': preferenceNeedles[family],
                  },
                ),
              ]);
            }
            if (round == 5) {
              await preferencesEncryptedBeforePost(f, 4);
              noPreferencesSecrets(f);
              return AutomaticSourcesFixture.calls([
                (
                  'read-$family',
                  'astoria_source_read',
                  {
                    'source': sources[family],
                    'selector': (f.body('search-$family')['pieces'] as List)
                        .first['selector'],
                  },
                ),
              ]);
            }
            expect(round, 6);
            await preferencesEncryptedBeforePost(f, 5);
            expect(
              jsonEncode(f.body('read-$family')),
              contains(preferenceNeedles[family]!),
            );
            noPreferencesSecrets(f);
            return AutomaticSourcesFixture.answer();
          };
          final result = await (await f.start()).finished.timeout(
            const Duration(seconds: 40),
          );
          expect(
            result.message?.status,
            'complete',
            reason:
                '${result.reason}: ${f.activity.map((a) => a.detail).join(' | ')}',
          );
          expect(f.wire, hasLength(6));
          expect({
            for (final key in prefs.getKeys()) key: prefs.get(key),
          }, before);
        });
      }
    },
    skip: !Platform.isWindows,
  );

  test(
    'Memory direct import intent after encrypted discovery retires old cursor and forbids next POST',
    () async {
      await savedPreferencesModelTest((f, prefs) async {
        String? cursor;
        var started = false;
        Future<void>? write;
        f.onActivity = (a) {
          if (!started &&
              a.detail ==
                  'Зашифрованное происхождение и исходный контекст подтверждены до передачи') {
            started = true;
            write = writeMemoryBooksPrefs({'apiKey': 'PRIVATE_NEW_KEY'}, false);
          }
        };
        f.script = (round) {
          if (round == 1)
            return AutomaticSourcesFixture.calls([
              ('list', 'astoria_sources_list', {'domain': 'applicationData'}),
            ]);
          if (round == 2) {
            cursor = f.result('list')['data']['nextCursor'] as String;
            final source =
                (f.result('list')['data']['pieces'] as List).last['source'];
            return AutomaticSourcesFixture.calls([
              ('contents', 'astoria_source_contents', {'source': source}),
            ]);
          }
          throw TestFailure('Stale preferences payload reached a real POST');
        };
        final result = await (await f.start()).finished.timeout(
          const Duration(seconds: 25),
        );
        await write;
        expect(started, true);
        expect(cursor, isNotNull);
        expect(f.wire, hasLength(2));
        expect(result.message?.status, isNot('complete'));
        noPreferencesSecrets(f);
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'original preferences producer retirement refuses old payload without replacement lookup',
    () async {
      var alive = true;
      await savedPreferencesModelTest((f, prefs) async {
        f.script = (round) {
          if (round == 1)
            return AutomaticSourcesFixture.calls([
              ('list', 'astoria_sources_list', {'domain': 'applicationData'}),
            ]);
          expect(round, 2);
          alive = false;
          return AutomaticSourcesFixture.calls([
            (
              'old-contents',
              'astoria_source_contents',
              {
                'source':
                    (f.result('list')['data']['pieces'] as List).last['source'],
              },
            ),
          ]);
        };
        final result = await (await f.start()).finished.timeout(
          const Duration(seconds: 25),
        );
        expect(f.wire, hasLength(2));
        expect(result.message?.status, isNot('complete'));
        noPreferencesSecrets(f);
      }, producerCurrent: () => alive);
    },
    skip: !Platform.isWindows,
  );
}
