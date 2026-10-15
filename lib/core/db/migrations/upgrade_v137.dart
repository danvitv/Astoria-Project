part of '../app_db.dart';

extension _AppDatabaseUpgradeV137 on AppDatabase {
  Future<void> _upgradeV137(Migrator m, int from) async {
    if (from >= 137) return;

    // Guarded per table: a database restored from a backup or test fixture can
    // already carry these tables while its user_version lags behind.
    // Declared @TableIndex entries are installed by _ensureSchemaIntegrity().
    final existingTables = (await customSelect(
      "SELECT name FROM sqlite_master WHERE type = 'table'",
    ).get()).map((row) => row.read<String>('name')).toSet();

    for (final table in <TableInfo<Table, Object?>>[
      supportSessions,
      supportMessages,
      supportContextBlocks,
      supportMutationJournal,
      supportReports,
    ]) {
      if (!existingTables.contains(table.actualTableName)) {
        await m.createTable(table);
      }
    }
  }
}
