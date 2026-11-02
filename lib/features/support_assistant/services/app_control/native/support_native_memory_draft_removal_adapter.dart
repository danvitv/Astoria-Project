import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/db/repositories/memory_book_repo.dart';
import '../../../../../core/db/repositories/support_repo.dart';
import '../../../../memory/state/memory_native_entry_owner.dart';
import '../../../models/support_app_action.dart';
import '../support_app_repair_runtime.dart';
import 'support_native_domain_sources.dart';

final class _RetainedMemoryDraftRemoval {
  _RetainedMemoryDraftRemoval(
    this.parent,
    this.owner,
    this.receipt,
    this._current,
  );
  final String parent;
  final MemoryNativeEntryOwner owner;
  final MemoryNativeDraftRemovalReceipt receipt;
  final bool Function() _current;
  bool _retired = false;
  bool current() {
    if (_retired) return false;
    try {
      if (!_current() || !receipt.current) _retired = true;
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }
}

/// ONE already-loaded idle draft removal. Exact raw evidence/conditional Undo
/// remains native and private; tool results contain no draft/unknown raw payload.
final class SupportNativeMemoryDraftRemovalAdapter
    implements SupportAppActionAdapter {
  SupportNativeMemoryDraftRemovalAdapter({
    required this.support,
    required this.sources,
    required this.owners,
    required this.originContainer,
    required this.metadata,
    required this.captureMetadataGuard,
  });
  final SupportRepo support;
  final SupportNativeDomainSources sources;
  final MemoryNativeEntryOwnerRegistry owners;
  final ProviderContainer originContainer;
  final SupportAppMetadataPolicy metadata;
  final bool Function() Function() captureMetadataGuard;
  final _receipts = <String, _RetainedMemoryDraftRemoval>{};
  int _reservedReceiptSlots = 0;
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _receipts.clear();
  }

  bool _hasReceiptRoom() {
    if (_disposed) return false;
    _receipts.removeWhere((_, saved) => !saved.current());
    return _receipts.length + _reservedReceiptSlots < 64;
  }

  bool _reserveReceiptSlot() {
    // Synchronous PRE-effect reservation includes all in-flight operations.
    // Never prune live Undo, and Cancel spends no slot or original receipt.
    if (!_hasReceiptRoom()) return false;
    _reservedReceiptSlots++;
    return true;
  }

