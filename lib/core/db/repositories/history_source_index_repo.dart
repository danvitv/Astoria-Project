import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:drift/drift.dart';

import '../database_transaction_guard.dart';

enum HistoryIndexMaintenanceState { ready, incomplete, unsupported }

final class HistoryIndexMaintenanceResult {
  const HistoryIndexMaintenanceResult(
    this.state,
    this.bytes,
    this.candidates,
    this.steps,
  );
  final HistoryIndexMaintenanceState state;
  final int bytes, candidates, steps;
}

final class HistoryIndexLocalCandidate {
  const HistoryIndexLocalCandidate(
    this.sessionId,
    this.label,
    this.sessionIndex,
    this.state,
  );
  final String sessionId, label;
  final int sessionIndex;
  final HistoryIndexMaintenanceState state;
}

final class HistoryIndexLocalPage {
  const HistoryIndexLocalPage(this.items, this.nextRowid);
  final List<HistoryIndexLocalCandidate> items;
  final int? nextRowid;
}

/// AppDatabase-owned capability. No raw handle, arbitrary SQL or model operation.
/// Native UDFs execute synchronously ON its retained connection, queued through
/// the same Drift reservation as the audited writer-excluding support ROOT.
final class HistorySourceIndexRepo {
  HistorySourceIndexRepo({
    required DatabaseConnectionUser database,
    required bool Function() isCurrent,
    required Future<void> Function(Future<void> Function()) joinLifetime,
  }) : _db = database,
       _current = isCurrent,
       _join = joinLifetime;
  final DatabaseConnectionUser _db;
  final bool Function() _current;
  final Future<void> Function(Future<void> Function()) _join;
  (String, String)? _paused;

  /// Explicit local picker/status only. Candidate keyset is bounded BEFORE
  /// eligibility; no game bodies, grants, model registry or model actions.
  Stream<HistoryIndexLocalPage> watchLocalPage({
    required int afterRowid,
    required Set<ResultSetImplementation<HasResultSet, dynamic>> readsFrom,
  }) {
    if (afterRowid < 0) throw ArgumentError.value(afterRowid);
    return _db
        .customSelect(
          '''
      SELECT s.candidate_rowid,
        CASE WHEN c.hidden=0 AND octet_length(s.session_id)<=256 THEN s.session_id END AS source_id,
        CASE WHEN octet_length(c.name)<=1024 THEN c.name END AS label,
        s.session_index,
        CASE WHEN c.hidden=0 AND octet_length(s.session_id)<=256
          THEN astoria_history_index('observe',s.session_id,'') END AS observation
      FROM (SELECT rowid AS candidate_rowid,session_id,character_id,session_index
        FROM chat_sessions WHERE rowid>? ORDER BY rowid LIMIT 16) s
      LEFT JOIN characters c ON c.char_id=s.character_id
      ORDER BY s.candidate_rowid
    ''',
          variables: [Variable.withInt(afterRowid)],
          readsFrom: readsFrom,
        )
        .watch()
        .map((rows) {
          if (!_current())
            throw StateError('Original native owner unavailable');
          final items = <HistoryIndexLocalCandidate>[];
          for (final row in rows) {
            final id = row.data['source_id'],
                observation = row.data['observation'];
            if (id is! String ||
                id.isEmpty ||
                observation is! String ||
                observation.length > 512)
              continue;
            final value = jsonDecode(observation);
            if (value is! Map<String, dynamic>)
              throw StateError('Invalid native history status');
            final state = switch (value['status']) {
              'ready' => HistoryIndexMaintenanceState.ready,
              'unsupported' => HistoryIndexMaintenanceState.unsupported,
              _ => HistoryIndexMaintenanceState.incomplete,
            };
            items.add(
              HistoryIndexLocalCandidate(
                id,
                row.data['label'] as String? ?? 'Источник',
                row.read<int>('session_index'),
                state,
              ),
            );
          }
          return HistoryIndexLocalPage(
            List.unmodifiable(items),
            rows.length < 16 ? null : rows.last.read<int>('candidate_rowid'),
          );
        });
  }

  Future<bool> attestNavigation() async {
    if (!_current()) return false;
    final value = await _command('attest', '', '');
    return _current() && value['status'] == 'ready';
  }

  Future<Map<String, Object?>> observe(String session) async {
    if (!_current()) throw StateError('Native history unavailable');
    final value = await _command('observe', session, '');
    if (!_current()) throw StateError('Native history unavailable');
    return value;
  }

