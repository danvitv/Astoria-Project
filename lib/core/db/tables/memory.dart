part of '../tables.dart';

@DataClassName('MemoryBookRow')
class MemoryBookRows extends Table {
  @override
  String get tableName => 'memory_book_rows';

  TextColumn get sessionId => text()();
  TextColumn get entriesJson => text().withDefault(const Constant('[]'))();
  TextColumn get pendingDraftsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get settingsJson => text().withDefault(const Constant('{}'))();
  IntColumn get lastProcessedMessageCount =>
      integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId};
}

@DataClassName('MemoryCatalogRow')
@TableIndex(
  name: 'idx_memory_catalog_session_entry',
  columns: {#chatSessionId, #memoryEntryId},
)
@TableIndex(name: 'idx_memory_catalog_stale', columns: {#stale})
class MemoryCatalogRows extends Table {
  @override
  String get tableName => 'memory_catalog_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get memoryEntryId => text()();
  TextColumn get entryRevision => text().withDefault(const Constant(''))();
  TextColumn get sourceHash => text().withDefault(const Constant(''))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get keysJson => text().withDefault(const Constant('[]'))();
  TextColumn get entitiesJson => text().withDefault(const Constant('[]'))();
  TextColumn get locationsJson => text().withDefault(const Constant('[]'))();
  TextColumn get topicsJson => text().withDefault(const Constant('[]'))();
  IntColumn get messageRangeStart => integer().nullable()();
  IntColumn get messageRangeEnd => integer().nullable()();
  RealColumn get importance => real().withDefault(const Constant(0.0))();
  BoolColumn get temporallyBlind =>
      boolean().withDefault(const Constant(false))();
  IntColumn get tokenCount => integer().withDefault(const Constant(0))();
  TextColumn get abstractText => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  BoolColumn get stale => boolean().withDefault(const Constant(false))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemoryEntityRow')
@TableIndex(
  name: 'idx_memory_entity_session_name',
  columns: {#chatSessionId, #name},
)
@TableIndex(
  name: 'idx_memory_entity_session_type',
  columns: {#chatSessionId, #entityType},
)
@TableIndex(name: 'idx_memory_entity_entry', columns: {#memoryEntryId})
class MemoryEntityRows extends Table {
  @override
  String get tableName => 'memory_entity_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get memoryEntryId => text()();
  TextColumn get name => text()();
  TextColumn get entityType =>
      text().withDefault(const Constant('character'))();
  TextColumn get aliasesJson => text().withDefault(const Constant('[]'))();
  TextColumn get description => text().withDefault(const Constant(''))();
  RealColumn get salienceAvg => real().withDefault(const Constant(0.0))();
  RealColumn get saliencePeak => real().withDefault(const Constant(0.0))();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get factsJson => text().withDefault(const Constant('[]'))();
  TextColumn get emotionalValenceJson =>
      text().withDefault(const Constant('{}'))();
  IntColumn get mentionCount => integer().withDefault(const Constant(0))();
  IntColumn get lastSeenMessageIndex =>
      integer().withDefault(const Constant(0))();
  TextColumn get sourceHash => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemorySalienceRow')
@TableIndex(name: 'idx_memory_salience_session', columns: {#chatSessionId})
@TableIndex(name: 'idx_memory_salience_entry', columns: {#memoryEntryId})
class MemorySalienceRows extends Table {
  @override
  String get tableName => 'memory_salience_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  TextColumn get memoryEntryId => text()();
  RealColumn get score => real().withDefault(const Constant(0.0))();
  TextColumn get emotionalTagsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get narrativeFlagsJson =>
      text().withDefault(const Constant('[]'))();
  BoolColumn get hasDialogue => boolean().withDefault(const Constant(false))();
  BoolColumn get hasAction => boolean().withDefault(const Constant(false))();
  IntColumn get wordCount => integer().withDefault(const Constant(0))();
  TextColumn get scoreSource =>
      text().withDefault(const Constant('heuristic'))();
  IntColumn get scoredAt => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemoryCadenceRow')
class MemoryCadenceRows extends Table {
  @override
  String get tableName => 'memory_cadence_rows';

  TextColumn get chatSessionId => text()();
  IntColumn get assistantMessagesSinceLastRun =>
      integer().withDefault(const Constant(0))();
  IntColumn get lastRunMessageIndex =>
      integer().withDefault(const Constant(0))();
  IntColumn get lastRunAt => integer().withDefault(const Constant(0))();
  TextColumn get lastRunKind => text().withDefault(const Constant('graph'))();

  @override
  Set<Column> get primaryKey => {chatSessionId};
}

@DataClassName('MemoryConsolidationRow')
@TableIndex(
  name: 'idx_memory_consolidation_session_tier',
  columns: {#chatSessionId, #tier},
)
@TableIndex(
  name: 'idx_memory_consolidation_session_status',
  columns: {#chatSessionId, #status},
)
class MemoryConsolidationRows extends Table {
  @override
  String get tableName => 'memory_consolidation_rows';

  TextColumn get id => text()();
  TextColumn get chatSessionId => text()();
  IntColumn get tier => integer().withDefault(const Constant(1))();
  TextColumn get title => text().withDefault(const Constant(''))();
  TextColumn get summary => text().withDefault(const Constant(''))();
  TextColumn get sourceEntryIdsJson =>
      text().withDefault(const Constant('[]'))();
  TextColumn get entityIdsJson => text().withDefault(const Constant('[]'))();
  IntColumn get messageRangeStart => integer().withDefault(const Constant(0))();
  IntColumn get messageRangeEnd => integer().withDefault(const Constant(0))();
  RealColumn get salienceAvg => real().withDefault(const Constant(0.0))();
  TextColumn get emotionalTagsJson =>
      text().withDefault(const Constant('[]'))();
  IntColumn get tokenCount => integer().withDefault(const Constant(0))();
  TextColumn get sourceModel => text().withDefault(const Constant(''))();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get errorMessage => text().withDefault(const Constant(''))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemoryEventRow')
@TableIndex(
  name: 'idx_memory_events_session_branch_status',
  columns: {#sessionId, #branchId, #status},
)
class MemoryEventRows extends Table {
  @override
  String get tableName => 'memory_event_rows';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get branchId => text()();
  TextColumn get kind => text()();
  TextColumn get description => text()();
  TextColumn get state => text()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  TextColumn get boundaryMessageId => text().nullable()();
  IntColumn get boundarySwipeId => integer().nullable()();
  IntColumn get boundaryAgentSwipeId => integer().nullable()();
  IntColumn get boundaryOrdinal => integer().nullable()();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  IntColumn get acceptedAt => integer()();
  TextColumn get acceptedBy => text().withDefault(const Constant('user'))();
  IntColumn get createdAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemoryEventSourceRow')
@TableIndex(name: 'idx_memory_event_sources_event', columns: {#eventId})
@TableIndex(
  name: 'idx_memory_event_sources_memory',
  columns: {#sessionId, #memoryEntryId},
)
class MemoryEventSourceRows extends Table {
  @override
  String get tableName => 'memory_event_source_rows';

  TextColumn get id => text()();
  TextColumn get eventId => text()();
  TextColumn get sessionId => text()();
  TextColumn get branchId => text()();
  TextColumn get memoryEntryId => text()();
  TextColumn get revisionId => text()();
  TextColumn get fingerprint => text()();
  TextColumn get sourceManifestJson =>
      text().withDefault(const Constant('{}'))();
  TextColumn get messageIdsJson => text().withDefault(const Constant('[]'))();
  IntColumn get sourceSwipeId => integer().withDefault(const Constant(0))();
  IntColumn get sourceAgentSwipeId =>
      integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {id};
}

@DataClassName('MemoryEventLinkRow')
@TableIndex(name: 'idx_memory_event_links_from', columns: {#fromEventId})
@TableIndex(name: 'idx_memory_event_links_to', columns: {#toEventId})
class MemoryEventLinkRows extends Table {
  @override
  String get tableName => 'memory_event_link_rows';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get branchId => text()();
  TextColumn get fromEventId => text()();
  TextColumn get toEventId => text()();
  TextColumn get relation => text()();
  TextColumn get status => text().withDefault(const Constant('active'))();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  IntColumn get acceptedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};
}

/// Append-only audit trail for accepted events and links whose provenance
/// stopped verifying. Registry rows remain available for review.
@DataClassName('MemoryEventInvalidationRow')
class MemoryEventInvalidationRows extends Table {
  @override
  String get tableName => 'memory_event_invalidation_rows';

  IntColumn get id => integer().autoIncrement()();
  TextColumn get sessionId => text()();
  TextColumn get branchId => text()();
  TextColumn get targetType => text()();
  TextColumn get targetId => text()();
  TextColumn get causeMemoryEntryId => text().nullable()();
  TextColumn get reason => text()();
  IntColumn get createdAt => integer()();

  @override
  List<Set<Column>> get uniqueKeys => [
    {sessionId, branchId, targetType, targetId, reason},
  ];

  @override
  List<String> get customConstraints => [
    "CHECK (session_id <> '' AND branch_id <> '' AND target_type IN ('event', 'link') AND target_id <> '' AND reason <> '')",
  ];
}

/// Durable, resumable package work. Model output remains a draft until each
/// item is explicitly accepted through the event registry.
@DataClassName('MemoryConsolidationJobRow')
@TableIndex(
  name: 'idx_memory_consolidation_job_status_lease',
  columns: {#status, #leaseExpiresAt},
)
@TableIndex(
  name: 'idx_memory_consolidation_job_request_key',
  columns: {#requestKey},
  unique: true,
)
class MemoryConsolidationJobRows extends Table {
  @override
  String get tableName => 'memory_consolidation_job_rows';

  TextColumn get id => text()();
  TextColumn get sessionId => text()();
  TextColumn get branchId => text()();
  TextColumn get requestKey => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get packageDraftJson => text().nullable()();
  TextColumn get leaseOwnerId => text().nullable()();
  IntColumn get leaseExpiresAt => integer().nullable()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get version => integer().withDefault(const Constant(1))();
  TextColumn get lastError => text().nullable()();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (id <> '' AND session_id <> '' AND branch_id <> '' AND request_key <> '')",
    "CHECK (status IN ('pending', 'running', 'review_pending', 'failed', 'cancelled', 'completed'))",
    'CHECK (attempt_count >= 0 AND version > 0)',
    'CHECK ((lease_owner_id IS NULL AND lease_expires_at IS NULL) OR '
        '(lease_owner_id IS NOT NULL AND lease_expires_at IS NOT NULL))',
  ];
}

/// Per-source durable package progress and review draft. Draft JSON is not an
/// accepted registry write; acceptance remains a separate user action.
@DataClassName('MemoryConsolidationJobItemRow')
@TableIndex(
  name: 'idx_memory_consolidation_job_item_status',
  columns: {#jobId, #status},
)
class MemoryConsolidationJobItemRows extends Table {
  @override
  String get tableName => 'memory_consolidation_job_item_rows';

  TextColumn get id => text()();
  TextColumn get jobId => text()();
  TextColumn get memoryEntryId => text()();
  TextColumn get revisionId => text()();
  TextColumn get fingerprint => text()();
  TextColumn get proposedEventId => text()();
  TextColumn get status => text().withDefault(const Constant('pending'))();
  TextColumn get draftJson => text().nullable()();
  TextColumn get lastError => text().nullable()();
  IntColumn get attemptCount => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();

  @override
  Set<Column> get primaryKey => {id};

  @override
  List<String> get customConstraints => [
    "CHECK (id <> '' AND job_id <> '' AND memory_entry_id <> '' AND revision_id <> '' AND fingerprint <> '' AND proposed_event_id <> '')",
    "CHECK (status IN ('pending', 'running', 'review_pending', 'accepted', 'failed', 'cancelled'))",
    'CHECK (attempt_count >= 0)',
    'FOREIGN KEY (job_id) REFERENCES memory_consolidation_job_rows (id) ON DELETE CASCADE',
  ];
}

@DataClassName('EmbeddingRow')
@TableIndex(name: 'idx_embeddings_source_type', columns: {#sourceType})
@TableIndex(name: 'idx_embeddings_source_id', columns: {#sourceId})
@TableIndex(
  name: 'idx_embeddings_source_type_id',
  columns: {#sourceType, #sourceId},
)
class Embeddings extends Table {
  @override
  String get tableName => 'embeddings';

  TextColumn get entryId => text()();
  TextColumn get sourceType =>
      text().withDefault(const Constant('lorebook_entry'))();
  TextColumn get sourceId => text().nullable()();
  BlobColumn get vectorsBlob => blob().nullable()();
  TextColumn get textHash => text().nullable()();
  TextColumn get retrievalHintsJson => text().nullable()();
  TextColumn get errorJson => text().nullable()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {entryId};
}

@DataClassName('ChatSummary')
class ChatSummaries extends Table {
  @override
  String get tableName => 'chat_summaries';

  TextColumn get sessionId => text()();
  TextColumn get content => text()();
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();
  IntColumn get messageCount => integer().withDefault(const Constant(0))();
  TextColumn get prompt => text().nullable()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId};
}
