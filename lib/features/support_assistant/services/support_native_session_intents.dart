part of 'support_native_consent_controller.dart';

typedef SupportNativeSessionReader =
    Future<SupportConsentSessionMetadata> Function(
      SupportConsentSelectionSource source,
      String sessionId,
    );

/// Opaque, once-only original native choice. JSON/cards/restored metadata cannot
/// create it. The metadata is a Core exact-target projection, NOT history.
final class SupportNativeSessionChoice {
  SupportNativeSessionChoice._(
    this._issuer,
    this._review,
    this.metadata,
    this._sourceCheckpoint,
  );
  final SupportNativeConsentController _issuer;
  final SupportNativeReview _review;
  final SupportConsentSessionMetadata metadata;
  final Object? _sourceCheckpoint;
  bool _consumed = false;
  String get sessionId => metadata.sessionId!;
  SupportConsentSelectionSource get source => metadata.source;
  bool get isCurrent => !_consumed && _issuer._sessionChoiceCurrent(this);
  @override
  String toString() => 'SupportNativeSessionChoice';
}

extension SupportNativeSessionIntents on SupportNativeConsentController {
  bool _sessionReviewCurrent(SupportNativeReview review) {
    final a = review._policy, b = runtime.snapshot.preferences;
    return _current(review) &&
        runtime.pending == 0 &&
        runtime.snapshot.isAvailable &&
        a != null &&
        b != null &&
        a.supportSessionId == review.view.sessionId &&
        b.supportSessionId == runtime.sessionId &&
        a.policyIdentity == b.policyIdentity &&
        (a.scope == null ? b.scope == null : a.scope!.sameAs(b.scope)) &&
        (a.recipient == null
            ? b.recipient == null
            : a.recipient!.sameAs(b.recipient));
  }

  bool _sessionSourceCurrent(
    SupportConsentSelectionSource source,
    String id,
    Object? checkpoint,
  ) => source == SupportConsentSelectionSource.support
      ? id == runtime.sessionId &&
            id == runtime.snapshot.preferences?.supportSessionId
      : sessionSources != null &&
            checkpoint != null &&
            !sessionSources!.isSessionPending(id) &&
            identical(checkpoint, sessionSources!.sessionCheckpoint(id));

  bool _sessionChoiceCurrent(SupportNativeSessionChoice choice) =>
      identical(choice._issuer, this) &&
      readSession != null &&
      _sessionReviewCurrent(choice._review) &&
      _sessionSourceCurrent(
        choice.source,
        choice.sessionId,
        choice._sourceCheckpoint,
      );

  Future<SupportNativeSessionChoice?> prepareSessionHistory(
    SupportNativeReview review,
    SupportConsentSelectionSource source,
    String sessionId,
  ) async {
    final reader = readSession;
    if (reader == null || !_sessionReviewCurrent(review)) return null;
    try {
      requireSupportPermissionId(sessionId);
      final checkpoint = source == SupportConsentSelectionSource.roleplay
          ? sessionSources?.sessionCheckpoint(sessionId)
          : null;
      bool current() =>
          _sessionReviewCurrent(review) &&
          _sessionSourceCurrent(source, sessionId, checkpoint);
      if (!current()) return null;
      final metadata = await reader(source, sessionId);
      if (!current() ||
          !metadata.isAvailable ||
          metadata.source != source ||
          metadata.sessionId != sessionId) {
        return null;
      }
      return SupportNativeSessionChoice._(this, review, metadata, checkpoint);
    } catch (_) {
      return null;
    }
  }

  Future<bool> selectSessionHistory(SupportNativeSessionChoice choice) async {
    if (choice._consumed || !_sessionChoiceCurrent(choice)) return false;
    // Consume and fence local reads BEFORE notify, binding admission or await.
    choice._consumed = true;
    return _withLocalPermissionChange(() async {
      if (!_sessionChoiceCurrent(choice)) return false;
      final review = _admitBinding(choice._review);
      bool current() =>
          _current(review) &&
          _sessionSourceCurrent(
            choice.source,
            choice.sessionId,
            choice._sourceCheckpoint,
          );
      if (!current()) return false;
      SupportConsentSessionMetadata latest;
      try {
        latest = await readSession!(choice.source, choice.sessionId);
      } catch (_) {
        return false;
      }
      if (!current() ||
          !latest.isAvailable ||
          !choice.metadata.sameAs(latest)) {
        return false;
      }
      final s = review._policy!.scope;
      if (s?.selectionRevision == maxSupportPermissionRevision) return false;
      return _selectScope(
        review,
        SupportPermissionScope(
          selectionRevision: (s?.selectionRevision ?? 0) + 1,
          gameSessionId: choice.source == SupportConsentSelectionSource.roleplay
              ? choice.sessionId
              : s?.gameSessionId,
          gameHistory: choice.source == SupportConsentSelectionSource.roleplay
              ? null
              : s?.gameHistory,
          supportHistory: choice.source == SupportConsentSelectionSource.support
              ? null
              : s?.supportHistory,
          gameHistoryExtent:
              choice.source == SupportConsentSelectionSource.roleplay
              ? SupportHistoryExtent.wholeSession
              : s?.gameHistoryExtent ?? SupportHistoryExtent.selectedMessages,
          supportHistoryExtent:
              choice.source == SupportConsentSelectionSource.support
              ? SupportHistoryExtent.wholeSession
              : s?.supportHistoryExtent ??
                    SupportHistoryExtent.selectedMessages,
          safeCategories:
              s?.safeCategories.where(
                SupportNativeConsentController._implementedSafeCategory,
              ) ??
              const [],
        ),
        // _selectScope owns its admitted review. Retain only the ORIGINAL
        // candidate checkpoint here, not the pre-admission write owner.
        sourceIsCurrent: () => _sessionSourceCurrent(
          choice.source,
          choice.sessionId,
          choice._sourceCheckpoint,
        ),
        supportHistorySelected:
            choice.source == SupportConsentSelectionSource.support,
      );
    });
  }
}
