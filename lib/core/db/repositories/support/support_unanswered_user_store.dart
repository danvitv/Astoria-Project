part of '../support_repo.dart';

/// Sealed native observation of the actual last user row. Not a restored origin,
/// model capability or parentless SQL handle; only this library can issue it.
sealed class SupportUnansweredUserObservation {
  SupportUnansweredUserObservation._();
  SupportMessage get message;
  @override
  String toString() => 'SupportUnansweredUserObservation';
}

final class _SupportUnansweredUserObservation
    extends SupportUnansweredUserObservation {
  _SupportUnansweredUserObservation(this.original) : super._();
  final SupportUserEditingObservation original;
  @override
  SupportMessage get message => original.message;
}

extension _SupportUnansweredUserStore on _SupportGuardedReplyStore {
  Future<void> _unansweredTail(
    SupportMessage user,
    bool Function() current, {
    String? excludingReply,
  }) async {
    _requireCurrent(current);
    final rows = await _checked(
      db
          .customSelect(
            'SELECT 1 AS invalid_tail FROM support_messages WHERE session_id = ? AND id != ? '
            '${excludingReply == null ? '' : 'AND id != ? '}'
            "AND (typeof(created_at) != 'integer' OR created_at < 0 "
            'OR created_at > ${_SupportNativeInputStore.maxTime} OR created_at >= ?) LIMIT 1',
            variables: [
              Variable<String>(user.sessionId),
              Variable<String>(user.id),
              if (excludingReply != null) Variable<String>(excludingReply),
              Variable<int>(user.createdAt),
            ],
            readsFrom: {db.supportMessages},
          )
          .get(),
      current,
    );
    _require(
      rows.isEmpty,
    ); // Any later role or timestamp tie refuses the claim.
  }

  Future<void> _sameUnansweredUser(
    SupportUnansweredUserObservation expected,
    bool Function() current, {
    String? excludingReply,
  }) async {
    _require(expected is _SupportUnansweredUserObservation);
    final original = (expected as _SupportUnansweredUserObservation).original;
    _require(messages.nativeInput.user(original.message));
    await _sameUserObservation(original, current);
    await _unansweredTail(
      original.message,
      current,
      excludingReply: excludingReply,
    );
  }

  Future<SupportUnansweredUserObservation?> readUnansweredUser(
    SupportMessage user,
    bool Function() current,
  ) => _transaction(current, () async {
    _require(messages.nativeInput.user(user) && user.body.trim().isNotEmpty);
    await _unansweredTail(user, current);
    final original = await readUserForEditing(user, current);
    _requireCurrent(current);
    _require(original != null);
    final observation = _SupportUnansweredUserObservation(original!);
    await _sameUnansweredUser(observation, current);
    _requireCurrent(current);
    return observation;
  });

  Future<void> _freshRetryRun(
    String sessionId,
    String runId,
    bool Function() current,
  ) async {
    _requireCurrent(current);
    final rows = await _checked(
      db
          .customSelect(
            'SELECT 1 AS reused FROM support_messages WHERE session_id = ? AND run_id = ? LIMIT 1',
            variables: [Variable<String>(sessionId), Variable<String>(runId)],
            readsFrom: {db.supportMessages},
          )
          .get(),
      current,
    );
    _require(rows.isEmpty);
  }
}
