part of '../tables.dart';

@DataClassName('CharacterRow')
class Characters extends Table {
  @override
  String get tableName => 'characters';

  TextColumn get charId => text()();
  TextColumn get name => text()();
  TextColumn get avatarPath => text().nullable()();
  TextColumn get description => text().nullable()();
  TextColumn get personality => text().nullable()();
  TextColumn get scenario => text().nullable()();
  TextColumn get firstMes => text().nullable()();
  TextColumn get mesExample => text().nullable()();
  TextColumn get systemPrompt => text().nullable()();
  TextColumn get postHistoryInstructions => text().nullable()();
  TextColumn get creator => text().nullable()();
  TextColumn get creatorNotes => text().nullable()();
  TextColumn get color => text().nullable()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  TextColumn get tagsJson => text().nullable()();
  TextColumn get alternateGreetingsJson => text().nullable()();
  TextColumn get galleryJson => text().nullable()();
  IntColumn get currentSessionIndex =>
      integer().withDefault(const Constant(0))();
  BoolColumn get fav => boolean().withDefault(const Constant(false))();
  TextColumn get extensionsJson => text().nullable()();
  TextColumn get characterVersion => text().withDefault(const Constant('1'))();
  TextColumn get macroName => text().nullable()();
  TextColumn get picksHash => text().nullable()();
  IntColumn get tokenCount => integer().withDefault(const Constant(0))();

  // Variations: each row is a full character card, but rows sharing a
  // [variantGroupId] are presented as a single entry in the My Characters list.
  // The representative ("cover") is the row with the lowest [variantOrder] (0).
  // For a standalone character, variantGroupId equals its own charId.
  TextColumn get variantGroupId => text().withDefault(const Constant(''))();
  TextColumn get variantName => text().nullable()();
  IntColumn get variantOrder => integer().withDefault(const Constant(0))();

  // Hidden characters are excluded from the My Characters list (and its count)
  // unless the user reveals them via the secret gesture (10 taps on the
  // Characters tab within 1.5s). Applied group-wide for a variation group.
  BoolColumn get hidden => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {charId};
}

@DataClassName('CharacterFolderRow')
class CharacterFolders extends Table {
  @override
  String get tableName => 'character_folders';

  TextColumn get folderId => text()();
  TextColumn get name => text()();
  TextColumn get color => text().nullable()();
  IntColumn get sortOrder => integer().withDefault(const Constant(0))();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {folderId};
}

@DataClassName('CharacterFolderMemberRow')
@TableIndex(name: 'idx_cfm_folder', columns: {#folderId})
@TableIndex(name: 'idx_cfm_char', columns: {#charId})
class CharacterFolderMembers extends Table {
  @override
  String get tableName => 'character_folder_members';

  TextColumn get folderId => text()();
  TextColumn get charId => text()();
  IntColumn get addedAt => integer().withDefault(const Constant(0))();

  // Composite PK: a character can live in many folders (same charId across
  // different folderId rows), but cannot be duplicated within one folder.
  @override
  Set<Column> get primaryKey => {folderId, charId};
}

@DataClassName('ChatSessionRow')
@TableIndex(name: 'idx_chat_sessions_character_id', columns: {#characterId})
@TableIndex(name: 'idx_chat_sessions_updated_at', columns: {#updatedAt})
class ChatSessions extends Table {
  @override
  String get tableName => 'chat_sessions';

  TextColumn get sessionId => text()();
  TextColumn get characterId => text()();
  IntColumn get sessionIndex => integer()();
  TextColumn get messagesJson => text()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();
  TextColumn get sessionVarsJson => text().nullable()();
  TextColumn get authorsNoteJson => text().nullable()();
  TextColumn get draft => text().nullable()();
  TextColumn get lastScrollAnchorJson => text().nullable()();

  @override
  Set<Column> get primaryKey => {sessionId};
}

/// Presence marks a session whose canonical messages live in
/// [ChatMessageRows]. Legacy sessions have no state row and continue to use
/// `chat_sessions.messages_json` until the separate lazy-migration slice.
@DataClassName('ChatMessageStorageStateRow')
class ChatMessageStorageRows extends Table {
  @override
  String get tableName => 'chat_message_storage_rows';

  TextColumn get sessionId => text().references(
    ChatSessions,
    #sessionId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get activeGeneration => integer().withDefault(const Constant(1))();
  IntColumn get revision => integer().withDefault(const Constant(1))();
  IntColumn get messageCount => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {sessionId};

  @override
  List<String> get customConstraints => [
    'CHECK (active_generation > 0 AND revision > 0 AND message_count >= 0)',
  ];
}

/// Canonical per-message storage for row-backed chat sessions. [messageJson]
/// retains the complete ChatMessage codec while indexed projections support
/// ordered and identity-bounded operations without parsing unrelated messages.
@DataClassName('ChatMessageRow')
@TableIndex(
  name: 'idx_chat_message_rows_position',
  columns: {#sessionId, #storageGeneration, #positionKey},
  unique: true,
)
@TableIndex(
  name: 'idx_chat_message_rows_message_id',
  columns: {#sessionId, #storageGeneration, #messageId},
)
class ChatMessageRows extends Table {
  @override
  String get tableName => 'chat_message_rows';

  IntColumn get rowId => integer().autoIncrement()();
  TextColumn get sessionId => text().references(
    ChatSessions,
    #sessionId,
    onDelete: KeyAction.cascade,
  )();
  IntColumn get storageGeneration => integer()();
  IntColumn get positionKey => integer()();
  TextColumn get messageId => text()();
  TextColumn get role => text()();
  IntColumn get messageTimestamp => integer().nullable()();
  TextColumn get messageJson => text()();
  IntColumn get updatedAt => integer().withDefault(const Constant(0))();

  @override
  List<String> get customConstraints => [
    'CHECK (storage_generation > 0 AND position_key > 0 '
        "AND role <> '' AND message_json <> '')",
  ];
}

@DataClassName('PersonaRow')
class Personas extends Table {
  @override
  String get tableName => 'personas';

  TextColumn get personaId => text()();
  TextColumn get name => text()();
  TextColumn get prompt => text().nullable()();
  TextColumn get avatarPath => text().nullable()();
  IntColumn get createdAt => integer().withDefault(const Constant(0))();

  @override
  Set<Column> get primaryKey => {personaId};
}
