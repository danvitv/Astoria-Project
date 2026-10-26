import 'dart:math' as math;
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import '../../models/support_models.dart';
import '../../support/support_payload_cipher.dart';
import '../app_db.dart';
import 'support_source_text/support_source_json.dart';

part 'support/support_row_mapper.dart';
part 'support/support_session_store.dart';
part 'support/support_message_store.dart';
part 'support/support_native_input_store.dart';
part 'support/support_guarded_reply_store.dart';
part 'support/support_native_local_reply_store.dart';
part 'support/support_context_store.dart';
part 'support/support_assistant_settings_store.dart';
part 'support/support_global_permission_store.dart';
part 'support/support_journal_store.dart';
part 'support/support_mutation_journal_contract.dart';
part 'support/support_guarded_mutation_store.dart';
part 'support/support_mutation_history_reader.dart';
part 'support/support_mutation_history_types.dart';
part 'support/support_compaction_store.dart';
part 'support/support_reply_regeneration_store.dart';
part 'support/support_user_edit_store.dart';
part 'support/support_unanswered_user_store.dart';
part 'support/support_reply_source_store.dart';

/// Exact committed snapshots, retained only by the native run owner.
typedef SupportReplyReservation = ({
  SupportMessage message,
  SupportContextBlock provenance,
});

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

  /// Identity check only; never opens/replaces a database or grants custody.
  bool usesDatabase(AppDatabase db) => identical(_journal.db, db);

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

  /// Action-enabled deletion: one transaction excludes unresolved, unknown,
  /// malformed or unreadable journal evidence. Legacy deleteSession is unchanged.
  Future<bool> deleteSessionIfMutationsSettled({
    required String sessionId,
    required bool Function() isCurrent,
  }) => _journal.guarded.deleteSession(sessionId, isCurrent);
  Future<SupportMessage> appendMessage(
    SupportMessage message, {
    int? sessionUpdatedAt,
  }) =>
      _messages.put(message, append: true, sessionUpdatedAt: sessionUpdatedAt);
  Future<SupportMessage> putMessage(SupportMessage message) =>
      _messages.put(message);

  /// Create-only sanitized native user input. Null is a refusal; failures throw
  /// without committing. createdAt is a clock floor, not the stored timestamp.
  /// The returned durable row is custody, not permission to disclose its text.
  Future<SupportMessage?> appendCurrentUser({
    required SupportMessage message,
    required bool Function() isCurrent,
  }) => _messages.nativeInput.append(message, isCurrent);

  /// Exact original-row observation; no DTO can reconstruct encrypted custody.
  Future<SupportUserEditingObservation?> readUserForEditing({
    required SupportMessage expectedUser,
    required bool Function() isCurrent,
  }) => _messages.replies.readUserForEditing(expectedUser, isCurrent);
  Future<SupportMessage?> editUserMessage({
    required SupportUserEditingObservation expected,
    required String body,
    required bool Function() isCurrent,
  }) => _messages.replies.editUserMessage(expected, body, isCurrent);

  /// Last COMPLETE native input only. Observation is not disclosure permission.
  Future<SupportUnansweredUserObservation?> readUnansweredUser({
    required SupportMessage expectedUser,
    required bool Function() isCurrent,
  }) => _messages.replies.readUnansweredUser(expectedUser, isCurrent);
  Future<SupportReplyReservation?> reserveUnansweredReply({
    required SupportUnansweredUserObservation expected,
    required SupportMessage message,
    required String provenanceJson,
    required bool Function() isCurrent,
  }) => _messages.replies.reserve(
    message,
    provenanceJson,
    isCurrent,
    originatingUser: expected.message,
    unanswered: expected,
  );

  /// Create-only preparing reply and dedicated inactive encrypted provenance.
  /// Null means refused/missing; cipher/storage failures throw without commits.
  /// Text/provenance must already be sanitized by the trusted caller.
  Future<SupportReplyReservation?> reserveReply({
    required SupportMessage message,
    required String provenanceJson,
    required bool Function() isCurrent,
  }) => _messages.replies.reserve(message, provenanceJson, isCurrent);

  /// Opt-in native reservation: compare the exact same-run durable user and
  /// allocate later than all session message metadata and the supplied floor.
  /// Like reserveReply, this does not authorize a model request.
  Future<SupportReplyReservation?> reserveOrderedReply({
    required SupportMessage message,
    required SupportMessage originatingUser,
    required String provenanceJson,
    required bool Function() isCurrent,
  }) => _messages.replies.reserve(
    message,
    provenanceJson,
    isCurrent,
    originatingUser: originatingUser,
  );

  /// Opt-in last-answer observation/re-reservation. Neither restores native
  /// authority nor relaxes the create-only ordinary reservation contract.
  Future<SupportReplyRegenerationObservation?> readReplyForRegeneration({
    required SupportMessage expectedReply,
    required bool Function() isCurrent,
  }) => _messages.replies.readForRegeneration(expectedReply, isCurrent);
  Future<SupportMessage?> readReplyOrigin({
    required String sessionId,
    required String messageId,
    required bool Function() isCurrent,
  }) => _messages.replies.readOrigin(sessionId, messageId, isCurrent);
  Future<SupportReplyReservation?> reserveRegeneratedReply({
    required SupportReplyRegenerationObservation expected,
    required SupportMessage originatingUser,
    required String attemptRunId,
    required String provenanceJson,
    required bool Function() isCurrent,
  }) => _messages.replies.regenerate(
    expected,
    originatingUser,
    attemptRunId,
    provenanceJson,
    isCurrent,
  );
  Future<bool> validateRegenerationPosition({
    required SupportMessage reply,
    required bool Function() isCurrent,
  }) => _messages.replies.validateRegenerationPosition(reply, isCurrent);

  /// Only body/status may change; exact prior snapshots are compared inside the
  /// transaction. The guard can represent original-session settlement ownership
  /// independently of UI/transport ownership (and must remain synchronous).
  Future<SupportMessage?> settleReply({
    required SupportReplyReservation expected,
    required String status,
    String? body,
    required bool Function() isCurrent,
  }) => _messages.replies.settle(expected, status, body, isCurrent);

  /// Exact pending-row observation for appending encrypted source metadata only.
  Future<SupportReplySourceObservation?> readReplyForSourceExtension({
    required SupportReplyReservation expected,
    required SupportMessage originatingUser,
    required bool Function() isCurrent,
  }) => _messages.replies.readReplyForSourceExtension(
    expected,
    originatingUser,
    isCurrent,
  );

  Future<SupportReplyReservation?> extendReplySources({
    required SupportReplySourceObservation expected,
    required String provenanceJson,
    required bool Function() isCurrent,
  }) =>
      _messages.replies.extendReplySources(expected, provenanceJson, isCurrent);

  Future<SupportReplySourceCommit?> extendReplySourcesAttested({
    required SupportReplySourceObservation expected,
    required String provenanceJson,
    required bool Function() isCurrent,
  }) => _messages.replies.extendReplySourcesAttested(
    expected,
    provenanceJson,
    isCurrent,
  );

  /// Fixed native LOCAL response only. Reuses the exact-user reservation and
  /// settlement port, adding its cards in the SAME outer transaction. A refusal
  /// or any failure rolls back both the reply and dedicated encrypted recipe.
  /// The trusted caller supplies sanitized fixed text/cards and origin facts;
  /// this method does not classify old replies or authorize model disclosure.
  Future<SupportMessage?> appendNativeLocalReply({
    required SupportMessage message,
    required SupportMessage originatingUser,
    required String provenanceJson,
    required bool Function() isCurrent,
  }) => _messages.appendNativeLocalReply(
    message,
    originatingUser,
    provenanceJson,
    isCurrent,
  );

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

  /// Selected native row only. Metadata and live ownership are checked in the
  /// same transaction as deletion; no encrypted body or derived state is read.
  Future<bool> deleteCurrentMessage({
    required String sessionId,
    required String messageId,
    required int createdAt,
    required String role,
    required String? runId,
    required bool Function() isCurrent,
  }) => _messages.db.transaction(() async {
    if (!isCurrent()) return false;
    final row = await _messages.row(messageId);
    if (!isCurrent() ||
        row == null ||
        row.sessionId != sessionId ||
        row.createdAt != createdAt ||
        row.role != role ||
        row.runId != runId) {
      return false;
    }
    await _messages.delete(messageId);
    // A switch during the SQL await must roll back, not report a stale success.
    if (!isCurrent()) throw StateError('Support message deletion retired.');
    return true;
  });
  Future<SupportContextBlock> putContextBlock(SupportContextBlock block) =>
      _context.put(block);

  /// Latest-row decision and write share one transaction. A null candidate is
  /// a no-op; callbacks are synchronous and must not perform external work.
  Future<SupportContextBlock?> mutateContextBlock({
    required String blockId,
    required String sessionId,
    required SupportContextBlock? Function(SupportContextBlock? latest) mutate,
    bool Function()? isCurrent,
  }) => _context.mutate(blockId, sessionId, mutate, isCurrent);
  Future<SupportContextBlock?> getContextBlockById(String id) =>
      _context.get(id);

  /// One encrypted app-wide profile, outside all conversation ranges/cascades.
  static const assistantSettingsId = 'workspace-settings-global-v1';
  Future<SupportContextBlock?> initializeAssistantSettings({
    required List<String> legacySessionIds,
    required SupportContextBlock Function(SupportContextBlock? legacy) create,
    required bool Function() isCurrent,
  }) => _context.assistantSettings.initialize(
    legacySessionIds,
    create,
    isCurrent,
  );
  Future<SupportContextBlock?> mutateAssistantSettings({
    required SupportContextBlock? Function(SupportContextBlock? latest) mutate,
    bool Function()? isCurrent,
  }) => _context.assistantSettings.mutate(mutate, isCurrent ?? () => true);

  /// Fixed global permission profile, never a conversation or arbitrary body port.
  static const assistantPermissionsId = 'workspace-permissions-global-v1';
  Future<SupportContextBlock?> initializeAssistantPermissions({
    required String currentSessionId,
    required List<String> legacySessionIds,
    required SupportContextBlock Function(SupportContextBlock? legacy) create,
    required bool Function() isCurrent,
  }) => _SupportGlobalPermissionStore(
    _context,
  ).initialize(currentSessionId, legacySessionIds, create, isCurrent);
  Future<SupportContextBlock?> mutateAssistantPermissions({
    required String currentSessionId,
    required SupportContextBlock? Function(SupportContextBlock latest) mutate,
    required bool Function() isCurrent,
  }) => _SupportGlobalPermissionStore(
    _context,
  ).mutate(currentSessionId, mutate, isCurrent);

  /// Compatibility edits may not race a global initialization and report a
  /// successful change to an obsolete per-chat policy.
  Future<SupportContextBlock?> mutateLegacyAssistantPermissions({
    required String currentSessionId,
    required SupportContextBlock? Function(SupportContextBlock? latest) mutate,
    required bool Function() isCurrent,
  }) => _SupportGlobalPermissionStore(
    _context,
  ).mutateLegacy(currentSessionId, mutate, isCurrent);
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

  /// Create ONLY a pending record with SupportMutationEvidence-encoded, already
  /// sanitized native strings. The live admission guard must be synchronous.
  /// Null is refusal; cipher/storage failures throw and roll back. A committed
  /// return is DB custody, never native approval or permission for an effect.
  Future<SupportMutationReservation?> reserveMutation({
    required SupportMutationRecord record,
    required bool Function() isCurrent,
  }) => _journal.guarded.reserve(record, isCurrent);

  /// Validated exact encrypted expectation for observation/recovery. Reading a
  /// restored record cannot restore native approval or authorize any replay.
  Future<SupportMutationReservation?> readCurrentMutation({
    required String id,
    required String sessionId,
    required String domain,
    required String targetId,
    required bool Function() isCurrent,
  }) => _journal.guarded.read(id, sessionId, domain, targetId, isCurrent);

  /// Bounded primitive discovery, never decrypted evidence or effect custody.
  /// Null explicitly means unavailable, not an empty history.
  Future<SupportMutationHistoryPage?> discoverMutationHistory({
    required String sessionId,
    required String domain,
    required String targetId,
    required bool Function() isCurrent,
    SupportMutationHistoryCursor? cursor,
  }) =>
      _journal.history.discover(sessionId, domain, targetId, isCurrent, cursor);

  /// Revalidate the same bounded observation after a caller's awaited reads.
  Future<bool> validateMutationHistory({
    required SupportMutationHistoryPage page,
    required bool Function() isCurrent,
  }) => _journal.history.validate(page, isCurrent);

  /// Equality of two actual guarded observations on this original DB only.
  /// No DTO can manufacture either encrypted expectation; no effect is granted.
  bool sameMutationHistoryObservation(
    SupportMutationReservation expected,
    SupportMutationReservation observed,
  ) => _journal.history.sameObservation(expected, observed);

  /// New Undo admission only: applied -> undo_pending. Requires a fresh native
  /// approval and live admission guard in the caller; this API grants neither.
  Future<SupportMutationReservation?> reserveMutationUndo({
    required SupportMutationReservation expected,
    required bool Function() isCurrent,
  }) => _journal.guarded.beginUndo(expected, isCurrent);

  /// Record only an observed fact for ALREADY STARTED work. Custody is the
  /// original DB/session owner, independent of retired UI/permission ownership.
  /// No external effect is started here, and SQLite/another store are not atomic.
  Future<SupportMutationReservation?> settleMutation({
    required SupportMutationReservation expected,
    required SupportMutationFact fact,
    required bool Function() hasOriginalDbCustody,
  }) => _journal.guarded.settle(expected, fact, hasOriginalDbCustody);
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
