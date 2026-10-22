part of 'support_native_consent_controller.dart';

final class SupportNativeMessageChoice {
  SupportNativeMessageChoice._(
    this._issuer,
    this.review,
    this.page,
    this.offset,
  );
  final SupportNativeConsentController _issuer;
  final SupportNativeReview review;
  final SupportConsentMessagePage page;
  final int offset;
}

typedef SupportNativeMessageReader =
    Future<SupportConsentMessagePage> Function(
      SupportConsentSelectionSource source,
      String sessionId,
      int offset,
    );

/// Exact native metadata selection, separate from grant/recipient orchestration.
extension SupportNativeSelectionIntents on SupportNativeConsentController {
  Future<bool> selectConnections(SupportNativeReview review, bool selected) {
    final p = review._policy;
    if (!_current(review) || p == null) return Future.value(false);
    final s = p.scope;
    return _selectScope(
      review,
      SupportPermissionScope(
        selectionRevision: (s?.selectionRevision ?? 0) + 1,
        gameSessionId: s?.gameSessionId,
        gameHistory: s?.gameHistory,
        supportHistory: s?.supportHistory,
        // Only current implemented category; no fabricated private/file handles.
        safeCategories: selected ? [SupportSafeCategory.connections] : const [],
      ),
    );
  }

  Future<SupportNativeMessageChoice?> prepareMessages(
    SupportNativeReview review,
    SupportConsentSelectionSource source,
    String sessionId, {
    int offset = 0,
  }) async {
    if (!_current(review) ||
        (source == SupportConsentSelectionSource.support &&
            sessionId != review.view.sessionId)) {
      return null;
    }
    final page = await readMessages(source, sessionId, offset);
    if (!_current(review) ||
        page.source != source ||
        page.sessionId != sessionId ||
        !_eligible(page)) {
      return null;
    }
    return SupportNativeMessageChoice._(this, review, page, offset);
  }

  Future<bool> selectMessages(
    SupportNativeMessageChoice choice,
    List<String> selectedIds,
  ) async {
    var review = choice.review;
    final page = choice.page;
    if (!identical(choice._issuer, this) ||
        !_current(review) ||
        review._policy == null ||
        selectedIds.toSet().length != selectedIds.length) {
      return false;
    }
    final chosen = page.items
        .where((row) => selectedIds.contains(row.messageId))
        .toList();
    if (chosen.length != selectedIds.length ||
        chosen.any((row) => row.sessionId != page.sessionId)) {
      return false;
    }
    review = _admitBinding(review);
    final latest = await readMessages(
      page.source,
      page.sessionId!,
      choice.offset,
    );
    if (!_current(review) ||
        !_eligible(latest) ||
        latest.sessionId != page.sessionId ||
        latest.source != page.source ||
        !_sameSession(page.roleplaySession, latest.roleplaySession) ||
        chosen.any((a) => !latest.items.any((b) => _sameMessage(a, b)))) {
      return false;
    }
    final s = review._policy!.scope;
    final selection = chosen.isEmpty
        ? null
        : SupportMessageSelection(chosen.map((r) => r.messageId));
    return _selectScope(
      review,
      SupportPermissionScope(
        selectionRevision: (s?.selectionRevision ?? 0) + 1,
        gameSessionId: page.source == SupportConsentSelectionSource.roleplay
            ? page.sessionId
            : s?.gameSessionId,
        gameHistory: page.source == SupportConsentSelectionSource.roleplay
            ? selection
            : s?.gameHistory,
        supportHistory: page.source == SupportConsentSelectionSource.support
            ? selection
            : s?.supportHistory,
        safeCategories:
            s?.safeCategories.where(
              (c) => c == SupportSafeCategory.connections,
            ) ??
            const [],
      ),
    );
  }

  Future<bool> _selectScope(
    SupportNativeReview review,
    SupportPermissionScope scope,
  ) {
    if (!_current(review)) return Future.value(false);
    review = _admitBinding(review);
    return _write(
      review,
      () => runtime.permissions.changeReviewedFromNative(
        review._policy!,
        change: (p) => p.withNativeScope(scope),
        isCurrent: () => _current(review),
      ),
    );
  }

  static bool _eligible(SupportConsentMessagePage p) =>
      p.status == SupportConsentSelectionStatus.available ||
      p.status == SupportConsentSelectionStatus.limited;
  static bool _sameMessage(
    SupportConsentMessageOption a,
    SupportConsentMessageOption b,
  ) =>
      a.sessionId == b.sessionId &&
      a.messageId == b.messageId &&
      a.role == b.role &&
      a.nativeOrder == b.nativeOrder &&
      a.swipeId == b.swipeId &&
      a.agentSwipeId == b.agentSwipeId &&
      a.timestampMs == b.timestampMs &&
      a.createdAtSeconds == b.createdAtSeconds;
  static bool _sameSession(
    SupportConsentSessionOption? a,
    SupportConsentSessionOption? b,
  ) => a == null
      ? b == null
      : b != null &&
            a.sessionId == b.sessionId &&
            a.characterId == b.characterId &&
            a.sessionIndex == b.sessionIndex &&
            a.variantGroupId == b.variantGroupId &&
            a.variantOrder == b.variantOrder;
}
