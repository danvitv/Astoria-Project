part of '../app_db.dart';

extension _MemoryConsolidationPackageDraftMigration on AppDatabase {
  Future<void> _upgradeV143(Migrator m, int from) async {
    if (from >= 143) return;
    // A database older than v142 creates the job table from the current Drift
    // definition in _upgradeV142. Only an existing v142 table needs ALTER.
    if (from < 142) return;
    await m.addColumn(
      memoryConsolidationJobRows,
      memoryConsolidationJobRows.packageDraftJson,
    );
  }
}
