import '../credentials/memory_custom_api_credential_owner.dart';
import '../credentials/secret_redactor.dart';
import '../models/memory_book.dart';

/// Re-sanitize inside the dependent transaction, not merely at HTTP completion.
MemoryDraft sanitizeCustomMemoryDraft(
  MemoryDraft draft,
  MemoryCustomApiInvocation? original,
  SecretRedactor? snapshot,
) {
  if (original == null) return draft;
  original.requireCurrent();
  String safe(String text) => original.redact(text, snapshot!);
  return draft.copyWith(
    content: safe(draft.content),
    keys: draft.keys.map(safe).toList(),
    keyParagraphs: {
      for (final entry in draft.keyParagraphs.entries)
        safe(entry.key): entry.value,
    },
    ledgerRange: safe(draft.ledgerRange),
    error: draft.error == null ? null : safe(draft.error!),
  );
}
