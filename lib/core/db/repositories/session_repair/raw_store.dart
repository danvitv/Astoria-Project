part of '../session_repair_repo.dart';

/// Private finite source slices, not a public SQL engine. Every slice includes
/// full raw rows and exact absence/frontier evidence. Query bounds apply BEFORE
/// materialization. No tolerant model mapping, dropped fields or raw SQL errors.
final class _RepairSlice {
  _RepairSlice(
    this.table,
    this.column,
    this.id,
    List<Map<String, Object?>> rows,
  ) : rows = List.unmodifiable(
        (rows.map((r) => Map<String, Object?>.unmodifiable(r)).toList()
          ..sort((a, b) => jsonEncode(a).compareTo(jsonEncode(b)))),
      );
  final TableInfo<Table, dynamic> table;
  final String column, id;
  final List<Map<String, Object?>> rows;
  _RepairSlice withRows(List<Map<String, Object?>> value) =>
      _RepairSlice(table, column, id, value);
}

final class _RepairImage {
  const _RepairImage(this.targetSession, this.supportSession, this.slices);
  final String targetSession, supportSession;
  final List<_RepairSlice> slices;
  String get stamp => _repairHash(
    slices
        .map((s) => [s.table.actualTableName, s.column, s.id, s.rows])
        .toList(),
  );
  List<Map<String, Object?>> rows(TableInfo<Table, dynamic> table) =>
      slices.singleWhere((s) => identical(s.table, table)).rows;
  _RepairImage replacing(
    TableInfo<Table, dynamic> table,
    List<Map<String, Object?>> rows,
  ) => _RepairImage(
    targetSession,
    supportSession,
    List.unmodifiable(
      slices.map((s) => identical(s.table, table) ? s.withRows(rows) : s),
    ),
  );
}

List<dynamic> _repairMessagePayloads(_RepairImage image, AppDatabase db) {
  final storage = image.rows(db.chatMessageStorageRows);
  if (storage.isEmpty) {
    final decoded = jsonDecode(
      image.rows(db.chatSessions).single['messages_json'] as String,
    );
    _repairRequire(decoded is List, SessionRepairIssue.invalidShape);
    return decoded as List<dynamic>;
  }
  _repairRequire(storage.length == 1, SessionRepairIssue.invalidShape);
  final generation = storage.single['active_generation'];
  final expectedCount = storage.single['message_count'];
  _repairRequire(
    generation is int && generation > 0 && expectedCount is int,
    SessionRepairIssue.invalidShape,
  );
  final rows =
      image
          .rows(db.chatMessageRows)
          .where((row) => row['storage_generation'] == generation)
          .toList()
        ..sort(
          (a, b) =>
              (a['position_key'] as int).compareTo(b['position_key'] as int),
        );
  _repairRequire(rows.length == expectedCount, SessionRepairIssue.invalidShape);
  return rows
      .map((row) {
        final decoded = jsonDecode(row['message_json'] as String);
        _repairRequire(
          decoded is Map<String, dynamic> &&
              decoded['id'] == row['message_id'] &&
              decoded['role'] == row['role'] &&
              decoded['timestamp'] == row['message_timestamp'],
          SessionRepairIssue.invalidShape,
        );
        return decoded;
      })
      .toList(growable: false);
}

final class _RepairRawStore {
  const _RepairRawStore(this.db);
  final AppDatabase db;
  static const maxRows = 64,
      maxMessageRows = 4096,
      maxRowBytes = 65536,
      maxImageBytes = 524288;
  String q(String name) {
    _repairRequire(
      RegExp(r'^[a-z_][a-z0-9_]*$').hasMatch(name),
      SessionRepairIssue.invalidShape,
    );
    return '"$name"';
  }

  Future<T> checked<T>(
    bool Function() current,
    Future<T> Function() work,
  ) async {
    _repairRequire(current());
    final result = await work();
    _repairRequire(current());
    return result;
  }

  Variable variable(Object? value) {
    if (value == null) return const Variable<String>(null);
    if (value is String) return Variable<String>(value);
    if (value is int) return Variable<int>(value);
    if (value is double && value.isFinite) return Variable<double>(value);
    throw const _RepairRefused(SessionRepairIssue.invalidShape);
  }

