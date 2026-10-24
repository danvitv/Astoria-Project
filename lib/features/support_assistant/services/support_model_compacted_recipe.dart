part of 'support_model_service.dart';

/// Checkpoint proves exact original prefix bytes/membership; suffix recipes keep
/// their old origins. External origins STILL require independently leased ranges.
extension _CompactedConversationRecipe on _ModelRun {
  Future<SupportModelProvenance> _compactedConversationRecipe(
    List<SupportTextContextSnapshot> snapshots, {
    bool compactionBatch = false,
  }) async {
    final cp = checkpoint!, own = snapshots.first;
    final visible = binding.visibleConversation;
    final cut = visible?.indexWhere((m) => m.id == cp.endMessageId) ?? -1;
    if (visible == null ||
        cut < 0 ||
        own.provenance.length != own.messages.length ||
        (isCompact || compactionBatch
            ? visible.length - cut - 1 < own.messageIds.length
            : visible.length - cut - 1 != own.messageIds.length)) {
      _refuse(SupportModelRefusal.stale);
    }
    final stored = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
      cp.lineageJson,
    ).recipe;
    if (stored == null || stored.supportSessionId != sessionId) {
      _refuse(SupportModelRefusal.lineageUnavailable);
    }
    _checkRecipeIdentifiers(service._redaction.redactor, stored);
    final game = snapshots
        .skip(1)
        .where((s) => s.source == SupportTextContextSource.roleplay)
        .toList();
    bool covered(SupportModelSourceRange range) {
      final selected = game.where((s) => s.sessionId == range.sessionId);
      if (selected.length != 1) return false;
      var previous = -1;
      for (final id in range.orderedMessageIds) {
        final at = selected.single.messageIds.indexOf(id);
        if (at <= previous) return false;
        previous = at;
      }
      return true;
    }

    if (stored.originalRanges.any(
      (r) => r.domain != SupportModelSourceDomain.game || !covered(r),
    )) {
      _refuse(SupportModelRefusal.historyDenied);
    }
    final recipes = <String, SupportModelProvenance>{};
    final prefixIds = <String>{cp.endMessageId};
    for (var i = 0; i < own.messageIds.length; i++) {
      final id = own.messageIds[i],
          native = own.provenance[i],
          shown = visible[cut + 1 + i];
      if (shown.id != id ||
          shown.role != own.messages[i].role ||
          shown.text != own.messages[i].text ||
          native.messageId != id) {
        _refuse(SupportModelRefusal.stale);
      }
      if (own.messages[i].role == 'user') {
        if (native.dedicatedFactsJson != null) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
        continue;
      }
      if (native.dedicatedFactsJson == null) {
        if (native.runId != null) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
        continue;
      }
      final recipe = SupportModelProvenanceCodec.decodeFromEncryptedStorage(
        native.dedicatedFactsJson!,
      ).recipe;
      if (recipe == null ||
          recipe.supportSessionId != sessionId ||
          recipe.replyMessageId != id ||
          recipe.runId != native.runId) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      _checkRecipeIdentifiers(service._redaction.redactor, recipe);
      recipes[id] = recipe;
      prefixIds.add(recipe.currentUserMessageId);
      if (recipe.compactedThroughMessageId != null) {
        prefixIds.add(recipe.compactedThroughMessageId!);
      }
      for (final range in recipe.originalRanges) {
        if (range.domain == SupportModelSourceDomain.support) {
          prefixIds.addAll(range.orderedMessageIds);
        }
      }
      prefixIds.addAll(recipe.directReplies.map((r) => r.messageId));
      if (prefixIds.length > 4096 ||
          recipes.length >= SupportModelProvenanceLimits.maxRecipeNodes) {
        _refuse(SupportModelRefusal.tooLarge);
      }
    }
    final prefix = await operation.checked(
      () => operation.reader.compactionMembers(
        checkpoint: cp,
        messageIds: prefixIds.toList(),
        isCurrent: current,
      ),
    );
    final positions = <String, ({String role, String? runId, int order})>{
      ...prefix,
    };
    for (var i = 0; i < own.messageIds.length; i++) {
      positions[own.messageIds[i]] = (
        role: own.messages[i].role,
        runId: own.provenance[i].runId,
        order: cp.source.count + i + 1,
      );
    }
    final runs = <String>{runId}, inputs = <String>{userId};
    for (final recipe in recipes.values) {
      if (!runs.add(recipe.runId) || !inputs.add(recipe.currentUserMessageId)) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      final input = positions[recipe.currentUserMessageId],
          reply = positions[recipe.replyMessageId]!;
      if (input == null || input.role != 'user' || input.order >= reply.order) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      final anchor = recipe.compactedThroughMessageId;
      if (anchor != null &&
          (prefix[anchor] == null || prefix[anchor]!.order >= input.order)) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      final requiredReplies = <String>[];
      for (final range in recipe.originalRanges) {
        if (range.domain == SupportModelSourceDomain.game) {
          if (!covered(range)) _refuse(SupportModelRefusal.historyDenied);
          continue;
        }
        if (range.sessionId != sessionId) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
        var last = -1;
        for (final id in range.orderedMessageIds) {
          final item = positions[id];
          if (item == null ||
              item.order <= last ||
              item.order >= input.order ||
              !const ['user', 'assistant'].contains(item.role)) {
            _refuse(SupportModelRefusal.lineageUnavailable);
          }
          last = item.order;
          if (item.role == 'assistant' && item.runId != null) {
            requiredReplies.add(id);
          }
          if (item.role == 'assistant' &&
              item.runId == null &&
              recipe.currentConversationMessageIds?.contains(id) != true) {
            _refuse(SupportModelRefusal.lineageUnavailable);
          }
        }
      }
      final conversation = recipe.currentConversationMessageIds;
      final ownRange = recipe.originalRanges.where(
        (r) => r.domain == SupportModelSourceDomain.support,
      );
      if (conversation != null &&
          !_sameConversationIds(
            conversation,
            ownRange.isEmpty ? const [] : ownRange.single.orderedMessageIds,
          )) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      if (requiredReplies.length != recipe.directReplies.length) {
        _refuse(SupportModelRefusal.lineageUnavailable);
      }
      for (var i = 0; i < requiredReplies.length; i++) {
        final ref = recipe.directReplies[i];
        if (ref.sessionId != sessionId ||
            ref.messageId != requiredReplies[i] ||
            ref.runId != positions[ref.messageId]!.runId) {
          _refuse(SupportModelRefusal.lineageUnavailable);
        }
      }
    }
    return SupportModelProvenance(
      supportSessionId: sessionId,
      replyMessageId: replyId,
      runId: runId,
      currentUserMessageId: userId,
      originalRanges: [
        for (final s in snapshots)
          if (s.messageIds.isNotEmpty)
            SupportModelSourceRange(
              domain: s.source == SupportTextContextSource.support
                  ? SupportModelSourceDomain.support
                  : SupportModelSourceDomain.game,
              sessionId: s.sessionId,
              orderedMessageIds: s.messageIds,
            ),
      ],
      directReplies: [
        for (final r in recipes.values)
          SupportModelReplyReference(
            sessionId: sessionId,
            messageId: r.replyMessageId,
            runId: r.runId,
          ),
      ],
      currentConversationMessageIds: own.messageIds,
      compactedThroughMessageId: cp.endMessageId,
    );
  }
}
