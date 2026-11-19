import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:sqlite3/sqlite3.dart';

import 'history_json_framer.dart';
import 'history_message_unit.dart';
import 'history_index_schema.dart';
import 'sqlite_history_io.dart';

part 'history_index_build.dart';

/// Installed by both native construction paths on the ORIGINAL sqlite.Database.
/// A direct-only fixed command, not a handle getter, SQL/path API or model tool.
abstract final class NativeHistoryIndexWorker {
  static void install(Database source) {
    final worker = _HistoryIndexWorker(source);
    source.createFunction(
      functionName: 'astoria_history_index',
      argumentCount: const AllowedArgumentCount(3),
      directOnly: true,
      function: worker.command,
    );
    source.createFunction(
      functionName: 'astoria_history_unit_valid',
      argumentCount: const AllowedArgumentCount(8),
      directOnly: true,
      function: worker.verify,
    );
    source.createFunction(
      functionName: 'astoria_history_anchor_valid',
      argumentCount: const AllowedArgumentCount(11),
      directOnly: true,
      function: worker.verifyAnchor,
    );
  }
}

final class _HistoryIndexWorker {
  _HistoryIndexWorker(this.db)
    : _key = List.generate(32, (_) => Random.secure().nextInt(256)) {
    // Hook only retires in-memory trust; never writes its invoking connection.
    // Subscription and worker belong to the actual Database's own lifetime.
    db.updatesSync.listen((update) {
      if (!_writing &&
          (update.tableName.startsWith('history_') ||
              update.tableName == 'chat_sessions' ||
              update.tableName == 'chat_message_storage_rows' ||
              update.tableName == 'chat_message_rows' ||
              update.tableName == 'characters')) {
        _ready.clear();
        _discardBuild();
      }
    });
  }
  final Database db;
  final List<int> _key;
  final Map<String, _HistorySeal> _ready = {};
  _HistoryBuild? _build;
  int? _external, _schema;
  String? _schemaDigest;
  bool _writing = false;

  void _discardBuild() {
    _build?.close();
    _build = null;
  }

  String _mac(List<Object?> values) =>
      Hmac(sha256, _key).convert(utf8.encode(jsonEncode(values))).toString();

  void _fence() {
    final stamp = db
        .select(
          'SELECT data_version AS v, schema_version AS s FROM '
          'pragma_data_version, pragma_schema_version',
        )
        .single;
    final version = stamp['v'] as int, schema = stamp['s'] as int;
    if (_external != null && version != _external) {
      _ready.clear();
      _discardBuild();
    }
    if (_schema != schema) {
      if (_schema != null) {
        _ready.clear();
        _discardBuild();
      }
      final rows = db.select(
        "SELECT name,CASE WHEN octet_length(sql)<=8192 THEN sql END AS sql FROM sqlite_master WHERE name LIKE 'history_%' "
        "OR name LIKE 'idx_history_%' OR name LIKE 'idx_navigation_%' OR name='idx_trackers_session_scope' ORDER BY name LIMIT 64",
      );
      final names = rows.map((r) => r['name']).toSet();
      if (!names.containsAll(const {
        'history_index_clock',
        'history_source_generations',
        'history_message_units',
        'history_source_insert',
        'history_source_update',
        'history_source_delete',
        'history_character_insert',
        'history_character_update',
        'history_character_delete',
        'idx_history_units_active',
        'idx_history_units_identity',
      })) {
        throw StateError('History index schema unavailable');
      }
      final actual = {for (final row in rows) row['name']: row['sql']};
      for (final entry in historyIndexTriggers.entries) {
        final sql = actual[entry.key];
        if (sql is! String ||
            normalizeHistorySchema(sql) !=
                normalizeHistorySchema(entry.value)) {
          _ready.clear();
          _discardBuild();
          throw StateError('History invalidation schema unavailable');
        }
      }
      const indexes = {
        'idx_history_units_active':
            'CREATE UNIQUE INDEX idx_history_units_active ON history_message_units (session_id, incarnation, revision, active_ordinal)',
        'idx_history_units_identity':
            'CREATE UNIQUE INDEX idx_history_units_identity ON history_message_units (session_id, incarnation, revision, message_id)',
        'idx_trackers_session_scope':
            'CREATE INDEX idx_trackers_session_scope ON tracker_rows (session_id, scope)',
      };
      for (final entry in {...indexes, ...sourceNavigationIndexes}.entries) {
        final sql = actual[entry.key];
        if (sql is! String ||
            normalizeHistorySchema(sql) !=
                normalizeHistorySchema(entry.value)) {
          throw StateError('History address index unavailable');
        }
      }
      final clockIndex = db.select(
        "SELECT name,\"unique\" AS is_unique FROM pragma_index_list('tracker_rows') WHERE name='sqlite_autoindex_tracker_rows_1' LIMIT 1",
      );
      final clockColumns = db.select(
        "SELECT name,\"key\" AS is_key FROM pragma_index_xinfo('sqlite_autoindex_tracker_rows_1') ORDER BY seqno LIMIT 4",
      );
      if (clockIndex.length != 1 ||
          clockIndex.single['is_unique'] != 1 ||
          clockColumns.length != 3 ||
          clockColumns[0]['name'] != 'session_id' ||
          clockColumns[1]['name'] != 'name' ||
          clockColumns[2]['name'] != null ||
          clockColumns[2]['is_key'] != 0) {
        throw StateError('Fixed clock address index unavailable');
      }
      final storage = actual['history_message_units'];
      final columns = db.select(
        "SELECT name,type FROM pragma_table_info('history_message_units') ORDER BY cid LIMIT 13",
      );
      final types = {for (final row in columns) row['name']: row['type']};
      if (storage is! String ||
          !normalizeHistorySchema(
            storage,
          ).contains('check (octet_length(raw_json) <= 65536)') ||
          columns.length != 12 ||
          types['swipe_id'] != 'INTEGER' ||
          types['agent_swipe_id'] != 'INTEGER' ||
          types['role'] != 'TEXT' ||
          types['anchor_integrity'] != 'TEXT') {
        throw StateError('History physical bounds unavailable');
      }
      final digest = sha256
          .convert(
            utf8.encode(
              jsonEncode(rows.map((r) => [r['name'], r['sql']]).toList()),
            ),
          )
          .toString();
      if (_schemaDigest != null && digest != _schemaDigest) {
        _ready.clear();
        _discardBuild();
        throw StateError('History index schema changed');
      }
      _schemaDigest ??= digest;
      _schema = schema;
    }
    _external = version;
  }

