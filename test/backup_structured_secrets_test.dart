import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/archive_stream.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/services/backup/backup_secret_urls.dart';
import 'package:glaze_flutter/core/services/backup/backup_secrets.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

Map<String, Object?> parameter(String key, String value) => {
  'key': key,
  'value': value,
  'enabled': true,
};

Map<String, Object?> runtime(String credential) => {
  'cleaner': {
    'postCleanerExtraRequestParameters': [
      parameter('x-auth-token', credential),
      parameter('max_tokens', '512'),
      parameter('custom_payload', '{"token":"ordinary-payload"}'),
    ],
    'postCleanerStyleInstructions': '{"token":"ordinary-style"}',
    'postCleanerMaxTokens': 300,
  },
  'agentBlockRestoreState': {
    'token': 'inert-restore',
    'password': 'inert-password',
  },
  'broadcastBlocks': ['https://story.test/?key=ordinary-story'],
  'canon': {'accessToken': 'inert-canon'},
};

void main() {
  test(
    'keyless Memory history strips only audited credentials and endpoints',
    () {
      final settings = {
        for (final prefix in [
          'generation',
          'aux',
          'sidecar',
          'postCleaner',
          'consolidation',
        ])
          '${prefix}ApiKey': 'SYNTHETIC_HISTORY_${prefix}_SECRET',
        for (final prefix in [
          'generation',
          'aux',
          'sidecar',
          'postCleaner',
          'consolidation',
        ])
          '${prefix}Endpoint':
              'https://user:pass@history.example.test/api?key=secret&size=512',
        'generationSource': 'custom',
        'maxTokens': 512,
        'unknown': {
          'token': 'inert story token',
          'generationApiKey': 'inert nested text',
        },
      };
      final raw = jsonEncode(settings);
      final row = {
        'session_id': 'synthetic-session',
        'settings_json': raw,
        'entries_json': 'ordinary story',
      };
      final stripped = BackupSecrets.stripRow('memory_book_rows', row);
      final output = jsonDecode(stripped['settings_json'] as String) as Map;
      for (final prefix in [
        'generation',
        'aux',
        'sidecar',
        'postCleaner',
        'consolidation',
      ]) {
        expect(output['${prefix}ApiKey'], '');
        expect(
          output['${prefix}Endpoint'],
          'https://history.example.test/api?key=&size=512',
        );
      }
      expect(output['unknown'], settings['unknown']);
      expect(output['generationSource'], 'custom');
      expect(output['maxTokens'], 512);
      expect(stripped['entries_json'], row['entries_json']);
      expect(row['settings_json'], raw); // Never change the original row.
      expect(
        BackupSecrets.refillRow('memory_book_rows', stripped, row),
        stripped,
      );
    },
  );

  test(
    'unattestable historical settings are omitted only in keyless projection',
    () {
      for (final raw in [
        '{"generationApiKey":"SYNTHETIC_SECRET"',
        '["SYNTHETIC_SECRET"]',
        '"SYNTHETIC_SECRET"',
      ]) {
        final row = {'settings_json': raw};
        expect(
          BackupSecrets.stripRow('memory_book_rows', row)['settings_json'],
          '{}',
        );
        expect(row['settings_json'], raw);
        expect(BackupSecrets.stripRow('characters', row), row);
      }
      const raw = ' { "maxTokens" : 100 } ';
      expect(
        BackupSecrets.stripRow('memory_book_rows', {
          'settings_json': raw,
        })['settings_json'],
        raw,
      );
    },
  );
  test(
    'URI scrubber blanks only auth and preserves nonsecret query encoding',
    () {
      const raw =
          'https://user:pass@example.test:8443/route?key=secret&x-auth-token=auth&api-version=2026&max_tokens=800&pageToken=next&tag=a%20b';
      final safe = BackupSecretUrls.strip(raw, BackupSecrets.isSecretField);
      final uri = Uri.parse(safe);
      expect(uri.userInfo, '');
      expect(uri.queryParameters['key'], '');
      expect(uri.queryParameters['x-auth-token'], '');
      expect(
        safe,
        contains('api-version=2026&max_tokens=800&pageToken=next&tag=a%20b'),
      );
      expect(
        BackupSecretUrls.refill(safe, raw, BackupSecrets.isSecretField),
        raw,
      );
      for (final changed in [
        safe.replaceFirst('example.test', 'other.test'),
        safe.replaceFirst('https:', 'http:'),
        safe.replaceFirst('8443', '8444'),
        safe.replaceFirst('/route', '/another'),
        safe.replaceFirst('2026', '2025'),
      ]) {
        expect(
          BackupSecretUrls.refill(changed, raw, BackupSecrets.isSecretField),
          changed,
        );
      }
      const duplicate = 'https://example.test/?key=one&key=two';
      final blank = BackupSecretUrls.strip(
        duplicate,
        BackupSecrets.isSecretField,
      );
      expect(
        BackupSecretUrls.refill(blank, duplicate, BackupSecrets.isSecretField),
        blank,
      );
    },
  );

  test(
    'named auth aliases do not match budgets, token counts or arbitrary keys',
    () {
      for (final name in [
        'x-auth-token',
        'authentication',
        'bearerToken',
        'client_secret_key',
      ]) {
        expect(BackupSecrets.isSecretField(name), true);
      }
      for (final name in [
        'maxTokens',
        'tokenCount',
        'pageToken',
        'keys',
        'key',
      ]) {
        expect(BackupSecrets.isSecretField(name), false);
      }
    },
  );

  test(
    'local Studio snapshot contains only live named credential portions',
    () {
      final source = runtime('local-secret');
      final parameters =
          (source['cleaner'] as Map)['postCleanerExtraRequestParameters'];
      expect(BackupSecrets.snapshotParameters(jsonEncode(parameters)), [
        {'key': 'x-auth-token', 'value': 'local-secret'},
      ]);
      final safe = BackupSecrets.stripRow('studio_preset_rows', {
        'preset_id': 'p',
        'runtime_settings_json': jsonEncode(source),
      });
      final output = jsonDecode(safe['runtime_settings_json'] as String);
      expect(
        output['agentBlockRestoreState'],
        source['agentBlockRestoreState'],
      );
      expect(output['canon'], source['canon']);
      expect(
        output['cleaner']['postCleanerStyleInstructions'],
        contains('ordinary-style'),
      );
      expect(
        output['cleaner']['postCleanerExtraRequestParameters'][2]['value'],
        contains('ordinary-payload'),
      );
      expect(jsonEncode(output), isNot(contains('local-secret')));
    },
  );

  test(
    'changed nested image destination refuses URL and sibling key refill',
    () {
      final backup = jsonEncode({
        'novelai': {
          'endpoint': 'https://new.example.test/api?key=&size=512',
          'apiKey': '',
        },
      });
      final local = jsonEncode({
        'novelai': {
          'endpoint':
              'https://user:pass@old.example.test/api?key=local&size=512',
          'apiKey': 'wrong-provider-key',
        },
      });
      final output = BackupSecrets.refillPref(
        backup,
        local,
        key: 'gz_imggen_settings',
      );
      expect(output, backup);
      expect(output, isNot(contains('wrong-provider-key')));
    },
  );

  test(
    'Studio parameter refill rejects duplicate names and retains explicit values',
    () {
      final raw = jsonEncode({
        'cleaner': {
          'postCleanerExtraRequestParameters': [
            parameter('authentication', ''),
            parameter('authentication', ''),
            parameter('bearerToken', 'from-archive'),
            parameter('client_secret_key', ''),
          ],
        },
      });
      final output = BackupSecrets.refillRow(
        'studio_preset_rows',
        {'preset_id': 'same', 'runtime_settings_json': raw},
        {
          'cleaner_parameters': [
            parameter('authentication', 'local-auth'),
            parameter('bearerToken', 'local-bearer'),
            parameter('client_secret_key', 'local-secret'),
          ],
        },
      );
      final parameters =
          jsonDecode(
                output['runtime_settings_json'] as String,
              )['cleaner']['postCleanerExtraRequestParameters']
              as List;
      expect(parameters[0]['value'], '');
      expect(parameters[1]['value'], '');
      expect(parameters[2]['value'], 'from-archive');
      expect(parameters[3]['value'], ''); // No routing proof supplied.
    },
  );

  group('actual ZIP structured secrets', () {
    late AppDatabase db;
    late Directory temp;
    late ImageStorageService images;
    const endpoint =
        'https://source-user:source-pass@api.example.test/v1/chat/completions?key=source-query&api-version=2026&pageToken=next';
    const embedding =
        'https://source-embed-user:source-embed-pass@embed.example.test/v1/embeddings?access_token=source-embed-query&max_tokens=500';
    const image =
        'https://source-image-user:source-image-pass@image.example.test/api?key=source-image-query&size=512';
    const aliases = [
      'sc_api_connection_presets',
      'silly_cradle_api_presets',
      'api_connection_presets',
    ];

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'gz_imggen_settings': jsonEncode({
          'customEndpoint': image,
          'novelai': {'endpoint': image, 'apiKey': 'source-image-key'},
          'ordinaryText': 'https://story.test/?key=ordinary-text',
        }),
        'memorySettings': jsonEncode({
          'generationEndpoint': endpoint,
          'generationApiKey': 'source-memory-key',
        }),
        'gz_imggen_endpoint': image,
        for (final alias in aliases)
          alias: jsonEncode([
            {'id': 'a', 'key': 'source-alias-a', 'endpoint': endpoint},
            {'id': 'b', 'key': 'source-alias-b', 'endpoint': endpoint},
          ]),
      });
      db = AppDatabase.forTesting(NativeDatabase.memory());
      temp = await Directory(
        '${Platform.environment['LOCALAPPDATA']}/Temp/opencode',
      ).createTemp('astoria_structured_backup_');
      images = ImageStorageService(temp.path);
      await db
          .into(db.chatSessions)
          .insert(
            ChatSessionsCompanion.insert(
              sessionId: 'history-synthetic',
              characterId: 'history-character',
              sessionIndex: 0,
              messagesJson: '[]',
            ),
          );
      await db
          .into(db.memoryBookRows)
          .insert(
            MemoryBookRowsCompanion.insert(
              sessionId: 'history-synthetic',
              settingsJson: Value(
                jsonEncode({
                  'generationApiKey': 'source-history-key',
                  'generationEndpoint': endpoint,
                  'consolidationApiKey': 'source-history-consolidation',
                  'unknown': {'token': 'inert-history'},
                }),
              ),
            ),
          );
      for (final id in ['same', 'changed']) {
        await db
            .into(db.apiConfigs)
            .insert(
              ApiConfigsCompanion.insert(
                configId: id,
                name: id,
                endpoint: const Value(endpoint),
                embeddingEndpoint: const Value(embedding),
                apiKey: const Value('source-api-key'),
              ),
            );
      }
      for (final id in ['a', 'b', 'missing']) {
        await db
            .into(db.studioPresetRows)
            .insert(
              StudioPresetRowsCompanion.insert(
                presetId: id,
                name: id,
                runtimeSettingsJson: Value(
                  jsonEncode(runtime('source-studio-$id')),
                ),
              ),
            );
      }
    });

    tearDown(() async {
      await db.close();
      await temp.delete(recursive: true);
    });

    Future<Map<String, dynamic>> archiveJson(File file, String name) async {
      final input = InputFileStream(file.path);
      final archive = ZipDecoder().decodeStream(input);
      try {
        return jsonDecode(utf8.decode(archive.findFile(name)!.readBytes()!))
            as Map<String, dynamic>;
      } finally {
        await archive.clear();
        await input.close();
      }
    }

    Future<List<Map<String, dynamic>>> archiveRows(
      File file,
      String table,
    ) async {
      final input = InputFileStream(file.path);
      final archive = ZipDecoder().decodeStream(input);
      try {
        return (await readArchiveFileLines(
              archive.findFile('tables/$table.jsonl')!,
            ).toList())
            .map((line) => jsonDecode(line) as Map<String, dynamic>)
            .toList();
      } finally {
        await archive.clear();
        await input.close();
      }
    }

    test(
      'safe export removes live Studio/API/prefs auth without touching inert state',
      () async {
        final file = await BackupExporter(db, images).buildArchive(temp);
        final api = await archiveRows(file, 'api_configs');
        expect(jsonEncode(api), isNot(contains('source-')));
        expect(
          api.first['endpoint'],
          contains('api-version=2026&pageToken=next'),
        );
        final studio = await archiveRows(file, 'studio_preset_rows');
        expect(jsonEncode(studio), isNot(contains('source-studio-')));
        expect(jsonEncode(studio), contains('inert-restore'));
        expect(jsonEncode(studio), contains('ordinary-style'));
        expect(jsonEncode(studio), contains('ordinary-payload'));
        final history = await archiveRows(file, 'memory_book_rows');
        expect(jsonEncode(history), isNot(contains('source-history')));
        expect(jsonEncode(history), contains('inert-history'));
        expect(
          (await db.select(db.memoryBookRows).getSingle()).settingsJson,
          contains('source-history-key'),
        );
        final prefs = await archiveJson(file, 'preferences.json');
        expect(jsonEncode(prefs), isNot(contains('source-')));
        expect(prefs['gz_imggen_settings'], contains('ordinary-text'));
        for (final alias in aliases) {
          expect((jsonDecode(prefs[alias] as String) as List).first['key'], '');
        }
      },
    );

    test(
      'keyless import refills matching URL destinations and stable Studio presets',
      () async {
        final file = await BackupExporter(db, images).buildArchive(temp);
        await db.delete(db.apiConfigs).go();
        for (final id in ['changed', 'same']) {
          final localEndpoint = endpoint.replaceAll('source-', 'local-');
          final localEmbedding = embedding.replaceAll('source-', 'local-');
          await db
              .into(db.apiConfigs)
              .insert(
                ApiConfigsCompanion.insert(
                  configId: id,
                  name: 'local',
                  endpoint: Value(
                    id == 'same'
                        ? localEndpoint
                        : localEndpoint.replaceFirst(
                            'api.example.test',
                            'wrong.example.test',
                          ),
                  ),
                  embeddingEndpoint: Value(
                    id == 'same'
                        ? localEmbedding
                        : localEmbedding.replaceFirst(
                            'embed.example.test',
                            'wrong.example.test',
                          ),
                  ),
                  apiKey: const Value('local-api-key'),
                ),
              );
        }
        await db.delete(db.studioPresetRows).go();
        for (final id in ['b', 'a', 'local-only']) {
          final local = runtime('local-studio-$id');
          (local['cleaner'] as Map)['postCleanerExtraRequestParameters'] = [
            parameter('max_tokens', '999'),
            parameter('x-auth-token', 'local-studio-$id'),
          ];
          await db
              .into(db.studioPresetRows)
              .insert(
                StudioPresetRowsCompanion.insert(
                  presetId: id,
                  name: 'local',
                  runtimeSettingsJson: Value(jsonEncode(local)),
                ),
              );
        }
        final localImage = image.replaceAll('source-', 'local-');
        SharedPreferences.setMockInitialValues({
          'gz_imggen_settings': jsonEncode({
            'customEndpoint': localImage,
            'novelai': {'endpoint': localImage, 'apiKey': 'local-image-key'},
          }),
          'memorySettings': jsonEncode({
            'generationEndpoint': endpoint.replaceAll('source-', 'local-'),
            'generationApiKey': 'local-memory-key',
          }),
          'gz_imggen_endpoint': localImage,
          for (final alias in aliases)
            alias: jsonEncode([
              {
                'id': 'b',
                'key': 'local-alias-b',
                'endpoint': endpoint.replaceAll('source-', 'local-'),
              },
              {
                'id': 'a',
                'key': 'local-alias-a',
                'endpoint': endpoint
                    .replaceAll('source-', 'local-')
                    .replaceFirst('api.example.test', 'wrong.example.test'),
              },
            ]),
        });
        await FlutterBackupImporter(db, images).importFromZipFile(file.path);
        final api = await db.select(db.apiConfigs).get();
        final same = api.singleWhere((r) => r.configId == 'same');
        expect(same.endpoint, contains('local-user:local-pass@'));
        expect(same.endpoint, contains('key=local-query'));
        expect(same.embeddingEndpoint, contains('local-embed-query'));
        final changed = api.singleWhere((r) => r.configId == 'changed');
        expect(changed.endpoint, isNot(contains('local-')));
        expect(changed.embeddingEndpoint, isNot(contains('local-')));
        expect(changed.apiKey, '');
        final studio = await db.select(db.studioPresetRows).get();
        for (final id in ['a', 'b']) {
          final raw = studio
              .singleWhere((r) => r.presetId == id)
              .runtimeSettingsJson;
          expect(
            raw,
            isNot(contains('local-studio-$id')),
          ); // Slot/fallback unknown.
          expect(raw, contains('512'));
          expect(raw, isNot(contains('999')));
          expect(raw, contains('inert-canon'));
        }
        expect(
          studio
              .singleWhere((r) => r.presetId == 'missing')
              .runtimeSettingsJson,
          isNot(contains('local-studio')),
        );
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('gz_imggen_settings'),
          contains('local-image-query'),
        );
        expect(prefs.getString('memorySettings'), contains('local-memory-key'));
        expect(
          prefs.getString('gz_imggen_endpoint'),
          contains('local-image-pass'),
        );
        for (final alias in aliases) {
          final profiles = jsonDecode(prefs.getString(alias)!) as List;
          expect(profiles[0]['key'], '');
          expect(profiles[0]['endpoint'], isNot(contains('local-')));
          expect(profiles[1]['key'], 'local-alias-b');
          expect(profiles[1]['endpoint'], contains('local-query'));
        }
      },
    );

    test('explicit inclusion preserves Studio and URL credentials', () async {
      final file = await BackupExporter(
        db,
        images,
      ).buildArchive(temp, includeApiKeys: true);
      expect(
        (await archiveRows(file, 'api_configs')).first['endpoint'],
        endpoint,
      );
      expect(
        jsonEncode(await archiveRows(file, 'memory_book_rows')),
        contains('source-history-key'),
      );
      expect(
        jsonEncode(await archiveRows(file, 'studio_preset_rows')),
        contains('source-studio-a'),
      );
      expect(
        (await archiveJson(file, 'preferences.json'))['gz_imggen_endpoint'],
        image,
      );
      await db.delete(db.studioPresetRows).go();
      await FlutterBackupImporter(db, images).importFromZipFile(file.path);
      expect(
        (await db.select(db.studioPresetRows).get())
            .singleWhere((r) => r.presetId == 'a')
            .runtimeSettingsJson,
        contains('source-studio-a'),
      );
    });
  });
}
