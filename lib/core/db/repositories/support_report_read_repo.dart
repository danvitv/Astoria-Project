import 'package:drift/drift.dart';

import '../../support_report/support_report_error.dart';
import '../../llm/diagnostics/recorded_diagnostic_causal_assessment.dart';
import '../../llm/diagnostics/recorded_generation_runtime.dart';
import '../../llm/diagnostics/recorded_studio_runtime.dart';
import '../app_db.dart';
import 'support_report_root_repo.dart';
import 'chat_message_storage_sql.dart';

/// Narrow report read domain. SQL is exclusively here; no schema enumeration,
/// complete table dumping, credential values, transport JSON or journal bodies.
final class SupportReportReadRepo {
  SupportReportReadRepo(this._db);
  final AppDatabase _db;
  bool usesDatabase(AppDatabase db) => identical(_db, db);

  /// Join ONLY the parent-issued original actual native writer ROOT. Never
  /// create a read-only transaction or accept an inherited unrelated scope.
  Future<T> snapshot<T>({
    required NativeReportRootScope originalRoot,
    required bool Function() isCurrent,
    required Future<T> Function(SupportReportReadSnapshot) read,
    String? gameSessionId,
    String? supportSessionId,
    bool includeTitles = false,
    bool includeProse = false,
  }) {
    bool current() {
      originalRoot.check(_db);
      return originalRoot.belongsTo(_db) && isCurrent();
    }

    _check(current);
    return _snapshot(
      isCurrent: current,
      read: read,
      gameSessionId: gameSessionId,
      supportSessionId: supportSessionId,
      includeTitles: includeTitles,
      includeProse: includeProse,
    );
  }

  Future<T> _snapshot<T>({
    required bool Function() isCurrent,
    required Future<T> Function(SupportReportReadSnapshot) read,
    String? gameSessionId,
    String? supportSessionId,
    bool includeTitles = false,
    bool includeProse = false,
  }) async {
    _check(isCurrent);
    final stamp = await _stamp(isCurrent);
    _check(isCurrent);
    final schema = await _rows(
      'SELECT user_version AS version FROM pragma_user_version',
      isCurrent,
    );
    _check(isCurrent);
    final config = await _rows('''SELECT
        CASE WHEN protocol IN ('openai','openai_responses','anthropic','gemini','openrouter')
          THEN protocol ELSE 'unknown' END AS protocol,
        CASE WHEN endpoint IS NOT NULL AND length(endpoint)>0 THEN 1 ELSE 0 END AS endpoint_configured,
        min(length(coalesce(model,'')),4096) AS model_characters,
        stream,request_reasoning,embedding_enabled,max_tokens AS generation_limit,context_size,
        min(length(extra_request_parameters_json),65536) AS extra_parameter_characters
        FROM api_configs ORDER BY rowid DESC LIMIT 17''', isCurrent);
    _check(isCurrent);
    final capture = await _rows(
      '''SELECT truncated,attempt,stage_ordinal,
        CASE WHEN protocol IN ('openai','openai_responses','anthropic','gemini','openrouter')
          THEN protocol ELSE 'unknown' END AS protocol
        FROM llm_request_capture_rows ORDER BY created_at_ms DESC LIMIT 65''',
      isCurrent,
    );
    _check(isCurrent);
    final rawEvents = await _rows(
      '''SELECT
        CASE WHEN kind IN ('transport_succeeded','transport_failed','parser_accepted','parser_rejected',
          'result_selected','pipeline_completed','pipeline_failed') THEN kind ELSE 'unknown' END AS kind,
        CASE WHEN status_code BETWEEN 100 AND 599 THEN status_code ELSE NULL END AS status_code,
        status,truncated,attempt,stage,parser_name,parser_code,
        CASE WHEN parser_detail IS NULL THEN NULL ELSE 'present' END AS parser_detail,
        CASE WHEN length(payload_json)<=8192 THEN payload_json ELSE NULL END AS payload_json,
        CASE WHEN length(coalesce(session_id,''))>0
          AND length(coalesce(pipeline_run_id,''))>0
          AND length(coalesce(call_id,''))>0 THEN 1 ELSE 0 END AS _diagnosticIdentityValid
        FROM llm_call_event_rows ORDER BY created_at_ms DESC LIMIT 65''',
      isCurrent,
    );
    final events = rawEvents.map(_projectEvent).toList(growable: false);
    _check(isCurrent);
    final repairs = supportSessionId == null
        ? <Map<String, Object?>>[]
        : await _rows(
            '''SELECT CASE WHEN domain IN ('theme','api_config','provider') THEN domain ELSE 'unknown' END AS domain,
          CASE WHEN status IN ('applied','undone','failed','pending','conflict','prepared','rolled_back')
            THEN status ELSE 'unknown' END AS status
          FROM support_mutation_journal WHERE session_id=? ORDER BY created_at DESC LIMIT 17''',
            isCurrent,
            [Variable<String>(supportSessionId)],
          );
    _check(isCurrent);
    final personal = <Map<String, Object?>>[];
    if (gameSessionId != null && (includeTitles || includeProse)) {
      personal.addAll(
        await _rows(
          '''WITH ${ChatMessageStorageSql.targetPayloadCte('?')}
          SELECT
          ${includeTitles ? 'CASE WHEN length(c.name)<=4096 THEN c.name ELSE NULL END' : 'NULL'} AS title,
          ${includeProse ? 'CASE WHEN length(payload.messages_json)<=131072 THEN payload.messages_json ELSE NULL END' : 'NULL'} AS history,
          ${includeProse ? 'length(payload.messages_json)' : '0'} AS history_characters
          FROM chat_sessions s
          JOIN chat_message_payloads payload ON payload.session_id=s.session_id
          JOIN characters c ON c.char_id=s.character_id
           WHERE c.hidden=0 LIMIT 1''',
          isCurrent,
          [Variable<String>(gameSessionId)],
        ),
      );
      _check(isCurrent);
    }
    final supportTitle = supportSessionId == null || !includeTitles
        ? <Map<String, Object?>>[]
        : await _rows(
            '''SELECT id,CASE WHEN length(title_ciphertext)<=32768
              THEN title_ciphertext ELSE NULL END AS title
            FROM support_sessions WHERE id=? LIMIT 1''',
            isCurrent,
            [Variable<String>(supportSessionId)],
          );
    _check(isCurrent);
    final supportHistory = supportSessionId == null || !includeProse
        ? <Map<String, Object?>>[]
        : await _rows(
            '''SELECT id,role,status,CASE WHEN length(body_ciphertext)<=32768
              THEN body_ciphertext ELSE NULL END AS body
            FROM support_messages WHERE session_id=? ORDER BY created_at DESC,rowid DESC LIMIT 9''',
            isCurrent,
            [Variable<String>(supportSessionId)],
          );
    _check(isCurrent);
    final snapshot = SupportReportReadSnapshot._(
      this,
      stamp,
      schema: schema.single['version'] as int,
      tableCount: _db.allTables.length,
      configurations: config,
      captures: capture,
      events: events,
      repairs: repairs,
      game: personal,
      supportTitle: supportTitle,
      supportHistory: supportHistory,
    );
    final result = await read(snapshot);
    _check(isCurrent);
    return result;
  }

