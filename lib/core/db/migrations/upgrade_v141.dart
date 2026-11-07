part of '../app_db.dart';

extension _MemoryEventInvalidationMigration on AppDatabase {
  Future<void> _upgradeV141(Migrator m, int from) async {
    if (from >= 141) return;
    await m.createTable(memoryEventInvalidationRows);
  }
}
