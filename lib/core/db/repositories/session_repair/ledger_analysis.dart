part of '../session_repair_repo.dart';

/// A finite, read-only SQL projection, not a body reader or tolerant parser.
/// Initial delivery deliberately refuses retries/repair: debug rows have no call
/// ID, so multiple exchanges cannot be uniquely attributed to that journal.
final class _LedgerAnalysisReader {
  const _LedgerAnalysisReader(this.owner);
  final SessionRepairRepo owner;

  static Map<String, Object?> unavailable(String reason) => {
    'analysis': 'unavailable',
    'scope': 'latestSelectedTurn',
    'reason': reason,
    'capturedInstruction': 'unknown',
    'worldTimeOperation': 'unknown',
    'worldTimeParser': 'unverifiable',
    'persistedSnapshot': 'unverifiable',
    'snapshotState': 'unknown',
    'numericClockComparison': 'unknown',
    'captureCount': 0,
    'eventCount': 0,
    'debugCount': 0,
    'bodyAccess': 'notGranted',
    'advisory': true,
    'builtInContractEditable': false,
  };

  Future<Map<String, Object?>> read(
    String target,
    String parent,
    bool Function() current,
  ) async {
    final db = owner._db;
    if (!current() ||
        !owner._support.usesDatabase(db) ||
        db.resolvedEngine.executor is TransactionExecutor) {
      return unavailable('sourceChanged');
    }
    try {
      // Two distinct snapshots, never a retry-until-success loop. Internal
      // anchors are bounded scalar IDs/counts, not source bodies or hashes.
      final first = await _snapshot(target, parent, current);
      if (!current()) return unavailable('sourceChanged');
      final second = await _snapshot(target, parent, current);
      if (!current() ||
          first.length != second.length ||
          first.keys.any((key) => first[key] != second[key])) {
        return unavailable('sourceChanged');
      }
      final reason = first['reason'] as String;
      if (reason != 'none') return unavailable(reason);
      final result = <String, Object?>{
        'analysis': 'available',
        'scope': 'latestSelectedTurn',
        'reason': 'none',
        for (final key in const [
          'capturedInstruction',
          'worldTimeOperation',
          'worldTimeParser',
          'persistedSnapshot',
          'snapshotState',
          'numericClockComparison',
          'captureCount',
          'eventCount',
          'debugCount',
        ])
          key: first[key],
        'bodyAccess': 'notGranted',
        'advisory': true,
        'builtInContractEditable': false,
      };
      return current() ? result : unavailable('sourceChanged');
    } catch (_) {
      return unavailable(current() ? 'unsupportedShape' : 'sourceChanged');
    }
  }

  Future<Map<String, Object?>> _snapshot(
    String target,
    String parent,
    bool Function() current,
  ) => owner._db.transaction(() async {
    _repairRequire(current());
    final row = await owner._db
        .customSelect(
          _sql,
          variables: [
            Variable.withString(target),
            Variable.withString(parent),
            Variable.withString(StudioLedgerPrompt.gameClockRules),
          ],
          readsFrom: {
            owner._db.chatSessions,
            owner._db.supportSessions,
            owner._db.llmRequestCaptureRows,
            owner._db.llmCallEventRows,
            owner._db.ledgerDebugRuns,
            owner._db.trackerSnapshots,
          },
        )
        .getSingle();
    _repairRequire(current());
    return Map<String, Object?>.unmodifiable(row.data);
  });

