import 'package:drift/drift.dart';

import 'helpers/support_mutation_journal_fixture.dart' show JournalBarrier;

/// Records targets and returned column NAMES, not decrypted source data. SQL
/// scalar validity/count checks are metadata, not a claim that SQLite never
/// touches the underlying JSON bytes internally.
final class SessionScopeWidgetSql extends QueryInterceptor {
  SessionScopeWidgetSql(this.block);
  final Never Function(String) block;
  bool observing = false;
  int writes = 0, outstanding = 0;
  final reads = <SessionScopeWidgetRead>[];
  final barriers = <JournalBarrier>[];
  Future<void> Function(SessionScopeWidgetRead)? afterRead;

  void observe() {
    observing = true;
    writes = 0;
    reads.clear();
  }

  JournalBarrier barrier() {
    final gate = JournalBarrier();
    barriers.add(gate);
    return gate;
  }

  void release() {
    afterRead = null;
    for (final gate in barriers) {
      if (!gate.release.isCompleted) gate.release.complete();
    }
  }

  void _check(String sql) {
    if (!observing) return; // Declared schema creation/synthetic seed only.
    if (RegExp(r'\bapi_configs\b', caseSensitive: false).hasMatch(sql)) {
      block('API SQL during local guidance');
    }
  }

  void _write(String sql) {
    _check(sql);
    if (observing) writes++;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor, String statement, List<Object?> args,
  ) async {
    _check(statement);
    outstanding++;
    SessionScopeWidgetRead? observed;
    try {
      final rows = await super.runSelect(executor, statement, args);
      if (observing) {
        final read = SessionScopeWidgetRead(
          statement, args, rows.expand((row) => row.keys).toSet(),
        );
        observed = read;
        reads.add(read);
        if (RegExp(r'\b(chat_sessions|characters)\b', caseSensitive: false)
            .hasMatch(statement) && read.columns.any({
              'messages_json', 'content', 'description', 'avatar_path',
              'session_vars_json', 'authors_note_json', 'draft',
            }.contains)) {
          block('roleplay source body projection');
        }
        await afterRead?.call(read);
      }
      return rows;
    } finally {
      observed?.settled = true;
      outstanding--;
    }
  }

  @override
  Future<int> runInsert(QueryExecutor executor, String sql, List<Object?> args) {
    _write(sql);
    return super.runInsert(executor, sql, args);
  }
  @override
  Future<int> runUpdate(QueryExecutor executor, String sql, List<Object?> args) {
    _write(sql);
    return super.runUpdate(executor, sql, args);
  }
  @override
  Future<int> runDelete(QueryExecutor executor, String sql, List<Object?> args) {
    _write(sql);
    return super.runDelete(executor, sql, args);
  }
  @override
  Future<void> runCustom(QueryExecutor executor, String sql, List<Object?> args) {
    _write(sql);
    return super.runCustom(executor, sql, args);
  }
  @override
  Future<void> runBatched(QueryExecutor executor, BatchedStatements statements) =>
      block('unexpected UI SQL batch');
}

final class SessionScopeWidgetRead {
  SessionScopeWidgetRead(this.sql, List<Object?> args, Set<String> columns)
      : args = List.unmodifiable(args), columns = Set.unmodifiable(columns);
  final String sql;
  final List<Object?> args;
  final Set<String> columns;
  bool settled = false;
  bool get roleplayMetadata => columns.contains('character_label');
  bool get exactSessionMetadata => columns.contains('native_identity');
  bool get supportMessageBody => columns.contains('body_ciphertext');
}
