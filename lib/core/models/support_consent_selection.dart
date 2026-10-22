/// Native consent-screen metadata only. None of these values grant a model read
/// or prove unchanged content, readable encrypted bodies, or attachment consent.
enum SupportConsentSelectionStatus {
  available,
  limited,
  unavailable,
  parentLocked,
}

enum SupportConsentSelectionSource { roleplay, support }

enum SupportConsentSelectionRole { user, assistant, system }

final class SupportConsentSessionOption {
  const SupportConsentSessionOption({
    required this.sessionId,
    required this.characterId,
    required this.sessionIndex,
    required this.variantGroupId,
    required this.variantOrder,
    required this.characterLabel,
    required this.variantLabel,
    required this.messageCount,
    required this.status,
  });

  final String sessionId;
  final String characterId;
  final int sessionIndex;
  final String? variantGroupId;
  final int? variantOrder;
  final String characterLabel;
  final String variantLabel;

  /// Stored entry count, NOT eligible message count. Null means unavailable.
  final int? messageCount;
  final SupportConsentSelectionStatus status;
  String get label =>
      '$characterLabel · $variantLabel · Session ${sessionIndex + 1}';

  @override
  String toString() => 'SupportConsentSessionOption';
}

final class SupportConsentSessionPage {
  SupportConsentSessionPage({
    required Iterable<SupportConsentSessionOption> items,
    required this.status,
    this.omittedCount = 0,
    this.nextOffset,
  }) : items = List.unmodifiable(items);

  final List<SupportConsentSessionOption> items;
  final SupportConsentSelectionStatus status;

  /// Invalid identities in this bounded source page; hidden characters are not
  /// enumerated or counted. Offset addresses visible source rows, not items.
  final int omittedCount;
  final int? nextOffset;
  String get statusLabel => supportConsentSelectionStatusLabel(status);

  @override
  String toString() => 'SupportConsentSessionPage(${status.name})';
}

final class SupportConsentMessageOption {
  const SupportConsentMessageOption({
    required this.sessionId,
    required this.messageId,
    required this.role,
    required this.nativeOrder,
    this.swipeId,
    this.agentSwipeId,
    this.timestampMs,
    this.createdAtSeconds,
  });

  final String sessionId;
  final String messageId;
  final SupportConsentSelectionRole role;

  /// Zero-based stored roleplay list position or support createdAt/id order.
  final int nativeOrder;

  /// Current durable assistant indices, not variation content or a body freeze.
  final int? swipeId;
  final int? agentSwipeId;
  final int? timestampMs;
  final int? createdAtSeconds;
  String get label => 'Message ${nativeOrder + 1} · ${role.name}';

  @override
  String toString() => 'SupportConsentMessageOption';
}

final class SupportConsentMessagePage {
  SupportConsentMessagePage({
    required this.source,
    required this.sessionId,
    required Iterable<SupportConsentMessageOption> items,
    required this.status,
    this.roleplaySession,
    this.sourceCount,
    this.eligibleCount = 0,
    this.omittedCount = 0,
    this.limitedCount = 0,
    this.nextOffset,
  }) : items = List.unmodifiable(items);

  final SupportConsentSelectionSource source;

  /// Null for an invalid/unavailable request, never replaced by another target.
  final String? sessionId;
  final SupportConsentSessionOption? roleplaySession;
  final List<SupportConsentMessageOption> items;
  final SupportConsentSelectionStatus status;
  final int? sourceCount;
  final int eligibleCount;

  /// Hidden/error/typing/invalid/duplicate entries across the bounded source.
  final int omittedCount;

  /// Eligible entries outside this page, or unenumerated entries at a hard cap.
  final int limitedCount;

  /// Offset addresses eligible entries, unlike the session-list source offset.
  final int? nextOffset;
  String get statusLabel => supportConsentSelectionStatusLabel(status);

  /// Full content validation belongs to a later explicit preview/load.
  bool get bodiesRead => false;
  bool get attachmentsIncluded => false;

  @override
  String toString() => 'SupportConsentMessagePage(${status.name})';
}

String supportConsentSelectionStatusLabel(
  SupportConsentSelectionStatus status,
) => switch (status) {
  SupportConsentSelectionStatus.available => 'Metadata only',
  SupportConsentSelectionStatus.limited => 'Selection limit reached',
  SupportConsentSelectionStatus.unavailable => 'Selection unavailable',
  SupportConsentSelectionStatus.parentLocked => 'Session locked',
};
