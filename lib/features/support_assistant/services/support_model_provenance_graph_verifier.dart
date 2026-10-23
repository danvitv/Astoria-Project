part of 'support_model_provenance_codec.dart';

typedef _RowKey = (String, String);
typedef _SourceKey = (SupportModelSourceDomain, String);

/// Linear, bounded traversal of only caller-supplied selected recipes. There is
/// deliberately no ancestor resolver, read callback, authorizer or grant API.
final class _ProvenanceGraphVerifier {
  _ProvenanceGraphVerifier(this.proposed, this.ranges, this.messages);

  final SupportModelProvenance proposed;
  final List<SupportModelSourceRange> ranges;
  final List<SupportModelSelectedSupportMessage> messages;

  SupportModelProvenanceCoverageResult verify() {
    final selection = _ProvenanceSelection(proposed, ranges, messages);
    final recipes = <SupportModelProvenance>[
      proposed,
      for (final message in messages)
        if (message.role == SupportModelSelectedRole.assistant)
          message.provenance!,
    ];
    if (recipes.length > SupportModelProvenanceLimits.maxRecipeNodes) {
      _reject(SupportModelProvenanceFailure.limitExceeded);
    }
    var declarations = 0;
    var occurrences = 0;
    final runs = <_RowKey>{};
    final inputs = <_RowKey>{};
    for (final recipe in recipes) {
      declarations +=
          recipe.originalRanges.length + recipe.directReplies.length;
      if (declarations >
          SupportModelProvenanceLimits.maxDeclarationsAndReferences) {
        _reject(SupportModelProvenanceFailure.limitExceeded);
      }
      for (final range in recipe.originalRanges) {
        occurrences += range.orderedMessageIds.length;
        if (occurrences > SupportModelProvenanceLimits.maxSourceIdOccurrences) {
          _reject(SupportModelProvenanceFailure.limitExceeded);
        }
      }
      if (!runs.add((recipe.supportSessionId, recipe.runId)) ||
          !inputs.add((recipe.supportSessionId, recipe.currentUserMessageId))) {
        _reject(SupportModelProvenanceFailure.ownerMismatch);
      }
    }
    selection.requireExactProposedRanges();
    final checker = _ProvenanceRecipeChecker(selection);
    for (final recipe in recipes) {
      checker.checkSourcesAndReferences(recipe);
    }
    _requireDag(recipes);
    for (final recipe in recipes.skip(1)) {
      checker.checkHistoricalInputAndOrder(recipe);
    }
    return SupportModelProvenanceCoverageResult.valid(recipes.sublist(1));
  }

  void _requireDag(List<SupportModelProvenance> recipes) {
    final indices = <_RowKey, int>{};
    for (var i = 0; i < recipes.length; i++) {
      final recipe = recipes[i];
      indices[(recipe.supportSessionId, recipe.replyMessageId)] = i;
    }
    final edges = <List<int>>[for (final _ in recipes) <int>[]];
    final incoming = List<int>.filled(recipes.length, 0);
    for (var i = 0; i < recipes.length; i++) {
      for (final reference in recipes[i].directReplies) {
        final ancestor = indices[(reference.sessionId, reference.messageId)];
        if (ancestor == null) {
          _reject(SupportModelProvenanceFailure.missingDependency);
        }
        edges[i].add(ancestor);
        incoming[ancestor]++;
      }
    }
    final ready = <int>[
      for (var i = 0; i < incoming.length; i++)
        if (incoming[i] == 0) i,
    ];
    var visited = 0;
    for (var cursor = 0; cursor < ready.length; cursor++) {
      visited++;
      for (final ancestor in edges[ready[cursor]]) {
        if (--incoming[ancestor] == 0) ready.add(ancestor);
      }
    }
    if (visited != recipes.length) _reject(SupportModelProvenanceFailure.cycle);
  }
}

