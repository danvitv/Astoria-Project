import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:drift/drift.dart';
import 'package:path/path.dart' as p;
import 'package:shared_preferences/shared_preferences.dart';
import '../../preferences/saved_preferences_owner.dart';
import '../../preferences/tracked_shared_preferences.dart';

import '../../db/app_db.dart';
import '../../db/repositories/session_lorebook_embedding_job_repo.dart';
import '../../llm/vector_math.dart';
import '../../llm/transport/endpoint_normalizer.dart';
import '../../models/studio_agent_codec.dart';
import '../../models/studio_preset_codec.dart';
import '../image_storage_service.dart';
import 'archive_stream.dart';
import 'backup_cancel.dart';
import 'backup_helpers.dart';
import 'backup_secrets.dart';
import 'backup_secret_routes.dart';
import 'backup_secret_containers.dart';

class FlutterBackupImporter extends BackupHelpers {
  static const int _batchSize = 500;

  /// Table entries larger than this are decompressed to a temp file and read
  /// back from disk instead of being materialised in memory.
  static const int _spillToDiskBytes = 8 * 1024 * 1024;
  static const int _maxSchemaVersion = 14;
  // Support-assistant state is device-local and encrypted. The exporter
  // intentionally omits these tables; do not trust hand-crafted archives to
  // restore them through the generic table importer.
  static const Set<String> _excludedArchiveTables = {
    'support_sessions',
    'support_messages',
    'support_context_blocks',
    'support_mutation_journal',
    'support_reports',
  };

  @override
  final AppDatabase db;
  @override
  final ImageStorageService imageStorage;
  final ImportCancellationToken _cancel;
  final List<Map<String, dynamic>> _legacyStudioRuntimeRows = [];
  final _localRoutes = <String, Map<String, dynamic>>{};
  final _restoredRoutes = <String, Map<String, dynamic>>{};
  final _localRoutingPrefs = <String, dynamic>{};
  final _restoredRoutingPrefs = <String, dynamic>{};

  FlutterBackupImporter(this.db, this.imageStorage, [this._cancel = noCancel]);

  /// Imports a v2 Glaze backup (ZIP container with manifest.json and
  /// tables/*.jsonl). Streamed — file is never read fully into memory.
  Future<void> importFromZipFile(
    String filePath, {
    void Function(String stage)? onProgress,
  }) => SavedPreferencesWrites.run(SavedPreferencesKeys.all, () async {
    _legacyStudioRuntimeRows.clear();
    final input = InputFileStream(filePath);
    Archive? archive;
    try {
      archive = ZipDecoder().decodeStream(input);
      await _importFromZip(archive, filePath, onProgress: onProgress);
    } finally {
      _legacyStudioRuntimeRows.clear();
      _localRoutes.clear();
      _restoredRoutes.clear();
      _localRoutingPrefs.clear();
      _restoredRoutingPrefs.clear();
      try {
        await archive?.clear();
      } finally {
        await input.close();
      }
    }
  });

  /// Imports a legacy v1 Glaze JSON-monolith. Kept for completeness but
  /// the service layer rejects v1 with a "please re-export" message.
  Future<void> importFromLegacyJson(
    Map<String, dynamic> data, {
    void Function(String stage)? onProgress,
  }) async {
    _legacyStudioRuntimeRows.clear();
    try {
      final tables = data['tables'] as Map<String, dynamic>?;
      if (tables == null) return;
      await _importTablesFromJson(tables, onProgress: onProgress);
      await restoreGalleryImages(data['gallery'] as Map<String, dynamic>?);
      await _restoreAvatars(data['avatars'] as Map<String, dynamic>?);
    } finally {
      _legacyStudioRuntimeRows.clear();
    }
  }

  Future<void> import(
    Map<String, dynamic> data, {
    void Function(String stage)? onProgress,
  }) => importFromLegacyJson(data, onProgress: onProgress);

