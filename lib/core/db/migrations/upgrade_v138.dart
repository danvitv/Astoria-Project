part of '../app_db.dart';

extension _HistoryIndexMigration on AppDatabase {
  Future<void> _upgradeV138(Migrator m, int from) async {
    if (from >= 138) return;
    await m.createTable(historyIndexClock);
    await m.createTable(historySourceGenerations);
    await m.createTable(historyMessageUnits);
    await _installHistoryInvalidation();
  }

  Future<void> _installHistoryInvalidation() async {
    await customStatement(
      'INSERT OR IGNORE INTO history_index_clock (id,incarnation) VALUES(1,0)',
    );
    // Metadata keysets only. NEVER parse/rewrite legacy canonical messages_json.
    String? after;
    while (true) {
      final rows = await customSelect(
        'SELECT session_id FROM chat_sessions '
        '${after == null ? '' : 'WHERE session_id>? '}ORDER BY session_id LIMIT 128',
        variables: [if (after != null) Variable.withString(after)],
      ).get();
      for (final row in rows) {
        final id = row.read<String>('session_id');
        await customStatement(
          'UPDATE history_index_clock SET incarnation=incarnation+1 WHERE id=1',
        );
        await customStatement(
          'INSERT OR IGNORE INTO history_source_generations '
          '(session_id,incarnation,revision,alive,state) SELECT ?,incarnation,1,1,\'incomplete\' '
          'FROM history_index_clock WHERE id=1',
          [id],
        );
      }
      if (rows.length < 128) break;
      after = rows.last.read<String>('session_id');
    }
    for (final statement in historyIndexTriggers.values) {
      await customStatement(statement);
    }
    for (final statement in sourceNavigationIndexes.values) {
      await customStatement(statement);
    }
  }
}
