/// Bounded origin declarations, never permission or proof of an old body.
///
/// These types have no body, native approval, policy, storage or transport API.
/// Lists are defensively copied. Identifiers are opaque, case-sensitive Unicode
/// scalar strings, at most 128 UTF-16 units, without whitespace/control units.
abstract final class SupportModelProvenanceLimits {
  static const maxRawCharacters = 65536;
  static const maxJsonDepth = 24;
  static const maxJsonNodes = 8192;
  static const maxIdentifierCharacters = 128;
  static const maxRecipeNodes = 64;
  static const maxDeclarationsAndReferences = 128;
  static const maxIdsPerSource = 512;
  static const maxSourceIdOccurrences = 4096;
  static const maxSelectedSupportMessages = 4096;
}

enum SupportModelSourceDomain { support, game }

enum SupportModelSelectedRole { user, assistant, system, unknown }

/// Fixed diagnostics deliberately contain no offending input or identity.
enum SupportModelProvenanceFailure {
  invalidEncoding,
  duplicateKey,
  unknownField,
  unsupportedFormat,
  invalidIdentity,
  invalidSource,
  limitExceeded,
  unavailableRecipe,
  ownerMismatch,
  missingDependency,
  coverageMismatch,
  orderMismatch,
  currentInputOverlap,
  cycle,
}

final class SupportModelProvenanceException implements Exception {
  const SupportModelProvenanceException(this.failure);

  final SupportModelProvenanceFailure failure;

  @override
  String toString() => 'Support model provenance unavailable.';
}

final class SupportModelSourceRange {
  SupportModelSourceRange({
    required this.domain,
    required String sessionId,
    required List<String> orderedMessageIds,
  }) : sessionId = _identifier(sessionId),
       orderedMessageIds = _messageIds(orderedMessageIds);

  final SupportModelSourceDomain domain;
  final String sessionId;
  final List<String> orderedMessageIds;

  @override
  String toString() => 'SupportModelSourceRange';
}

final class SupportModelReplyReference {
  SupportModelReplyReference({
    required String sessionId,
    required String messageId,
    required String runId,
  }) : sessionId = _identifier(sessionId),
       messageId = _identifier(messageId),
       runId = _identifier(runId);

  final String sessionId;
  final String messageId;
  final String runId;

  @override
  String toString() => 'SupportModelReplyReference';
}

/// Immutable v1 recipe for one support reply.
///
/// [currentUserMessageId] is the originating row's identity. Once this reply is
/// used later, that row is a required HISTORICAL dependency. It never records
/// a reusable current-turn approval. [originalRanges] retain their exact order;
/// inherited declarations remain in directly referenced, selected recipes.
final class SupportModelProvenance {
  SupportModelProvenance({
    required String supportSessionId,
    required String replyMessageId,
    required String runId,
    required String currentUserMessageId,
    required List<SupportModelSourceRange> originalRanges,
    required List<SupportModelReplyReference> directReplies,
    List<String>? currentConversationMessageIds,
  }) : supportSessionId = _identifier(supportSessionId),
       replyMessageId = _identifier(replyMessageId),
       runId = _identifier(runId),
       currentUserMessageId = _identifier(currentUserMessageId),
       originalRanges = _boundedCopy(originalRanges),
       directReplies = _boundedCopy(directReplies),
       currentConversationMessageIds = currentConversationMessageIds == null
           ? null
           : currentConversationMessageIds.isEmpty
           ? const []
           : _messageIds(currentConversationMessageIds) {
    if (replyMessageId == currentUserMessageId) {
      _fail(SupportModelProvenanceFailure.invalidIdentity);
    }
    if (this.currentConversationMessageIds?.any(
          (id) => id == replyMessageId || id == currentUserMessageId,
        ) ==
        true) {
      _fail(SupportModelProvenanceFailure.currentInputOverlap);
    }
    if (originalRanges.length + directReplies.length >
        SupportModelProvenanceLimits.maxDeclarationsAndReferences) {
      _fail(SupportModelProvenanceFailure.limitExceeded);
    }
    final sources = <(SupportModelSourceDomain, String)>{};
    var occurrences = 0;
    for (final range in originalRanges) {
      if (!sources.add((range.domain, range.sessionId))) {
        _fail(SupportModelProvenanceFailure.invalidSource);
      }
      occurrences += range.orderedMessageIds.length;
    }
    if (occurrences > SupportModelProvenanceLimits.maxSourceIdOccurrences) {
      _fail(SupportModelProvenanceFailure.limitExceeded);
    }
    final references = <(String, String)>{};
    for (final reference in directReplies) {
      if (!references.add((reference.sessionId, reference.messageId))) {
        _fail(SupportModelProvenanceFailure.invalidSource);
      }
    }
  }

  final String supportSessionId;
  final String replyMessageId;
  final String runId;
  final String currentUserMessageId;
  final List<SupportModelSourceRange> originalRanges;
  final List<SupportModelReplyReference> directReplies;

