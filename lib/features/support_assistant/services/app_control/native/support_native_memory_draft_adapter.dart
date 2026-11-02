import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/db/repositories/memory_book_repo.dart';
import '../../../../../core/db/repositories/support_repo.dart';
import '../../../../memory/state/memory_native_entry_owner.dart';
import '../../../models/support_app_action.dart';
import '../support_app_repair_runtime.dart';
import 'support_native_domain_sources.dart';

final class _RetainedMemoryDraftText {
  _RetainedMemoryDraftText(
    this.parent,
    this.owner,
    this.receipt,
    this._current,
  );
  final String parent;
  final MemoryNativeEntryOwner owner;
  final MemoryNativeDraftReceipt receipt;
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

/// One pending-approval draft's exact content. Drafts have NO entry revisions;
/// the encrypted joint journal and retained original receipt own conditional Undo.
final class SupportNativeMemoryDraftAdapter implements SupportAppActionAdapter {
  SupportNativeMemoryDraftAdapter({
    required this.support,
    required this.sources,
    required this.owners,
    required this.originContainer,
    required this.metadata,
  });
  final SupportRepo support;
  final SupportNativeDomainSources sources;
  final MemoryNativeEntryOwnerRegistry owners;
  final ProviderContainer originContainer;
  final SupportAppMetadataPolicy metadata;
  final _receipts = <String, _RetainedMemoryDraftText>{};
  int _reservedReceiptSlots = 0;
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _receipts.clear();
  }

  bool _hasReceiptRoom() {
    if (_disposed) return false;
    // Only retired genuine authority may be pruned. Never evict live Undo.
    _receipts.removeWhere((_, saved) => !saved.current());
    return _receipts.length + _reservedReceiptSlots < 64;
  }

  bool _reserveReceiptSlot() {
    // No await between availability and reservation: simultaneous prepared
    // actions cannot both spend the final slot. Cancellation reserves nothing.
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
      name: 'astoria_memory_draft_text_edit',
      description:
          'Edit only exact content of ONE existing pending_approval draft '
          'in the already-loaded selected idle original Memory tab. First discover '
          'the exact draftId with astoria_memory_inspect view=drafts. '
          'Native confirmation shows exact before/after JSON string literals. '
          'No approval, generation, entry history, embedding or network dispatch. '
          'Vector-enabled targets refuse; all draft metadata remains unchanged.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'sessionId': const SupportAppActionField.text(128),
        'draftId': const SupportAppActionField.text(128),
        'content': const SupportAppActionField.bodyText(8192),
      },
      requiredFields: {'sessionId', 'draftId', 'content'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_draft_text_receipts',
      description:
          'List only genuine retained original draft-text receipts in '
          'this Astoria parent. Metadata only; fresh confirmation is required for Undo.',
      risk: SupportAppActionRisk.metadata,
      fields: {'offset': const SupportAppActionField.integer(0, 63)},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_draft_text_undo',
      description:
          'Restore ONLY draft content from a genuine retained original '
          'receipt after fresh exact native confirmation and current conflict checks. '
          'Guessed IDs, journal JSON and stale owners grant no authority.',
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
    if (action == 'astoria_memory_draft_text_edit') {
      return arguments['sessionId'] as String?;
    }
    if (action != 'astoria_memory_draft_text_undo' || !context.current)
      return null;
    final saved = _receipts[arguments['receipt']];
    return saved != null && saved.parent == context.sessionId && saved.current()
        ? saved.receipt.sessionId
        : null;
  }

