part of 'history_index_worker.dart';

final class _DigestSink implements Sink<Digest> {
  Digest? digest;
  @override
  void add(Digest value) => digest = value;
  @override
  void close() {}
}

final class _HistoryBuild {
  _HistoryBuild(this.session, this.token, Map<String, Object?> generation)
    : incarnation = generation['incarnation'] as int,
      revision = generation['revision'] as int,
      rowid = generation['source_rowid'] as int,
      sourceType = generation['source_type'] as String,
      storageGeneration = generation['storage_generation'] as int? {
    hash = sha256.startChunkedConversion(digest);
  }
  final String session, token;
  final int incarnation, revision, rowid;
  final String sourceType;
  final int? storageGeneration;
  final framer = HistoryJsonFramer();
  int rowCursor = 0;
  int sourceBytes = 0;
  int get checkpoint => sourceType == 'rows' ? rowCursor : framer.offset;
  // Closed by close() on success, cancellation, invalidation and failure.
  // ignore: close_sinks
  final digest = _DigestSink();
  // ignore: close_sinks
  late final ByteConversionSink hash;
  bool _closed = false;
  void close() {
    if (!_closed) {
      _closed = true;
      hash.close();
    }
  }

  int units = 0, active = 0;
  bool pruning = true;
}

extension _HistoryIndexBuild on _HistoryIndexWorker {
  Map<String, Object?> _step(
    _HistoryBuild build,
    HistoryNativeDeadline deadline,
  ) {
    final generation = _generation(build.session);
    if (generation == null ||
        generation['incarnation'] != build.incarnation ||
        generation['revision'] != build.revision ||
        generation['checkpoint'] != build.checkpoint ||
        generation['source_type'] != build.sourceType ||
        generation['storage_generation'] != build.storageGeneration) {
      throw StateError('History generation changed');
    }
    // Pruning is bounded and explicit too. No unbounded DELETE of a huge mirror
    // inside a model request. A changed generation never makes old rows readable.
    if (build.pruning) {
      db.execute(
        'DELETE FROM history_message_units WHERE rowid IN (SELECT rowid '
        'FROM history_message_units WHERE session_id=? LIMIT 128)',
        [build.session],
      );
      build.pruning = db.updatedRows != 0;
      return {
        'status': 'incomplete',
        'checkpoint': 0,
        'bytes': 0,
        'candidates': 0,
      };
    }
    if (build.sourceType == 'rows') {
      return _stepRows(build, deadline);
    }
    final blob = HistoryBlobRead(db.handle.cast(), build.rowid);
    var bytesRead = 0, candidates = 0;
    try {
      deadline.check();
      final left = blob.length - build.framer.offset;
      if (left < 0) throw StateError('History changed');
      if (left > 0) {
        final bytes = blob.read(build.framer.offset, min(left, 8192));
        bytesRead = bytes.length;
        deadline.check();
        build.hash.add(bytes);
        build.framer.add(bytes, (raw) {
          deadline.check();
          _appendUnit(build, raw);
          candidates++;
        });
      }
      final finished = build.framer.offset == blob.length;
      if (finished) {
        build.framer.finish();
        build.close();
        final integrity = _mac([
          build.session,
          build.incarnation,
          build.revision,
          build.units,
          build.active,
          blob.length,
          build.digest.digest.toString(),
        ]);
        db.execute(
          "UPDATE history_source_generations SET state='ready',checkpoint=?,unit_count=?,"
          'active_count=?,integrity=? WHERE session_id=? AND incarnation=? AND revision=?',
          [
            build.framer.offset,
            build.units,
            build.active,
            integrity,
            build.session,
            build.incarnation,
            build.revision,
          ],
        );
        _ready[build.session] = _HistorySeal(
          build.incarnation,
          build.revision,
          build.units,
          build.active,
          integrity,
          build.token,
        );
        _build = null;
      } else {
        db.execute(
          'UPDATE history_source_generations SET checkpoint=? WHERE session_id=?',
          [build.framer.offset, build.session],
        );
      }
      return {
        'status': finished ? 'ready' : 'incomplete',
        'checkpoint': build.framer.offset,
        'bytes': bytesRead,
        'candidates': candidates,
      };
    } finally {
      blob.close();
    }
  }

  Map<String, Object?> _stepRows(
    _HistoryBuild build,
    HistoryNativeDeadline deadline,
  ) {
    final storageGeneration = build.storageGeneration;
    if (storageGeneration == null) throw const FormatException();
    final rows = db.select(
      'SELECT position_key,message_json FROM chat_message_rows '
      'WHERE session_id=? AND storage_generation=? AND position_key>? '
      'ORDER BY position_key LIMIT 32',
      [build.session, storageGeneration, build.rowCursor],
    );
    var bytesRead = 0;
    for (final row in rows) {
      deadline.check();
      final text = row['message_json'];
      final position = row['position_key'];
      if (text is! String || position is! int || position <= build.rowCursor) {
        throw const FormatException();
      }
      final raw = utf8.encode(text);
      if (raw.length > 65536) throw const FormatException();
      build.hash.add(utf8.encode('${raw.length}:'));
      build.hash.add(raw);
      _appendUnit(build, text);
      build.rowCursor = position;
      build.sourceBytes += raw.length;
      bytesRead += raw.length;
    }
    final finished = rows.length < 32;
    if (finished) {
      build.close();
      final integrity = _mac([
        build.session,
        build.incarnation,
        build.revision,
        build.units,
        build.active,
        build.sourceBytes,
        build.digest.digest.toString(),
      ]);
      db.execute(
        "UPDATE history_source_generations SET state='ready',checkpoint=?,unit_count=?,"
        'active_count=?,integrity=? WHERE session_id=? AND incarnation=? AND revision=?',
        [
          build.rowCursor,
          build.units,
          build.active,
          integrity,
          build.session,
          build.incarnation,
          build.revision,
        ],
      );
      _ready[build.session] = _HistorySeal(
        build.incarnation,
        build.revision,
        build.units,
        build.active,
        integrity,
        build.token,
      );
      _build = null;
    } else {
      db.execute(
        'UPDATE history_source_generations SET checkpoint=? WHERE session_id=?',
        [build.rowCursor, build.session],
      );
    }
    return {
      'status': finished ? 'ready' : 'incomplete',
      'checkpoint': build.rowCursor,
      'bytes': bytesRead,
      'candidates': rows.length,
    };
  }

  void _appendUnit(_HistoryBuild build, String raw) {
    final message = HistoryMessageUnit(raw);
    final ordinal = message.eligible ? build.active++ : null;
    final material = <Object?>[
      build.session,
      build.incarnation,
      build.revision,
      build.units,
      ordinal,
      message.id,
      raw,
    ];
    // Unique identity index detects ALL duplicates, including excluded units.
    final integrity = _mac(material);
    final metadata = <Object?>[
      ...material.take(6),
      message.nativeSwipe == null ? null : message.swipe,
      message.nativeAgentSwipe == null ? null : message.agentSwipe,
      message.role,
      integrity,
    ];
    db.execute(
      'INSERT INTO history_message_units (session_id,incarnation,revision,native_order,'
      'active_ordinal,message_id,raw_json,integrity,swipe_id,agent_swipe_id,role,anchor_integrity) '
      'VALUES (?,?,?,?,?,?,?,?,?,?,?,?)',
      [
        ...material,
        integrity,
        ...metadata.skip(6).take(3),
        _mac(['anchor-v1', ...metadata]),
      ],
    );
    build.units++;
  }
}