/// Validates that the caller's selected support metadata describes exactly its
/// full support ranges, in the supplied native order. Game range IDs remain in
/// their own domain and cannot stand in for support rows with the same IDs.
final class _ProvenanceSelection {
  _ProvenanceSelection(
    this.proposed,
    this.ranges,
    List<SupportModelSelectedSupportMessage> messages,
  ) {
    if (ranges.length >
            SupportModelProvenanceLimits.maxDeclarationsAndReferences ||
        messages.length >
            SupportModelProvenanceLimits.maxSelectedSupportMessages) {
      _reject(SupportModelProvenanceFailure.limitExceeded);
    }
    var occurrences = 0;
    var supportOffset = 0;
    var assistantCount = 0;
    for (var i = 0; i < ranges.length; i++) {
      final range = ranges[i];
      final key = (range.domain, range.sessionId);
      if (sourceIndices.containsKey(key)) {
        _reject(SupportModelProvenanceFailure.invalidSource);
      }
      sourceIndices[key] = i;
      final positions = <String, int>{};
      for (var j = 0; j < range.orderedMessageIds.length; j++) {
        final id = range.orderedMessageIds[j];
        positions[id] = j;
        occurrences++;
        if (occurrences > SupportModelProvenanceLimits.maxSourceIdOccurrences) {
          _reject(SupportModelProvenanceFailure.limitExceeded);
        }
        if (range.domain != SupportModelSourceDomain.support) continue;
        if (range.sessionId == proposed.supportSessionId &&
            (id == proposed.currentUserMessageId ||
                id == proposed.replyMessageId)) {
          _reject(SupportModelProvenanceFailure.currentInputOverlap);
        }
        if (supportOffset >= messages.length) {
          _reject(SupportModelProvenanceFailure.missingDependency);
        }
        final message = messages[supportOffset++];
        if (message.sessionId != range.sessionId || message.messageId != id) {
          _reject(SupportModelProvenanceFailure.orderMismatch);
        }
        final rowKey = (message.sessionId, message.messageId);
        if (rows.containsKey(rowKey)) {
          _reject(SupportModelProvenanceFailure.invalidSource);
        }
        rows[rowKey] = message;
        _requireKnownOrigin(message);
        if (message.role == SupportModelSelectedRole.assistant &&
            ++assistantCount >= SupportModelProvenanceLimits.maxRecipeNodes) {
          _reject(SupportModelProvenanceFailure.limitExceeded);
        }
      }
      sourcePositions[key] = positions;
    }
    if (supportOffset != messages.length) {
      _reject(SupportModelProvenanceFailure.invalidSource);
    }
  }

  final SupportModelProvenance proposed;
  final List<SupportModelSourceRange> ranges;
  final sourceIndices = <_SourceKey, int>{};
  final sourcePositions = <_SourceKey, Map<String, int>>{};
  final rows = <_RowKey, SupportModelSelectedSupportMessage>{};

  void _requireKnownOrigin(SupportModelSelectedSupportMessage message) {
    switch (message.role) {
      case SupportModelSelectedRole.user:
        if (message.provenance != null) {
          _reject(SupportModelProvenanceFailure.ownerMismatch);
        }
      case SupportModelSelectedRole.assistant:
        final recipe = message.provenance;
        if (recipe == null || message.runId == null) {
          _reject(SupportModelProvenanceFailure.unavailableRecipe);
        }
        if (recipe.supportSessionId != message.sessionId ||
            recipe.replyMessageId != message.messageId ||
            recipe.runId != message.runId) {
          _reject(SupportModelProvenanceFailure.ownerMismatch);
        }
      case SupportModelSelectedRole.system:
      case SupportModelSelectedRole.unknown:
        _reject(SupportModelProvenanceFailure.unavailableRecipe);
    }
  }

  void requireExactProposedRanges() {
    if (proposed.originalRanges.length != ranges.length) {
      _reject(SupportModelProvenanceFailure.coverageMismatch);
    }
    for (var i = 0; i < ranges.length; i++) {
      final original = proposed.originalRanges[i];
      final selected = ranges[i];
      if (original.domain != selected.domain ||
          original.sessionId != selected.sessionId ||
          original.orderedMessageIds.length !=
              selected.orderedMessageIds.length) {
        _reject(SupportModelProvenanceFailure.coverageMismatch);
      }
      for (var j = 0; j < original.orderedMessageIds.length; j++) {
        if (original.orderedMessageIds[j] != selected.orderedMessageIds[j]) {
          _reject(SupportModelProvenanceFailure.orderMismatch);
        }
      }
    }
  }
}

