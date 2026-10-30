import 'dart:math';

import '../../../../core/application/chat_source_mutation_registry.dart';
import '../../../chat/state/chat_session_write_queue.dart';
import '../../models/support_app_action.dart';

/// Trusted native integration, not JSON. Bind a genuine existing owner queue
/// and latest cache/Ledger/Collector/InfoBlock/prompt invalidations. The optional
/// maintenance mode below is distinct from a loaded controller; neither mode
/// builds a replacement controller or substitutes an unconditional current guard.
abstract interface class SupportAppRepairNativePort {
  bool get isCurrent;
  ChatSessionWriteQueue? existingQueue(String targetSessionId);
  bool invalidateLatestSession(String targetSessionId);
  bool invalidateLatestDatabaseRepair();
}

/// Optional genuine native maintenance mode. Legacy loaded-owner ports keep
/// their original queue behavior; no JSON or permissive test fallback is added.
abstract interface class SupportAppRepairQueueResolutionPort {
  bool requiresMaintenanceOwner(String session);
  bool isMaintenanceQueue(String session, ChatSessionWriteQueue queue);
  ChatSessionWriteQueue? resolveRepairQueue(
    String session,
    SupportAppActionContext context,
  );
  bool retainsRepairQueue(String session, ChatSessionWriteQueue queue);
  Future<bool> validateRepairQueue(String session, ChatSessionWriteQueue queue);
  void repairQueueStarted(String session, ChatSessionWriteQueue queue);
  void repairQueueSettled(String session, ChatSessionWriteQueue queue);
}

final class SupportAppRepairRuntime {
  const SupportAppRepairRuntime({
    required this.mutations,
    required this.native,
    required this.isOriginalOwnerCurrent,
  });
  final ChatSourceMutationRegistry mutations;
  final SupportAppRepairNativePort native;
  final bool Function() isOriginalOwnerCurrent;
  bool get current =>
      !mutations.isDisposed && native.isCurrent && isOriginalOwnerCurrent();

  bool ownsAdmittedEffect(String session, SupportAppActionContext context) =>
      context.domainEffectForSession(session) &&
      (context.domainEffectForOperation(
            SupportAppDomainOperation.sessionRepair,
          ) ||
          context.domainEffectForOperation(
            SupportAppDomainOperation.sessionUndo,
          ));

  Object? checkpoint(String session) =>
      current && !mutations.isSessionPending(session)
      ? mutations.sessionCheckpoint(session)
      : null;

  bool unchanged(String session, Object checkpoint) =>
      current &&
      !mutations.isSessionPending(session) &&
      identical(mutations.sessionCheckpoint(session), checkpoint);

  ChatSessionWriteQueue? _queue(
    String session,
    SupportAppActionContext context,
  ) => native is SupportAppRepairQueueResolutionPort
      ? (native as SupportAppRepairQueueResolutionPort).resolveRepairQueue(
          session,
          context,
        )
      : native.existingQueue(session);

  bool needsQueueOwnerPreparation(String session) =>
      native is SupportAppRepairQueueResolutionPort &&
      (native as SupportAppRepairQueueResolutionPort).requiresMaintenanceOwner(
        session,
      );

  /// Undo has no core prepare queue. Prove the native owner before taking its
  /// fresh checkpoint/confirmation, without holding a queue across the gesture.
  Future<bool> prepareQueueOwner(
    String session,
    SupportAppActionContext context,
  ) async {
    if (!needsQueueOwnerPreparation(session)) return true;
    final expected = checkpoint(session);
    if (expected == null) return false;
    final scope = begin(
      session,
      expected,
      context,
    ); // Begin before first await.
    if (scope == null) return false;
    try {
      return await scope.run(() async => true) == true;
    } finally {
      scope.close();
    }
  }

  /// Synchronous retirement BEFORE queue/preparation/effect awaits. If it retires
  /// the requester's model ROOT, existing gateway fences deny further effects.
  /// Terminal same-ROOT dispatch must be integrated by the real ROOT owner.
  SupportAppRepairScope? begin(
    String session,
    Object expected,
    SupportAppActionContext context,
  ) {
    if (ownsAdmittedEffect(session, context)) {
      final queue = _queue(session, context);
      final checkpoint = mutations.sessionCheckpoint(session);
      if (queue == null || checkpoint == null || !current) return null;
      // The native composition already began this exact source before awaiting.
      // Adopt ONLY its factual custody; do not fence again or restore ModelRun.
      return SupportAppRepairScope._(
        this,
        session,
        context,
        queue,
        context.domainPublication(session)!,
        checkpoint,
        () {},
      );
    }
    if (!context.current || !unchanged(session, expected)) return null;
    final queue = _queue(session, context);
    if (queue == null || !context.current || !unchanged(session, expected)) {
      return null;
    }
    final settle = mutations.beginMutation(sessionId: session);
    try {
      final checkpoint = mutations.sessionCheckpoint(session);
      final publication = queue.beginPublication();
      if (checkpoint == null || !context.current || !current) {
        settle();
        return null;
      }
      return SupportAppRepairScope._(
        this,
        session,
        context,
        queue,
        publication,
        checkpoint,
        settle,
      );
    } catch (_) {
      settle();
      return null;
    }
  }
}