  Future<void> _importFromZip(
    Archive archive,
    String filePath, {
    void Function(String stage)? onProgress,
  }) async {
    final manifestEntry = archive.files.firstWhere(
      (f) => f.isFile && f.name == 'manifest.json',
      orElse: () => throw const FormatException(
        'Backup is missing manifest.json — not a v2 backup',
      ),
    );
    final manifestJson =
        jsonDecode(utf8.decode(manifestEntry.readBytes()!))
            as Map<String, dynamic>;
    manifestEntry.clear();
    final schemaVersion = manifestJson['schemaVersion'] as int? ?? 0;
    // Minimum supported schemaVersion is 2 (initial ZIP format).
    // v3 added extension_presets and info_blocks — older backups simply won't
    // have those JSONL files, leaving the tables empty after import (fine).
    if (schemaVersion < 2) {
      throw const FormatException(
        'Backup schema is too old. Please re-export from the source app.',
      );
    }
    if (schemaVersion > _maxSchemaVersion) {
      throw const FormatException('Backup was created by a newer app version.');
    }

    // Absence means a legacy, keys-included archive. Capture credentials before
    // destructive table replacement, then refill each bounded insert batch.
    final keysStripped = manifestJson[BackupSecrets.manifestFlag] == false;
    final localApiSecrets = <String, Map<String, dynamic>>{};
    final localStudioSecrets = <String, Map<String, dynamic>>{};
    final localPrefs = <String, dynamic>{};
    if (keysStripped) {
      _cancel.check();
      final columns = [
        ...BackupSecrets.tableColumns['api_configs']!,
        ...BackupSecrets.tableJsonColumns['api_configs']!,
        ...BackupSecretRoutes.apiColumns,
      ];
      final rows = await db
          .customSelect(
            'SELECT config_id, ${columns.join(', ')} FROM api_configs',
          )
          .get();
      for (final row in rows) {
        final routing = {
          for (final column in BackupSecretRoutes.apiColumns)
            column: row.data[column],
        };
        _localRoutes[row.read<String>('config_id')] = routing;
        _restoredRoutes[row.read<String>('config_id')] = routing;
        localApiSecrets[row.read<String>('config_id')] = {
          ...row.data,
          'extra_request_parameters_json': BackupSecrets.snapshotParameters(
            row.data['extra_request_parameters_json'],
          ),
        };
      }
      final prefs = await SharedPreferences.getInstance();
      for (final key in prefs.getKeys()) {
        localPrefs[key] = prefs.get(key);
      }
      _localRoutingPrefs.addAll(localPrefs);
      // Only archived routing selectors prove the restored fallback. Missing
      // or malformed settings must not silently borrow the device's active id.
      final preferenceEntry = archive.findFile('preferences.json');
      if (preferenceEntry != null) {
        try {
          final values = jsonDecode(utf8.decode(preferenceEntry.readBytes()!));
          if (values is Map<String, dynamic>) {
            _restoredRoutingPrefs.addAll(values);
          }
        } on Object {
          /* Unknown settings route => do not invent fallback. */
        }
      }
      // Resolve every restored API destination before any credential refill.
      // A pinned embedding source may occur after its consumer in JSONL.
      final routesInput = InputFileStream(filePath);
      Archive? routeArchive;
      try {
        routeArchive = ZipDecoder().decodeStream(routesInput);
        final apiFile = routeArchive.findFile('tables/api_configs.jsonl');
        if (apiFile != null) {
          _restoredRoutes.clear();
          await for (final line in _tableLines(apiFile)) {
            _cancel.check();
            try {
              final row = jsonDecode(line) as Map<String, dynamic>;
              _restoredRoutes[row['config_id'] as String] = {
                for (final column in BackupSecretRoutes.apiColumns)
                  column: row[column],
              };
            } on FormatException {
              /* Invalid row has no proven route. */
            }
          }
        }
      } finally {
        try {
          await routeArchive?.clear();
        } finally {
          await routesInput.close();
        }
      }
      // Select just the known live credential container, never giant inert
      // runtime/block restore JSON. Page rows before retaining credential parts.
      var offset = 0;
      while (true) {
        _cancel.check();
        final rows = await db
            .customSelect(
              'SELECT preset_id, cleaner_api_config_id, '
              "CASE WHEN json_valid(runtime_settings_json) THEN json_extract(runtime_settings_json, '\$.cleaner.postCleanerModel') END AS cleaner_model, "
              "CASE WHEN json_valid(runtime_settings_json) THEN json_extract(runtime_settings_json, '\$.cleaner.postCleanerUseResponsesApi') END AS cleaner_responses, "
              'CASE WHEN json_valid(runtime_settings_json) THEN '
              "json_extract(runtime_settings_json, '\$.cleaner.postCleanerExtraRequestParameters') "
              'END AS cleaner_parameters FROM studio_preset_rows '
              'ORDER BY rowid LIMIT $_batchSize OFFSET $offset',
            )
            .get();
        for (final row in rows) {
          final parameters = BackupSecrets.snapshotParameters(
            row.data['cleaner_parameters'],
          );
          if (parameters is List && parameters.isNotEmpty) {
            localStudioSecrets[row.read<String>('preset_id')] = {
              'cleaner_parameters': parameters,
              'cleaner_destination': BackupSecretRoutes.cleaner(
                row.data,
                _localRoutes,
                _localRoutingPrefs,
              ),
              'cleaner_protocol': BackupSecretRoutes.cleanerRoute(
                row.data,
                _localRoutes,
                _localRoutingPrefs,
              )?['protocol'],
            };
          }
        }
        if (rows.length < _batchSize) break;
        offset += rows.length;
      }
      _cancel.check();
    }

    final tableFiles = archive.files
        .where(
          (f) =>
              f.isFile &&
              f.name.startsWith('tables/') &&
              f.name.endsWith('.jsonl') &&
              !_excludedArchiveTables.contains(
                f.name
                    .substring('tables/'.length)
                    .replaceAll(RegExp(r'\.jsonl$'), ''),
              ),
        )
        .toList();
    final avatarFiles = archive.files
        .where((f) => f.isFile && f.name.startsWith('avatars/'))
        .toList();
    final galleryFiles = archive.files
        .where((f) => f.isFile && f.name.startsWith('gallery/'))
        .toList();

    // Pre-fetch existing columns.
    final existingColumns = <String, Set<String>>{};
    final allTableNames = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'drift_%'",
        )
        .get();
    for (final t in allTableNames) {
      final tName = t.read<String>('name');
      final cols = await db.customSelect("PRAGMA table_info('$tName')").get();
      existingColumns[tName] = cols.map((c) => c.read<String>('name')).toSet();
    }