  bool get _current =>
      !_disposed &&
      owners.current &&
      sources.isOriginalOwnerCurrent() &&
      sources.owners.isCurrent &&
      !sources.mutations.isDisposed;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_memory_draft_delete',
      description:
          'Delete ONE existing pending_approval non-vector draft in the '
          'already-loaded selected idle original Memory tab. Discover exact sessionId '
          'and draftId via astoria_session_integrity and astoria_memory_inspect view=drafts. '
          'Native confirmation shows the exact decoded content JSON literal and one '
          'affected record. Other raw tokens, entries/settings/cursors remain unchanged. '
          'No approval, generation, provider, indexing, embedding or canon operation. '
          'A genuine retained receipt permits fresh confirmed conditional exact raw Undo.',
      risk: SupportAppActionRisk.destructive,
      fields: {
        'sessionId': const SupportAppActionField.text(128),
        'draftId': const SupportAppActionField.text(128),
      },
      requiredFields: {'sessionId', 'draftId'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_draft_delete_receipts',
      description:
          'List only genuine retained original draft-removal receipts in '
          'this Astoria parent. Metadata only; no raw draft body or journal import.',
      risk: SupportAppActionRisk.metadata,
      fields: {'offset': const SupportAppActionField.integer(0, 63)},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_draft_delete_undo',
      description:
          'Restore the exact removed raw draft object/order ONLY from a '
          'genuine retained original receipt, with fresh native confirmation, fresh '
          'private absence observation and unchanged full raw array CAS. Ordinary '
          'writes, replaced owners, source changes and guessed/journal IDs refuse.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'receipt': const SupportAppActionField.text(
          64,
          pattern: r'^repair-[a-f0-9]{32}$',
        ),
      },
      requiredFields: {'receipt'},
    ),
  ];

  String? targetSession(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) {
    if (action == 'astoria_memory_draft_delete')
      return arguments['sessionId'] as String?;
    if (action != 'astoria_memory_draft_delete_undo' || !context.current)
      return null;
    final saved = _receipts[arguments['receipt']];
    return saved != null && saved.parent == context.sessionId && saved.current()
        ? saved.receipt.sessionId
        : null;
  }

  bool _safe(String session, String id, String content) =>
      metadata is SupportAppBodyMetadataPolicy &&
      (metadata as SupportAppBodyMetadataPolicy).exactBodyText(
            content,
            maxLength: 8192,
          ) ==
          content &&
      metadata.exactText(session, maxLength: 128) == session &&
      metadata.exactText(id, maxLength: 128) == id &&
      metadata.exactText(jsonEncode(content), maxLength: 256) ==
          jsonEncode(content);

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    final definition = definitions.where((d) => d.name == action).firstOrNull;
    if (definition == null ||
        !definition.accepts(arguments) ||
        !_current ||
        !context.current ||
        context.domainRoot == null)
      return null;
    if (action == 'astoria_memory_draft_delete_receipts') {
      final offset = arguments['offset'] as int? ?? 0;
      return SupportAppPreparedAction(
        target: 'native-retained-memory-draft-removal-receipts',
        observation: Object(),
        observationIsCurrent: () => _current && context.current,
        execute: (current) async {
          if (!current() || !_current)
            return SupportAppActionOutcome(SupportAppActionCode.stale);
          final ids = _receipts.entries
              .where(
                (e) => e.value.parent == context.sessionId && e.value.current(),
              )
              .map((e) => e.key)
              .toList();
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            data: {
              'records': [
                for (final id in ids.skip(offset).take(16))
                  {'receipt': id, 'conditional': true},
              ],
              'count': ids.length,
              'nextOffset': offset + 16 < ids.length ? offset + 16 : null,
            },
          );
        },
      );
    }
    final session = targetSession(action, arguments, context);
    if (session == null || session == context.sessionId) return null;
    final undo = action == 'astoria_memory_draft_delete_undo';
    if (!undo && !_hasReceiptRoom()) return null;
    final saved = undo ? _receipts[arguments['receipt']] : null;
    final owner = owners.existing(session, originContainer: originContainer),
        chat = sources.owners.existing(session);
    if (owner == null ||
        chat == null ||
        owner.characterId != chat.characterId ||
        !owner.queue.idle ||
        (undo && (saved == null || !identical(saved.owner, owner))))
      return null;
    final memoryRevision = owners.revision,
        chatRevision = sources.owners.revision;
    final nativeLifetime = owner.captureNativeGuard(),
        policyCurrent = captureMetadataGuard();
    final queueRevision = owner.queue.revision;
    final checkpoint = sources.mutations.sessionCheckpoint(session);
    final id = undo ? saved!.receipt.draft.id : arguments['draftId']! as String;
    bool ownerCurrent() =>
        _current &&
        policyCurrent() &&
        nativeLifetime() &&
        identical(owner.originContainer, originContainer) &&
        owners.revision == memoryRevision &&
        sources.owners.revision == chatRevision &&
        owner.current &&
        identical(
          owners.existing(session, originContainer: originContainer),
          owner,
        ) &&
        sources.owners.retains(chat, session);
    bool readCurrent() =>
        ownerCurrent() &&
        context.current &&
        owner.queue.idle &&
        owner.queue.revision == queueRevision &&
        checkpoint != null &&
        !sources.mutations.isSessionPending(session) &&
        identical(sources.mutations.sessionCheckpoint(session), checkpoint) &&
        (!undo || saved!.current());
    final removed = undo
        ? null
        : await owner.observeDraftRemoval(id, readCurrent);
    if (!readCurrent() || (!undo && removed == null)) return null;
    final absence = undo
        ? await owner.observeDraftRemovalUndo(saved!.receipt, readCurrent)
        : null;
    if (!readCurrent() || (undo && absence == null)) return null;
    final draft = undo ? saved!.receipt.draft : removed!.draft;
    final Object observed = undo ? absence! : removed!;
    bool safe() => policyCurrent() && _safe(session, id, draft.content);
    if (!safe()) return null;
    final target = undo ? arguments['receipt']! as String : '$session/$id';
    return SupportAppPreparedAction(
      target: target,
      observation: observed,
      observationIsCurrent: () =>
          readCurrent() &&
          safe() &&
          (undo ? absence!.current : removed!.current && _hasReceiptRoom()),
      preview: {
        'operation': undo
            ? 'conditionalMemoryDraftRemovalUndo'
            : 'deleteMemoryDraft',
        'contentJson': jsonEncode(draft.content),
        'affectedRecords': 1,
        'delete': !undo,
        'restoreExactRawObjectAndOrder': undo,
        'status': 'pending_approval',
        'vectorEnabled': false,
        'preservesOtherRawTokensEntriesSettingsAndCursors': true,
        'indexing': 'notDispatched',
        'conditional': true,
        'sourceAuthorityRetirement': true,
      },
      execute: (admitted) async {
        final operation = undo
            ? SupportAppDomainOperation.memoryDraftDeleteUndo
            : SupportAppDomainOperation.memoryDraftDelete;
        final event = sources.mutations.sessionCheckpoint(session);
        final publication = context.domainPublication(session);
        bool current() =>
            admitted() &&
            ownerCurrent() &&
            safe() &&
            publication != null &&
            chat.queue.isCurrentPublication(publication) &&
            context.domainEffectForSession(session) &&
            context.domainEffectForOperation(operation) &&
            context.domainEffectMatches(target, observed) &&
            identical(sources.mutations.sessionCheckpoint(session), event);
        if (!current())
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        final reservedSlot = !undo && _reserveReceiptSlot();
        if (!undo && !reservedSlot)
          return SupportAppActionOutcome(SupportAppActionCode.unavailable);
        try {
          if (undo) {
            final restored = await owner.undoDraftRemoval(
              receipt: saved!.receipt,
              observed: absence!,
              queueRevision: queueRevision,
              support: support,
              parentSession: context.sessionId,
              sourceCurrent: current,
            );
            if (restored == null)
              return SupportAppActionOutcome(SupportAppActionCode.conflict);
            _receipts.remove(arguments['receipt']);
            return SupportAppActionOutcome(
              SupportAppActionCode.completed,
              effect: SupportAppActionEffect.persisted,
              data: {
                'outcome': 'undone',
                'affectedRecords': 1,
                'refreshPending':
                    !current() ||
                    !restored.current ||
                    !owner.current ||
                    owner.cachedDraft(id) != restored.draft,
              },
            );
          }
          final receipt = await owner.removeDraft(
            observed: removed!,
            queueRevision: queueRevision,
            support: support,
            parentSession: context.sessionId,
            operationId: supportRepairOpaqueId('memory-draft-delete-op'),
            sourceCurrent: current,
          );
          if (receipt == null)
            return SupportAppActionOutcome(SupportAppActionCode.conflict);
          String? handle;
          if (!_disposed && current() && receipt.current) {
            final removedBook = owner.readBook();
            final retained = _RetainedMemoryDraftRemoval(
              context.sessionId,
              owner,
              receipt,
              () =>
                  ownerCurrent() &&
                  safe() &&
                  owner.queue.idle &&
                  owner.queue.revision == queueRevision + 2 &&
                  identical(owner.readBook(), removedBook) &&
                  removedBook != null &&
                  !removedBook.pendingDrafts.any((d) => d.id == id) &&
                  chat.queue.isCurrentPublication(publication!) &&
                  identical(
                    sources.mutations.sessionCheckpoint(session),
                    event,
                  ),
            );
            if (retained.current()) {
              handle = supportRepairOpaqueId('repair');
              _receipts[handle] = retained;
            }
          }
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            effect: SupportAppActionEffect.persisted,
            data: {
              'outcome': 'applied',
              'affectedRecords': 1,
              if (handle != null) 'receipt': handle,
              'refreshPending':
                  !current() ||
                  !receipt.current ||
                  !owner.current ||
                  owner.readBook()?.pendingDrafts.any((d) => d.id == id) !=
                      false,
            },
          );
        } on MemoryNativeDraftStorageException {
          return SupportAppActionOutcome(
            SupportAppActionCode.storageUncertain,
            effect: SupportAppActionEffect.uncertain,
          );
        } finally {
          if (reservedSlot) _reservedReceiptSlots--;
        }
      },
    );
  }
}
