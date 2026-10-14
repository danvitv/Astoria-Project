import 'dart:convert';
import 'dart:io';
import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/services/backup/backup_secret_urls.dart';
import 'package:glaze_flutter/core/services/backup/backup_secrets.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

const same = 'https://same.test/v1/chat/completions';
const changed = 'https://changed.test/v1/chat/completions';
Map<String, Object?> param(String value) => {
  'key': 'authentication',
  'value': value,
};
String runtime(String value) => jsonEncode({
  'cleaner': {
    'postCleanerExtraRequestParameters': [
      param(value),
      {'key': 'max_tokens', 'value': '55'},
    ],
  },
  'agentBlockRestoreState': {'password': 'story-password'},
});

void main() {
  test('malformed URI query components cannot defeat credential stripping', () {
    for (final raw in [
      'https://u:p@example.test/v1?%FF=x&key=live',
      'https://u:p@example.test/v1?%FF=%FE&%6bey=live&key=second',
      'https://u:p@example.test/v1?key=%FF&size=5',
    ]) {
      final safe = BackupSecretUrls.strip(raw, BackupSecrets.isSecretField);
      expect(safe, isNot(contains('u:p')));
      expect(safe, isNot(contains('live')));
      expect(safe, isNot(contains('second')));
      expect(
        BackupSecretUrls.refill(safe, raw, BackupSecrets.isSecretField),
        safe,
      );
    }
  });

  test('arbitrary preferences and inert live-container text stay verbatim', () {
    final content = jsonEncode({
      'token': 'story-token',
      'password': 'story-pass',
      'secret': 'story-secret',
      'apiKey': 'story-key',
    });
    final input = {
      'globalVars': content,
      'glaze.global_variables': content,
      'customPrompt': content,
      'password': 'ordinary preference',
      'pipelineSettings': jsonEncode({
        'cleaner': {'postCleanerStyleInstructions': content},
        'studioAgent': {'arbitraryStory': jsonDecode(content)},
      }),
      'gz_imggen_settings': jsonEncode({
        'references': [
          {'description': content},
        ],
        'refInstruction': content,
      }),
    };
    expect(BackupSecrets.stripPrefs(input), input);
    for (final key in input.keys) {
      expect(
        BackupSecrets.refillPref(
          input[key],
          '{"password":"wrong-local"}',
          key: key,
        ),
        input[key],
      );
    }
  });

  test(
    'legacy embedding_key aliases strip and require independent matching route',
    () {
      for (final alias in [
        'gz_api_connection_presets',
        'sc_api_connection_presets',
        'silly_cradle_api_presets',
        'api_connection_presets',
      ]) {
        final source = jsonEncode([
          {
            'id': 'a',
            'key': 'source-key',
            'embedding_key': 'source-embed',
            'endpoint': same,
            'embedding_endpoint': 'https://embed.test/v1/embeddings',
          },
        ]);
        final safe = BackupSecrets.stripPrefs({alias: source})[alias] as String;
        expect(safe, isNot(contains('source-')));
        final local = source.replaceAll('source-', 'local-');
        expect(
          BackupSecrets.refillPref(safe, local, key: alias),
          contains('local-embed'),
        );
        final rerouted = local.replaceFirst('embed.test', 'wrong.test');
        expect(
          BackupSecrets.refillPref(safe, rerouted, key: alias),
          isNot(contains('local-embed')),
        );
      }
      expect(
        BackupSecrets.stripPrefs({'globalVars': '{"embedding_key":"story"}'}),
        {'globalVars': '{"embedding_key":"story"}'},
      );
    },
  );

  group('actual ZIP route ownership', () {
    late AppDatabase db;
    late Directory temp;
    late ImageStorageService images;
    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'activeApiConfigId': 'same',
        'gz_imggen_endpoint': changed,
        'gz_embedding_endpoint': changed,
        'api-endpoint': changed,
        'globalVars': '{"password":"story"}',
        'pipelineSettings': jsonEncode({
          'cleaner': {
            'postCleanerExtraRequestParameters': [param('source-global')],
          },
          'studioAgent': {
            'studioFinalExtraRequestParameters': [param('source-final')],
            'studioControllerExtraRequestParameters': [
              param('source-controller'),
            ],
          },
        }),
      });
      db = AppDatabase.forTesting(NativeDatabase.memory());
      temp = await Directory(
        '${Platform.environment['LOCALAPPDATA']}/Temp/opencode',
      ).createTemp('astoria_gate1_backup_');
      images = ImageStorageService(temp.path);
    });
    tearDown(() async {
      await db.close();
      await temp.delete(recursive: true);
    });

    Future<void> api(
      String id,
      String endpoint, {
      String embed = '',
      bool useSame = false,
      String mode = 'chat',
      String pinned = '',
      String key = 'source',
    }) async {
      await db
          .into(db.apiConfigs)
          .insert(
            ApiConfigsCompanion.insert(
              configId: id,
              name: id,
              endpoint: Value(endpoint),
              apiKey: Value('$key-key'),
              embeddingApiKey: Value('$key-embed'),
              embeddingEndpoint: Value(embed),
              embeddingUseSame: Value(useSame),
              mode: Value(mode),
              embeddingLlmPresetId: Value(pinned),
              extraRequestParametersJson: Value(
                jsonEncode([param('$key-param')]),
              ),
            ),
          );
    }

    Future<void> studio(String id, String slot, String secret) async {
      await db
          .into(db.studioPresetRows)
          .insert(
            StudioPresetRowsCompanion.insert(
              presetId: id,
              name: id,
              cleanerApiConfigId: Value(slot),
              runtimeSettingsJson: Value(runtime(secret)),
            ),
          );
    }

    test(
      'API lanes, Studio slots/fallback and separate legacy pairs refuse rerouting',
      () async {
        await api('same', same, embed: 'https://embed.test/v1/embeddings');
        await api(
          'rerouted',
          changed,
          embed: 'https://other-embed.test/v1/embeddings',
        );
        await api(
          'embed-changed',
          same,
          embed: 'https://other-embed.test/v1/embeddings',
        );
        await api('unknown', '');
        await api(
          'borrow',
          '',
          useSame: true,
          mode: 'embedding',
          pinned: 'rerouted',
        );
        for (final pair in {
          'same-preset': 'same',
          'changed-preset': 'rerouted',
          'fallback': '',
          'unknown-preset': 'missing',
        }.entries) {
          await studio(pair.key, pair.value, 'source-studio');
        }
        final file = await BackupExporter(db, images).buildArchive(temp);
        await db.delete(db.apiConfigs).go();
        await db.delete(db.studioPresetRows).go();
        for (final id in ['same', 'rerouted', 'embed-changed']) {
          await api(
            id,
            same,
            embed: 'https://embed.test/v1/embeddings',
            key: 'local',
          );
        }
        await api('unknown', '', key: 'local');
        await api(
          'borrow',
          '',
          useSame: true,
          mode: 'embedding',
          pinned: 'same',
          key: 'local',
        );
        for (final pair in {
          'same-preset': 'same',
          'changed-preset': 'same',
          'fallback': '',
          'unknown-preset': 'missing',
        }.entries) {
          await studio(pair.key, pair.value, 'local-studio');
        }
        SharedPreferences.setMockInitialValues({
          'activeApiConfigId': 'same',
          'gz_imggen_endpoint': same,
          'gz_imggen_api_key': 'local-image',
          'gz_embedding_endpoint': same,
          'gz_embedding_key': 'local-embedding',
          'api-endpoint': same,
          'api-key': 'local-legacy',
          'pipelineSettings': jsonEncode({
            'cleaner': {
              'postCleanerExtraRequestParameters': [param('local-global')],
            },
            'studioAgent': {
              'studioFinalExtraRequestParameters': [param('local-final')],
              'studioControllerExtraRequestParameters': [
                param('local-controller'),
              ],
            },
          }),
        });
        await FlutterBackupImporter(db, images).importFromZipFile(file.path);
        final rows = {
          for (final row in await db.select(db.apiConfigs).get())
            row.configId: row,
        };
        expect(rows['same']!.apiKey, 'local-key');
        expect(rows['same']!.embeddingApiKey, 'local-embed');
        expect(rows['rerouted']!.apiKey, '');
        expect(rows['rerouted']!.embeddingApiKey, '');
        expect(
          rows['rerouted']!.extraRequestParametersJson,
          isNot(contains('local-param')),
        );
        expect(rows['embed-changed']!.apiKey, 'local-key');
        expect(rows['embed-changed']!.embeddingApiKey, '');
        expect(rows['unknown']!.apiKey, '');
        expect(rows['borrow']!.embeddingApiKey, '');
        final presets = {
          for (final row in await db.select(db.studioPresetRows).get())
            row.presetId: row,
        };
        expect(
          presets['same-preset']!.runtimeSettingsJson,
          contains('local-studio'),
        );
        expect(
          presets['fallback']!.runtimeSettingsJson,
          contains('local-studio'),
        );
        expect(
          presets['changed-preset']!.runtimeSettingsJson,
          isNot(contains('local-studio')),
        );
        expect(
          presets['unknown-preset']!.runtimeSettingsJson,
          isNot(contains('local-studio')),
        );
        expect(
          presets['same-preset']!.runtimeSettingsJson,
          contains('story-password'),
        );
        final prefs = await SharedPreferences.getInstance();
        for (final key in [
          'gz_imggen_api_key',
          'gz_embedding_key',
          'api-key',
        ]) {
          expect(prefs.getString(key), '');
        }
        expect(prefs.getString('globalVars'), '{"password":"story"}');
        expect(prefs.getString('pipelineSettings'), isNot(contains('local-')));
        expect(prefs.getString('pipelineSettings'), isNot(contains('source-')));
      },
    );

    test(
      'unknown fallback refuses override and complete archive remains explicit',
      () async {
        await api('same', same);
        await studio('fallback', '', 'source-override');
        final file = await BackupExporter(db, images).buildArchive(temp);
        SharedPreferences.setMockInitialValues({});
        await FlutterBackupImporter(db, images).importFromZipFile(file.path);
        expect(
          (await db.select(db.studioPresetRows).get())
              .singleWhere((r) => r.presetId == 'fallback')
              .runtimeSettingsJson,
          isNot(contains('source-override')),
        );
        await db
            .update(db.studioPresetRows)
            .write(valueRuntime('archive-explicit'));
        final full = await BackupExporter(
          db,
          images,
        ).buildArchive(temp, includeApiKeys: true);
        await FlutterBackupImporter(db, images).importFromZipFile(full.path);
        expect(
          (await db.select(db.studioPresetRows).get())
              .singleWhere((r) => r.presetId == 'fallback')
              .runtimeSettingsJson,
          contains('archive-explicit'),
        );
      },
    );

    for (final preferenceData in [null, 'not-json', '[]', '{}']) {
      test(
        'fallback refuses unavailable archived selector: $preferenceData',
        () async {
          final prefs = await SharedPreferences.getInstance();
          await prefs.setString(
            'pipelineSettings',
            jsonEncode({
              'cleaner': {
                'postCleanerExtraRequestParameters': [param('local-global')],
              },
            }),
          );
          await api('same', same, key: 'local');
          await studio('fallback', '', 'local-override');
          final archive = Archive();
          archive.addFile(
            ArchiveFile.bytes(
              'manifest.json',
              utf8.encode(
                jsonEncode({
                  'schemaVersion': 13,
                  BackupSecrets.manifestFlag: false,
                }),
              ),
            ),
          );
          archive.addFile(
            ArchiveFile.bytes(
              'tables/studio_preset_rows.jsonl',
              utf8.encode(
                '${jsonEncode({'preset_id': 'fallback', 'name': 'backup', 'cleaner_api_config_id': '', 'runtime_settings_json': runtime('')})}\n',
              ),
            ),
          );
          if (preferenceData != null) {
            archive.addFile(
              ArchiveFile.bytes(
                'preferences.json',
                utf8.encode(preferenceData),
              ),
            );
          }
          final file = File('${temp.path}/missing_selector.glz');
          await file.writeAsBytes(ZipEncoder().encode(archive));
          await FlutterBackupImporter(db, images).importFromZipFile(file.path);
          final restored = (await db.select(db.studioPresetRows).get())
              .singleWhere((r) => r.presetId == 'fallback');
          expect(
            restored.runtimeSettingsJson,
            isNot(contains('local-override')),
          );
          expect(
            prefs.getString('pipelineSettings'),
            isNot(contains('local-global')),
          );
        },
      );
    }

    test(
      'slot IDs may differ only when resolved concrete route matches',
      () async {
        await api('same', same, key: 'source');
        await api('other-id', same, key: 'source');
        await studio('preset', 'other-id', 'source-override');
        final file = await BackupExporter(db, images).buildArchive(temp);
        await db
            .update(db.studioPresetRows)
            .write(
              const StudioPresetRowsCompanion(
                cleanerApiConfigId: Value('same'),
              ),
            );
        await db
            .update(db.studioPresetRows)
            .write(valueRuntime('local-override'));
        await FlutterBackupImporter(db, images).importFromZipFile(file.path);
        expect(
          (await db.select(db.studioPresetRows).get())
              .singleWhere((r) => r.presetId == 'preset')
              .runtimeSettingsJson,
          contains('local-override'),
        );
      },
    );
  });
}

StudioPresetRowsCompanion valueRuntime(String value) =>
    StudioPresetRowsCompanion(runtimeSettingsJson: Value(runtime(value)));
