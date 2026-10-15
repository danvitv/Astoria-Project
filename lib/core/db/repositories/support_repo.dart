import 'dart:math' as math;
import 'package:drift/drift.dart';
import '../../models/support_models.dart';
import '../../support/support_payload_cipher.dart';
import '../app_db.dart';

part 'support/support_row_mapper.dart';
part 'support/support_session_store.dart';
part 'support/support_message_store.dart';
part 'support/support_context_store.dart';
part 'support/support_journal_store.dart';

/// Stable entry point; each specialist owns its narrow DB transactions.
class SupportRepo {
  SupportRepo(AppDatabase db, SupportPayloadCipher cipher) {
    final mapper = _SupportRowMapper(cipher);
    _sessions = _SupportSessionStore(db, cipher, mapper);
    _messages = _SupportMessageStore(db, cipher, mapper, _sessions);
    _context = _SupportContextStore(db, cipher, mapper, _sessions);
    _journal = _SupportJournalStore(db, cipher, mapper, _sessions);
  }
  late final _SupportSessionStore _sessions;
  late final _SupportMessageStore _messages;
  late final _SupportContextStore _context;
  late final _SupportJournalStore _journal;

  Future<SupportSession> createSession(SupportSession session) =>
      _sessions.put(session, createOnly: true);
  Future<SupportSession> putSession(SupportSession session) =>
      _sessions.put(session);
  Future<SupportSession?> getSessionById(String id) => _sessions.get(id);
  Future<List<SupportSession>> getAllSessions() => _sessions.all();
  Stream<List<SupportSession>> watchAllSessions() => _sessions.watch();
  Future<SupportSession?> renameSession({
    required String sessionId,
    required String title,
    int? updatedAt,
  }) => _sessions.rename(sessionId, title, updatedAt);
  Future<SupportSession?> updateSessionMetadata({
    required String sessionId,
    bool? pinned,
    String? mode,
    String? activeApiConfigId,
    bool clearActiveApiConfigId = false,
    String? activeModelId,
    bool clearActiveModelId = false,
    int? updatedAt,
  }) => _sessions.updateMetadata(
    sessionId: sessionId,
    pinned: pinned,
    mode: mode,
    activeApiConfigId: activeApiConfigId,
    clearActiveApiConfigId: clearActiveApiConfigId,
    activeModelId: activeModelId,
    clearActiveModelId: clearActiveModelId,
    updatedAt: updatedAt,
  );
  Future<void> deleteSession(String sessionId) => _sessions.delete(sessionId);
  Future<SupportMessage> appendMessage(
    SupportMessage message, {
    int? sessionUpdatedAt,
  }) =>
      _messages.put(message, append: true, sessionUpdatedAt: sessionUpdatedAt);
  Future<SupportMessage> putMessage(SupportMessage message) =>
      _messages.put(message);
  Future<SupportMessage?> mutateMessage({
    required String messageId,
    required SupportMessage Function(SupportMessage latest) mutate,
  }) => _messages.mutate(messageId, mutate);
  Future<SupportMessage?> updateMessageStatus({
    required String messageId,
    required String status,
  }) => _messages.updateStatus(messageId, status);
  Future<SupportMessage?> getMessageById(String id) => _messages.get(id);
  Future<List<SupportMessage>> getMessagesForSession(String sessionId) =>
      _messages.all(sessionId);
  Stream<List<SupportMessage>> watchMessagesForSession(String sessionId) =>
      _messages.watch(sessionId);
  Future<void> deleteMessage(String messageId) => _messages.delete(messageId);
  Future<SupportContextBlock> putContextBlock(SupportContextBlock block) =>
      _context.put(block);
  Future<SupportContextBlock?> getContextBlockById(String id) =>
      _context.get(id);
  Future<List<SupportContextBlock>> getContextBlocksForSession(
    String sessionId, {
    bool activeOnly = false,
  }) => _context.all(sessionId, activeOnly: activeOnly);
  Future<void> deactivateContextBlock(String blockId) =>
      _context.deactivate(blockId);
  Future<SupportMutationRecord> recordMutation(SupportMutationRecord record) =>
      _journal.putMutation(record);
  Future<SupportMutationRecord> putMutation(SupportMutationRecord record) =>
      _journal.putMutation(record);
  Future<SupportMutationRecord?> getMutationById(String id) =>
      _journal.getMutation(id);
  Future<List<SupportMutationRecord>> getMutationsForSession(
    String sessionId,
  ) => _journal.mutations(sessionId);
  Future<SupportMutationRecord?> updateMutationStatus({
    required String id,
    required String status,
  }) => _journal.updateMutationStatus(id, status);
  Future<SupportReportRecord> recordReport(SupportReportRecord report) =>
      _journal.putReport(report);
  Future<SupportReportRecord> putReport(SupportReportRecord report) =>
      _journal.putReport(report);
  Future<SupportReportRecord?> getReportById(String id) =>
      _journal.getReport(id);
  Future<List<SupportReportRecord>> getReportsForSession(String sessionId) =>
      _journal.reports(sessionId);
}