  (String, List<Variable>) exact(Map<String, Object?> row) {
    final clauses = <String>[], args = <Variable>[];
    for (final e in row.entries) {
      clauses.add(
        '${q(e.key)} IS ? COLLATE BINARY AND typeof(${q(e.key)}) = ?',
      );
      args.add(variable(e.value));
      args.add(
        Variable<String>(
          e.value == null
              ? 'null'
              : e.value is String
              ? 'text'
              : e.value is int
              ? 'integer'
              : 'real',
        ),
      );
    }
    return (clauses.join(' AND '), args);
  }

  Future<_RepairSlice> slice(
    TableInfo<Table, dynamic> table,
    String column,
    String id,
    bool Function() current,
  ) async {
    // Message rows replaced one legacy aggregate row. Keep the total image and
    // per-row byte fences, but do not turn the generic 64-row relation bound
    // into an accidental 64-message chat limit.
    final rowLimit = identical(table, db.chatMessageRows)
        ? maxMessageRows
        : maxRows;
    final schema = await checked(
      current,
      () => db
          .customSelect(
            'SELECT name FROM pragma_table_info(?) ORDER BY cid',
            variables: [Variable<String>(table.actualTableName)],
          )
          .get(),
    );
    _repairRequire(
      schema.length == table.$columns.length &&
          schema.every(
            (r) => table.$columns.any((c) => c.name == r.data['name']),
          ),
      SessionRepairIssue.invalidShape,
    );
    final size = table.$columns
        .map((c) => 'coalesce(length(CAST(${q(c.name)} AS BLOB)),0)')
        .join(' + ');
    final sizes = await checked(
      current,
      () => db
          .customSelect(
            'SELECT ($size) AS bytes FROM ${q(table.actualTableName)} WHERE ${q(column)} IS ? COLLATE BINARY LIMIT ${rowLimit + 1}',
            variables: [Variable<String>(id)],
            readsFrom: {table},
          )
          .get(),
    );
    _repairRequire(
      sizes.length <= rowLimit &&
          sizes.every(
            (r) =>
                r.data['bytes'] is int &&
                (r.data['bytes'] as int) <= maxRowBytes,
          ),
      SessionRepairIssue.oversized,
    );
    final order = table.$columns.map((c) => q(c.name)).join(',');
    final rows = await checked(
      current,
      () => db
          .customSelect(
            'SELECT $order FROM ${q(table.actualTableName)} WHERE ${q(column)} IS ? COLLATE BINARY AND ($size) <= $maxRowBytes ORDER BY $order LIMIT ${rowLimit + 1}',
            variables: [Variable<String>(id)],
            readsFrom: {table},
          )
          .get(),
    );
    _repairRequire(
      rows.length == sizes.length,
      SessionRepairIssue.incompleteInspection,
    );
    for (final row in rows) {
      for (final c in table.$columns) {
        final value = row.data[c.name];
        _repairRequire(
          value == null
              ? c.$nullable
              : c.type == DriftSqlType.string
              ? value is String
              : c.type == DriftSqlType.double
              ? value is num && value.isFinite
              : value is int &&
                    (c.type != DriftSqlType.bool || value == 0 || value == 1),
          SessionRepairIssue.invalidShape,
        );
      }
    }
    return _RepairSlice(table, column, id, rows.map((r) => r.data).toList());
  }

