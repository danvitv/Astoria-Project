part of '../tables.dart';

@DataClassName('SupportSessionRow')
@TableIndex(
  name: 'idx_support_sessions_updated_at',
  columns: {#pinned, #updatedAt},
)
class SupportSessions extends Table {
  @override
  String get tableName => 'support_sessions';

  TextColumn get id => text()();
  TextColumn get titleCiphertext => text()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();
  TextColumn get mode => text().withDefault(const Constant('hybrid'))();
  TextColumn get activeApiConfigId => text().nullable()();
  TextColumn get activeModelId => text().nullable()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SupportMessageRow')
@TableIndex(name: 'idx_support_messages_session_id', columns: {#sessionId})
@TableIndex(
  name: 'idx_support_messages_session_created_at',
  columns: {#sessionId, #createdAt},
)
class SupportMessages extends Table {
  @override
  String get tableName => 'support_messages';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get role => text()();
  TextColumn get bodyCiphertext => text()();
  TextColumn get cardsCiphertext => text().withDefault(const Constant(''))();
  TextColumn get runId => text().nullable()();
  TextColumn get status => text().withDefault(const Constant('complete'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SupportContextBlockRow')
@TableIndex(
  name: 'idx_support_context_blocks_session_id',
  columns: {#sessionId},
)
@TableIndex(
  name: 'idx_support_context_blocks_session_active',
  columns: {#sessionId, #isActive},
)
class SupportContextBlocks extends Table {
  @override
  String get tableName => 'support_context_blocks';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get startMessageId => text()();
  TextColumn get endMessageId => text()();
  TextColumn get summaryCiphertext => text()();
  TextColumn get protectedFactsCiphertext =>
      text().withDefault(const Constant(''))();
  BoolColumn get isActive => boolean().withDefault(const Constant(true))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SupportMutationJournalRow')
@TableIndex(
  name: 'idx_support_mutation_journal_session_id',
  columns: {#sessionId},
)
@TableIndex(
  name: 'idx_support_mutation_journal_session_created_at',
  columns: {#sessionId, #createdAt},
)
class SupportMutationJournal extends Table {
  @override
  String get tableName => 'support_mutation_journal';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get domain => text()();
  TextColumn get targetId => text()();
  TextColumn get beforeCiphertext => text()();
  TextColumn get afterCiphertext => text()();
  TextColumn get status => text().withDefault(const Constant('applied'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('SupportReportRow')
@TableIndex(name: 'idx_support_reports_session_id', columns: {#sessionId})
class SupportReports extends Table {
  @override
  String get tableName => 'support_reports';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get fileHash => text()();
  TextColumn get status => text().withDefault(const Constant('exported'))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}
