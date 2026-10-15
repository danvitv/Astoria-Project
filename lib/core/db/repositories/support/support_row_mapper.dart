part of '../support_repo.dart';

/// Maps encrypted durable rows to readable models or explicit locked metadata.
final class _SupportRowMapper {
  _SupportRowMapper(this.cipher);
  final SupportPayloadCipher cipher;
  Future<String> _decrypt(
    String text,
    String table,
    String id,
    String session,
    String field,
  ) => cipher.decrypt(
    envelopeText: text,
    table: table,
    rowId: id,
    sessionId: session,
    field: field,
  );
  Future<SupportSession> session(SupportSessionRow row) async {
    var title = '';
    var locked = false;
    try {
      title = await _decrypt(
        row.titleCiphertext,
        'support_sessions',
        row.id,
        row.id,
        'title_ciphertext',
      );
    } on SupportCipherException {
      locked = true;
    }
    return SupportSession(
      id: row.id,
      title: title,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      pinned: row.pinned,
      mode: row.mode,
      activeApiConfigId: row.activeApiConfigId,
      activeModelId: row.activeModelId,
      isLocked: locked,
    );
  }

  Future<SupportMessage> message(SupportMessageRow row) async {
    var body = '';
    var cards = '';
    var locked = false;
    try {
      body = await _decrypt(
        row.bodyCiphertext,
        'support_messages',
        row.id,
        row.sessionId,
        'body_ciphertext',
      );
      if (row.cardsCiphertext.isNotEmpty) {
        cards = await _decrypt(
          row.cardsCiphertext,
          'support_messages',
          row.id,
          row.sessionId,
          'cards_ciphertext',
        );
      }
    } on SupportCipherException {
      locked = true;
      body = '';
      cards = '';
    }
    return SupportMessage(
      id: row.id,
      sessionId: row.sessionId,
      role: row.role,
      body: body,
      cardsJson: cards,
      runId: row.runId,
      status: row.status,
      createdAt: row.createdAt,
      isLocked: locked,
    );
  }

  Future<SupportContextBlock> context(SupportContextBlockRow row) async {
    var summary = '';
    var facts = '';
    var locked = false;
    try {
      summary = await _decrypt(
        row.summaryCiphertext,
        'support_context_blocks',
        row.id,
        row.sessionId,
        'summary_ciphertext',
      );
      if (row.protectedFactsCiphertext.isNotEmpty) {
        facts = await _decrypt(
          row.protectedFactsCiphertext,
          'support_context_blocks',
          row.id,
          row.sessionId,
          'protected_facts_ciphertext',
        );
      }
    } on SupportCipherException {
      locked = true;
      summary = '';
      facts = '';
    }
    return SupportContextBlock(
      id: row.id,
      sessionId: row.sessionId,
      startMessageId: row.startMessageId,
      endMessageId: row.endMessageId,
      summary: summary,
      protectedFactsJson: facts,
      isActive: row.isActive,
      createdAt: row.createdAt,
      isLocked: locked,
    );
  }

  Future<SupportMutationRecord> mutation(SupportMutationJournalRow row) async {
    var before = '';
    var after = '';
    var locked = false;
    try {
      before = await _decrypt(
        row.beforeCiphertext,
        'support_mutation_journal',
        row.id,
        row.sessionId,
        'before_ciphertext',
      );
      after = await _decrypt(
        row.afterCiphertext,
        'support_mutation_journal',
        row.id,
        row.sessionId,
        'after_ciphertext',
      );
    } on SupportCipherException {
      locked = true;
      before = '';
      after = '';
    }
    return SupportMutationRecord(
      id: row.id,
      sessionId: row.sessionId,
      domain: row.domain,
      targetId: row.targetId,
      beforeJson: before,
      afterJson: after,
      status: row.status,
      createdAt: row.createdAt,
      isLocked: locked,
    );
  }

  SupportReportRecord report(SupportReportRow row) => SupportReportRecord(
    id: row.id,
    sessionId: row.sessionId,
    fileHash: row.fileHash,
    status: row.status,
    createdAt: row.createdAt,
  );
}
