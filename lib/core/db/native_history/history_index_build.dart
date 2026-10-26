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
      rowid = generation['source_rowid'] as int {
    hash = sha256.startChunkedConversion(digest);
  }
  final String session, token;
  final int incarnation, revision, rowid;
  final framer = HistoryJsonFramer();
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
        generation['checkpoint'] != build.framer.offset) {
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
            [...material, integrity, ...metadata.skip(6).take(3), _mac(['anchor-v1', ...metadata])],
          );
          build.units++;
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
}
