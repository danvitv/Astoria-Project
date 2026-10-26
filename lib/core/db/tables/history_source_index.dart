part of '../tables.dart';

/// Local, rebuildable projection. None of these tables is canonical history or
/// a backup/sync collection. Tombstones and the clock outlive session deletion.
class HistoryIndexClock extends Table {
  IntColumn get id => integer()();
  IntColumn get incarnation => integer().withDefault(const Constant(0))();
  @override
  Set<Column> get primaryKey => {id};
}

class HistorySourceGenerations extends Table {
  TextColumn get sessionId => text()();
  IntColumn get incarnation => integer()();
  IntColumn get revision => integer()();
  BoolColumn get alive => boolean()();
  TextColumn get state => text().withDefault(const Constant('incomplete'))();
  IntColumn get checkpoint => integer().withDefault(const Constant(0))();
  IntColumn get unitCount => integer().withDefault(const Constant(0))();
  IntColumn get activeCount => integer().withDefault(const Constant(0))();
  TextColumn get integrity => text().nullable()();
  @override
  Set<Column> get primaryKey => {sessionId};
}

@TableIndex(
  name: 'idx_history_units_active',
  columns: {#sessionId, #incarnation, #revision, #activeOrdinal},
  unique: true,
)
@TableIndex(
  name: 'idx_history_units_identity',
  columns: {#sessionId, #incarnation, #revision, #messageId},
  unique: true,
)
class HistoryMessageUnits extends Table {
  TextColumn get sessionId => text()();
  IntColumn get incarnation => integer()();
  IntColumn get revision => integer()();
  IntColumn get nativeOrder => integer()();
  IntColumn get activeOrdinal => integer().nullable()();
  TextColumn get messageId => text()();
  IntColumn get swipeId => integer().nullable()();
  IntColumn get agentSwipeId => integer().nullable()();
  TextColumn get role => text().customConstraint(
    "NOT NULL CHECK (role IN ('user','assistant','system'))",
  )();
  TextColumn get anchorIntegrity => text()();
  // Physical row payload is capped, not merely returned/excerpted bytes.
  TextColumn get rawJson => text().customConstraint(
    'NOT NULL CHECK (octet_length(raw_json) <= 65536)',
  )();
  TextColumn get integrity => text()();
  @override
  Set<Column> get primaryKey => {sessionId, incarnation, revision, nativeOrder};
}