  Map<String, Object?>? _generation(String session) {
    final rows = db.select(
      '''SELECT g.*,
        CASE WHEN storage.session_id IS NULL THEN s.rowid ELSE storage.rowid END AS source_rowid,
        CASE WHEN storage.session_id IS NULL THEN typeof(s.messages_json) ELSE 'rows' END AS source_type,
        storage.active_generation AS storage_generation
      FROM history_source_generations g
      INNER JOIN chat_sessions s ON s.session_id=g.session_id
      LEFT JOIN chat_message_storage_rows storage ON storage.session_id=s.session_id '''
      'WHERE g.session_id=? AND g.alive=1 LIMIT 1',
      [session],
    );
    return rows.isEmpty ? null : Map<String, Object?>.from(rows.single);
  }

  bool _matches(_HistorySeal seal, Map<String, Object?> generation) =>
      generation['incarnation'] == seal.incarnation &&
      generation['revision'] == seal.revision &&
      generation['state'] == 'ready' &&
      generation['unit_count'] == seal.units &&
      generation['active_count'] == seal.active &&
      generation['integrity'] == seal.integrity;

  String command(List<Object?> args) {
    HistoryNativeDeadline? deadline;
    try {
      if (args.length != 3 ||
          args[0] is! String ||
          args[1] is! String ||
          args[2] is! String ||
          (args[1] as String).length > 256 ||
          (args[2] as String).length > 64) {
        throw StateError('Invalid command');
      }
      final operation = args[0],
          session = args[1] as String,
          token = args[2] as String;
      if (!const {
        'attest',
        'observe',
        'start',
        'resume',
        'step',
        'abort',
      }.contains(operation)) {
        throw StateError('Invalid command');
      }
      deadline = HistoryNativeDeadline(
        db.handle.cast(),
        const Duration(milliseconds: 250),
      );
      _fence();
      if (operation == 'attest') {
        if (session.isNotEmpty || token.isNotEmpty) {
          throw StateError('Invalid command');
        }
        return jsonEncode({'status': 'ready'});
      }
      if (operation == 'observe') {
        if (token.isNotEmpty) throw StateError('Invalid command');
        final generation = _generation(session), seal = _ready[session];
        final ready =
            generation != null && seal != null && _matches(seal, generation);
        return jsonEncode({
          'status': ready ? 'ready' : 'incomplete',
          if (generation != null) 'incarnation': generation['incarnation'],
          if (generation != null) 'revision': generation['revision'],
          if (ready) 'activeCount': seal.active,
          if (ready) 'integrity': seal.integrity,
        });
      }
      // These commands are local maintenance ONLY. The owning repo rejects an
      // ambient transaction and reserves the original executor before invoking.
      if (db.autocommit || !RegExp(r'^[0-9a-f]{64}$').hasMatch(token)) {
        throw StateError('Unreserved maintenance');
      }
      _writing = true;
      if (operation == 'abort') {
        if (_build?.token == token && _build?.session == session) {
          _discardBuild();
        }
        if (_ready[session]?.token == token) {
          _ready.remove(session);
          db.execute(
            "UPDATE history_source_generations SET state='incomplete',integrity=NULL WHERE session_id=?",
            [session],
          );
        }
        return jsonEncode({'status': 'incomplete'});
      }
      if (operation == 'start') {
        if (_build != null) throw StateError('Maintenance busy');
        final generation = _generation(session);
        if (generation == null ||
            !const {'text', 'rows'}.contains(generation['source_type'])) {
          throw const FormatException();
        }
        _ready.remove(session);
        db.execute(
          "UPDATE history_source_generations SET state='incomplete',checkpoint=0,"
          'unit_count=0,active_count=0,integrity=NULL WHERE session_id=?',
          [session],
        );
        _build = _HistoryBuild(session, token, generation);
        return jsonEncode({
          'status': 'incomplete',
          'checkpoint': 0,
          'bytes': 0,
          'candidates': 0,
        });
      }
      if (operation == 'resume') {
        final build = _build, generation = _generation(session);
        if (build == null ||
            build.token != token ||
            build.session != session ||
            generation == null ||
            generation['incarnation'] != build.incarnation ||
            generation['revision'] != build.revision ||
            generation['checkpoint'] != build.checkpoint ||
            generation['source_rowid'] != build.rowid ||
            generation['source_type'] != build.sourceType ||
            generation['storage_generation'] != build.storageGeneration) {
          _discardBuild();
          return jsonEncode({'status': 'incomplete', 'restart': true});
        }
        return jsonEncode({
          'status': 'incomplete',
          'checkpoint': build.checkpoint,
        });
      }
      final build = _build;
      if (build == null || build.token != token || build.session != session) {
        throw StateError('Invalid maintenance');
      }
      final result = _step(build, deadline);
      deadline.check();
      return jsonEncode(result);
    } on FormatException {
      _discardBuild();
      _ready.remove(args[1]);
      return jsonEncode({
        'status': 'unsupported',
        'bytes': 0,
        'candidates': 0,
        'continuable': false,
      });
    } on SqliteException catch (error) {
      _discardBuild();
      _ready.remove(args[1]);
      return jsonEncode({
        'status': error.resultCode == 19 ? 'unsupported' : 'incomplete',
        'bytes': 0,
        'candidates': 0,
        'continuable': false,
      });
    } catch (_) {
      _discardBuild();
      _ready.remove(args[1]);
      return jsonEncode({
        'status': 'incomplete',
        'bytes': 0,
        'candidates': 0,
        'continuable': false,
      });
    } finally {
      _writing = false;
      deadline?.close();
    }
  }

