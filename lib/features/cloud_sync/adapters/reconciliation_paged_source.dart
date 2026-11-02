part of 'ext_blocks_sync_stores.dart';

/// A transaction-scoped DB source. Pages contain exactly one physical
/// row: effects can contain entire knowledge snapshots and must not accumulate.
final class _ReconciliationDatabaseSource implements ReconciliationStateSource {
  _ReconciliationDatabaseSource(this._db, this.sessionId);

  final AppDatabase _db;
  bool _open = true;

  @override
  final String sessionId;

  @override
  int get schemaVersion => 2;

  void close() => _open = false;

  void _requireOpen() {
    if (!_open) throw StateError('Reconciliation export snapshot has closed');
  }

  /// Preflight covers the actual rows a local bulk read consumes, not only the
  /// completed/scrubbed export view. Failed collectors can carry large details.
  Stream<Map<String, dynamic>> readLocalMetadata(
    ReconciliationSection section,
  ) {
    _requireOpen();
    if (section == ReconciliationSection.collectors) {
      return _pages(_db.cardEvolutionCollectorRuns, ['collector_ordinal']);
    }
    return readSection(section);
  }

  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    _requireOpen();
    final Stream<Map<String, dynamic>> rows;
    switch (section) {
      case ReconciliationSection.runs:
        rows = _pages(_db.ledgerReconciliationSuccessfulRuns, ['ordinal']);
      case ReconciliationSection.effects:
        rows = _effects();
      case ReconciliationSection.invalidations:
        rows = _pages(
          _db.ledgerReconciliationRunInvalidations,
          ['run_id', 'cause_message_id', 'reason'],
          normalize: ReconciliationStateSyncStore._invalidationForSync,
        );
      case ReconciliationSection.manifests:
        rows = _pages(_db.lorebookUseManifests, [_manifestSortKey]);
      case ReconciliationSection.manifestEntries:
        rows = _pages(_db.lorebookUseManifestEntries, [_manifestEntrySortKey]);
      case ReconciliationSection.acceptances:
        rows = _pages(_db.lorebookUseAcceptanceRecords, ['acceptance_id']);
      case ReconciliationSection.collectors:
        rows = _pages(
          _db.cardEvolutionCollectorRuns,
          ['collector_ordinal'],
          filter: "status = 'completed'",
          normalize: ReconciliationStateSyncStore._collectorForSync,
        );
      case ReconciliationSection.observations:
        rows = _pages(
          _db.cardEvolutionObservations,
          ['semantic_scope_key'],
          normalize: ReconciliationStateSyncStore._observationForSync,
        );
      case ReconciliationSection.completedClaims:
        rows = _pages(
          _db.cardEvolutionClaims,
          ['input_hash'],
          filter:
              "status = 'completed' AND EXISTS ("
              'SELECT 1 FROM card_evolution_collector_runs AS collector '
              'WHERE collector.session_id = card_evolution_claims.session_id '
              "AND collector.status = 'completed' "
              'AND collector.collector_ordinal = '
              'card_evolution_claims.predecessor_run_ordinal '
              'AND collector.reconciliation_chain_hash = '
              'card_evolution_claims.predecessor_cursor_hash)',
          normalize: ReconciliationStateSyncStore._claimForSync,
        );
    }
    var count = 0;
    await for (final row in rows) {
      _requireOpen();
      if (_isReconciliationMetadata(section) &&
          ++count > ReconciliationJsonCodec.maxRunRows) {
        throw const FormatException(
          'Reconciliation metadata exceeds row budget',
        );
      }
      // Export encoding/fingerprinting and local metadata preflight enforce the
      // exact encoded record budget. Do not serialize their rows a second time.
      // Effects retain their own pre-decode budget check below.
      yield row;
    }
  }

  Stream<Map<String, dynamic>> _effects() async* {
    final repo = LedgerReconciliationRunRepo(_db);
    await for (final json in _pages(_db.ledgerReconciliationSuccessfulRuns, [
      'ordinal',
    ])) {
      ReconciliationJsonCodec.encodeRow(json);
      final run = LedgerReconciliationSuccessfulRunRow.fromJson(json);
      final effect = await repo.readEffect(run.id);
      if (effect == null) continue;
      final encoded = effect.toJson();
      // Check the record budget before decoding its potentially huge states.
      ReconciliationJsonCodec.encodeRow(encoded);
      if (repo.validateEffectRow(run, effect) is ReconciliationEffectValid) {
        yield encoded;
      }
    }
  }

  Stream<Map<String, dynamic>> _pages<D extends DataClass>(
    TableInfo<Table, D> table,
    List<String> order, {
    String? filter,
    Map<String, dynamic> Function(D row)? normalize,
  }) async* {
    // SQLite sorts only scalar keys and physical row IDs once, never all the
    // payloads, and never once per page. Scalar discovery is eight rows at a
    // time. Encode strings as UTF-16 keys: SQLite's UTF-8 binary order otherwise
    // differs from Dart compareTo for supplementary Unicode characters.
    final page = '__reconciliation_export_page_${_nextPageId++}';
    final staging = '${page}_keys';
    final raw = '${page}_raw';
    final columns = [for (var i = 0; i < order.length; i++) 'sort_$i'];
    _requireOpen();
    await _db.customStatement(
      'CREATE TEMP TABLE $page '
      '(sequence INTEGER PRIMARY KEY, source_rowid INTEGER NOT NULL)',
    );
    try {
      await _db.customStatement(
        'CREATE TEMP TABLE $staging (source_rowid INTEGER PRIMARY KEY, '
        '${columns.join(', ')})',
      );
      // First discover this session once using its existing indexes. Paging the
      // raw scalar table by its integer PK cannot re-sort or scan other chats.
      await _db.customStatement(
        'CREATE TEMP TABLE $raw (source_rowid INTEGER PRIMARY KEY, '
        '${columns.join(', ')})',
      );
      await _db.customStatement(
        'INSERT INTO $raw (source_rowid, ${columns.join(', ')}) '
        'SELECT rowid, ${order.join(', ')} FROM ${table.actualTableName} '
        'WHERE session_id = ? ${filter == null ? '' : 'AND ($filter)'}',
        [sessionId],
      );
      int? physicalCursor;
      while (true) {
        _requireOpen();
        final metadata = await _db
            .customSelect(
              'SELECT source_rowid, ${columns.join(', ')} FROM $raw '
              '${physicalCursor == null ? '' : 'WHERE source_rowid > ?'} '
              'ORDER BY source_rowid LIMIT 8',
              variables: [
                if (physicalCursor != null) Variable.withInt(physicalCursor),
              ],
            )
            .get();
        if (metadata.isEmpty) break;
        await _db.batch((batch) {
          for (final row in metadata) {
            batch.customStatement(
              'INSERT INTO $staging (source_rowid, ${columns.join(', ')}) '
              'VALUES (${List.filled(columns.length + 1, '?').join(', ')})',
              [
                row.read<int>('source_rowid'),
                for (final column in columns)
                  _utf16SortKey(row.data[column] as Object),
              ],
            );
          }
        });
        physicalCursor = metadata.last.read<int>('source_rowid');
      }
      await _db.customStatement('DROP TABLE $raw');
      await _db.customStatement(
        'INSERT INTO $page (source_rowid) '
        'SELECT source_rowid FROM $staging '
        'ORDER BY ${columns.join(', ')}, source_rowid',
      );
      await _db.customStatement('DROP TABLE $staging');
      var cursor = 0;
      while (true) {
        _requireOpen();
        final row = await _db
            .customSelect(
              'SELECT source.*, page.sequence AS __page_sequence '
              'FROM $page AS page JOIN ${table.actualTableName} AS source '
              'ON source.rowid = page.source_rowid '
              'WHERE page.sequence > ? ORDER BY page.sequence LIMIT 1',
              variables: [Variable.withInt(cursor)],
            )
            .getSingleOrNull();
        _requireOpen();
        if (row == null) return;
        cursor = row.read<int>('__page_sequence');
        final mapped = await table.map(row.data);
        yield normalize?.call(mapped) ?? mapped.toJson();
      }
    } finally {
      await _db.customStatement('DROP TABLE IF EXISTS $raw');
      await _db.customStatement('DROP TABLE IF EXISTS $staging');
      await _db.customStatement('DROP TABLE IF EXISTS $page');
    }
  }

  static var _nextPageId = 0;

  static Object _utf16SortKey(Object value) => value is String
      ? value.codeUnits
            .map((unit) => unit.toRadixString(16).padLeft(4, '0'))
            .join()
      : value;

  // Match the legacy Dart CONCAT keys, not numeric multi-column ordering.
  // In particular entryOrder 1, 10, 2 is intentional wire compatibility.
  static const _manifestSortKey =
      "message_id || char(31) || CAST(swipe_id AS TEXT) || char(31) || "
      'CAST(agent_swipe_id AS TEXT)';
  static const _manifestEntrySortKey =
      '$_manifestSortKey || char(31) || lorebook_id || char(31) || '
      'entry_id || char(31) || CAST(entry_order AS TEXT)';
}

