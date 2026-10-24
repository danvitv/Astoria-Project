import '../../../core/credentials/secret_redactor.dart';
import '../../../core/models/support_text_context.dart';
import '../models/support_model_provenance.dart';
import 'support_model_provenance_codec.dart';

/// Pure native encrypted-facts validation. Does not load dependencies, establish
/// coverage/rights, approve a run, sanitize facts or expose them as model text.
/// The service's separate graph verifier and native authorization remain required.
abstract final class SupportModelNativeProvenanceValidator {
  static bool validate(
    String sessionId,
    SupportTextContextProvenance item,
    SecretRedactor currentRedactor,
  ) {
    try {
      final facts = item.dedicatedFactsJson;
      if (facts == null || item.runId == null) return false;
      final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        facts,
      );
      final recipe = decoded.recipe;
      if (!decoded.isValid ||
          recipe == null ||
          recipe.supportSessionId != sessionId ||
          recipe.replyMessageId != item.messageId ||
          recipe.runId != item.runId) {
        return false;
      }
      // Keep the supplied closed/known-secret policy and its input allowance.
      // Lowering it to the short ID cap could exhaust a legitimate long key.
      final redactor = currentRedactor.withKnownSecrets(
        const [],
        maxOutputLength: SupportModelProvenanceLimits.maxIdentifierCharacters,
      );
      // Strict decode already validates all scalar strings, fixed keys, enums,
      // version, duplicate keys, shape and aggregate budgets. Only variable
      // values enter the secret/token/URL policy; schema sessionId keys do NOT.
      for (final id in [
        sessionId,
        item.messageId,
        item.runId!,
        recipe.supportSessionId,
        recipe.replyMessageId,
        recipe.runId,
        recipe.currentUserMessageId,
        ...?recipe.currentConversationMessageIds,
        for (final range in recipe.originalRanges) ...[
          range.sessionId,
          ...range.orderedMessageIds,
        ],
        for (final reference in recipe.directReplies) ...[
          reference.sessionId,
          reference.messageId,
          reference.runId,
        ],
      ]) {
        if (id.contains(SecretRedactor.removed) ||
            id.contains(SecretRedactor.limited) ||
            redactor.redactText(id) != id) {
          return false;
        }
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
