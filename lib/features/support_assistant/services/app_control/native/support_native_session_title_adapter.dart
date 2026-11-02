import '../../../../../core/db/repositories/chat_repo.dart';
import '../../../../../core/db/repositories/support_repo.dart';
import '../../../../chat/state/chat_native_owner_registry.dart';
import '../../../models/support_app_action.dart';
import '../support_app_repair_runtime.dart';
import 'support_native_domain_sources.dart';

final class _RetainedTitle {
  _RetainedTitle(this.parent, this.owner, this.receipt, this._isCurrent);
  final String parent;
  final ChatNativeOwner owner;
  final ChatNativeTitleReceipt receipt;
  final bool Function() _isCurrent;
  bool _retired = false;
  bool current() {
    if (_retired) return false;
    try {
      if (!_isCurrent()) _retired = true;
    } catch (_) {
      _retired = true;
    }
    return !_retired;
  }
}

/// Only loaded roleplay-session title rename and genuine retained conditional
/// Undo. No ChatNotifier bootstrap, general metadata patch or diagnostic effect.
final class SupportNativeSessionTitleAdapter
    implements SupportAppActionAdapter {
  SupportNativeSessionTitleAdapter({
    required this.support,
    required this.sources,
  });
  final SupportRepo support;
  final SupportNativeDomainSources sources;
  final _receipts = <String, _RetainedTitle>{};
  bool _disposed = false;
  void dispose() {
    _disposed = true;
    _receipts.clear();
  }

  bool get _current =>
      !_disposed &&
      sources.isOriginalOwnerCurrent() &&
      sources.owners.isCurrent &&
      !sources.mutations.isDisposed;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: 'astoria_session_rename',
      description:
          'Rename only the exact already-loaded idle roleplay session. '
          'Native confirmation shows the exact before/after title; history and '
          'unrelated variables are preserved. Never creates or opens a chat.',
      risk: SupportAppActionRisk.configuration,
      fields: {
        'sessionId': const SupportAppActionField.text(128),
        'title': const SupportAppActionField.text(256),
      },
      requiredFields: {'sessionId', 'title'},
    ),
    SupportAppActionDefinition(
      name: 'astoria_session_title_receipts',
      description:
          'List only actual retained original title receipts in this '
          'Astoria parent. A later rename Undo still requires fresh native confirmation.',
      risk: SupportAppActionRisk.metadata,
      fields: {'offset': const SupportAppActionField.integer(0, 63)},
    ),
    SupportAppActionDefinition(
      name: 'astoria_session_rename_undo',
      description:
          'Conditionally undo one original retained session-title receipt '
          'after fresh exact native confirmation. Stale owners/sources and guessed '
          'or imported receipt JSON grant nothing.',
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
    if (action == 'astoria_session_rename')
      return arguments['sessionId'] as String?;
    if (action != 'astoria_session_rename_undo' || !context.current)
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
    if (action == 'astoria_session_title_receipts') {
      final ids = _receipts.entries
          .where(
            (e) => e.value.parent == context.sessionId && e.value.current(),
          )
          .map((e) => e.key)
          .toList();
      final offset = arguments['offset'] as int? ?? 0;
      return SupportAppPreparedAction(
        target: 'native-retained-title-receipts',
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
    final owner = sources.owners.existing(session);
    final titles = owner?.titles;
    final checkpoint = sources.mutations.sessionCheckpoint(session);
    final revision = sources.owners.revision;
    if (owner == null ||
        titles == null ||
        checkpoint == null ||
        sources.mutations.isSessionPending(session))
      return null;
    final undo = action == 'astoria_session_rename_undo';
    if (!undo && action != 'astoria_session_rename') return null;
    final saved = undo ? _receipts[arguments['receipt']] : null;
    if (undo && (saved == null || !identical(saved.owner, owner))) return null;
    bool ownerCurrent() =>
        _current &&
        sources.owners.revision == revision &&
        sources.owners.retains(owner, session) &&
        identical(sources.owners.existing(session), owner);
    bool readCurrent() =>
        ownerCurrent() &&
        context.current &&
        !sources.mutations.isSessionPending(session) &&
        identical(sources.mutations.sessionCheckpoint(session), checkpoint) &&
        (!undo || saved!.current());
    final observed = await owner.queue.run(
      () => titles.observe(session, readCurrent),
    );
    if (!readCurrent() ||
        observed == null ||
        observed.characterId != owner.characterId ||
        (undo &&
            (observed.kind != ChatNativeTitleKind.text ||
                observed.text != saved!.receipt.afterText)))
      return null;
    final target = undo ? arguments['receipt']! as String : session;
    final afterKind = undo
        ? saved!.receipt.beforeKind
        : ChatNativeTitleKind.text;
    final afterTitle = undo
        ? saved!.receipt.beforeText
        : arguments['title']! as String;
    return SupportAppPreparedAction(
      target: target,
      observation: observed,
      observationIsCurrent: readCurrent,
      preview: {
        'operation': undo ? 'conditionalTitleUndo' : 'renameSessionTitle',
        'beforeKind': observed.kind.name,
        'beforeTitle': observed.text,
        'afterKind': afterKind.name,
        'afterTitle': afterTitle,
        'affectedRecords': 1,
        'titleOnly': true,
        'conditional': true,
        'preservesVariablesAndHistory': true,
        'sourceAuthorityRetirement': true,
        'bodyAccess': 'notGranted',
      },
      execute: (admitted) async {
        final operation = undo
            ? SupportAppDomainOperation.sessionTitleUndo
            : SupportAppDomainOperation.sessionRename;
        final event = sources.mutations.sessionCheckpoint(session);
        final publication = context.domainPublication(session);
        bool effectCurrent() =>
            admitted() &&
            ownerCurrent() &&
            publication != null &&
            owner.queue.isCurrentPublication(publication) &&
            context.domainEffectForSession(session) &&
            context.domainEffectForOperation(operation) &&
            context.domainEffectMatches(target, observed) &&
            identical(sources.mutations.sessionCheckpoint(session), event);
        if (!effectCurrent())
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        try {
          if (undo) {
            final restored = await titles.undo(
              receipt: saved!.receipt,
              observed: observed,
              support: support,
              parentSession: context.sessionId,
              current: effectCurrent,
            );
            if (restored != true)
              return SupportAppActionOutcome(SupportAppActionCode.conflict);
            _receipts.remove(arguments['receipt']);
            return SupportAppActionOutcome(
              SupportAppActionCode.completed,
              effect: SupportAppActionEffect.persisted,
              data: const {'outcome': 'undone', 'affectedRecords': 1},
            );
          }
          if (observed.kind == afterKind && observed.text == afterTitle) {
            return SupportAppActionOutcome(SupportAppActionCode.noChange);
          }
          final receipt = await titles.rename(
            observed: observed,
            title: afterTitle!,
            support: support,
            parentSession: context.sessionId,
            operationId: supportRepairOpaqueId('title-op'),
            createdAt: DateTime.now().millisecondsSinceEpoch ~/ 1000,
            current: effectCurrent,
          );
          if (receipt == null)
            return SupportAppActionOutcome(SupportAppActionCode.conflict);
          if (_disposed) {
            return SupportAppActionOutcome(
              SupportAppActionCode.completed,
              effect: SupportAppActionEffect.persisted,
              data: const {
                'outcome': 'applied',
                'affectedRecords': 1,
                'refreshPending': true,
              },
            );
          }
          // Keep only this operation's event, never adopt a later observer's ABA.
          final handle = supportRepairOpaqueId('repair');
          while (_receipts.length >= 64) {
            _receipts.remove(_receipts.keys.first);
          }
          _receipts[handle] = _RetainedTitle(
            context.sessionId,
            owner,
            receipt,
            () =>
                ownerCurrent() &&
                owner.queue.isCurrentPublication(publication!) &&
                identical(sources.mutations.sessionCheckpoint(session), event),
          );
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            effect: SupportAppActionEffect.persisted,
            data: {
              'outcome': 'applied',
              'affectedRecords': 1,
              'receipt': handle,
            },
          );
        } on ChatNativeTitleStorageException {
          return SupportAppActionOutcome(
            SupportAppActionCode.storageUncertain,
            effect: SupportAppActionEffect.uncertain,
          );
        }
      },
    );
  }
}