  /// Explicit LOCAL maintenance, never reachable through source model tools.
  /// A budget pause can resume the exact original worker's bounded parser/hash
  /// state after generation/checkpoint validation. A new owner/restart rebuilds:
  /// a persisted byte offset alone cannot authenticate a partial JSON snapshot.
  /// maxSteps includes pruning. Stop is checked BETWEEN bounded native commands;
  /// deadline progress callbacks cancel SQL VM work, not asynchronous waiting.
  Future<HistoryIndexMaintenanceResult> maintain({
    required String sessionId,
    required bool Function() isCurrent,
    int maxSteps = 256,
    Duration deadline = const Duration(seconds: 30),
  }) async {
    if (maxSteps < 1 ||
        maxSteps > 4096 ||
        deadline <= Duration.zero ||
        deadline > const Duration(seconds: 180)) {
      throw ArgumentError('Invalid local history budget');
    }
    var token = List.generate(
      32,
      (_) => Random.secure().nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    final clock = Stopwatch()..start();
    var bytes = 0, candidates = 0, steps = 0;
    var state = HistoryIndexMaintenanceState.incomplete;
    var paused = false;
    var continuable = true;
    bool current() => _current() && isCurrent() && clock.elapsed < deadline;
    await _join(
      () => outsideDatabaseTransaction(
        _db,
        () => _db.exclusively(() async {
          if (!current()) return;
          try {
            Map<String, Object?>? started;
            final previous = _paused;
            _paused = null;
            if (previous != null && previous.$1 == sessionId) {
              token = previous.$2;
              final resumed = await _db.transaction(
                () => _command('resume', sessionId, token),
              );
              if (resumed['restart'] != true) started = resumed;
            } else if (previous != null) {
              await _db.transaction(
                () => _command('abort', previous.$1, previous.$2),
              );
            }
            final Map<String, Object?> startedResult =
                started ??
                await _db.transaction<Map<String, Object?>>(
                  () => _command('start', sessionId, token),
                );
            if (startedResult['status'] == 'unsupported') {
              state = HistoryIndexMaintenanceState.unsupported;
            }
            if (startedResult['continuable'] == false) return;
            while (current() && steps < maxSteps) {
              final result = await _db.transaction(() async {
                if (!current())
                  return <String, Object?>{'status': 'incomplete'};
                return _command('step', sessionId, token);
              });
              // COMMIT has settled before any Stop check. Do not race original futures.
              steps++;
              bytes += (result['bytes'] as int? ?? 0);
              candidates += (result['candidates'] as int? ?? 0);
              if (!current()) break;
              if (result['status'] == 'ready') {
                state = HistoryIndexMaintenanceState.ready;
                break;
              }
              if (result['status'] == 'unsupported') {
                state = HistoryIndexMaintenanceState.unsupported;
                break;
              }
              if (result['continuable'] == false) {
                continuable = false;
                break;
              }
              await Future<void>.delayed(Duration.zero);
            }
            // No blob/callback/transaction survives this pause. Only the bounded
            // parser/hash remains private on the original worker, never model data.
            paused =
                current() &&
                continuable &&
                state == HistoryIndexMaintenanceState.incomplete &&
                steps == maxSteps;
            if (paused) _paused = (sessionId, token);
          } finally {
            // Reservation/lifetime still held; abort closes native build custody even
            // after Stop. It never publishes a checkpoint as ready or rewrites JSON.
            if (!current()) {
              state = HistoryIndexMaintenanceState.incomplete;
              paused = false;
              _paused = null;
            }
            if (state != HistoryIndexMaintenanceState.ready && !paused) {
              await _db.transaction(() => _command('abort', sessionId, token));
            }
          }
        }),
        onRejected: () =>
            StateError('Local maintenance requires original executor scope'),
      ),
    );
    return HistoryIndexMaintenanceResult(state, bytes, candidates, steps);
  }

  Future<Map<String, Object?>> _command(
    String operation,
    String session,
    String token,
  ) async {
    final row = await _db
        .customSelect(
          'SELECT astoria_history_index(?,?,?) AS result',
          variables: [
            Variable.withString(operation),
            Variable.withString(session),
            Variable.withString(token),
          ],
        )
        .getSingle();
    final raw = row.read<String>('result');
    if (raw.length > 512) throw StateError('Invalid native history reply');
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic> ||
        !const {
          'ready',
          'incomplete',
          'unsupported',
        }.contains(value['status'])) {
      throw StateError('Invalid native history reply');
    }
    return Map<String, Object?>.from(value);
  }
}
