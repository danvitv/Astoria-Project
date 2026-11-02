import 'dart:async';

import 'package:drift/drift.dart';

/// One finite gate AFTER the actual second MemoryBook SELECT, plus exact SQL
/// submission observations. Used only by the native custom draft regressions.
final class CustomMemoryDraftPublicationSql extends QueryInterceptor {
  int _readsRemaining = 0;
  Completer<void>? _release;
  final _entered = Completer<void>();
  final writes = <({String statement, List<Object?> args})>[];
  Future<void> Function()? afterWrite;

  void holdSecondRead() {
    _readsRemaining = 2;
    _release = Completer<void>();
    writes.clear();
  }

  Future<void> get entered => _entered.future;

  void release() {
    if (_release != null && !_release!.isCompleted) _release!.complete();
  }

  bool _isBook(String statement) =>
      statement.toLowerCase().contains('memory_book_rows');

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    final rows = await super.runSelect(executor, statement, args);
    if (_isBook(statement) && _readsRemaining > 0 && --_readsRemaining == 0) {
      _entered.complete();
      await _release!.future;
    }
    return rows;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (_isBook(statement))
      writes.add((statement: statement, args: List.of(args)));
    final count = await super.runInsert(executor, statement, args);
    if (_isBook(statement)) await afterWrite?.call();
    return count;
  }

  @override
  Future<int> runUpdate(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    if (_isBook(statement))
      writes.add((statement: statement, args: List.of(args)));
    final count = await super.runUpdate(executor, statement, args);
    if (_isBook(statement)) await afterWrite?.call();
    return count;
  }
}
