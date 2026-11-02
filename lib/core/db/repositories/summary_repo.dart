import 'package:drift/drift.dart';

import '../../credentials/credential_vault.dart';
import '../../credentials/memory_custom_api_credential_owner.dart';
import '../../credentials/secret_redactor.dart';
import '../app_db.dart';
import '../database_transaction_guard.dart';
import '../tables.dart';
import '../../utils/time_helpers.dart';

part 'summary_repo.g.dart';

@DriftAccessor(tables: [ChatSummaries])
class SummaryRepo extends DatabaseAccessor<AppDatabase>
    with _$SummaryRepoMixin {
  SummaryRepo(super.db);

  Future<ChatSummary?> get(String sessionId) {
    return (select(
      chatSummaries,
    )..where((t) => t.sessionId.equals(sessionId))).getSingleOrNull();
  }

  Future<List<String>> getAllSessionIds() async {
    final rows = await select(chatSummaries).get();
    return rows.map((r) => r.sessionId).toList();
  }

  Future<List<ChatSummary>> getAll() => select(chatSummaries).get();

  Future<void> put({
    required String sessionId,
    required String content,
    required int messageCount,
    bool? enabled,
    String? prompt,
  }) async {
    final existing = await get(sessionId);
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: content,
        enabled: Value(enabled ?? existing?.enabled ?? true),
        messageCount: Value(messageCount),
        prompt: Value(prompt ?? existing?.prompt),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> putSynced({
    required String sessionId,
    required String content,
    required int messageCount,
    required bool enabled,
    required String? prompt,
    required int updatedAt,
  }) async {
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: content,
        enabled: Value(enabled),
        messageCount: Value(messageCount),
        prompt: Value(prompt),
        updatedAt: Value(updatedAt),
      ),
    );
  }

  /// Only generated custom summaries use this transaction. The original custom
  /// custody is never refreshed from a matching row or a replacement owner.
  /// Ordinary/manual writes and their public signatures remain unchanged.
  Future<String> putGeneratedCustomSummary({
    required String sessionId,
    required String content,
    required int messageCount,
    String? prompt,
    required MemoryCustomApiInvocation original,
    required SecretRedactor originalRedactor,
    required bool Function() isCurrent,
  }) async {
    final guard = _CustomSummaryWriteGuard(
      original,
      originalRedactor,
      content,
      isCurrent,
    );
    original.requireCurrent();
    final durable = await outsideDatabaseTransaction(
      attachedDatabase,
      () => attachedDatabase.runWithInterceptor(
        () => attachedDatabase.transaction(() async {
          original.requireCurrent();
          final existing = await get(sessionId);
          original.requireCurrent();
          // The read may have introduced a new CURRENT alias. Produce the
          // write's content only now; the SQL/commit guard rejects any later
          // policy change that would make this content unsafe, rolling back.
          final safe = guard.prepareContent();
          await into(chatSummaries).insertOnConflictUpdate(
            ChatSummariesCompanion.insert(
              sessionId: sessionId,
              content: safe,
              enabled: Value(existing?.enabled ?? true),
              messageCount: Value(messageCount),
              prompt: Value(prompt ?? existing?.prompt),
              updatedAt: Value(currentTimestampSeconds()),
            ),
          );
          guard.requireSafe();
          return safe;
        }),
        interceptor: guard,
      ),
      onRejected: () => const CredentialVaultAdmissionDenied(),
    );
    guard.requireSafe();
    return durable;
  }

  /// Writes only the summarization template, leaving the content and the
  /// message count alone. A settings screen that edits the prompt must not
  /// stamp a new message count — that silently restarts the auto-summary
  /// countdown.
  Future<void> setPrompt({
    required String sessionId,
    required String? prompt,
  }) async {
    final existing = await get(sessionId);
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: existing?.content ?? '',
        enabled: Value(existing?.enabled ?? true),
        messageCount: Value(existing?.messageCount ?? 0),
        prompt: Value(prompt),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> setEnabled({
    required String sessionId,
    required bool enabled,
  }) async {
    final existing = await get(sessionId);
    await into(chatSummaries).insertOnConflictUpdate(
      ChatSummariesCompanion.insert(
        sessionId: sessionId,
        content: existing?.content ?? '',
        enabled: Value(enabled),
        messageCount: Value(existing?.messageCount ?? 0),
        prompt: Value(existing?.prompt),
        updatedAt: Value(currentTimestampSeconds()),
      ),
    );
  }

  Future<void> deleteBySessionId(String sessionId) {
    return (delete(
      chatSummaries,
    )..where((t) => t.sessionId.equals(sessionId))).go().then((_) {});
  }

  /// Carries user settings, but resets generated content because this model
  /// has only a message count and cannot prove that a summary predates a cut.
  Future<void> copySettingsForSessionBranch({
    required String fromSessionId,
    required String toSessionId,
  }) async {
    final source = await get(fromSessionId);
    if (source == null) return;
    await put(
      sessionId: toSessionId,
      content: '',
      messageCount: 0,
      enabled: source.enabled,
      prompt: source.prompt,
    );
  }
}

/// A finite fence for the single summary SELECT/upsert/commit above, not an
/// ordinary mutation framework. Redaction changes after dispatch deny the
/// transaction rather than issuing a second write under new authority.
final class _CustomSummaryWriteGuard extends QueryInterceptor {
  _CustomSummaryWriteGuard(
    this.original,
    this.snapshot,
    this.content,
    this.isCurrent,
  );
  final MemoryCustomApiInvocation original;
  final SecretRedactor snapshot;
  final String content;
  final bool Function() isCurrent;
  String? _written;

  String prepareContent() {
    requireSafe();
    return _written = original.redact(content, snapshot).trim();
  }

  void requireSafe() {
    if (!isCurrent()) throw const CredentialVaultAdmissionDenied();
    original.requireCurrent();
    if (_written != null &&
        original.redact(content, snapshot).trim() != _written) {
      throw const CredentialVaultAdmissionDenied();
    }
  }

  @override
  Future<bool> ensureOpen(
    QueryExecutor executor,
    QueryExecutorUser user,
  ) async {
    requireSafe();
    final opened = await super.ensureOpen(executor, user);
    requireSafe();
    return opened;
  }

  @override
  Future<List<Map<String, Object?>>> runSelect(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    requireSafe();
    final rows = await super.runSelect(executor, statement, args);
    requireSafe();
    return rows;
  }

  @override
  Future<int> runInsert(
    QueryExecutor executor,
    String statement,
    List<Object?> args,
  ) async {
    requireSafe();
    final changed = await super.runInsert(executor, statement, args);
    requireSafe();
    return changed;
  }

  @override
  Future<void> commitTransaction(TransactionExecutor inner) async {
    requireSafe();
    await super.commitTransaction(inner);
    // Settled-commit publication is checked AFTER the transaction future above.
    // Do not report an already-committed transaction to Drift as commit failure.
  }
}