  /// Called in ORIGINAL held native ROOT immediately around final handoff.
  Future<T> revalidate<T>(
    SupportReportReadSnapshot snapshot,
    bool Function() isCurrent,
    Future<T> Function() work, {
    required NativeReportRootScope originalRoot,
  }) async {
    if (!identical(snapshot._owner, this)) _changed();
    bool current() {
      originalRoot.check(_db);
      return originalRoot.belongsTo(_db) && isCurrent();
    }

    _check(current);
    final stamp = await _stamp(current);
    _check(current);
    if (stamp != snapshot._stamp) _changed();
    final result = await work();
    _check(current);
    // Work may return an admission capsule, NEVER the OS response future.
    return result;
  }

  Future<(int, int, int)> _stamp(bool Function() current) async {
    final rows = await _rows('''SELECT total_changes() AS changes,
      data_version AS version,(SELECT schema_version FROM pragma_schema_version) AS schema
      FROM pragma_data_version''', current);
    _check(current);
    return (
      rows.single['changes'] as int,
      rows.single['version'] as int,
      rows.single['schema'] as int,
    );
  }

  Future<List<Map<String, Object?>>> _rows(
    String sql,
    bool Function() current, [
    List<Variable<Object>> variables = const [],
  ]) async {
    _check(current);
    final result = await _db.customSelect(sql, variables: variables).get();
    _check(current);
    return List.unmodifiable(
      result.map((r) => Map<String, Object?>.unmodifiable(r.data)),
    );
  }

  Map<String, Object?> _projectEvent(Map<String, Object?> row) {
    final runtime =
        RecordedGenerationRuntime.fromColumns(row) ??
        RecordedStudioRuntime.fromColumns(row);
    final assessment = RecordedDiagnosticCausalAssessment.fromRuntime(runtime);
    return Map.unmodifiable({
      'kind': row['kind'],
      'status_code': row['status_code'],
      'truncated': row['truncated'],
      'attempt': row['attempt'],
      if (assessment != null) '_causalAssessment': assessment.toJson(),
    });
  }

  void _check(bool Function() current) {
    if (!current() || _db.isClosing) _changed();
  }

  Never _changed() =>
      throw const SupportReportException(SupportReportFailure.changed);
}

/// Detached private read material; never serialize this object. Identities and
/// ciphertext are only for context-bound local decryption, never packet output.
final class SupportReportReadSnapshot {
  SupportReportReadSnapshot._(
    this._owner,
    this._stamp, {
    required this.schema,
    required this.tableCount,
    required this.configurations,
    required this.captures,
    required this.events,
    required this.repairs,
    required this.game,
    required this.supportTitle,
    required this.supportHistory,
  });
  final SupportReportReadRepo _owner;
  final (int, int, int) _stamp;
  final int schema, tableCount;
  final List<Map<String, Object?>> configurations,
      captures,
      events,
      repairs,
      game,
      supportTitle,
      supportHistory;

  /// Retain only private revalidation custody once sanitized blocks are built.
  /// UI preview closures never keep original prose or source ciphertext alive.
  SupportReportReadSnapshot revalidationOnly() => SupportReportReadSnapshot._(
    _owner,
    _stamp,
    schema: schema,
    tableCount: tableCount,
    configurations: const [],
    captures: const [],
    events: const [],
    repairs: const [],
    game: const [],
    supportTitle: const [],
    supportHistory: const [],
  );
  @override
  String toString() => 'SupportReportReadSnapshot';
}
