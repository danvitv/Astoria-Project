import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:glaze_flutter/core/db/repositories/studio_preset_repo.dart';
import 'package:glaze_flutter/core/db/repositories/support_source_text_repo.dart';
import 'package:glaze_flutter/core/models/preset.dart';
import 'package:glaze_flutter/core/models/studio_config.dart';
import 'package:glaze_flutter/core/state/active_studio_preset_provider.dart';
import 'package:glaze_flutter/core/support/source_navigation.dart' as nav;
import 'package:glaze_flutter/features/support_assistant/models/support_permission_preferences.dart';

import '../helpers/support_automatic_sources_fixture.dart';
import '../support_app_backup_loop_fixture.dart';

const _id = 'PRIVATE_STUDIO_SHARED_ID';
const _label = 'Current saved Studio block validation';
const _topologyLabel = 'Current saved Studio agent topology';

Future<void> _seed(BackupLoopNative native, {bool topology = false}) async {
  await StudioPresetRepo(native.db).upsert(
    const StudioPreset(
      id: _id,
      name: 'Synthetic Studio validation target',
      blocks: [
        StudioPresetBlock(
          id: 'PRIVATE_STUDIO_BLOCK',
          content: 'PRIVATE_STUDIO_PROMPT',
          targetAgentId: 'PRIVATE_UNKNOWN_AGENT',
        ),
      ],
    ),
  );
  if (topology) {
    // Synthetic imported/corrupt roster: normal upsert correctly refuses to
    // remove Main Writer. Do not weaken that mutation guard for diagnosis.
    await native.db.customStatement(
      'UPDATE studio_preset_rows SET agents_json=? WHERE preset_id=?',
      [
        jsonEncode([
          const StudioAgent(
            id: 'PRIVATE_THINK_AGENT',
            name: 'Synthetic Think',
            role: 'system',
            controllerId: 'think',
            specId: 'think',
            reasoningMode: 'think-replacement',
          ).toJson(),
        ]),
        _id,
      ],
    );
  }
  // The ordinary namespace has exactly the same ID. It is not a Studio target.
  await native.db.customStatement(
    'INSERT INTO presets(preset_id,name,data_json) VALUES(?,?,?)',
    [
      _id,
      'Synthetic ordinary target',
      jsonEncode(
        const Preset(id: _id, name: 'Synthetic ordinary target').toJson(),
      ),
    ],
  );
}

SupportSourceNavigationRepo _reader(AutomaticSourcesFixture f) =>
    SupportSourceNavigationRepo(
      boundary: SupportSourceTextRepo(
        db: f.native.db,
        cipher: f.native.cipher,
        currentRedactor: () => f.native.redaction.redactor,
      ),
      isCurrent: () => f.native.rootCurrent,
    );

Future<nav.SourceObservation> _source(
  SupportSourceNavigationRepo reader,
  nav.SourceDomain domain,
) async => (await reader.discover(
  domain,
  null,
  null,
  const nav.WorkBound(),
)).items.singleWhere((s) => s.key.nativeId == _id);

