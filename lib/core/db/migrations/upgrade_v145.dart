part of '../app_db.dart';

extension _ChatMessageStorageMigration on AppDatabase {
  Future<void> _upgradeV145(Migrator m, int from) async {
    if (from >= 145) return;
    await m.createTable(chatMessageStorageRows);
    await m.createTable(chatMessageRows);
    await _installChatMessageStorageLifecycle();
    await _installHistoryInvalidation();
  }

  Future<void> _installChatMessageStorageLifecycle() async {
    // Foreign keys are not enabled uniformly on every retained/imported
    // connection. Keep row-backed history from surviving its owning session.
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS chat_message_rows_session_delete
      AFTER DELETE ON chat_sessions BEGIN
        DELETE FROM chat_message_rows WHERE session_id = OLD.session_id;
        DELETE FROM chat_message_storage_rows WHERE session_id = OLD.session_id;
      END
    ''');
    // State removal is an explicit fallback/repair operation. Its inactive and
    // active generations must disappear together even without FK enforcement.
    await customStatement('''
      CREATE TRIGGER IF NOT EXISTS chat_message_rows_state_delete
      AFTER DELETE ON chat_message_storage_rows BEGIN
        DELETE FROM chat_message_rows WHERE session_id = OLD.session_id;
      END
    ''');
  }
}
