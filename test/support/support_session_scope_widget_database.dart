import 'package:drift/drift.dart';
import 'package:glaze_flutter/core/db/app_db.dart';

/// Source-only declared schema. Observes the entire ORIGINAL Drift transaction,
/// not just its final SELECT, so a held parent-metadata read cannot outlive close.
final class GuidanceMemoryDatabase extends AppDatabase {
  GuidanceMemoryDatabase(super.executor) : super.forTesting();
  int activeTransactions = 0;
  @override
  MigrationStrategy get migration =>
      MigrationStrategy(onCreate: (migrator) => migrator.createAll());

  @override
  Future<T> transaction<T>(
    Future<T> Function() action, {
    bool requireNew = false,
  }) async {
    activeTransactions++;
    try {
      return await super.transaction(action, requireNew: requireNew);
    } finally {
      activeTransactions--;
    }
  }
}