  int verify(List<Object?> args) {
    try {
      if (args.length != 8 ||
          args[0] is! String ||
          args[5] is! String ||
          args[6] is! String ||
          args[7] is! String ||
          utf8.encode(args[6] as String).length > 65536) {
        return 0;
      }
      _fence();
      final session = args[0] as String,
          seal = _ready[session],
          generation = _generation(session);
      if (seal == null ||
          generation == null ||
          !_matches(seal, generation) ||
          args[1] != seal.incarnation ||
          args[2] != seal.revision ||
          _mac(args.take(7).toList()) != args[7]) {
        return 0;
      }
      return 1;
    } catch (_) {
      return 0;
    }
  }

  /// Authenticates only bounded metadata, including its full raw-unit MAC.
  /// No raw_json read/decode occurs in discovery or cross-domain references.
  int verifyAnchor(List<Object?> args) {
    try {
      if (args.length != 11 ||
          args[0] is! String ||
          args[5] is! String ||
          utf8.encode(args[5] as String).length > 256 ||
          args[1] is! int ||
          args[2] is! int ||
          args[3] is! int ||
          (args[4] != null && (args[4] is! int || (args[4] as int) < 0)) ||
          [
            args[6],
            args[7],
          ].any((v) => v != null && (v is! int || v < 0 || v > 1000000)) ||
          !const ['user', 'assistant', 'system'].contains(args[8]) ||
          args[9] is! String ||
          (args[9] as String).length != 64 ||
          args[10] is! String ||
          (args[10] as String).length != 64) {
        return 0;
      }
      _fence();
      final seal = _ready[args[0]], generation = _generation(args[0] as String);
      if (seal == null ||
          generation == null ||
          !_matches(seal, generation) ||
          args[1] != seal.incarnation ||
          args[2] != seal.revision ||
          _mac(['anchor-v1', ...args.take(10)]) != args[10]) {
        return 0;
      }
      return 1;
    } catch (_) {
      return 0;
    }
  }
}

final class _HistorySeal {
  const _HistorySeal(
    this.incarnation,
    this.revision,
    this.units,
    this.active,
    this.integrity,
    this.token,
  );
  final int incarnation, revision, units, active;
  final String integrity;
  final String token;
}