    const importOrder = [
      'characters',
      'character_revision_rows',
      'chat_sessions',
      'lorebooks',
      'lorebook_use_manifests',
      'lorebook_use_manifest_entries',
      'lorebook_use_acceptance_records',
      'character_knowledge_fact_rows',
      'character_session_baseline_rows',
      'reconciliation_successful_runs',
      'ledger_reconciliation_effects',
      'reconciliation_run_invalidations',
      'ledger_reconciliation_checkpoints',
      'ledger_reconciliation_cleanup_journals',
      'card_evolution_collector_runs',
      'card_evolution_observations',
      'ledger_reconciliation_cursors',
      'rewrite_jobs',
      'rewrite_operations',
      'rewrite_operation_revisions',
      'rewrite_evidence_rows',
      'card_evolution_claims',
      'card_evolution_writer_calls',
      'card_evolution_proposal_runs',
      'applied_canon_transition_rows',
      'canon_transition_fact_refs',
      'session_canon_checkpoint_rows',
      'session_lorebook_evolution_rows',
      'session_lorebook_revision_rows',
    ];
    int rank(ArchiveFile file) {
      final table = file.name
          .substring('tables/'.length)
          .replaceAll(RegExp(r'\.jsonl$'), '');
      final index = importOrder.indexOf(table);
      return index < 0 ? importOrder.length : index;
    }

