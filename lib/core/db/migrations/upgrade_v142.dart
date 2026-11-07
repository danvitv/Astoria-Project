part of '../app_db.dart';

extension _MemoryConsolidationJobsMigration on AppDatabase {
  Future<void> _upgradeV142(Migrator m, int from) async {
    if (from >= 142) return;
    await m.createTable(memoryConsolidationJobRows);
    await m.createTable(memoryConsolidationJobItemRows);
  }
}