final class _BoundedReconciliationSource implements ReconciliationStateSource {
  _BoundedReconciliationSource(this._source);
  final ReconciliationStateSource _source;
  int _metadataBytes = 0;
  @override
  String get sessionId => _source.sessionId;
  @override
  int get schemaVersion => _source.schemaVersion;
  @override
  Stream<Map<String, dynamic>> readSection(
    ReconciliationSection section,
  ) async* {
    await for (final row in _source.readSection(section)) {
      final bytes = ReconciliationJsonCodec.encodeRow(row);
      if (_isReconciliationMetadata(section)) {
        _metadataBytes += bytes.length;
        if (_metadataBytes > ReconciliationJsonCodec.maxMetadataBytes) {
          throw const FormatException(
            'Reconciliation metadata exceeds byte budget',
          );
        }
      }
      yield row;
    }
  }
}

bool _isReconciliationMetadata(ReconciliationSection section) =>
    section == ReconciliationSection.runs ||
    section == ReconciliationSection.invalidations ||
    section == ReconciliationSection.collectors;

Future<List<Map<String, dynamic>>> _readReconciliationMetadata(
  ReconciliationStateSource source,
  ReconciliationSection section,
) async {
  final rows = <Map<String, dynamic>>[];
  await for (final row in source.readSection(section)) {
    if (rows.length == ReconciliationJsonCodec.maxRunRows) {
      throw const FormatException('Reconciliation metadata exceeds row budget');
    }
    // Normalization sorts/maps its own copies, never mutates the replay source.
    rows.add(Map<String, dynamic>.from(row));
  }
  return rows;
}
