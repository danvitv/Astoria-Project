import '../../../core/db/repositories/chat_repo.dart';
import '../../../core/db/repositories/support_repo.dart';

/// Finite delegation by the actual loaded ChatNotifier, not a queue factory or
/// general mutation callback. The caller already runs on this owner's queue.
final class ChatNativeSessionTitlePort {
  const ChatNativeSessionTitlePort(this._repo, this._originalCurrent);
  final ChatRepo _repo;
  final bool Function() _originalCurrent;

  Future<ChatNativeTitleObservation?> observe(
    String session,
    bool Function() current,
  ) => _repo.observeNativeTitle(session, () => _originalCurrent() && current());

  Future<ChatNativeTitleReceipt?> rename({
    required ChatNativeTitleObservation observed,
    required String title,
    required SupportRepo support,
    required String parentSession,
    required String operationId,
    required int createdAt,
    required bool Function() current,
  }) => _repo.renameNativeTitle(
    before: observed,
    title: title,
    support: support,
    parentSession: parentSession,
    operationId: operationId,
    createdAt: createdAt,
    isCurrent: () => _originalCurrent() && current(),
  );

  Future<bool?> undo({
    required ChatNativeTitleReceipt receipt,
    required ChatNativeTitleObservation observed,
    required SupportRepo support,
    required String parentSession,
    required bool Function() current,
  }) => _repo.undoNativeTitle(
    receipt: receipt,
    observed: observed,
    support: support,
    parentSession: parentSession,
    isCurrent: () => _originalCurrent() && current(),
  );
}