  /// v2: visible current-chat text authorized by this reply's original Send.
  /// Null is the old v1 recipe. IDs are NOT external origins or reusable grants.
  /// Existing origin ranges/references remain unchanged and independently gated.
  final List<String>? currentConversationMessageIds;

  @override
  String toString() => 'SupportModelProvenance';
}

/// Metadata of an ALREADY explicitly selected support row, in native order.
/// Game rows are described only by their selected game range, not assigned a
/// fabricated support recipe. This type cannot load any row or check rights.
final class SupportModelSelectedSupportMessage {
  SupportModelSelectedSupportMessage({
    required String sessionId,
    required String messageId,
    required this.role,
    String? runId,
    this.provenance,
  }) : sessionId = _identifier(sessionId),
       messageId = _identifier(messageId),
       runId = runId == null ? null : _identifier(runId);

  final String sessionId;
  final String messageId;
  final SupportModelSelectedRole role;
  final String? runId;
  final SupportModelProvenance? provenance;

  @override
  String toString() => 'SupportModelSelectedSupportMessage';
}

final class SupportModelProvenanceDecodeResult {
  const SupportModelProvenanceDecodeResult.valid(
    SupportModelProvenance this.recipe,
  ) : failure = null;
  const SupportModelProvenanceDecodeResult.unavailable(
    SupportModelProvenanceFailure this.failure,
  ) : recipe = null;

  final SupportModelProvenance? recipe;
  final SupportModelProvenanceFailure? failure;
  bool get isValid => recipe != null && failure == null;

  @override
  String toString() => 'SupportModelProvenanceDecodeResult';
}

/// A pure consistency result, not a capability or authorization.
/// Retains each selected recipe unchanged, without flattening its ranges.
final class SupportModelProvenanceCoverageResult {
  SupportModelProvenanceCoverageResult.valid(
    List<SupportModelProvenance> retainedRecipes,
  ) : retainedRecipes = _retainedRecipes(retainedRecipes),
      failure = null;

  const SupportModelProvenanceCoverageResult.unavailable(
    SupportModelProvenanceFailure this.failure,
  ) : retainedRecipes = const [];

  final List<SupportModelProvenance> retainedRecipes;
  final SupportModelProvenanceFailure? failure;
  bool get isValid => failure == null;

  @override
  String toString() => 'SupportModelProvenanceCoverageResult';
}

Never _fail(SupportModelProvenanceFailure failure) =>
    throw SupportModelProvenanceException(failure);

List<SupportModelProvenance> _retainedRecipes(
  List<SupportModelProvenance> values,
) {
  if (values.length >= SupportModelProvenanceLimits.maxRecipeNodes) {
    _fail(SupportModelProvenanceFailure.limitExceeded);
  }
  return List<SupportModelProvenance>.unmodifiable(values);
}

List<T> _boundedCopy<T>(List<T> values) {
  if (values.length >
      SupportModelProvenanceLimits.maxDeclarationsAndReferences) {
    _fail(SupportModelProvenanceFailure.limitExceeded);
  }
  return List<T>.unmodifiable(values);
}

List<String> _messageIds(List<String> values) {
  if (values.isEmpty) _fail(SupportModelProvenanceFailure.invalidSource);
  if (values.length > SupportModelProvenanceLimits.maxIdsPerSource) {
    _fail(SupportModelProvenanceFailure.limitExceeded);
  }
  final seen = <String>{};
  for (final value in values) {
    if (!seen.add(_identifier(value))) {
      _fail(SupportModelProvenanceFailure.invalidSource);
    }
  }
  return List<String>.unmodifiable(values);
}

String _identifier(String value) {
  if (value.isEmpty ||
      value.length > SupportModelProvenanceLimits.maxIdentifierCharacters) {
    _fail(SupportModelProvenanceFailure.invalidIdentity);
  }
  for (var i = 0; i < value.length; i++) {
    final unit = value.codeUnitAt(i);
    if (unit <= 0x20 ||
        (unit >= 0x7f && unit <= 0x9f) ||
        unit == 0xa0 ||
        unit == 0x1680 ||
        (unit >= 0x2000 && unit <= 0x200f) ||
        (unit >= 0x2028 && unit <= 0x202f) ||
        (unit >= 0x205f && unit <= 0x206f) ||
        unit == 0x3000 ||
        unit == 0xfeff) {
      _fail(SupportModelProvenanceFailure.invalidIdentity);
    }
    if (unit >= 0xd800 && unit <= 0xdbff) {
      if (++i >= value.length) {
        _fail(SupportModelProvenanceFailure.invalidIdentity);
      }
      final low = value.codeUnitAt(i);
      if (low < 0xdc00 || low > 0xdfff) {
        _fail(SupportModelProvenanceFailure.invalidIdentity);
      }
    } else if (unit >= 0xdc00 && unit <= 0xdfff) {
      _fail(SupportModelProvenanceFailure.invalidIdentity);
    }
  }
  return value;
}
