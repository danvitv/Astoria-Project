part of 'support_model_service.dart';

/// Separate direct-current-chat authority, not a clean-origin fallback for v1.
/// Checks only materialized current-chat metadata and independently leased game
/// ranges. Never resolves ancestors, invents local recipes or declassifies game
/// origins. Originless native local help remains originless in encrypted storage.
extension _DirectConversationRecipe on _ModelRun {
  SupportModelProvenance _directConversationRecipe(
    List<SupportTextContextSnapshot> snapshots, {
    bool compactionBatch = false,
  }) {
    final own = snapshots.first;
    final visible = isCompact || compactionBatch
        ? binding.visibleConversation?.take(own.messageIds.length).toList()
        : binding.visibleConversation;
    if (own.source != SupportTextContextSource.support ||
        own.sessionId != sessionId ||
        own.provenance.length != own.messages.length ||
        visible == null ||
        visible.length != own.messageIds.length) {
      _refuse(SupportModelRefusal.lineageUnavailable);
    }
    final ranges = <SupportModelSourceRange>[
      for (final snapshot in snapshots)
        if (snapshot.messageIds.isNotEmpty)
          SupportModelSourceRange(
            domain: snapshot.source == SupportTextContextSource.support
                ? SupportModelSourceDomain.support
                : SupportModelSourceDomain.game,
            sessionId: snapshot.sessionId,
            orderedMessageIds: snapshot.messageIds,
          ),
    ];
    final positions = <String, int>{};
    final recipes = <String, SupportModelProvenance>{};
    for (var i = 0; i < own.messageIds.length; i++) {
      final id = own.messageIds[i], native = own.provenance[i];
      if (visible[i].id != id ||
          visible[i].role != own.messages[i].role ||
          visible[i].text != own.messages[i].text) {
        _refuse(SupportModelRefusal.stale);
      }
      if (id == userId ||
          id == replyId ||
          native.messageId != id ||
          !const ['user', 'assistant'].contains(own.messages[i].role)) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      positions[id] = i;
      if (own.messages[i].role == 'user') {
        if (native.dedicatedFactsJson != null) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
        continue;
      }
      if (native.dedicatedFactsJson == null) {
        // No run means native local-help/legacy visible text. A missing recipe
        // on a model-run row is NOT treated as clean local text.
        if (native.runId != null) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
        continue;
      }
      final decoded = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        native.dedicatedFactsJson!,
      );
      final recipe = decoded.recipe;
      if (recipe == null ||
          recipe.supportSessionId != sessionId ||
          recipe.replyMessageId != id ||
          recipe.runId != native.runId) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      _checkRecipeIdentifiers(service._redaction.redactor, recipe);
      recipes[id] = recipe;
    }
    if (recipes.length >= SupportModelProvenanceLimits.maxRecipeNodes) {
      _refuse(SupportModelRefusal.tooLarge);
    }
    final runs = <String>{runId}, inputs = <String>{userId};
    var declarations = ranges.length + recipes.length;
    var occurrences =
        own.messageIds.length +
        ranges.fold<int>(0, (n, range) => n + range.orderedMessageIds.length);
    for (final recipe in recipes.values) {
      if (!runs.add(recipe.runId) || !inputs.add(recipe.currentUserMessageId)) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      final inputPosition = positions[recipe.currentUserMessageId];
      final replyPosition = positions[recipe.replyMessageId]!;
      if (inputPosition == null ||
          inputPosition >= replyPosition ||
          own.messages[inputPosition].role != 'user') {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      final conversation = recipe.currentConversationMessageIds;
      final requiredReplies = <String>[];
      var previousSource = -1;
      for (final range in recipe.originalRanges) {
        declarations++;
        occurrences += range.orderedMessageIds.length;
        final sourceIndex = ranges.indexWhere(
          (selected) =>
              selected.domain == range.domain &&
              selected.sessionId == range.sessionId,
        );
        if (sourceIndex <= previousSource) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
        previousSource = sourceIndex;
        final selectedIds = ranges[sourceIndex].orderedMessageIds;
        var previousId = -1;
        for (final id in range.orderedMessageIds) {
          final position = selectedIds.indexOf(id);
          if (position <= previousId) {
            _refuse(SupportModelRefusal.lineageUnavailable);
          }
          previousId = position;
          if (range.domain != SupportModelSourceDomain.support) continue;
          if (range.sessionId != sessionId || positions[id]! >= inputPosition) {
            _refuse(SupportModelRefusal.lineageUnavailable);
          }
          if (own.messages[positions[id]!].role != 'assistant') continue;
          if (recipes.containsKey(id)) {
            requiredReplies.add(id);
          } else if (conversation?.contains(id) != true) {
            _refuse(SupportModelRefusal.lineageUnavailable);
          }
        }
      }
      if (conversation != null) {
        occurrences += conversation.length;
        final ownRange = recipe.originalRanges.where(
          (range) =>
              range.domain == SupportModelSourceDomain.support &&
              range.sessionId == sessionId,
        );
        final expectedIds = ownRange.isEmpty
            ? const <String>[]
            : ownRange.single.orderedMessageIds;
        if (!_sameConversationIds(conversation, expectedIds)) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
      }
      declarations += recipe.directReplies.length;
      if (declarations >
              SupportModelProvenanceLimits.maxDeclarationsAndReferences ||
          occurrences > SupportModelProvenanceLimits.maxSourceIdOccurrences) {
        _refuse(SupportModelRefusal.tooLarge);
      }
      if (requiredReplies.length != recipe.directReplies.length) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      for (var i = 0; i < requiredReplies.length; i++) {
        final reference = recipe.directReplies[i];
        final original = recipes[requiredReplies[i]]!;
        if (reference.sessionId != sessionId ||
            reference.messageId != original.replyMessageId ||
            reference.runId != original.runId) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
        // Every edge predates the input, hence no cycle or forward reference.
      }
    }
    return SupportModelProvenance(
      supportSessionId: sessionId,
      replyMessageId: replyId,
      runId: runId,
      currentUserMessageId: userId,
      originalRanges: ranges,
      directReplies: [
        for (final recipe in recipes.values)
          SupportModelReplyReference(
            sessionId: sessionId,
            messageId: recipe.replyMessageId,
            runId: recipe.runId,
          ),
      ],
      currentConversationMessageIds: own.messageIds,
    );
  }
}

bool _sameConversationIds(List<String> a, List<String> b) =>
    a.length == b.length &&
    Iterable<int>.generate(a.length).every((i) => a[i] == b[i]);
