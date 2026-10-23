/// Exact source domain; this is not a permission or an origin declaration.
enum SupportTextContextSource { support, roleplay }

enum SupportTextContextFailure { invalidSelection, unavailable, limited, stale }

/// Opaque native current-input boundary. Only its original issuing repository
/// accepts it. No tuple, pagination/exclusion DTO, serializer or authority.
abstract interface class SupportSessionHistoryBoundary {}

/// Fixed diagnostics only: no database errors, envelopes or source text.
final class SupportTextContextException implements Exception {
  const SupportTextContextException(this.failure);
  final SupportTextContextFailure failure;

  @override
  String toString() => 'SupportTextContextException(${failure.name})';
}

/// Body-only, sanitized model-facing text. Native identities stay on the
/// snapshot, not in each model message. No arbitrary JSON or serializer.
final class SupportTextContextMessage {
  const SupportTextContextMessage({required this.role, required this.text});
  final String role;
  final String text;

  @override
  String toString() => 'SupportTextContextMessage';
}

/// Native-only evidence for a future trusted provenance decoder. This is NOT a
/// model message, permission, default origin or arbitrary context-block export.
/// A null declaration means unknown/legacy, not ordinary own-history origin.
final class SupportTextContextProvenance {
  const SupportTextContextProvenance({
    required this.messageId,
    required this.runId,
    required this.dedicatedFactsJson,
  });
  final String messageId;

  /// Exact bounded native row binding for the trusted decoder, never model text.
  final String? runId;
  final String? dedicatedFactsJson;

  @override
  String toString() => 'SupportTextContextProvenance';
}

/// The repository alone creates admitted implementations. Revalidation rejects
/// caller-created implementations and snapshots belonging to another repo.
///
/// This DTO grants no local-read or model-use authority. The feature must guard
/// before loading and again at the actual send. Missing derived-reply provenance
/// is unknown, never an implied ordinary own-history origin.
abstract interface class SupportTextContextSnapshot {
  SupportTextContextSource get source;
  String get sessionId;
  List<String> get messageIds;
  List<SupportTextContextMessage> get messages;
  List<SupportTextContextProvenance> get provenance;

  /// Whole source membership is retained privately and rediscovered at admission.
  /// Even a confirmed readable empty source has an owned whole-session snapshot.
  bool get isWholeSession;
  SupportSessionHistoryBoundary? get currentInput;
}