final class SupportAppRepairScope {
  SupportAppRepairScope._(
    this.runtime,
    this.session,
    this.context,
    this.queue,
    this.publication,
    this.checkpoint,
    this._settle,
  );
  final SupportAppRepairRuntime runtime;
  final String session;
  final SupportAppActionContext context;
  final ChatSessionWriteQueue queue;
  final int publication;
  final Object checkpoint;
  final void Function() _settle;
  bool _closed = false, _retired = false;
  bool get current {
    if (_closed || _retired) return false;
    if (!runtime.current ||
        (runtime.native is SupportAppRepairQueueResolutionPort &&
            !(runtime.native as SupportAppRepairQueueResolutionPort)
                .retainsRepairQueue(session, queue)) ||
        !(runtime.ownsAdmittedEffect(session, context) || context.current) ||
        !identical(runtime.mutations.sessionCheckpoint(session), checkpoint)) {
      _retired = true;
    }
    return !_retired;
  }

  Future<T?> run<T>(Future<T?> Function() operation) async {
    final native = runtime.native;
    final maintenance =
        native is SupportAppRepairQueueResolutionPort &&
        (native as SupportAppRepairQueueResolutionPort).isMaintenanceQueue(
          session,
          queue,
        );
    if (maintenance) {
      (native as SupportAppRepairQueueResolutionPort).repairQueueStarted(
        session,
        queue,
      );
    }
    try {
      return await queue.run<T?>(() async {
        if (!current) return null;
        if (maintenance &&
            !await (native as SupportAppRepairQueueResolutionPort)
                .validateRepairQueue(session, queue)) {
          return null;
        }
        if (!current) return null;
        return operation(); // Repo owns every awaited DB/encryption/CAS boundary.
      });
    } finally {
      if (maintenance) {
        (native as SupportAppRepairQueueResolutionPort).repairQueueSettled(
          session,
          queue,
        );
      }
    }
  }

  /// Called only for an ACTUAL durable receipt, even after requester Stop. No
  /// stale data is published: native port evicts/reloads latest durable state.
  bool invalidateDurable() =>
      !_closed &&
      runtime.current &&
      queue.isCurrentPublication(publication) &&
      runtime.native.invalidateLatestSession(session);
  void close() {
    if (_closed) return;
    _closed = true;
    _settle();
  }
}

/// One ORIGINAL plan may cross only its own preparation/effect admission events.
/// The stored core callback remains this same authority; closing preparation
/// must not kill it, and a new callback must never resurrect a retired source.
final class SupportAppRepairAuthority {
  SupportAppRepairAuthority(
    this.runtime,
    this.session,
    this.context,
    Object checkpoint,
  ) : _checkpoint = checkpoint;
  final SupportAppRepairRuntime runtime;
  final String session;
  final SupportAppActionContext context;
  Object _checkpoint;
  bool _retired = false;
  bool get current {
    if (_retired) return false;
    if (!runtime.current ||
        !(runtime.ownsAdmittedEffect(session, context) || context.current) ||
        !identical(runtime.mutations.sessionCheckpoint(session), _checkpoint)) {
      _retired = true;
    }
    return !_retired;
  }

  SupportAppRepairScope? begin() {
    if (runtime.ownsAdmittedEffect(session, context)) {
      if (_retired) return null;
      final scope = runtime.begin(session, _checkpoint, context);
      if (scope != null) _checkpoint = scope.checkpoint;
      return scope;
    }
    if (!current) return null;
    final scope = runtime.begin(session, _checkpoint, context);
    if (scope == null) {
      _retired = true;
      return null;
    }
    _checkpoint = scope.checkpoint;
    return scope;
  }
}

String supportRepairOpaqueId(String prefix) {
  final random = Random.secure();
  return '$prefix-${List.generate(16, (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0')).join()}';
}

/// Bounded original native custody. Public handles address ONLY these retained
/// objects, never journal JSON. Eviction means unavailable, not reconstructed.
final class SupportAppRepairCustody<T> {
  final _values = <String, (String, String, T)>{};
  String retain(T value, SupportAppActionContext context) {
    while (_values.length >= 64) {
      _values.remove(_values.keys.first);
    }
    final id = supportRepairOpaqueId('repair');
    _values[id] = (context.runId, context.sessionId, value);
    return id;
  }

  T? read(String id, SupportAppActionContext context) {
    final found = _values[id];
    return context.current &&
            found != null &&
            found.$1 == context.runId &&
            found.$2 == context.sessionId
        ? found.$3
        : null;
  }

  /// Fresh native Undo may come from a later run in the SAME original Astoria
  /// parent. It still receives only the retained actual receipt, and the owner
  /// revalidates every original dependency and encrypted journal condition.
  T? readForUndo(String id, SupportAppActionContext context) {
    final found = _values[id];
    return context.current && found != null && found.$2 == context.sessionId
        ? found.$3
        : null;
  }

  void remove(String id) => _values.remove(id);
  void clear() => _values.clear();
}
