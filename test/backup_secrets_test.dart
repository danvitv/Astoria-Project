import 'dart:convert';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:drift/drift.dart' show Value;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:glaze_flutter/core/db/app_db.dart';
import 'package:glaze_flutter/core/services/backup/archive_stream.dart';
import 'package:glaze_flutter/core/services/backup/backup_cancel.dart';
import 'package:glaze_flutter/core/services/backup/backup_exporter.dart';
import 'package:glaze_flutter/core/services/backup/backup_secrets.dart';
import 'package:glaze_flutter/core/services/backup/flutter_backup_importer.dart';
import 'package:glaze_flutter/core/services/backup_service.dart';
import 'package:glaze_flutter/core/services/image_storage_service.dart';

void main() {
  test('credential matching leaves token budgets and ordinary keys alone', () {
    for (final name in [
      'apiKey',
      'generationApiKey',
      'customApiKey',
      'embedding_api_key',
      'refresh_token',
      'accessToken',
      'password',
      'client_secret',
      'Authorization',
      'x-api-key',
      'cookie',
    ]) {
      expect(BackupSecrets.isSecretField(name), isTrue, reason: name);
    }
    for (final name in [
      'key',
      'keys',
      'maxTokens',
      'tokenCount',
      'tokens',
      'tokenizer',
      'pageToken',
      'scopeKey',
      'apiKeysIncluded',
    ]) {
      expect(BackupSecrets.isSecretField(name), isFalse, reason: name);
    }
  });

  test('filters all audited credentials, nested JSON and legacy profiles', () {
    final input = <String, dynamic>{
      for (final key in BackupSecrets.prefKeys) key: 'synthetic-$key',
      'gz_imggen_settings': jsonEncode({
        'customApiKey': 'synthetic-custom',
        'routmyApiKey': 'synthetic-routmy',
        'naisteraApiKey': 'synthetic-naistera',
        for (final provider in [
          'xai',
          'openrouter',
          'electronhub',
          'a1111',
          'novelai',
          'comfyui',
        ])
          provider: {'apiKey': 'synthetic-$provider', 'model': provider},
      }),
      'pipelineSettings': jsonEncode({
        'memoryBookApi': {'generationApiKey': 'synthetic-memory'},
        'auxApiKey': 'synthetic-aux',
        'sidecarApiKey': 'synthetic-sidecar',
        'maxTokens': 200,
        'tokenCount': 100,
        'pageToken': 'next',
        'key': 'ordinary-key',
        'keys': ['lore-key'],
        'embedded': jsonEncode({'access_token': 'ordinary-nested'}),
      }),
      'gz_provider_profiles': [
        jsonEncode({'id': 'p1', 'key': 'synthetic-legacy', 'name': 'Profile'}),
        jsonEncode({'id': 'p2', 'apiKey': 'synthetic-profile'}),
      ],
      'plain': 'plain text',
      'n': 3,
      'b': true,
      'untouched': '{ "a" : 1 }',
    };
    final output = BackupSecrets.stripPrefs(input);
    expect(jsonEncode(output), isNot(contains('synthetic-')));
    for (final key in BackupSecrets.prefKeys) {
      expect(output.containsKey(key), isFalse, reason: key);
    }
    final pipeline = jsonDecode(output['pipelineSettings'] as String);
    expect(pipeline['memoryBookApi']['generationApiKey'], '');
    expect(pipeline['maxTokens'], 200);
    expect(pipeline['tokenCount'], 100);
    expect(pipeline['pageToken'], 'next');
    expect(pipeline['key'], 'ordinary-key');
    expect(pipeline['keys'], ['lore-key']);
    expect(output['untouched'], input['untouched']);
    expect(input['gz_imggen_settings'], contains('synthetic-custom'));
  });

  test(
    'refill never guesses list positions, names or ambiguous identities',
    () {
      final backup = [
        {'id': 'b', 'apiKey': '', 'model': 'new'},
        {'id': 'a', 'apiKey': ''},
        {'id': 'missing', 'apiKey': ''},
        {'name': 'same-name', 'apiKey': ''},
        {'id': 'duplicate', 'apiKey': ''},
        {'id': 'duplicate', 'apiKey': ''},
        {'id': 'account', 'email': 'new@example.test', 'accessToken': ''},
        {'id': 'ambiguous', 'apiKey': ''},
      ];
      final local = [
        {'id': 'a', 'apiKey': 'local-a'},
        {'id': 'b', 'apiKey': 'local-b', 'model': 'old'},
        {'id': 'removed', 'apiKey': 'local-removed'},
        {'name': 'same-name', 'apiKey': 'local-nameless'},
        {'id': 'duplicate', 'apiKey': 'local-duplicate'},
        {
          'id': 'account',
          'email': 'old@example.test',
          'accessToken': 'local-account',
        },
        {'id': 'ambiguous', 'apiKey': 'local-one'},
        {'id': 'ambiguous', 'apiKey': 'local-two'},
      ];
      final withEndpoint = [
        for (final row in backup) {...row, 'endpoint': 'https://same.test/v1'},
      ];
      final localWithEndpoint = [
        for (final row in local) {...row, 'endpoint': 'https://same.test/v1'},
      ];
      final output =
          BackupSecrets.refillPref(
                withEndpoint,
                localWithEndpoint,
                key: 'gz_provider_profiles',
              )
              as List;
      expect(output[0]['apiKey'], 'local-b');
      expect(output[0]['model'], 'new');
      expect(output[1]['apiKey'], 'local-a');
      for (final i in [2, 3, 4, 5, 7]) {
        expect(output[i]['apiKey'], '');
      }
      expect(output[6]['accessToken'], '');
    },
  );

  test(
    'refills string-list JSON profiles, retains explicit archive values',
    () {
      final output =
          BackupSecrets.refillPref(
                [
                  jsonEncode({
                    'id': 'b',
                    'key': '',
                    'endpoint': 'https://same.test/v1',
                  }),
                  jsonEncode({'id': 'a', 'key': 'archive-key'}),
                ],
                [
                  jsonEncode({'id': 'a', 'key': 'local-a'}),
                  jsonEncode({
                    'id': 'b',
                    'key': 'local-b',
                    'endpoint': 'https://same.test/v1',
                  }),
                ],
                key: 'gz_provider_profiles',
              )
              as List;
      expect(jsonDecode(output[0] as String)['key'], 'local-b');
      expect(jsonDecode(output[1] as String)['key'], 'archive-key');
    },
  );

  test(
    'nested account maps refuse changed identity and preserve nonsecrets',
    () {
      final backup = jsonEncode({
        'account': {'id': 'new-account', 'access_token': ''},
        'profile': {'profileId': 'same', 'password': '', 'tokenCount': 15},
        'another': {'userId': 'absent-local', 'refreshToken': ''},
      });
      final local = jsonEncode({
        'account': {'id': 'old-account', 'access_token': 'wrong-account'},
        'profile': {
          'profileId': 'same',
          'password': 'local-password',
          'tokenCount': 9,
        },
      });
      final output = jsonDecode(
        BackupSecrets.refillPref(backup, local) as String,
      );
      expect(output['account']['access_token'], '');
      expect(output['profile']['password'], '');
      expect(output['profile']['tokenCount'], 15);
      expect(output['another']['refreshToken'], '');
    },
  );

  test('Studio/canon/content rows remain verbatim and Tavo stays disabled', () {
    expect(
      BackupExporter.tableNames,
      containsAll([
        'studio_config_rows',
        'studio_preset_rows',
        'tracker_rows',
        'tracker_snapshots',
        'session_canon_checkpoint_rows',
        'session_lorebook_revision_rows',
        'rewrite_operations',
      ]),
    );
    for (final table in [
      'studio_preset_rows',
      'characters',
      'rewrite_operations',
    ]) {
      final row = {'id': 'fixture', 'content': '{"token":"story token"}'};
      expect(BackupSecrets.stripRow(table, row), row);
    }
    expect(BackupService.tavoImportEnabled, false);
  });

  group('archive credential round trips', () {
    late AppDatabase db;
    late Directory temp;
    late ImageStorageService images;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        'gz_sync_tokens': '{"dropbox":{"refresh_token":"source-sync"}}',
        'gz_dc_device': 'source-device',
        'gz_dc_user_token': 'source-datacat',
        'gz_cf_clearance_janitor': 'source-cookie',
        'gz_chub_api_key': 'source-chub',
        'pipelineSettings': jsonEncode({
          'memoryBookApi': {
            'generationApiKey': 'source-memory',
            'generationEndpoint': 'https://memory.test/v1',
            'model': 'new',
          },
        }),
        'gz_provider_profiles': [
          jsonEncode({
            'id': 'b',
            'key': 'source-b',
            'endpoint': 'https://same.test/v1',
          }),
          jsonEncode({
            'id': 'a',
            'apiKey': 'source-a',
            'endpoint': 'https://same.test/v1',
          }),
          jsonEncode({'id': 'missing', 'apiKey': 'source-missing'}),
        ],
        'theme_accent': '7996CE',
        // A remembered UI choice must not change backend defaults.
        BackupSecrets.includeApiKeysPrefKey: true,
      });
      db = AppDatabase.forTesting(NativeDatabase.memory());
      temp = await Directory(
        '${Platform.environment['LOCALAPPDATA']}/Temp/opencode',
      ).createTemp('astoria_backup_secrets_');
      images = ImageStorageService(temp.path);
      for (final id in ['b', 'a', 'new']) {
        await db
            .into(db.apiConfigs)
            .insert(
              ApiConfigsCompanion.insert(
                configId: id,
                name: 'Source $id',
                endpoint: const Value('https://api.test/v1/chat/completions'),
                embeddingEndpoint: const Value(
                  'https://embed.test/v1/embeddings',
                ),
                embeddingUseSame: const Value(false),
                apiKey: Value('source-key-$id'),
                embeddingApiKey: Value('source-embedding-$id'),
                extraRequestParametersJson: Value(
                  jsonEncode([
                    {
                      'key': 'access_token',
                      'value': 'source-extra-$id',
                      'enabled': true,
                    },
                    {'key': 'max_tokens', 'value': '512', 'enabled': true},
                  ]),
                ),
              ),
            );
      }
    });

    tearDown(() async {
      await db.close();
      await temp.delete(recursive: true);
    });

    Future<Archive> decode(File file) async {
      final archive = ZipDecoder().decodeStream(InputFileStream(file.path));
      addTearDown(archive.clear);
      return archive;
    }

    Map<String, dynamic> readJson(Archive archive, String name) =>
        jsonDecode(utf8.decode(archive.findFile(name)!.readBytes()!))
            as Map<String, dynamic>;

    test(
      'default archive omits credentials, explicit true stays complete',
      () async {
        final exporter = BackupExporter(db, images);
        // Frozen method contracts are callable without a credential argument.
        expect(
          exporter.export,
          isA<Future<String> Function({bool includeApiKeys})>(),
        );
        expect(
          BackupService(db, images).exportBackup,
          isA<Future<String> Function({bool includeApiKeys})>(),
        );
        final file = await exporter.buildArchive(temp);
        expect(file.path, contains('Astoria_backup_'));
        final archive = await decode(file);
        expect(
          readJson(archive, 'manifest.json')[BackupSecrets.manifestFlag],
          false,
        );
        final prefs = readJson(archive, 'preferences.json');
        expect(jsonEncode(prefs), isNot(contains('source-')));
        expect(prefs['theme_accent'], '7996CE');
        final lines = await readArchiveFileLines(
          archive.findFile('tables/api_configs.jsonl')!,
        ).toList();
        expect(lines, hasLength(3));
        for (final line in lines) {
          final row = jsonDecode(line);
          expect(row['api_key'], '');
          expect(row['embedding_api_key'], '');
          expect(
            row['extra_request_parameters_json'],
            isNot(contains('source-extra')),
          );
          expect(row['extra_request_parameters_json'], contains('512'));
        }
        // Clear the open ZIP before reusing its timestamp-based filename.
        await archive.clear();
        final complete = await decode(
          await exporter.buildArchive(temp, includeApiKeys: true),
        );
        expect(
          readJson(complete, 'manifest.json')[BackupSecrets.manifestFlag],
          true,
        );
        expect(
          readJson(complete, 'preferences.json')['gz_dc_user_token'],
          'source-datacat',
        );
        final fullLines = await readArchiveFileLines(
          complete.findFile('tables/api_configs.jsonl')!,
        ).toList();
        expect(fullLines.first, contains('source-key-b'));
        expect(fullLines.first, contains('source-embedding-b'));
        expect(fullLines.first, contains('source-extra-b'));
      },
    );

    test(
      'keyless restore refills stable rows and reordered profiles only',
      () async {
        final file = await BackupExporter(db, images).buildArchive(temp);
        await db.delete(db.apiConfigs).go();
        for (final id in ['a', 'b', 'local-only']) {
          await db
              .into(db.apiConfigs)
              .insert(
                ApiConfigsCompanion.insert(
                  configId: id,
                  name: 'Local $id',
                  endpoint: const Value('https://api.test/v1/chat/completions'),
                  embeddingEndpoint: const Value(
                    'https://embed.test/v1/embeddings',
                  ),
                  embeddingUseSame: const Value(false),
                  apiKey: Value('local-key-$id'),
                  embeddingApiKey: Value('local-embedding-$id'),
                  extraRequestParametersJson: Value(
                    jsonEncode([
                      {'key': 'max_tokens', 'value': '999'},
                      {'key': 'access_token', 'value': 'local-extra-$id'},
                    ]),
                  ),
                ),
              );
        }
        SharedPreferences.setMockInitialValues({
          'gz_sync_tokens': 'local-sync',
          'gz_dc_device': 'local-device',
          'gz_dc_user_token': 'local-datacat',
          'gz_chub_api_key': 'local-chub',
          'gz_cf_clearance_janitor': 'local-cookie',
          'pipelineSettings': jsonEncode({
            'memoryBookApi': {
              'generationApiKey': 'local-memory',
              'generationEndpoint': 'https://memory.test/v1',
              'model': 'old',
            },
          }),
          'gz_provider_profiles': [
            jsonEncode({
              'id': 'a',
              'apiKey': 'local-a',
              'endpoint': 'https://same.test/v1',
            }),
            jsonEncode({
              'id': 'b',
              'key': 'local-b',
              'endpoint': 'https://same.test/v1',
            }),
            jsonEncode({'id': 'local-only', 'apiKey': 'local-unused'}),
          ],
        });
        await FlutterBackupImporter(db, images).importFromZipFile(file.path);
        final rows = await db.select(db.apiConfigs).get();
        expect(rows.map((r) => r.configId), unorderedEquals(['a', 'b', 'new']));
        for (final id in ['a', 'b']) {
          final row = rows.singleWhere((r) => r.configId == id);
          expect(row.apiKey, 'local-key-$id');
          expect(row.embeddingApiKey, 'local-embedding-$id');
          expect(row.name, 'Source $id');
          expect(row.extraRequestParametersJson, contains('local-extra-$id'));
          expect(row.extraRequestParametersJson, contains('512'));
          expect(row.extraRequestParametersJson, isNot(contains('999')));
        }
        expect(rows.singleWhere((r) => r.configId == 'new').apiKey, '');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('gz_sync_tokens'), 'local-sync');
        expect(prefs.getString('gz_dc_device'), 'local-device');
        expect(prefs.getString('gz_dc_user_token'), 'local-datacat');
        expect(prefs.getString('gz_cf_clearance_janitor'), 'local-cookie');
        expect(prefs.getString('pipelineSettings'), contains('local-memory'));
        final profiles = prefs
            .getStringList('gz_provider_profiles')!
            .map(jsonDecode)
            .toList();
        expect(profiles[0]['key'], 'local-b');
        expect(profiles[1]['apiKey'], 'local-a');
        expect(profiles[2]['apiKey'], '');
      },
    );

    test(
      'clean-device keyless restore leaves blanks, not credential markers',
      () async {
        final file = await BackupExporter(db, images).buildArchive(temp);
        await db.delete(db.apiConfigs).go();
        SharedPreferences.setMockInitialValues({});
        await FlutterBackupImporter(db, images).importFromZipFile(file.path);
        for (final row in await db.select(db.apiConfigs).get()) {
          expect(row.apiKey, '');
          expect(row.embeddingApiKey, '');
        }
        expect(
          (await SharedPreferences.getInstance()).getString('gz_sync_tokens'),
          isNull,
        );
      },
    );

    test(
      'explicit complete archive restores its keys instead of local keys',
      () async {
        final file = await BackupExporter(
          db,
          images,
        ).buildArchive(temp, includeApiKeys: true);
        await db
            .update(db.apiConfigs)
            .write(
              const ApiConfigsCompanion(
                apiKey: Value('local-key'),
                embeddingApiKey: Value('local-embedding'),
              ),
            );
        SharedPreferences.setMockInitialValues({
          'gz_dc_device': 'local-device',
          'gz_dc_user_token': 'local-datacat',
          'gz_sync_tokens': 'local-sync',
        });
        await BackupService(db, images).importBackupFromFile(file.path);
        final row = (await db.select(db.apiConfigs).get()).singleWhere(
          (row) => row.configId == 'a',
        );
        expect(row.apiKey, 'source-key-a');
        expect(row.embeddingApiKey, 'source-embedding-a');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('gz_dc_device'), 'source-device');
        expect(prefs.getString('gz_dc_user_token'), 'source-datacat');
        expect(prefs.getString('gz_sync_tokens'), contains('source-sync'));
      },
    );

    test(
      'legacy archives without flag do not refill or override archive keys',
      () async {
        final archive = Archive();
        archive.addFile(
          ArchiveFile.bytes(
            'manifest.json',
            utf8.encode(jsonEncode({'schemaVersion': 13})),
          ),
        );
        archive.addFile(
          ArchiveFile.bytes(
            'tables/api_configs.jsonl',
            utf8.encode(
              '${jsonEncode({'config_id': 'a', 'name': 'Legacy', 'api_key': '', 'embedding_api_key': 'legacy-embedding'})}\n',
            ),
          ),
        );
        archive.addFile(
          ArchiveFile.bytes(
            'preferences.json',
            utf8.encode(
              jsonEncode({
                'gz_sync_tokens': 'legacy-sync',
                'pipelineSettings': '{"memoryBookApi":{"generationApiKey":""}}',
              }),
            ),
          ),
        );
        final file = File('${temp.path}/legacy.glz');
        await file.writeAsBytes(ZipEncoder().encode(archive));
        await FlutterBackupImporter(db, images).importFromZipFile(file.path);
        final row = await db.select(db.apiConfigs).getSingle();
        expect(row.apiKey, '');
        expect(row.embeddingApiKey, 'legacy-embedding');
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('gz_sync_tokens'), 'legacy-sync');
        expect(
          prefs.getString('pipelineSettings'),
          isNot(contains('source-memory')),
        );
      },
    );

    test(
      'cancel after credential snapshot precedes destructive import',
      () async {
        final file = await BackupExporter(db, images).buildArchive(temp);
        var cancelled = false;
        final cancel = ImportCancellationToken.wrap(
          isCancelled: () => cancelled,
          check: () {
            if (cancelled) throw const ImportCancelledException();
          },
        );
        await expectLater(
          FlutterBackupImporter(db, images, cancel).importFromZipFile(
            file.path,
            onProgress: (stage) {
              if (stage == 'Importing tables...') cancelled = true;
            },
          ),
          throwsA(isA<ImportCancelledException>()),
        );
        expect(
          (await db.select(db.apiConfigs).get()).first.apiKey,
          'source-key-b',
        );
      },
    );
  });
}
