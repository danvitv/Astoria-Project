part of '../app_db.dart';

extension _HistoryAnchorMigration on AppDatabase {
  /// Shipped v138 may have the original eight-column derived projection. It
  /// cannot acquire authenticated anchors by inventing defaults or parsing the
  /// canonical history during opening. Discard only that rebuildable cache.
  Future<void> _upgradeV139(Migrator m, int from) async {
    if (from < 138 || from >= 139) return;
    final columns = (await customSelect(
      "SELECT name FROM pragma_table_info('history_message_units')",
    ).get()).map((row) => row.read<String>('name')).toSet();
    const original = {
      'session_id',
      'incarnation',
      'revision',
      'native_order',
      'active_ordinal',
      'message_id',
      'raw_json',
      'integrity',
    };
    const anchored = {
      ...original,
      'swipe_id',
      'agent_swipe_id',
      'role',
      'anchor_integrity',
    };
    if (columns.length == anchored.length && columns.containsAll(anchored)) {
      return; // Already generated twelve-column v138: no duplicate ALTERs.
    }
    if (columns.length != original.length || !columns.containsAll(original)) {
      throw StateError('Unsupported derived history schema at version 138.');
    }
    await customStatement('DROP TABLE history_message_units');
    await m.createTable(historyMessageUnits);
    // Keep incarnation/tombstone identity and the monotonic clock. Retire old
    // revisions, including checkpoints, so nothing is ready until owned rebuild.
    await customStatement(
      "UPDATE history_source_generations SET revision=revision+1,state='incomplete',"
      'checkpoint=0,unit_count=0,active_count=0,integrity=NULL',
    );
    for (final statement in historyIndexTriggers.values) {
      await customStatement(statement);
    }
    // Declared unit indexes are restored by the final schema integrity pass.
  }
}