  Future<_RepairImage> capture(
    String target,
    String parent,
    bool Function() current,
  ) async {
    _repairRequire(
      _repairId(target) && _repairId(parent),
      SessionRepairIssue.authorityDenied,
    );
    final sessions = await slice(
      db.chatSessions,
      'session_id',
      target,
      current,
    );
    final parents = await slice(db.supportSessions, 'id', parent, current);
    _repairRequire(
      sessions.rows.length == 1 && parents.rows.length == 1,
      SessionRepairIssue.authorityDenied,
    );
    final char = sessions.rows.single['character_id'] as String;
    final specs = <(TableInfo<Table, dynamic>, String, String)>[
      (db.chatMessageStorageRows, 'session_id', target),
      (db.chatMessageRows, 'session_id', target),
      (db.characters, 'char_id', char),
      (db.characterRevisionRows, 'character_id', char),
      (db.trackerRows, 'session_id', target),
      (db.trackerSnapshots, 'session_id', target),
      (db.cardEvolutionCollectorRuns, 'session_id', target),
      (db.cardEvolutionObservations, 'session_id', target),
      (db.cardEvolutionClaims, 'session_id', target),
      (db.cardEvolutionProposalRuns, 'session_id', target),
      (db.cardEvolutionWriterCalls, 'session_id', target),
      (db.rewriteJobs, 'chat_session_id', target),
      (db.rewriteOperations, 'chat_session_id', target),
      (db.appliedCanonTransitionRows, 'character_id', char),
      (db.sessionCanonCheckpointRows, 'chat_session_id', target),
      (db.sessionLorebookRevisionRows, 'chat_session_id', target),
      (db.characterSessionBaselineRows, 'chat_session_id', target),
      (db.characterKnowledgeFactRows, 'chat_session_id', target),
      (db.ledgerReconciliationSuccessfulRuns, 'session_id', target),
      (db.ledgerReconciliationEffects, 'session_id', target),
      (db.ledgerReconciliationRunInvalidations, 'session_id', target),
      (db.ledgerReconciliationCursors, 'session_id', target),
      (db.ledgerReconciliationCheckpoints, 'session_id', target),
      (db.ledgerReconciliationLeases, 'session_id', target),
      (db.lorebookUseAcceptanceRecords, 'session_id', target),
      (db.lorebookUseManifests, 'session_id', target),
      (db.llmCallEventRows, 'session_id', target),
      (db.llmRequestCaptureRows, 'session_id', target),
    ];
    final slices = <_RepairSlice>[sessions, parents];
    var bytes = utf8.encode(jsonEncode([sessions.rows, parents.rows])).length;
    for (final spec in specs) {
      final found = await slice(spec.$1, spec.$2, spec.$3, current);
      bytes += utf8.encode(jsonEncode(found.rows)).length;
      _repairRequire(bytes <= maxImageBytes, SessionRepairIssue.oversized);
      slices.add(found);
    }
    return _RepairImage(target, parent, List.unmodifiable(slices));
  }

  Future<bool> matches(_RepairImage image, bool Function() current) async =>
      (await capture(
        image.targetSession,
        image.supportSession,
        current,
      )).stamp ==
      image.stamp;

  Future<bool> matchesSlice(
    _RepairSlice expected,
    bool Function() current,
  ) async =>
      _repairHash(
        (await slice(
          expected.table,
          expected.column,
          expected.id,
          current,
        )).rows,
      ) ==
      _repairHash(expected.rows);

  /// Undo-only observation, not a change to capture/stamp/Apply guards. The
  /// SAME original parent may advance its activity clock between operations;
  /// every other raw column (including encrypted title and settings) stays exact.
  /// The observed FULL row must then stay exact across confirmation and AEAD.
  Future<_RepairSlice> observeUndoParent(
    _RepairImage original,
    bool Function() current,
  ) async {
    final before = original.rows(db.supportSessions).single;
    final fresh = await slice(
      db.supportSessions,
      'id',
      original.supportSession,
      current,
    );
    _repairRequire(fresh.rows.length == 1, SessionRepairIssue.authorityDenied);
    final latest = fresh.rows.single;
    final time = latest['updated_at'];
    _repairRequire(
      time is int &&
          time >= 0 &&
          time <= 9007199254740991 &&
          time >= (before['updated_at'] as int) &&
          _repairHash([
                {...latest, 'updated_at': before['updated_at']},
              ]) ==
              _repairHash([before]),
      SessionRepairIssue.authorityDenied,
    );
    _repairRequire(await matchesSlice(fresh, current));
    return fresh;
  }

  Future<void> narrowSchema(
    TableInfo<Table, dynamic> table,
    bool Function() current,
  ) async {
    // Neither owned effect target has native triggers or SQL FK edges. Refuse
    // altered schema that could make a selected-row repair a hidden cascade.
    final result = await checked(
      current,
      () => db
          .customSelect(
            "SELECT (SELECT count(*) FROM sqlite_master WHERE type='trigger' AND tbl_name=?) + "
            '(SELECT count(*) FROM pragma_foreign_key_list(?)) + '
            '(SELECT count(*) FROM sqlite_master m, pragma_foreign_key_list(m.name) f '
            'WHERE m.type=\'table\' AND f."table"=?) AS n',
            variables: List.generate(
              3,
              (_) => Variable<String>(table.actualTableName),
            ),
          )
          .getSingle(),
    );
    _repairRequire(
      result.data['n'] == 0,
      SessionRepairIssue.dependentEffectUnsupported,
    );
  }
}
