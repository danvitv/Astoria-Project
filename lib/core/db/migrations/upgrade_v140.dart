part of '../app_db.dart';

extension _MemoryEventRegistryMigration on AppDatabase {
  Future<void> _upgradeV140(Migrator m, int from) async {
    if (from >= 140) return;
    final existingTables = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ).get()).map((row) => row.read<String>('name')).toSet();

    for (final table in <TableInfo<Table, Object?>>[
      memoryEventRows,
      memoryEventSourceRows,
      memoryEventLinkRows,
    ]) {
      if (!existingTables.contains(table.actualTableName)) {
        await m.createTable(table);
      }
    }
  }
}