Future<nav.Page<nav.SectionDescriptor>> _settings(
  SupportSourceNavigationRepo reader,
  nav.SourceObservation source,
) async {
  final scope = reader.approvalScope(source)!;
  final roots = await reader.contents(
    source,
    scope,
    null,
    null,
    const nav.WorkBound(),
  );
  return reader.contents(
    source,
    scope,
    roots.items
        .singleWhere((r) => r.selection.sectionId == 'settings')
        .selection,
    null,
    const nav.WorkBound(),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  test(
    'native topology observes imported Think without writer without changing saved data',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native, topology: true);
        final saved = await StudioPresetRepo(f.native.db).getById(_id);
        final reader = _reader(f);
        try {
          final source = await _source(reader, nav.SourceDomain.studioPreset);
          final fields = await _settings(reader, source);
          expect(fields.items.where((i) => i.label == _label), hasLength(1));
          final field = fields.items.singleWhere(
            (i) => i.label == _topologyLabel,
          );
          final read = await reader.read(
            source,
            reader.approvalScope(source)!,
            nav.ReadQuery(field.selection, 0, 0),
            const nav.WorkBound(),
          );
          final data = read.items.single.payload as Map<String, Object?>;
          expect(data['scope'], 'current_saved_agent_topology_only');
          expect(data['phaseEligibility'], 'think_without_main_writer');
          expect(data['selectedFinalAgentIndex'], isNull);
          expect(data['executionPerformed'], false);
          expect(data['automaticRepair'], false);
          expect(jsonEncode(data), isNot(contains('PRIVATE_')));
        } finally {
          reader.retire();
        }
        expect(await StudioPresetRepo(f.native.db).getById(_id), saved);
      });
    },
    skip: !Platform.isWindows,
  );
  test(
    'topology current-secret collision leaves the independent block validation unit',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native, topology: true);
        f.native.redaction.registerSecret('think_requires_enabled_main_writer');
        final reader = _reader(f);
        try {
          final source = await _source(reader, nav.SourceDomain.studioPreset);
          final fields = await _settings(reader, source);
          expect(fields.items.where((i) => i.label == _topologyLabel), isEmpty);
          expect(fields.items.where((i) => i.label == _label), hasLength(1));
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );
  test(
    'native Studio validation uses one complete unit and does not mutate its saved row',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        final saved = await StudioPresetRepo(f.native.db).getById(_id);
        final reader = _reader(f);
        try {
          final source = await _source(reader, nav.SourceDomain.studioPreset);
          final field = (await _settings(
            reader,
            source,
          )).items.singleWhere((i) => i.label == _label);
          final read = await reader.read(
            source,
            reader.approvalScope(source)!,
            nav.ReadQuery(field.selection, 0, 0),
            const nav.WorkBound(),
          );
          final data = read.items.single.payload as Map<String, Object?>;
          expect(data['namespace'], 'studioPreset');
          expect(data['scope'], 'current_saved_codec_block_rules_only');
          expect(data['status'], 'block_rule_errors');
          expect(
            data['issues'],
            contains(
              equals({
                'code': 'unknownTargetAgent',
                'severity': 'error',
                'blockIndex': 0,
              }),
            ),
          );
          expect(data['notChecked'], contains('historical_prompt_and_phases'));
          expect(jsonEncode(data), isNot(contains('PRIVATE_')));
        } finally {
          reader.retire();
        }
        expect(await StudioPresetRepo(f.native.db).getById(_id), saved);
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'ordinary preset with the same ID has no Studio validator result',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        final reader = _reader(f);
        try {
          final source = await _source(reader, nav.SourceDomain.ordinaryPreset);
          final search = await reader.search(
            source,
            reader.approvalScope(source)!,
            'StudioPresetValidator',
            null,
            null,
            const nav.WorkBound(),
          );
          expect(search.items, isEmpty);
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'unsupported stored shapes remain refused, not codec-reset into validity',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        await f.native.db.customStatement(
          'UPDATE studio_preset_rows SET blocks_json=? WHERE preset_id=?',
          [
            jsonEncode([
              {
                'id': 'private',
                'type': 'instruction',
                'content': 'text',
                'unsupportedField': true,
              },
            ]),
            _id,
          ],
        );
        final reader = _reader(f);
        try {
          final source = await _source(reader, nav.SourceDomain.studioPreset);
          await expectLater(
            _settings(reader, source),
            throwsA(isA<SupportSourceReadException>()),
          );
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  test(
    'new Studio facts are omitted on current redactor collision',
    () async {
      await automaticSourcesTest((f) async {
        await _seed(f.native);
        f.native.redaction.registerSecret('unknownTargetAgent');
        final reader = _reader(f);
        try {
          final source = await _source(reader, nav.SourceDomain.studioPreset);
          expect(
            (await _settings(
              reader,
              source,
            )).items.where((i) => i.label == _label),
            isEmpty,
          );
        } finally {
          reader.retire();
        }
      });
    },
    skip: !Platform.isWindows,
  );

  for (final topology in [false, true]) {
    backupLoopTest(
      topology
          ? 'native Send reads Studio topology without executing or bypassing trackers'
          : 'native Send reads actual Studio block validation before final POST',
      (tester, f) async {
        // This Studio lane alone reads these real providers, over the injected
        // original DB/tracked synthetic plugin. No active-owner override.
        f.isolation.extraAllowed.addAll({
          studioPresetProvider,
          activeStudioPresetProvider,
        });
        await backupLoopReal(tester, () async {
          await _seed(f.native, topology: topology);
          await f.container.read(activeStudioPresetProvider.future);
          await f.container.read(activeStudioPresetProvider.notifier).set(_id);
          await f.native.permissions.initializeGlobalFromNative(
            f.native.session,
            isCurrent: () => f.native.rootCurrent,
          );
          await f.native.permissions.setGrantFromNative(
            f.native.session,
            SupportPermission.readApplicationData,
            true,
            isCurrent: () => f.native.rootCurrent,
          );
          await f.native.runtime.refresh(resolve: true);
        });
        final writes = f.native.storage.writeKeys.length;
        f.replies.addAll(
          List.generate(5, (_) => AutomaticSourcesFixture.answer()),
        );
        Map<String, dynamic> result(String id) =>
            (jsonDecode(
                      ((f.wire.last['messages'] as List).lastWhere(
                            (m) =>
                                m['role'] == 'tool' && m['tool_call_id'] == id,
                          ))['content']
                          as String,
                    )
                    as Map)
                .cast<String, dynamic>();
        Map<String, dynamic> body(String id) =>
            (jsonDecode(result(id)['data']['sourceText'] as String) as Map)
                .cast<String, dynamic>();
        late String source, settings, selector;
        String? scriptFailure;
        f.onFetch = (round) async {
          try {
            f.replies[round - 1] = switch (round) {
              1 => AutomaticSourcesFixture.calls([
                ('catalog', 'astoria_sources_list', {'domain': 'studioPreset'}),
              ]),
              2 => (() {
                source =
                    (result('catalog')['data']['pieces'] as List).singleWhere(
                          (p) =>
                              p['label'] ==
                              'Synthetic Studio validation target',
                        )['source']
                        as String;
                return AutomaticSourcesFixture.calls([
                  ('roots', 'astoria_source_contents', {'source': source}),
                ]);
              })(),
              3 => (() {
                settings =
                    (body('roots')['pieces'] as List).singleWhere(
                          (p) => p['label'] == 'settings',
                        )['selector']
                        as String;
                return AutomaticSourcesFixture.calls([
                  (
                    'settings',
                    'astoria_source_contents',
                    {'source': source, 'section': settings},
                  ),
                ]);
              })(),
              4 => (() {
                selector =
                    (body('settings')['pieces'] as List).singleWhere(
                          (p) =>
                              p['label'] ==
                              (topology ? _topologyLabel : _label),
                        )['selector']
                        as String;
                return AutomaticSourcesFixture.calls([
                  (
                    'validation',
                    'astoria_source_read',
                    {'source': source, 'selector': selector},
                  ),
                ]);
              })(),
              5 => (() {
                final evidence = jsonEncode(body('validation'));
                if (topology) {
                  expect(
                    evidence,
                    contains('StudioActivationGate.splitAgentsByPhase'),
                  );
                  expect(
                    evidence,
                    contains('think_requires_enabled_main_writer'),
                  );
                  expect(
                    evidence,
                    contains('current_saved_agent_topology_only'),
                  );
                  expect(
                    evidence,
                    contains('enabled_tracker_failure_blocks_final_writer'),
                  );
                } else {
                  expect(evidence, contains('StudioPresetValidator'));
                  expect(evidence, contains('unknownTargetAgent'));
                  expect(
                    evidence,
                    contains('current_saved_codec_block_rules_only'),
                  );
                }
                expect(evidence, contains('historical_prompt_and_phases'));
                expect(evidence, isNot(contains('PRIVATE_')));
                return AutomaticSourcesFixture.answer();
              })(),
              _ => throw TestFailure('Unexpected extra POST'),
            };
          } catch (e) {
            scriptFailure = 'round=$round ${e.runtimeType}';
            rethrow;
          }
        };
        await f.start(
          tester,
          picker: false,
          text: 'Проверь ошибки Studio-пресета.',
        );
        final finished = await f.finish(tester);
        expect(scriptFailure, isNull);
        expect(finished.status, 'complete');
        expect(f.wire, hasLength(5));
        expect(f.native.storage.writeKeys.length, writes);
        final outward = jsonEncode(f.wire);
        expect(outward, contains('studio_diagnostics'));
        expect(outward, isNot(contains('PRIVATE_')));
        f.noEgress();
      },
    );
  }
}