  bool _safe(String session, String draft, String before, String after) =>
      metadata is SupportAppBodyMetadataPolicy &&
      (metadata as SupportAppBodyMetadataPolicy).exactBodyText(
            before,
            maxLength: 8192,
          ) ==
          before &&
      (metadata as SupportAppBodyMetadataPolicy).exactBodyText(
            after,
            maxLength: 8192,
          ) ==
          after &&
      metadata.exactText(session, maxLength: 128) == session &&
      metadata.exactText(draft, maxLength: 128) == draft &&
      metadata.exactText(jsonEncode(before), maxLength: 256) ==
          jsonEncode(before) &&
      metadata.exactText(jsonEncode(after), maxLength: 256) ==
          jsonEncode(after);

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
    if (action == 'astoria_memory_draft_text_receipts') {
      final offset = arguments['offset'] as int? ?? 0;
      return SupportAppPreparedAction(
        target: 'native-retained-memory-draft-text-receipts',
        observation: Object(),
        observationIsCurrent: () => _current && context.current,
        execute: (current) async {
          if (!current() || !_current) {
            return SupportAppActionOutcome(SupportAppActionCode.stale);
          }
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
    final undo = action == 'astoria_memory_draft_text_undo';
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
    final nativeLifetime = owner.captureNativeGuard();
    final queueRevision = owner.queue.revision;
    final checkpoint = sources.mutations.sessionCheckpoint(session);
    final id = undo ? saved!.receipt.draftId : arguments['draftId']! as String;
    bool ownerCurrent() =>
        _current &&
        identical(owner.originContainer, originContainer) &&
        nativeLifetime() &&
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
    final observed = await owner.observeDraft(id, readCurrent);
    if (!readCurrent() ||
        observed == null ||
        (undo && observed.draft != saved!.receipt.after))
      return null;
    final content = undo
        ? saved!.receipt.beforeContent
        : arguments['content']! as String;
    bool safe() => _safe(session, id, observed.draft.content, content);
    if (!safe()) return null;
    final target = undo ? arguments['receipt']! as String : '$session/$id';
    return SupportAppPreparedAction(
      target: target,
      observation: observed,
      observationIsCurrent: () =>
          readCurrent() &&
          observed.current &&
          safe() &&
          (undo || _hasReceiptRoom()),
      preview: {
        'operation': undo
            ? 'conditionalMemoryDraftTextUndo'
            : 'editMemoryDraftText',
        'beforeContentJson': jsonEncode(observed.draft.content),
        'afterContentJson': jsonEncode(content),
        'affectedRecords': 1,
        'contentOnly': true,
        'status': 'pending_approval',
        'preservesDraftMetadataEntriesSettingsAndCursors': true,
        'appendOnlyEntryHistory': false,
        'indexing': 'notDispatched',
        'vectorEnabled': false,
        'conditional': true,
        'sourceAuthorityRetirement': true,
      },
      execute: (admitted) async {
        final operation = undo
            ? SupportAppDomainOperation.memoryDraftTextUndo
            : SupportAppDomainOperation.memoryDraftText;
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
        if (observed.draft.content == content) {
          return SupportAppActionOutcome(SupportAppActionCode.noChange);
        }
        final reservedSlot = !undo && _reserveReceiptSlot();
        if (!undo && !reservedSlot) {
          return SupportAppActionOutcome(SupportAppActionCode.unavailable);
        }
        try {
          if (undo) {
            final restored = await owner.undoDraftText(
              receipt: saved!.receipt,
              observed: observed,
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
                    !owner.current ||
                    owner.cachedDraft(id) != restored.after ||
                    !restored.current,
              },
            );
          }
          final receipt = await owner.reviseDraftText(
            observed: observed,
            queueRevision: queueRevision,
            content: content,
            support: support,
            parentSession: context.sessionId,
            operationId: supportRepairOpaqueId('memory-draft-text-op'),
            sourceCurrent: current,
          );
          if (receipt == null)
            return SupportAppActionOutcome(SupportAppActionCode.conflict);
          String? handle;
          if (!_disposed && current() && receipt.current) {
            final retained = _RetainedMemoryDraftText(
              context.sessionId,
              owner,
              receipt,
              () =>
                  ownerCurrent() &&
                  safe() &&
                  owner.queue.idle &&
                  owner.queue.revision == queueRevision + 2 &&
                  owner.cachedDraft(id) == receipt.after &&
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
                  !owner.current ||
                  owner.cachedDraft(id) != receipt.after ||
                  !receipt.current,
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
