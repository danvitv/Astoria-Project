/// Optional neutral admission hook. Start synchronously before transaction work;
/// the returned callback settles once in finally, on success or failure.
typedef SessionMutationStarted = void Function() Function(String sessionId);

abstract class SessionDeletionStore {
  Future<void> deleteSession(String sessionId);
}