  // Every body stays inside SQLite. CASE substitutes safe JSON BEFORE any JSON
  // operation. LIMIT 33 is an overflow sentinel, never a sampled success.
  static final String _sql = r'''
WITH RECURSIVE
args AS (SELECT ? AS target, ? AS parent, ? AS instruction),
chat AS MATERIALIZED (
  SELECT c.updated_at, length(CAST(c.messages_json AS BLOB)) AS bytes,
    CASE WHEN length(CAST(c.messages_json AS BLOB)) <= 524288 THEN
      CASE WHEN json_valid(c.messages_json) THEN c.messages_json ELSE 'null' END
      ELSE 'null' END AS j
  FROM chat_sessions c, args WHERE c.session_id = args.target
),
head AS MATERIALIZED (
  SELECT *, CASE WHEN json_type(j) = 'array'
    THEN json_extract(j, '$[#-1]') ELSE 'null' END AS h FROM chat
),
anchor AS MATERIALIZED (
  SELECT *, json_extract(h, '$.id') AS mid,
    json_extract(h, '$.swipeId') AS green,
    json_extract(h, '$.agentSwipeId') AS blue,
    'ledger:' || json_extract(h, '$.id') || ':' ||
      json_extract(h, '$.swipeId') || ':' || json_extract(h, '$.agentSwipeId') AS pipeline
  FROM head WHERE json_type(h) = 'object'
),
captures AS MATERIALIZED (
  SELECT c.* FROM llm_request_capture_rows c, args, anchor a
  WHERE (c.session_id = args.target AND c.message_id = a.mid
    AND (c.stage LIKE 'ledger.%' OR c.pipeline_run_id = a.pipeline))
    OR c.pipeline_run_id = a.pipeline
  LIMIT 33
),
events AS MATERIALIZED (
  SELECT e.* FROM llm_call_event_rows e, args, anchor a
  WHERE (e.session_id = args.target AND e.related_artifact_id = a.mid
    AND e.stage LIKE 'ledger.%') OR e.pipeline_run_id = a.pipeline
    OR e.call_id IN (SELECT call_id FROM captures)
  LIMIT 33
),
debug AS MATERIALIZED (
  SELECT d.* FROM ledger_debug_runs d, args, anchor a
  WHERE d.session_id = args.target AND d.message_id = a.mid
    AND d.swipe_id = a.green AND d.agent_swipe_id = a.blue AND d.kind = 'normal'
  LIMIT 33
),
counts AS (
  SELECT (SELECT count(*) FROM captures) AS nc,
    (SELECT count(*) FROM events) AS ne, (SELECT count(*) FROM debug) AS nd
),
capture AS MATERIALIZED (
  SELECT *, CASE WHEN truncated = 0 AND length(CAST(event_json AS BLOB)) <= 1048576 THEN
    CASE WHEN json_valid(event_json) THEN event_json ELSE '{}' END ELSE '{}' END AS cj
  FROM captures WHERE (SELECT nc FROM counts) = 1
),
run AS MATERIALIZED (
  SELECT *, CASE WHEN length(CAST(attempts_json AS BLOB)) <= 65536 THEN
    CASE WHEN json_valid(attempts_json) THEN attempts_json ELSE 'null' END ELSE 'null' END AS aj,
    CASE WHEN length(CAST(rejected_ops_json AS BLOB)) <= 65536 THEN
    CASE WHEN json_valid(rejected_ops_json) THEN rejected_ops_json ELSE 'null' END ELSE 'null' END AS rj,
    CASE WHEN length(response_text) <= 200000 THEN response_text END AS dr
  FROM debug WHERE (SELECT nd FROM counts) = 1
),
transport AS MATERIALIZED (
  SELECT *, CASE WHEN length(CAST(payload_json AS BLOB)) <= 65536 THEN
    CASE WHEN json_valid(payload_json) THEN payload_json ELSE 'null' END ELSE 'null' END AS tj,
    CASE WHEN length(response_text) <= 200000 THEN response_text END AS tr
  FROM events WHERE kind = 'transport_succeeded'
    AND (SELECT ne FROM counts) = 2
),
parser AS MATERIALIZED (
  SELECT *, CASE WHEN length(CAST(payload_json AS BLOB)) <= 65536 THEN
    CASE WHEN json_valid(payload_json) THEN payload_json ELSE 'null' END ELSE 'null' END AS pj,
    CASE WHEN length(response_text) <= 200000 THEN response_text END AS pr
  FROM events WHERE kind IN ('parser_accepted', 'parser_rejected')
    AND (SELECT ne FROM counts) = 2
),
exchange AS MATERIALIZED (
  SELECT c.id AS cid, t.id AS tid, p.id AS pid, d.id AS did,
    json_extract(c.cj, '$.messages[0].content') AS prompt,
    d.dr AS response, p.kind AS verdict,
    CASE WHEN json_type(p.pj, '$.rejectedOps') = 'array'
      THEN json_extract(p.pj, '$.rejectedOps') ELSE 'null' END AS rejected,
    d.repair_attempted, d.aj, d.rj, c.cj, p.pj
  FROM capture c, transport t, parser p, run d, anchor a, args
  WHERE c.session_id = args.target AND c.message_id = a.mid
    AND c.related_artifact_id = a.mid AND c.pipeline_run_id = a.pipeline
    AND c.logical_call_id = a.pipeline AND c.stage = 'ledger.turn' AND c.attempt = 1
    AND typeof(c.attempt) = 'integer'
    AND length(c.call_id) BETWEEN 1 AND 256
    AND t.session_id = c.session_id AND p.session_id = c.session_id
    AND t.pipeline_run_id = c.pipeline_run_id AND p.pipeline_run_id = c.pipeline_run_id
    AND t.call_id = c.call_id AND p.call_id = c.call_id
    AND t.stage = c.stage AND p.stage = c.stage
    AND t.related_artifact_id = a.mid AND p.related_artifact_id = a.mid
    AND t.attempt = 1 AND p.attempt = 1 AND t.status = 'ok'
    AND d.status IN ('ok', 'error') AND d.parse_failure = p.parser_code
    AND p.parser_name = 'StudioLedgerExportParser'
    AND p.parser_code IN ('none', 'semanticSchema', 'emptyExport')
    AND t.truncated = 0 AND p.truncated = 0 AND c.truncated = 0
    AND length(t.id) <= 256 AND length(p.id) <= 256 AND length(d.id) <= 256
    AND d.dr IS NOT NULL AND t.tr IS NOT NULL
    AND instr(d.dr, '…[truncated]') = 0
    AND t.tr = d.dr
    AND (p.response_text IS NULL OR p.pr = t.tr)
    AND d.repair_attempted = 0 AND d.repair_response_text IS NULL
    AND json_type(c.cj, '$.messages') = 'array'
    AND json_array_length(c.cj, '$.messages') = 1
    AND json_extract(c.cj, '$.messages[0].role') = 'user'
    AND json_type(c.cj, '$.messages[0].content') = 'text'
    AND json_type(c.cj, '$.truncated') = 'false'
    AND json_type(c.cj, '$.context') = 'object'
    AND json_extract(c.cj, '$.context.callId') = c.call_id
    AND json_extract(c.cj, '$.context.logicalCallId') = c.logical_call_id
    AND json_extract(c.cj, '$.context.pipelineRunId') = c.pipeline_run_id
    AND json_extract(c.cj, '$.context.messageId') = a.mid
    AND json_extract(c.cj, '$.context.sessionId') = args.target
    AND json_extract(c.cj, '$.context.stage') = 'ledger.turn'
    AND json_type(c.cj, '$.context.attempt') = 'integer'
    AND json_extract(c.cj, '$.context.attempt') = 1
    AND json_type(d.aj) = 'array' AND json_array_length(d.aj) = 1
    AND json_type(d.aj, '$[0].attempt') = 'integer'
    AND json_type(d.aj, '$[0].statusCode') = 'integer'
    AND json_type(d.aj, '$[0].startedAtMs') = 'integer'
    AND json_type(d.aj, '$[0].elapsedMs') = 'integer'
    AND json_extract(d.aj, '$[0].attempt') = 1
    AND json_extract(d.aj, '$[0].status') = t.status
    AND json_extract(d.aj, '$[0].statusCode') = t.status_code
    AND json_type(t.tj, '$.startedAtMs') = 'integer'
    AND json_type(t.tj, '$.elapsedMs') = 'integer'
    AND json_extract(d.aj, '$[0].startedAtMs') = json_extract(t.tj, '$.startedAtMs')
    AND json_extract(d.aj, '$[0].elapsedMs') = json_extract(t.tj, '$.elapsedMs')
    AND json_type(d.rj) = 'array' AND d.rj = json_extract(p.pj, '$.rejectedOps')
    AND ((p.kind = 'parser_accepted' AND p.parser_code = 'none'
        AND json_type(p.pj, '$.hasExport') = 'true')
      OR (p.kind = 'parser_rejected' AND p.parser_code IN ('semanticSchema', 'emptyExport')
        AND json_type(p.pj, '$.hasExport') = 'false'))
    AND NOT EXISTS (SELECT 1 FROM json_tree(c.cj)
      WHERE key IS NOT NULL GROUP BY parent, key HAVING count(*) > 1)
    AND NOT EXISTS (SELECT 1 FROM json_tree(p.pj)
      WHERE key IS NOT NULL GROUP BY parent, key HAVING count(*) > 1)
    AND NOT EXISTS (SELECT 1 FROM json_tree(t.tj)
      WHERE key IS NOT NULL GROUP BY parent, key HAVING count(*) > 1)
    AND NOT EXISTS (SELECT 1 FROM json_tree(d.aj)
      WHERE key IS NOT NULL GROUP BY parent, key HAVING count(*) > 1)
),
blocks AS MATERIALIZED (
  SELECT *, CASE WHEN instr(response, '<glaze_memory_export>') > 0
    AND instr(response, '</glaze_memory_export>') > instr(response, '<glaze_memory_export>')
    AND instr(substr(response, instr(response, '<glaze_memory_export>') + 21), '<glaze_memory_export>') = 0
    AND instr(substr(response, instr(response, '</glaze_memory_export>') + 22), '</glaze_memory_export>') = 0
    THEN trim(substr(response, instr(response, '<glaze_memory_export>') + 21,
      instr(response, '</glaze_memory_export>') - instr(response, '<glaze_memory_export>') - 21))
    ELSE 'null' END AS export_text,
    CASE WHEN instr(prompt, char(10) || '<current_state>' || char(10)) > 0
    AND instr(prompt, char(10) || '</current_state>' || char(10)) > instr(prompt, char(10) || '<current_state>' || char(10))
    AND instr(substr(prompt, instr(prompt, char(10) || '<current_state>' || char(10)) + 17), char(10) || '<current_state>' || char(10)) = 0
    AND instr(substr(prompt, instr(prompt, char(10) || '</current_state>' || char(10)) + 18), char(10) || '</current_state>' || char(10)) = 0
    THEN substr(prompt, instr(prompt, char(10) || '<current_state>' || char(10)) + 17,
      instr(prompt, char(10) || '</current_state>' || char(10)) - instr(prompt, char(10) || '<current_state>' || char(10)) - 17)
    ELSE '' END AS baseline
  FROM exchange
),
export AS MATERIALIZED (
  SELECT *, CASE WHEN length(CAST(export_text AS BLOB)) <= 65536 THEN
    CASE WHEN json_valid(export_text) THEN export_text ELSE 'null' END ELSE 'null' END AS ej
  FROM blocks
),
ops AS MATERIALIZED (
  SELECT o.* FROM export e, json_each(CASE WHEN json_type(e.ej, '$.ops') = 'array'
    AND json_array_length(e.ej, '$.ops') <= 32 THEN json_extract(e.ej, '$.ops') ELSE '[]' END) o
),
clock AS MATERIALIZED (
  SELECT value FROM ops WHERE type = 'object' AND json_extract(value, '$.key') = 'world:time'
),
snapshot AS MATERIALIZED (
  SELECT s.created_at, s.committed,
    CASE WHEN length(CAST(s.trackers_json AS BLOB)) <= 65536 THEN
    CASE WHEN json_valid(s.trackers_json) THEN s.trackers_json ELSE 'null' END ELSE 'null' END AS sj
  FROM tracker_snapshots s, args, anchor a WHERE s.session_id = args.target
    AND s.message_id = a.mid AND s.swipe_id = a.green AND s.agent_swipe_id = a.blue
    AND s.committed IN (0, 1)
),
trackers AS MATERIALIZED (
  SELECT t.* FROM snapshot s, json_each(CASE WHEN json_type(s.sj) = 'array'
    AND json_array_length(s.sj) <= 32 THEN s.sj ELSE '[]' END) t
),
lines(n, line, rest) AS (
  SELECT 0, '', baseline || char(10) FROM export
  UNION ALL SELECT n + 1, substr(rest, 1, instr(rest, char(10)) - 1),
    substr(rest, instr(rest, char(10)) + 1) FROM lines
    WHERE n < 32 AND rest <> '' AND instr(rest, char(10)) > 0
),
tuple AS (
  SELECT 'baseline' AS source,
    (SELECT substr(line, 13) FROM lines WHERE substr(line, 1, 12) = 'world:time: ') AS time,
    (SELECT substr(line, 13) FROM lines WHERE substr(line, 1, 12) = 'world:date: ') AS date,
    (SELECT substr(line, 12) FROM lines WHERE substr(line, 1, 11) = 'world:day: ') AS day,
    (SELECT count(*) FROM lines WHERE lower(substr(line, 1, 10)) = 'world:time') = 1 AND
    (SELECT count(*) FROM lines WHERE lower(substr(line, 1, 10)) = 'world:date') = 1 AND
    (SELECT count(*) FROM lines WHERE lower(substr(line, 1, 9)) = 'world:day') = 1 AND
    NOT EXISTS (SELECT 1 FROM lines WHERE n = 32 AND rest <> '') AS unique_clock
  UNION ALL SELECT 'snapshot',
    (SELECT json_extract(value, '$.value') FROM trackers WHERE type = 'object' AND json_extract(value, '$.name') = 'world:time'),
    (SELECT json_extract(value, '$.value') FROM trackers WHERE type = 'object' AND json_extract(value, '$.name') = 'world:date'),
    (SELECT json_extract(value, '$.value') FROM trackers WHERE type = 'object' AND json_extract(value, '$.name') = 'world:day'),
    (SELECT count(*) FROM trackers WHERE type = 'object' AND json_extract(value, '$.name') IN ('world:time', 'world:date', 'world:day')) = 3
    AND NOT EXISTS (SELECT 1 FROM trackers WHERE type <> 'object')
    AND NOT EXISTS (SELECT 1 FROM trackers WHERE type = 'object' AND json_extract(value, '$.name') IN ('world:time', 'world:date', 'world:day')
      AND (coalesce(json_type(value, '$.value'), '') <> 'text' OR coalesce(json_type(value, '$.scope'), '') <> 'text'
        OR json_extract(value, '$.scope') NOT IN ('ledger', 'chat')))
    AND NOT EXISTS (SELECT 1 FROM trackers WHERE type = 'object' AND
      EXISTS (SELECT 1 FROM json_tree(trackers.value) WHERE key IS NOT NULL GROUP BY parent, key HAVING count(*) > 1))
),
canonical AS MATERIALIZED (
  SELECT * FROM tuple WHERE unique_clock AND time GLOB '[0-2][0-9]:[0-5][0-9]'
    AND length(time) = 5 AND CAST(substr(time, 1, 2) AS INTEGER) <= 23
    AND date GLOB '[0-3][0-9].[0-1][0-9].[0-9][0-9][0-9][0-9]'
    AND length(date) = 10 AND CAST(substr(date, 7, 4) AS INTEGER) BETWEEN 1 AND 9999
    AND CAST(substr(date, 4, 2) AS INTEGER) BETWEEN 1 AND 12
    AND CAST(substr(date, 1, 2) AS INTEGER) BETWEEN 1 AND CASE CAST(substr(date, 4, 2) AS INTEGER)
      WHEN 2 THEN 28 + (CAST(substr(date, 7, 4) AS INTEGER) % 4 = 0 AND
        (CAST(substr(date, 7, 4) AS INTEGER) % 100 <> 0 OR CAST(substr(date, 7, 4) AS INTEGER) % 400 = 0))
      WHEN 4 THEN 30 WHEN 6 THEN 30 WHEN 9 THEN 30 WHEN 11 THEN 30 ELSE 31 END
    AND length(day) BETWEEN 1 AND 10 AND day NOT GLOB '*[^0-9]*'
    AND CAST(day AS INTEGER) BETWEEN 0 AND 2147483647
    AND CAST(CAST(day AS INTEGER) AS TEXT) = day
),
facts AS MATERIALIZED (
  SELECT e.*, CASE WHEN json_type(e.ej) = 'object'
    AND json_type(e.ej, '$.ops') = 'array' AND json_array_length(e.ej, '$.ops') <= 32
    AND json_type(e.ej, '$.knowledgeFacts') = 'array' AND json_array_length(e.ej, '$.knowledgeFacts') <= 32
    AND NOT EXISTS (SELECT 1 FROM json_each(e.ej) WHERE key NOT IN ('ops', 'knowledgeFacts'))
    AND NOT EXISTS (SELECT 1 FROM json_tree(e.ej) WHERE key IS NOT NULL GROUP BY parent, key HAVING count(*) > 1)
    AND NOT EXISTS (SELECT 1 FROM ops WHERE type <> 'object')
    AND NOT EXISTS (SELECT 1 FROM ops WHERE type = 'object' AND
      (coalesce(json_type(value, '$.key'), '') <> 'text' OR coalesce(json_type(value, '$.op'), '') <> 'text'
        OR json_extract(value, '$.op') NOT IN ('set', 'delete')
        OR (json_extract(value, '$.op') = 'set' AND coalesce(json_type(value, '$.value'), '') <> 'text')
        OR (json_extract(value, '$.key') = 'world:time' AND
          (coalesce(json_type(value, '$.evidence'), '') <> 'text'
            OR coalesce(json_type(value, '$.eventState'), '') <> 'text'))
        OR EXISTS (SELECT 1 FROM json_each(ops.value)
          WHERE key NOT IN ('op', 'key', 'value', 'evidence', 'eventState'))))
    THEN 1 ELSE 0 END AS valid_export,
    CASE WHEN json_type(e.rejected) = 'array' AND json_array_length(e.rejected) <= 32
    AND NOT EXISTS (SELECT 1 FROM json_each(e.rejected) WHERE type <> 'text')
      THEN 1 ELSE 0 END AS valid_rejections,
    (SELECT count(*) FROM clock) AS clock_count,
    (SELECT count(*) FROM json_each(CASE WHEN json_type(e.rejected) = 'array' AND json_array_length(e.rejected) <= 32 THEN e.rejected ELSE '[]' END)
      WHERE type = 'text' AND (substr(value, 1, 15) = 'set world:time:' OR substr(value, 1, 18) = 'delete world:time:')) AS clock_rejections
  FROM export e
),
observed AS MATERIALIZED (
  SELECT *, CASE WHEN valid_export = 1 AND clock_count = 0 THEN 'missing'
    WHEN valid_export = 1 AND clock_count = 1 THEN 'explicitReturned' ELSE 'unknown' END AS operation,
    CASE WHEN valid_export = 1 AND valid_rejections = 1 AND clock_count = 1 AND
      (clock_rejections > 0 OR verdict = 'parser_rejected') THEN 'rejected'
    WHEN valid_export = 1 AND valid_rejections = 1 AND clock_count = 1 AND clock_rejections = 0
      AND verdict = 'parser_accepted' AND
      (SELECT json_extract(value, '$.op') FROM clock) = 'set' AND
      (SELECT json_extract(value, '$.eventState') FROM clock) = 'completed' AND
      (SELECT json_extract(value, '$.value') FROM clock) GLOB '[0-2][0-9]:[0-5][0-9]'
      AND length((SELECT json_extract(value, '$.value') FROM clock)) = 5
      AND CAST(substr((SELECT json_extract(value, '$.value') FROM clock), 1, 2) AS INTEGER) <= 23
    THEN 'accepted' ELSE 'unverifiable' END AS clock_parser
  FROM facts
),
agreement AS MATERIALIZED (
  SELECT o.*, CASE WHEN clock_parser = 'accepted' AND
    EXISTS (SELECT 1 FROM canonical WHERE source = 'snapshot') AND
    EXISTS (SELECT 1 FROM trackers t, anchor a WHERE t.type = 'object'
      AND json_extract(t.value, '$.name') = 'world:time'
      AND json_extract(t.value, '$.provenance') = 'source=studio_ledger|message=' || a.mid || '|swipe=' || a.green || '|agentSwipe=' || a.blue ||
        CASE WHEN trim((SELECT json_extract(value, '$.evidence') FROM clock)) <> ''
          THEN '|evidence=' || substr(trim((SELECT json_extract(value, '$.evidence') FROM clock)), 1, 80) ELSE '' END)
    THEN CASE WHEN (SELECT time FROM canonical WHERE source = 'snapshot') =
      (SELECT json_extract(value, '$.value') FROM clock) THEN 'matching' ELSE 'mismatch' END
    ELSE 'unverifiable' END AS persistence FROM observed o
)
SELECT CASE
  WHEN NOT EXISTS (SELECT 1 FROM support_sessions s, args WHERE s.id = args.parent)
    OR NOT EXISTS (SELECT 1 FROM chat) THEN 'missing'
  WHEN (SELECT bytes FROM chat) > 524288 THEN 'truncated'
  WHEN NOT EXISTS (SELECT 1 FROM anchor) THEN 'unsupportedShape'
  WHEN (SELECT json_extract(h, '$.role') FROM anchor) <> 'assistant'
    OR EXISTS (SELECT 1 FROM anchor WHERE json_extract(h, '$.isError') <> 0
      OR json_extract(h, '$.isTyping') <> 0 OR json_extract(h, '$.isEditing') <> 0) THEN 'pending'
  WHEN EXISTS (SELECT 1 FROM anchor a WHERE coalesce(json_type(h, '$.id'), '') <> 'text' OR length(mid) NOT BETWEEN 1 AND 96
    OR coalesce(json_type(h, '$.role'), '') <> 'text'
    OR coalesce(json_type(h, '$.swipeId'), '') <> 'integer' OR coalesce(json_type(h, '$.agentSwipeId'), '') <> 'integer'
    OR green < 0 OR blue < 0 OR coalesce(json_type(h, '$.swipes'), '') <> 'array'
    OR coalesce(json_type(h, '$.agentSwipes'), '') <> 'array'
    OR json_array_length(h, '$.swipes') > 32 OR json_array_length(h, '$.agentSwipes') > 32
    OR (json_array_length(h, '$.swipes') = 0 AND green <> 0)
    OR (json_array_length(h, '$.swipes') > 0 AND green >= json_array_length(h, '$.swipes'))
    OR (json_array_length(h, '$.agentSwipes') = 0 AND blue <> 0)
    OR (json_array_length(h, '$.agentSwipes') > 0 AND (blue >= json_array_length(h, '$.agentSwipes')
       OR coalesce(json_extract(h, '$.agentSwipes[' || blue || '].kind'), '') <> 'final'
       OR coalesce(json_type(h, '$.agentSwipes[' || blue || '].content'), '') <> 'text'
       OR json_extract(h, '$.agentSwipes[' || blue || '].content') IS NOT json_extract(h, '$.content')
       OR coalesce(json_type(h, '$.swipesMeta[' || green || '].agentSwipes'), '') <> 'array'
       OR json_extract(h, '$.swipesMeta[' || green || '].agentSwipes') IS NOT json_extract(h, '$.agentSwipes')
       OR coalesce(json_type(h, '$.swipesMeta[' || green || '].agentSwipeId'), '') <> 'integer'
       OR json_extract(h, '$.swipesMeta[' || green || '].agentSwipeId') IS NOT blue))
     OR (json_array_length(h, '$.agentSwipes') = 0 AND json_array_length(h, '$.swipes') > 0
       AND (coalesce(json_type(h, '$.swipes[' || green || ']'), '') <> 'text'
         OR json_extract(h, '$.swipes[' || green || ']') IS NOT json_extract(h, '$.content')))
    OR coalesce(json_type(h, '$.content'), '') <> 'text' OR length(json_extract(h, '$.content')) = 0
    OR coalesce(json_type(h, '$.isError'), '') NOT IN ('true', 'false')
    OR coalesce(json_type(h, '$.isTyping'), '') NOT IN ('true', 'false')
    OR coalesce(json_type(h, '$.isEditing'), '') NOT IN ('true', 'false')
    OR EXISTS (SELECT 1 FROM json_tree(h) WHERE key IS NOT NULL GROUP BY parent, key HAVING count(*) > 1)
    OR (SELECT count(*) FROM json_each(a.j) WHERE type = 'object' AND json_extract(value, '$.id') = a.mid) <> 1)
    THEN 'unsupportedShape'
  WHEN nc > 32 OR ne > 32 OR nd > 32 THEN 'truncated'
  WHEN nc = 0 OR ne = 0 OR nd = 0 THEN 'missing'
  WHEN EXISTS (SELECT 1 FROM captures WHERE truncated <> 0 OR length(CAST(event_json AS BLOB)) > 1048576)
    OR EXISTS (SELECT 1 FROM events WHERE truncated <> 0 OR length(response_text) > 200000)
    OR EXISTS (SELECT 1 FROM debug WHERE CASE WHEN length(response_text) > 200000 THEN 1
      ELSE instr(response_text, '…[truncated]') > 0 END) THEN 'truncated'
  WHEN nc <> 1 OR ne <> 2 OR nd <> 1 THEN 'ambiguous'
  WHEN NOT EXISTS (SELECT 1 FROM agreement) THEN 'unsupportedShape'
  ELSE 'none' END AS reason,
  CASE WHEN EXISTS (SELECT 1 FROM agreement, args WHERE instr(prompt, instruction) > 0)
    THEN 'present' ELSE 'unknown' END AS capturedInstruction,
  coalesce((SELECT operation FROM agreement), 'unknown') AS worldTimeOperation,
  coalesce((SELECT clock_parser FROM agreement), 'unverifiable') AS worldTimeParser,
  coalesce((SELECT persistence FROM agreement), 'unverifiable') AS persistedSnapshot,
  CASE (SELECT committed FROM snapshot) WHEN 0 THEN 'tentative' WHEN 1 THEN 'committed' ELSE 'unknown' END AS snapshotState,
  CASE WHEN (SELECT persistence FROM agreement) = 'matching' AND (SELECT count(*) FROM canonical) = 2
    THEN CASE WHEN EXISTS (SELECT 1 FROM canonical b, canonical s WHERE b.source = 'baseline' AND s.source = 'snapshot'
      AND b.time = s.time AND b.date = s.date AND b.day = s.day) THEN 'sameNumeric' ELSE 'differentNumeric' END
    ELSE 'unknown' END AS numericClockComparison,
  min(nc, 32) AS captureCount, min(ne, 32) AS eventCount, min(nd, 32) AS debugCount,
  (SELECT updated_at FROM chat) AS anchorUpdated,
  (SELECT bytes FROM chat) AS anchorBytes,
  (SELECT json_array_length(j) FROM chat) AS anchorCount,
  (SELECT mid FROM anchor WHERE length(mid) <= 96) AS anchorMessage,
  (SELECT green FROM anchor) AS anchorGreen, (SELECT blue FROM anchor) AS anchorBlue,
  (SELECT cid FROM agreement) AS anchorCapture, (SELECT tid FROM agreement) AS anchorTransport,
  (SELECT pid FROM agreement) AS anchorParser, (SELECT did FROM agreement) AS anchorDebug,
  (SELECT created_at FROM snapshot) AS anchorSnapshot,
  (SELECT created_at FROM support_sessions s, args WHERE s.id = args.parent) AS anchorParentCreated
FROM counts
''';
}