    tableFiles.sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      return byRank != 0 ? byRank : a.name.compareTo(b.name);
    });

    onProgress?.call('Importing tables...');
    await db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      if (schemaVersion < 12) {
        await _clearAgentOpsStateMissingFromLegacyBackup();
      }
      if (schemaVersion < 14) {
        await _clearMemoryEventRegistryMissingFromLegacyBackup();
      }
      for (final f in tableFiles) {
        _cancel.check();
        // e.g. tables/characters.jsonl → characters
        final tableName = f.name
            .substring('tables/'.length)
            .replaceAll(RegExp(r'\.jsonl$'), '');
        final knownCols = existingColumns[tableName];
        if (knownCols == null) continue;
        onProgress?.call('Importing $tableName...');
        await _importTableFromJsonl(
          f,
          tableName,
          knownCols,
          localSecrets: keysStripped
              ? switch (tableName) {
                  'api_configs' => localApiSecrets,
                  'studio_preset_rows' => localStudioSecrets,
                  _ => null,
                }
              : null,
        );
        // Truncate WAL between tables to keep heap small.
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      }
      if (schemaVersion < 13) {
        await _clearLegacyCollectorCadence();
      }
      await db.applyLegacyStudioRuntimePayloads(_legacyStudioRuntimeRows);
      if (schemaVersion >= 11) await _rebuildSessionLorebookEmbeddingQueue();
    } finally {
      await db.customStatement('PRAGMA foreign_keys = ON');
    }

    onProgress?.call('Restoring avatars...');
    _cancel.check();
    await _restoreAvatarsFromZip(avatarFiles);

    onProgress?.call('Restoring gallery...');
    _cancel.check();
    await _restoreGalleryFromZip(galleryFiles);

    onProgress?.call('Restoring settings...');
    _cancel.check();
    await _restorePreferences(
      archive,
      localSecrets: keysStripped ? localPrefs : null,
    );
  }

  Future<void> _clearAgentOpsStateMissingFromLegacyBackup() =>
      db.transaction(() async {
        for (final table in const [
          'card_evolution_writer_calls',
          'card_evolution_claims',
          'card_evolution_observations',
          'card_evolution_collector_runs',
          'ledger_reconciliation_cursors',
          'ledger_reconciliation_cleanup_journals',
          'ledger_reconciliation_checkpoints',
          'ledger_reconciliation_effects',
          'reconciliation_run_invalidations',
          'reconciliation_successful_runs',
          'lorebook_use_acceptance_records',
          'lorebook_use_manifest_entries',
          'lorebook_use_manifests',
        ]) {
          await db.customStatement('DELETE FROM $table');
        }
      });

  Future<void> _clearLegacyCollectorCadence() => db.transaction(() async {
    await db.customStatement(
      'DELETE FROM card_evolution_writer_calls WHERE claim_id IN '
      "(SELECT id FROM card_evolution_claims WHERE status <> 'completed')",
    );
    await db.customStatement(
      "DELETE FROM card_evolution_claims WHERE status <> 'completed'",
    );
    await db.customStatement('DELETE FROM card_evolution_collector_runs');
    await db.customStatement('DELETE FROM card_evolution_observations');
  });

  Future<void> _clearMemoryEventRegistryMissingFromLegacyBackup() =>
      db.transaction(() async {
        await db.customStatement('DELETE FROM memory_event_link_rows');
        await db.customStatement('DELETE FROM memory_event_source_rows');
        await db.customStatement('DELETE FROM memory_event_rows');
      });

  /// Restores all SharedPreferences from [preferences.json] inside the ZIP.
  /// Keys are written as-is; missing file is silently ignored (v1 legacy or
  /// older backups that pre-date the preferences export).
  Future<void> _restorePreferences(
    Archive archive, {
    Map<String, dynamic>? localSecrets,
  }) => SavedPreferencesWrites.run(
    [
      if (localSecrets != null && localSecrets['pipelineSettings'] is String)
        'pipelineSettings',
    ],
    () async {
      // Missing/malformed preferences must not leave old global auth overrides
      // attached to API/Studio routes replaced by a partial keyless archive.
      if (localSecrets != null && localSecrets['pipelineSettings'] is String) {
        final prefs = await TrackedSharedPreferences.getInstance();
        _cancel.check();
        await prefs.setString(
          'pipelineSettings',
          BackupSecretContainers.discardGlobalOverrides(
                localSecrets['pipelineSettings'],
                BackupSecrets.isSecretField,
              )
              as String,
        );
      }
      final matches = archive.files
          .where((f) => f.isFile && f.name == 'preferences.json')
          .toList();
      if (matches.isEmpty) return;

      final preferencesEntry = matches.first;
      final bytes = preferencesEntry.readBytes();
      preferencesEntry.clear();
      if (bytes == null || bytes.isEmpty) return;

      Map<String, dynamic> map;
      try {
        map = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
      } catch (_) {
        return;
      }

      final intent = SavedPreferencesOwner.process.begin([
        ...map.keys,
        ...?localSecrets?.keys,
      ]);
      try {
        final prefs = await TrackedSharedPreferences.getInstance();
        if (localSecrets != null) {
          for (final entry in BackupSecretContainers.pairUpdates(
            map,
            localSecrets,
            BackupSecrets.isSecretField,
          ).entries) {
            _cancel.check();
            await prefs.setString(entry.key, entry.value as String);
          }
        }
        for (final entry in map.entries) {
          _cancel.check();
          final key = entry.key;
          // Credential-only preferences are deliberately absent from keyless
          // exports. Ignore them even in an incorrectly labelled archive.
          if (localSecrets != null && BackupSecrets.isSecretPref(key)) continue;
          final value = localSecrets == null
              ? entry.value
              : BackupSecrets.refillPref(
                  entry.value,
                  localSecrets[key],
                  key: key,
                );
          try {
            if (value is bool) {
              await prefs.setBool(key, value);
            } else if (value is int) {
              await prefs.setInt(key, value);
            } else if (value is double) {
              await prefs.setDouble(key, value);
            } else if (value is String) {
              await prefs.setString(key, value);
            } else if (value is List) {
              await prefs.setStringList(
                key,
                value.map((e) => e.toString()).toList(),
              );
            }
          } catch (_) {
            // Skip individual keys that fail (e.g. type mismatch from older schema).
          }
        }
      } finally {
        intent.settle();
      }
    },
  );

  /// Imports one `tables/<name>.jsonl` entry, row by row.
  ///
  /// The old path read the whole entry into memory, decoded it into one string,
  /// split that into a list of every line, and then queued every INSERT into a
  /// single batch (plus a second copy in a buffer that was never read) — four
  /// simultaneous copies of a table that runs to hundreds of megabytes in a
  /// chat-heavy library, which is where a restore ran out of memory. Lines are
  /// now streamed and written [_batchSize] at a time, so peak memory is one
  /// chunk plus one batch no matter how big the table is.
  Future<void> _importTableFromJsonl(
    ArchiveFile file,
    String tableName,
    Set<String> knownCols, {
    Map<String, Map<String, dynamic>>? localSecrets,
  }) async {
    try {
      await db.customStatement('DELETE FROM $tableName');
    } catch (_) {}

    // This table is inserted in a specific order (variation rows first), so its
    // lines have to be buffered before anything can be written. It holds one
    // row per acceptance — nothing like the tables the streaming path exists
    // for.
    if (tableName == 'lorebook_use_acceptance_records') {
      final lines = <String>[];
      await for (final line in _tableLines(file)) {
        lines.add(line);
      }
      lines.sort((a, b) => _acceptanceRank(a).compareTo(_acceptanceRank(b)));
      var pending = <String>[];
      for (final line in lines) {
        pending.add(line);
        if (pending.length >= _batchSize) {
          _cancel.check();
          await _insertJsonlRows(tableName, knownCols, pending);
          pending = <String>[];
        }
      }
      await _insertJsonlRows(tableName, knownCols, pending);
      return;
    }

    var pending = <String>[];
    await for (final line in _tableLines(file)) {
      pending.add(line);
      if (pending.length >= _batchSize) {
        _cancel.check();
        await _insertJsonlRows(
          tableName,
          knownCols,
          pending,
          localSecrets: localSecrets,
        );
        pending = <String>[];
      }
    }
    await _insertJsonlRows(
      tableName,
      knownCols,
      pending,
      localSecrets: localSecrets,
    );
  }

  /// Streams the non-empty lines of a `.jsonl` archive entry.
  ///
  /// Entries past [_spillToDiskBytes] are decompressed straight to a temp file
  /// and read back from there: `ArchiveFile` can only hand out its content as
  /// one decompressed buffer it then caches, which for the chat tables is the
  /// allocation that kills the import. Smaller entries take the in-memory path
  /// and are released right after.
  Stream<String> _tableLines(ArchiveFile file) async* {
    final spill = _spillToDisk(file);
    if (spill != null) {
      try {
        yield* spill
            .openRead()
            .transform(const Utf8Decoder(allowMalformed: true))
            .transform(const LineSplitter())
            .where((line) => line.trim().isNotEmpty);
      } finally {
        try {
          if (spill.existsSync()) spill.deleteSync();
        } catch (_) {}
      }
      return;
    }

    try {
      yield* readArchiveFileLines(file).where((l) => l.trim().isNotEmpty);
    } finally {
      // ArchiveFile caches what it decompressed; drop it before the next table.
      file.clear();
    }
  }

  /// Decompresses [file] straight to a temp file when it is too big to hold in
  /// memory, and returns that file.
  ///
  /// Returns null when the entry is small enough to read in memory, or when the
  /// spill could not be written (no temp space, read-only tmp) — the caller
  /// then falls back to the in-memory read, because a hungrier import still
  /// beats a failed restore.
  File? _spillToDisk(ArchiveFile file) {
    if (file.size <= _spillToDiskBytes) return null;

    final spill = File(
      p.join(
        Directory.systemTemp.path,
        'glaze_restore_${DateTime.now().microsecondsSinceEpoch}_'
        '${p.basename(file.name)}',
      ),
    );
    try {
      final sink = OutputFileStream(spill.path);
      try {
        // Streams the inflate straight into the file: nothing but the codec's
        // own window is held in memory.
        file.decompress(sink);
      } finally {
        sink.closeSync();
      }
      file.clear();
      return spill;
    } catch (_) {
      try {
        if (spill.existsSync()) spill.deleteSync();
      } catch (_) {}
      return null;
    }
  }

  static int _acceptanceRank(String line) {
    try {
      final row = jsonDecode(line) as Map<String, dynamic>;
      return row['acceptance_kind'] == 'variation' ? 0 : 1;
    } catch (_) {
      return 2;
    }
  }

  /// Writes one chunk of JSONL rows in a single batch.
  Future<void> _insertJsonlRows(
    String tableName,
    Set<String> knownCols,
    List<String> lines, {
    Map<String, Map<String, dynamic>>? localSecrets,
  }) async {
    if (lines.isEmpty) return;
    _cancel.check();
    await db.batch((batch) {
      for (final line in lines) {
        Map<String, dynamic> row;
        try {
          row = jsonDecode(line) as Map<String, dynamic>;
          _stageLegacyStudioRuntimeRow(tableName, row);
          row = _canonicalizeRow(tableName, row);
          if (localSecrets != null) {
            if (tableName == 'api_configs') {
              _restoredRoutes[row['config_id'] as String] = {
                for (final column in BackupSecretRoutes.apiColumns)
                  column: row[column],
              };
            }
            final local =
                localSecrets[row[BackupSecrets
                    .tableIdentityColumns[tableName]]];
            final runtime = BackupSecretContainers.document(
              row['runtime_settings_json'],
            );
            final cleaner = runtime is Map ? runtime['cleaner'] : null;
            row = BackupSecrets.refillRow(
              tableName,
              row,
              local,
              embeddingRouteMatches:
                  BackupSecretRoutes.flag(row['embedding_use_same'], true) ==
                      BackupSecretRoutes.flag(
                        local?['embedding_use_same'],
                        true,
                      ) &&
                  BackupSecretRoutes.same(
                    BackupSecretRoutes.embedding(
                      row,
                      _restoredRoutes,
                      _restoredRoutingPrefs,
                    ),
                    BackupSecretRoutes.embedding(
                      local,
                      _localRoutes,
                      _localRoutingPrefs,
                    ),
                    BackupSecrets.isSecretField,
                  ),
              cleanerRouteMatches:
                  local?['cleaner_protocol'] != null &&
                  local?['cleaner_protocol'] ==
                      BackupSecretRoutes.cleanerRoute(
                        row,
                        _restoredRoutes,
                        _restoredRoutingPrefs,
                      )?['protocol'] &&
                  BackupSecretRoutes.same(
                    BackupSecretRoutes.cleaner(
                      {
                        ...row,
                        if (cleaner is Map)
                          'cleaner_model': cleaner['postCleanerModel'],
                        if (cleaner is Map)
                          'cleaner_responses':
                              cleaner['postCleanerUseResponsesApi'],
                      },
                      _restoredRoutes,
                      _restoredRoutingPrefs,
                    ),
                    local?['cleaner_destination'] as String?,
                    BackupSecrets.isSecretField,
                  ),
            );
          }
        } catch (_) {
          continue;
        }
        final statement = _insertStatement(tableName, knownCols, row);
        if (statement == null) continue;
        batch.customStatement(statement.$1, statement.$2);
      }
    });
  }

  /// Builds the INSERT for one decoded row, or null when the row carries no
  /// column this build knows about.
  (String, List<dynamic>)? _insertStatement(
    String tableName,
    Set<String> knownCols,
    Map<String, dynamic> row,
  ) {
    final columns = row.keys.where(knownCols.contains).toList();
    if (columns.isEmpty) return null;

    final placeholders = columns.map((_) => '?').join(', ');
    final quotedColumns = columns.map((c) => '"$c"').join(', ');
    final args = <dynamic>[];
    for (final c in columns) {
      final v = row[c];
      args.add(_columnValue(tableName, c, v));
    }
    return (
      'INSERT OR REPLACE INTO $tableName ($quotedColumns) VALUES ($placeholders)',
      args,
    );
  }

  dynamic _columnValue(String tableName, String column, dynamic value) {
    if (tableName == 'embeddings' && column == 'vectors_blob') {
      final bytes = vectorBytesFromJson(value);
      if (bytes != null) return bytes;
    }
    return value is List || value is Map ? jsonEncode(value) : value;
  }

  Future<void> _rebuildSessionLorebookEmbeddingQueue() async {
    await db.transaction(() async {
      await db.customStatement(
        "DELETE FROM embeddings WHERE source_type = 'session_lorebook_entry'",
      );
      await db.delete(db.sessionLorebookEmbeddingJobRows).go();
      final overlays = await db.select(db.sessionLorebookEvolutionRows).get();
      final jobs = SessionLorebookEmbeddingJobRepo(db);
      for (final overlay in overlays) {
        final checkpoint =
            await (db.select(db.sessionCanonCheckpointRows)
                  ..where(
                    (row) => row.chatSessionId.equals(overlay.chatSessionId),
                  )
                  ..orderBy([(row) => OrderingTerm.desc(row.sequence)])
                  ..limit(1))
                .getSingleOrNull();
        if (checkpoint == null) continue;
        await jobs.enqueueInTransaction(
          sessionId: overlay.chatSessionId,
          checkpointId: checkpoint.id,
          lorebookId: overlay.lorebookId,
          entryId: overlay.entryId,
          expectedContentHash: overlay.contentHash,
        );
      }
    });
  }

  Future<void> _importTablesFromJson(
    Map<String, dynamic> tables, {
    void Function(String stage)? onProgress,
  }) async {
    final existingColumns = <String, Set<String>>{};
    final allTableNames = await db
        .customSelect(
          "SELECT name FROM sqlite_master WHERE type='table' "
          "AND name NOT LIKE 'sqlite_%' AND name NOT LIKE 'drift_%'",
        )
        .get();
    for (final t in allTableNames) {
      final tName = t.read<String>('name');
      final cols = await db.customSelect("PRAGMA table_info('$tName')").get();
      existingColumns[tName] = cols.map((c) => c.read<String>('name')).toSet();
    }

    await db.customStatement('PRAGMA foreign_keys = OFF');
    try {
      for (final entry in tables.entries) {
        _cancel.check();
        final tableName = entry.key;
        final rows = entry.value as List<dynamic>;
        if (rows.isEmpty) continue;

        onProgress?.call('Importing $tableName...');

        final knownCols = existingColumns[tableName];
        if (knownCols == null) continue;

        try {
          await db.customStatement('DELETE FROM $tableName');
        } catch (_) {}

        await db.transaction(() async {
          await db.batch((batch) {
            var i = 0;
            for (final row in rows) {
              if ((++i % _batchSize) == 0) _cancel.check();
              final source = Map<String, dynamic>.from(row as Map);
              _stageLegacyStudioRuntimeRow(tableName, source);
              final r = _canonicalizeRow(tableName, source);
              final columns = r.keys.where(knownCols.contains).toList();
              if (columns.isEmpty) continue;
              final placeholders = columns.map((_) => '?').join(', ');
              final quotedColumns = columns.map((c) => '"$c"').join(', ');
              final sql =
                  'INSERT OR REPLACE INTO $tableName ($quotedColumns) VALUES ($placeholders)';
              final args = <dynamic>[];
              for (final c in columns) {
                args.add(_columnValue(tableName, c, r[c]));
              }
              batch.customStatement(sql, args);
            }
          });
        });
        await db.customStatement('PRAGMA wal_checkpoint(TRUNCATE)');
      }
      await db.applyLegacyStudioRuntimePayloads(_legacyStudioRuntimeRows);
    } finally {
      await db.customStatement('PRAGMA foreign_keys = ON');
    }
  }

  Map<String, dynamic> _canonicalizeRow(
    String tableName,
    Map<String, dynamic> row,
  ) {
    try {
      if (tableName == 'api_configs') {
        bool readBool(String key, {required bool fallback}) {
          final value = row[key];
          if (value is bool) return value;
          if (value is num) return value != 0;
          return fallback;
        }

        return {
          ...row,
          'endpoint': EndpointNormalizer.persistedLlmEndpoint(
            raw: row['endpoint']?.toString() ?? '',
            protocol: row['protocol']?.toString() ?? 'openai',
            model: row['model']?.toString() ?? '',
            stream: readBool('stream', fallback: true),
            useResponsesApi: readBool('use_responses_api', fallback: false),
          ),
          'embedding_endpoint': EndpointNormalizer.persistedEmbeddingEndpoint(
            row['embedding_endpoint']?.toString() ?? '',
          ),
        };
      }
      if (tableName == 'studio_preset_rows') {
        final blocks = row['blocks_json'];
        final source = blocks is String ? blocks : jsonEncode(blocks);
        final canonical = <String, dynamic>{
          ...row,
          'blocks_json': StudioPresetCodec.canonicalizeBlocksJson(source),
        };
        if (row.containsKey('agents_json')) {
          final agents = row['agents_json'];
          final agentsSource = agents is String ? agents : jsonEncode(agents);
          canonical['agents_json'] = StudioAgentCodec.canonicalizeAgentsJson(
            agentsSource,
          );
        }
        return canonical;
      }
      if (tableName == 'studio_config_rows') {
        final agents = row['agents_json'];
        final source = agents is String ? agents : jsonEncode(agents);
        return StudioAgentCodec.canonicalizeConfigRow({
          ...row,
          'agents_json': StudioAgentCodec.canonicalizeAgentsJson(source),
        });
      }
    } on Object {
      return row;
    }
    return row;
  }

  void _stageLegacyStudioRuntimeRow(
    String tableName,
    Map<String, dynamic> row,
  ) {
    if (tableName != 'studio_config_rows') return;
    const executionKeys = {
      'agents_json',
      'agents',
      'run_api_config_id',
      'runApiConfigId',
      'expensive_api_config_id',
      'expensiveApiConfigId',
      'cheap_api_config_id',
      'cheapApiConfigId',
      'cleaner_api_config_id',
      'cleanerApiConfigId',
      'max_final_history_messages',
      'maxFinalHistoryMessages',
    };
    if (row.keys.any(executionKeys.contains)) {
      _legacyStudioRuntimeRows.add(Map<String, dynamic>.from(row));
    }
  }

  Future<void> restoreGalleryImages(Map<String, dynamic>? galleryData) async {
    if (galleryData == null) return;

    for (final entry in galleryData.entries) {
      final charId = entry.key;
      final images = entry.value as List<dynamic>;

      final restoredEntries = <Map<String, dynamic>>[];

      for (final img in images) {
        _cancel.check();
        final imgMap = img as Map<String, dynamic>;
        final entryData = imgMap['entry'] as Map<String, dynamic>?;
        final base64Data = imgMap['base64'] as String?;
        if (base64Data == null) continue;

        final ext = extFromEntry(entryData);
        final id =
            entryData?['id'] as String? ??
            'gal_${DateTime.now().millisecondsSinceEpoch}';

        try {
          final savedPath = await imageStorage.saveBytes(
            base64Decode(base64Data),
            'gallery/$charId',
            id,
            ext,
          );
          if (entryData != null) {
            restoredEntries.add({...entryData, 'imagePath': savedPath});
          }
        } catch (_) {}
      }

      if (restoredEntries.isNotEmpty) {
        try {
          await db.customStatement(
            'UPDATE characters SET gallery_json = ? WHERE char_id = ?',
            [jsonEncode(restoredEntries), charId],
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _restoreAvatars(Map<String, dynamic>? avatarsData) async {
    if (avatarsData == null) return;

    final chars = avatarsData['characters'] as Map<String, dynamic>?;
    if (chars != null) {
      for (final e in chars.entries) {
        _cancel.check();
        if (e.value is! String) continue;
        try {
          final bytes = base64Decode(e.value as String);
          final savedPath = await imageStorage.saveAvatar(
            e.key,
            Uint8List.fromList(bytes),
          );
          await db.customStatement(
            'UPDATE characters SET avatar_path = ? WHERE char_id = ?',
            [savedPath, e.key],
          );
        } catch (_) {}
      }
    }

    final personas = avatarsData['personas'] as Map<String, dynamic>?;
    if (personas != null) {
      for (final e in personas.entries) {
        _cancel.check();
        if (e.value is! String) continue;
        try {
          final bytes = base64Decode(e.value as String);
          final savedPath = await imageStorage.saveAvatar(
            e.key,
            Uint8List.fromList(bytes),
          );
          await db.customStatement(
            'UPDATE personas SET avatar_path = ? WHERE persona_id = ?',
            [savedPath, e.key],
          );
        } catch (_) {}
      }
    }
  }

  Future<void> _restoreAvatarsFromZip(List<ArchiveFile> avatarFiles) async {
    for (final f in avatarFiles) {
      _cancel.check();
      // avatars/<id>.png → id
      final base = p.basenameWithoutExtension(f.name);
      if (base.isEmpty) continue;
      try {
        final bytes = f.readBytes();
        f.clear();
        if (bytes == null) continue;
        final savedPath = await imageStorage.saveAvatar(base, bytes);
        if (f.name.startsWith('avatars/characters/') || !f.name.contains('/')) {
          await db.customStatement(
            'UPDATE characters SET avatar_path = ? WHERE char_id = ?',
            [savedPath, base],
          );
        } else if (f.name.startsWith('avatars/personas/')) {
          await db.customStatement(
            'UPDATE personas SET avatar_path = ? WHERE persona_id = ?',
            [savedPath, base],
          );
        }
      } catch (_) {}
    }
  }

  Future<void> _restoreGalleryFromZip(List<ArchiveFile> galleryFiles) async {
    // group by charId (gallery/<charId>/<id>.<ext>)
    final grouped = <String, List<Map<String, dynamic>>>{};
    for (final f in galleryFiles) {
      _cancel.check();
      final rel = f.name.substring('gallery/'.length);
      final parts = rel.split('/');
      if (parts.length < 2) continue;
      final charId = parts.first;
      final filename = parts.last;
      final ext = p.extension(filename).replaceFirst('.', '');
      final id = p.basenameWithoutExtension(filename);
      try {
        final bytes = f.readBytes();
        f.clear();
        if (bytes == null) continue;
        final savedPath = await imageStorage.saveBytes(
          bytes,
          'gallery/$charId',
          id,
          ext.isEmpty ? 'png' : ext,
        );
        grouped.putIfAbsent(charId, () => []).add({
          'id': id,
          'characterId': charId,
          'imagePath': savedPath,
        });
      } catch (_) {}
    }
    for (final e in grouped.entries) {
      try {
        await db.customStatement(
          'UPDATE characters SET gallery_json = ? WHERE char_id = ?',
          [jsonEncode(e.value), e.key],
        );
      } catch (_) {}
    }
  }
}