/// Each declaration is checked once against pre-indexed selected positions.
/// References must equal exactly the derived support rows of that recipe's own
/// ranges, in source/message order. Nothing is inferred from a declared right.
final class _ProvenanceRecipeChecker {
  _ProvenanceRecipeChecker(this.selection);

  final _ProvenanceSelection selection;

  void checkSourcesAndReferences(SupportModelProvenance recipe) {
    var previousSource = -1;
    final requiredReplies = <SupportModelSelectedSupportMessage>[];
    for (final range in recipe.originalRanges) {
      final key = (range.domain, range.sessionId);
      final sourceIndex = selection.sourceIndices[key];
      final positions = selection.sourcePositions[key];
      if (sourceIndex == null || positions == null) {
        _reject(SupportModelProvenanceFailure.coverageMismatch);
      }
      if (sourceIndex <= previousSource) {
        _reject(SupportModelProvenanceFailure.orderMismatch);
      }
      previousSource = sourceIndex;
      var previousId = -1;
      for (final id in range.orderedMessageIds) {
        final position = positions[id];
        if (position == null) {
          _reject(SupportModelProvenanceFailure.coverageMismatch);
        }
        if (position <= previousId) {
          _reject(SupportModelProvenanceFailure.orderMismatch);
        }
        previousId = position;
        if (range.domain != SupportModelSourceDomain.support) continue;
        if (range.sessionId == recipe.supportSessionId &&
            (id == recipe.currentUserMessageId ||
                id == recipe.replyMessageId)) {
          _reject(SupportModelProvenanceFailure.currentInputOverlap);
        }
        final message = selection.rows[(range.sessionId, id)]!;
        if (message.role == SupportModelSelectedRole.assistant) {
          requiredReplies.add(message);
        }
      }
    }
    for (final reference in recipe.directReplies) {
      final row = selection.rows[(reference.sessionId, reference.messageId)];
      if (row == null || row.role != SupportModelSelectedRole.assistant) {
        _reject(SupportModelProvenanceFailure.missingDependency);
      }
      if (row.runId != reference.runId) {
        _reject(SupportModelProvenanceFailure.ownerMismatch);
      }
    }
    if (requiredReplies.length != recipe.directReplies.length) {
      _reject(SupportModelProvenanceFailure.missingDependency);
    }
    for (var i = 0; i < requiredReplies.length; i++) {
      final row = requiredReplies[i];
      final reference = recipe.directReplies[i];
      if (reference.sessionId != row.sessionId ||
          reference.messageId != row.messageId) {
        _reject(SupportModelProvenanceFailure.orderMismatch);
      }
    }
  }

  void checkHistoricalInputAndOrder(SupportModelProvenance recipe) {
    final input =
        selection.rows[(recipe.supportSessionId, recipe.currentUserMessageId)];
    if (input == null) _reject(SupportModelProvenanceFailure.missingDependency);
    if (input.role != SupportModelSelectedRole.user) {
      _reject(SupportModelProvenanceFailure.ownerMismatch);
    }
    final positions =
        selection.sourcePositions[(
          SupportModelSourceDomain.support,
          recipe.supportSessionId,
        )]!;
    final replyPosition = positions[recipe.replyMessageId]!;
    if (positions[recipe.currentUserMessageId]! >= replyPosition) {
      _reject(SupportModelProvenanceFailure.orderMismatch);
    }
    // Within this support session, original history predates this reply/input.
    // Other domains/sessions have independent native orders, not invented time.
    for (final range in recipe.originalRanges) {
      if (range.domain != SupportModelSourceDomain.support ||
          range.sessionId != recipe.supportSessionId) {
        continue;
      }
      for (final id in range.orderedMessageIds) {
        if (positions[id]! >= positions[recipe.currentUserMessageId]!) {
          _reject(SupportModelProvenanceFailure.orderMismatch);
        }
      }
    }
  }
}
