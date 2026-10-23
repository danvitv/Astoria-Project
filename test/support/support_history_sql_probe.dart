import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:glaze_flutter/core/db/repositories/support_repo.dart';

import 'helpers/support_mutation_journal_fixture.dart';
import 'support_theme_provider_fixture.dart';

/// Actual-query affordance with the SAME seven-table SQL classifier. Arguments
/// and returned row counts are recorded, not a simulated query/result.
final class HistorySqlProbe extends QueryInterceptor {
  HistorySqlProbe(this.block);
  final Never Function(String) block;
  final metadata = <({String sql, List<Object?> args, int rows})>[];
  final writes = <String>[];
  void check(String sql) {
    checkThemeProviderSql(sql, block);
    if (RegExp(
      r'^\s*(INSERT|UPDATE|DELETE)\b',
      caseSensitive: false,
    ).hasMatch(sql)) {
      writes.add(sql);
    }
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    check(statement);
    final rows = await super.runSelect(executor, statement, args);
    if (statement.startsWith('SELECT id, session_id, domain, target_id')) {
      metadata.add((
        sql: statement,
        args: List.unmodifiable(args),
        rows: rows.length,
      ));
    }
    return rows;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    check(statement);
    return super.runInsert(executor, statement, args);
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    check(statement);
    return super.runUpdate(executor, statement, args);
  }

  @override
  Future<int> runDelete(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    check(statement);
    return super.runDelete(executor, statement, args);
  }

  @override
  Future<void> runCustom(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) {
    check(statement);
    return super.runCustom(executor, statement, args);
  }

  @override
  Future<void> runBatched(
    QueryExecutor executor,
    BatchedStatements statements,
  ) => block('unexpected history SQL batch');
}

({JournalMemoryDatabase db, SupportRepo repo, HistorySqlProbe sql})
historyProbe(ThemeProviderFixture f) {
  final sql = HistorySqlProbe(f.isolation.block);
  final db = JournalMemoryDatabase(NativeDatabase.memory().interceptWith(sql));
  f.databases.add(db); // Closed under original setup-through-cleanup denials.
  return (db: db, repo: SupportRepo(db, f.cipher), sql: sql);
}
