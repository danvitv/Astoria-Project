import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../../../core/db/repositories/memory_book_repo.dart';
import '../../../../../core/db/repositories/memory_catalog_repo.dart';
import '../../../models/support_app_action.dart';
import 'memory_control_definitions.dart';
import 'memory_control_projection.dart';
import 'session_memory_guard.dart';

/// Actual local repository effects only. No detached sheet, imported draft job,
/// provider lookup, network client or destructive approximation.
final class SupportAppMemoryAdapter implements SupportAppActionAdapter {
  SupportAppMemoryAdapter({
    required this.books,
    required this.chats,
    required this.catalog,
    required this.guard,
    required this.isDraftBusy,
    required this.onBookChanged,
  });
  final MemoryBookRepo books;
  final ChatRepo chats;
  final MemoryCatalogRepo catalog;
  final SessionMemoryGuard guard;
  final bool Function(String sessionId) isDraftBusy;
  final void Function(String sessionId) onBookChanged;

  @override
  List<SupportAppActionDefinition> get definitions =>
      MemoryControlDefinitions.all;

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    final definition = definitions.where((d) => d.name == action).firstOrNull;
    if (definition == null || !definition.accepts(arguments)) return null;
    final id = arguments['sessionId']! as String;
    final sourceCurrent = guard.observe(id, context);
    if (sourceCurrent == null) return null;
    final reading = action == 'astoria_memory_inspect';
    // The existing ROOT terminal port admits keyless connection plans only.
    // Never mutate a rooted model's source through a forged connection dispatch.
    if (!reading && context.terminalRoot != null && context.domainRoot == null)
      return null;
    if (action == 'astoria_memory_settings' && arguments.length == 1) {
      throw const SupportAppActionRefused(
        SupportAppActionCode.invalidArguments,
      );
    }
    final session = await chats.getById(id);
    if (!sourceCurrent() || session == null) return null;
    final observed = await books.observeForControl(id);
    if (!sourceCurrent()) return null;
    if (action == 'astoria_memory_create') {
      if (observed != null) {
        return SupportAppPreparedAction(
          target: id,
          observation: observed,
          observationIsCurrent: sourceCurrent,
          preview: {'sessionId': id, 'status': 'already_exists'},
          execute: (current) async => current() && sourceCurrent()
              ? SupportAppActionOutcome(SupportAppActionCode.noChange)
              : SessionMemoryGuard.interrupted(context),
        );
      }
      return SupportAppPreparedAction(
        target: id,
        observation: session,
        observationIsCurrent: sourceCurrent,
        preview: {
          'sessionId': id,
          'enabled': arguments['enabled'],
          'entryCount': 0,
          'draftCount': 0,
          'automation': false,
          'vectorSearch': false,
          'status': 'empty_local_book',
        },
        execute: (admitted) => _settle(
          id,
          context,
          () => books.createEmptyForControl(
            sessionId: id,
            enabled: arguments['enabled']! as bool,
            isCurrent: () => admitted() && sourceCurrent(),
          ),
          () => admitted() && sourceCurrent(),
        ),
      );
    }
    if (observed == null) return null;
    if (reading) {
      return SupportAppPreparedAction(
        target: id,
        observation: observed,
        observationIsCurrent: sourceCurrent,
        execute: (current) async => current() && sourceCurrent()
            ? SupportAppActionOutcome(
                SupportAppActionCode.completed,
                data: MemoryControlProjection.inspect(observed.book, arguments),
              )
            : SessionMemoryGuard.interrupted(context),
      );
    }
    final draftFlag = action == 'astoria_memory_draft_vector';
    final draftId = arguments['draftId'] as String?;
    if (draftFlag &&
        (isDraftBusy(id) ||
            observed.book.pendingDrafts.where((d) => d.id == draftId).length !=
                1)) {
      return null;
    }
    if (action == 'astoria_memory_catalog_rebuild' &&
        context.sourceAccess == null) {
      return null;
    }
    final patch = <String, Object?>{...arguments}..remove('sessionId');
    bool observedCurrent() =>
        sourceCurrent() && (!draftFlag || !isDraftBusy(id));
    return SupportAppPreparedAction(
      target: id,
      observation: observed,
      observationIsCurrent: observedCurrent,
      preview: {
        'sessionId': id,
        if (draftFlag) 'draftId': draftId,
        if (action == 'astoria_memory_settings') 'settings': patch,
        if (draftFlag) 'vectorSearch': arguments['vectorSearch'],
        if (action == 'astoria_memory_catalog_rebuild') ...{
          'entryCount': observed.book.entries.length,
          'status': 'local_catalog_only',
        },
      },
      execute: (admitted) async {
        bool current() => admitted() && observedCurrent();
        if (!current()) return SessionMemoryGuard.interrupted(context);
        if (action == 'astoria_memory_catalog_rebuild') {
          SupportAppSourceLease? lease;
          try {
            lease = await context.sourceAccess!.acquire(
              domain: 'memory_book',
              sourceId: observed.book.id,
              observation: observed,
              context: context,
            );
          } catch (_) {
            return SupportAppActionOutcome(SupportAppActionCode.unavailable);
          }
          if (lease == null) {
            return SupportAppActionOutcome(SupportAppActionCode.unavailable);
          }
          final originalLease = lease;
          try {
            if (!current() || !originalLease.isCurrent) {
              return SessionMemoryGuard.interrupted(context);
            }
            return await _settle(
              id,
              context,
              () => books.rebuildCatalogForControl(
                expected: observed,
                catalog: catalog,
                isCurrent: () => current() && originalLease.isCurrent,
              ),
              () => current() && originalLease.isCurrent,
            );
          } finally {
            // Read-lease cleanup cannot erase an already known durable effect.
            // This plan never retains or reuses the lease, even on port failure.
            try {
              originalLease.release();
            } catch (_) {}
          }
        }
        return _settle(
          id,
          context,
          () => draftFlag
              ? books.setDraftVectorForControl(
                  expected: observed,
                  draftId: draftId!,
                  vectorSearch: arguments['vectorSearch']! as bool,
                  isCurrent: current,
                )
              : books.patchSettingsForControl(
                  expected: observed,
                  fields: patch,
                  isCurrent: current,
                ),
          current,
        );
      },
    );
  }

  Future<SupportAppActionOutcome> _settle(
    String id,
    SupportAppActionContext context,
    Future<bool> Function() write,
    bool Function() isCurrent,
  ) async {
    final changed = await write();
    if (changed) {
      // Durable effect survives a stopped model. This is existing owner cache
      // invalidation, not new UI/native authorization or a replacement POST.
      try {
        onBookChanged(id);
      } catch (_) {
        return SupportAppActionOutcome(
          SupportAppActionCode.completed,
          effect: SupportAppActionEffect.persisted,
          data: const {'refreshPending': true},
        );
      }
    }
    if (!isCurrent())
      return SessionMemoryGuard.interrupted(context, persisted: changed);
    return SupportAppActionOutcome(
      changed ? SupportAppActionCode.completed : SupportAppActionCode.conflict,
      effect: changed
          ? SupportAppActionEffect.persisted
          : SupportAppActionEffect.none,
      data: changed ? {'sessionId': id, 'status': 'persisted'} : const {},
    );
  }
}
