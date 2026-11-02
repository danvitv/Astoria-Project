import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/db/repositories/memory_book_repo.dart';
import '../../../../../core/db/repositories/support_repo.dart';
import '../../../../memory/state/memory_native_entry_owner.dart';
import '../../../models/support_app_action.dart';
import '../support_app_repair_runtime.dart';
import 'support_native_domain_sources.dart';

final class _RetainedMemoryEntry {
  _RetainedMemoryEntry(this.parent, this.owner, this.receipt, this._current);
  final String parent;
  final MemoryNativeEntryOwner owner;
  final MemoryNativeEntryReceipt receipt;
  final bool Function() _current;
  bool _retired = false;
  bool current() {
    if (_retired) return false;
    try {
      if (!receipt.current || !_current()) _retired = true;
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }
}

/// Exact content only; the ordinary editor's auto-index path is NOT called.
final class SupportNativeMemoryEntryAdapter implements SupportAppActionAdapter {
  SupportNativeMemoryEntryAdapter({
    required this.support,
    required this.sources,
    required this.owners,
    required this.originContainer,
  });
  final SupportRepo support;
  final SupportNativeDomainSources sources;
  final MemoryNativeEntryOwnerRegistry owners;
  final ProviderContainer originContainer;
  final _receipts = <String, _RetainedMemoryEntry>{};
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _receipts.clear();
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
      name: 'astoria_memory_entry_text_revise',
      description:
          'Revise only the content of one exact approved entry in an '
          'already-loaded idle original Memory tab. Native preview confirms exact '
          'before/after text and append-only history. Vector-enabled targets refuse '
          'until original index invalidation is supported. No generation or network.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'sessionId': const SupportAppActionField.text(128),
        'entryId': const SupportAppActionField.text(128),
        'content': const SupportAppActionField.bodyText(8192),
      },
      requiredFields: {'sessionId', 'entryId', 'content'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_entry_text_receipts',
      description:
          'List genuine retained original Memory text receipts in this '
          'Astoria parent only. Conditional Undo requires fresh native confirmation.',
      risk: SupportAppActionRisk.metadata,
      fields: {'offset': const SupportAppActionField.integer(0, 63)},
    ),
    SupportAppActionDefinition(
      name: 'astoria_memory_entry_text_undo',
      description:
          'Undo only a genuine retained original Memory text receipt '
          'after fresh exact native confirmation, appending a NEW revision. '
          'Guessed IDs/imported JSON and stale original owners grant no authority.',
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
    if (action == 'astoria_memory_entry_text_revise')
      return arguments['sessionId'] as String?;
    if (action != 'astoria_memory_entry_text_undo' || !context.current)
      return null;
    final saved = _receipts[arguments['receipt']];
    return saved != null && saved.parent == context.sessionId && saved.current()
        ? saved.receipt.sessionId
        : null;
  }

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    if (!_current || !context.current || context.domainRoot == null)
      return null;
    if (action == 'astoria_memory_entry_text_receipts') {
      final ids = _receipts.entries
          .where(
            (e) => e.value.parent == context.sessionId && e.value.current(),
          )
          .map((e) => e.key)
          .toList();
      final offset = arguments['offset'] as int? ?? 0;
      return SupportAppPreparedAction(
        target: 'native-retained-memory-text-receipts',
        observation: Object(),
        observationIsCurrent: () => _current && context.current,
        execute: (current) async => SupportAppActionOutcome(
          current() && _current
              ? SupportAppActionCode.completed
              : SupportAppActionCode.stale,
          data: current() && _current
              ? {
                  'records': [
                    for (final id in ids.skip(offset).take(16))
                      {'receipt': id, 'conditional': true},
                  ],
                  'count': ids.length,
                  'nextOffset': offset + 16 < ids.length ? offset + 16 : null,
                }
              : const {},
        ),
      );
    }
    final session = targetSession(action, arguments, context);
    if (session == null || session == context.sessionId) return null;
    final undo = action == 'astoria_memory_entry_text_undo';
    if (!undo && action != 'astoria_memory_entry_text_revise') return null;
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
    final entryId = undo
        ? saved!.receipt.entryId
        : arguments['entryId']! as String;
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
    final observed = await owner.observe(entryId, readCurrent);
    if (!readCurrent() ||
        observed == null ||
        (undo && observed.entry != saved!.receipt.after))
      return null;
    // Leave one bounded append for genuine Undo; never offer a receipt whose
    // history budget is already exhausted by the apply itself.
    if (observed.entry.revisions.length >= (undo ? 32 : 31)) return null;
    final content = undo
        ? saved!.receipt.beforeContent
        : arguments['content']! as String;
    final target = undo ? arguments['receipt']! as String : '$session/$entryId';
    return SupportAppPreparedAction(
      target: target,
      observation: observed,
      observationIsCurrent: () => readCurrent() && observed.current,
      preview: {
        'operation': undo
            ? 'conditionalMemoryTextUndo'
            : 'reviseMemoryEntryText',
        // Exact JSON string literals preserve whitespace/newlines inside the
        // existing single-line metadata contract; its whole-string redaction
        // and size checks remain unchanged. No content is clipped or normalized.
        'beforeContentJson': jsonEncode(observed.entry.content),
        'afterContentJson': jsonEncode(content),
        'beforeRevision': observed.entry.activeRevisionId,
        'affectedRecords': 1,
        'contentOnly': true,
        'appendOnlyHistory': true,
        'preservesSourcesSettingsDraftsAndOtherEntries': true,
        'indexing': 'notDispatched',
        'vectorEnabled': false,
        'conditional': true,
        'sourceAuthorityRetirement': true,
      },
      execute: (admitted) async {
        final operation = undo
            ? SupportAppDomainOperation.memoryEntryTextUndo
            : SupportAppDomainOperation.memoryEntryText;
        final event = sources.mutations.sessionCheckpoint(session);
        final publication = context.domainPublication(session);
        bool current() =>
            admitted() &&
            ownerCurrent() &&
            publication != null &&
            chat.queue.isCurrentPublication(publication) &&
            context.domainEffectForSession(session) &&
            context.domainEffectForOperation(operation) &&
            context.domainEffectMatches(target, observed) &&
            identical(sources.mutations.sessionCheckpoint(session), event);
        if (!current())
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        if (observed.entry.content == content)
          return SupportAppActionOutcome(SupportAppActionCode.noChange);
        try {
          if (undo) {
            final restored = await owner.undo(
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
                'activeRevision': restored.activeRevisionId,
                'refreshPending':
                    !owner.current || owner.cached(entryId) != restored,
              },
            );
          }
          final receipt = await owner.revise(
            observed: observed,
            queueRevision: queueRevision,
            content: content,
            support: support,
            parentSession: context.sessionId,
            operationId: supportRepairOpaqueId('memory-text-op'),
            sourceCurrent: current,
          );
          if (receipt == null)
            return SupportAppActionOutcome(SupportAppActionCode.conflict);
          String? handle;
          if (!_disposed) {
            handle = supportRepairOpaqueId('repair');
            while (_receipts.length >= 64) {
              _receipts.remove(_receipts.keys.first);
            }
            _receipts[handle] = _RetainedMemoryEntry(
              context.sessionId,
              owner,
              receipt,
              () =>
                  ownerCurrent() &&
                  owner.queue.idle &&
                  owner.queue.revision == queueRevision + 2 &&
                  owner.cached(entryId) == receipt.after &&
                  chat.queue.isCurrentPublication(publication!) &&
                  identical(
                    sources.mutations.sessionCheckpoint(session),
                    event,
                  ),
            );
          }
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            effect: SupportAppActionEffect.persisted,
            data: {
              'outcome': 'applied',
              'affectedRecords': 1,
              'activeRevision': receipt.after.activeRevisionId,
              if (handle != null) 'receipt': handle,
              'refreshPending':
                  !owner.current || owner.cached(entryId) != receipt.after,
            },
          );
        } on MemoryNativeEntryStorageException {
          return SupportAppActionOutcome(
            SupportAppActionCode.storageUncertain,
            effect: SupportAppActionEffect.uncertain,
          );
        }
      },
    );
  }
}
