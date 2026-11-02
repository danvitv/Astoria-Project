import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../../../core/db/repositories/manual_rewrite_job_repo.dart';
import '../../../../../core/db/repositories/support_repo.dart';
import '../../../../card_rewrite/rewrite_native_owner.dart';
import '../../../models/support_app_action.dart';
import '../support_app_repair_runtime.dart';
import 'support_native_domain_sources.dart';

final class _RetainedRewriteReject {
  _RetainedRewriteReject(
    this.parent,
    this.owner,
    this.commit,
    this._nativeCurrent,
  );
  final String parent;
  final RewriteNativeReviewOwner owner;
  final RewriteNativeRejectCommit commit;
  final bool Function() _nativeCurrent;
  bool _retired = false;
  bool current() {
    if (!_retired) {
      try {
        if (!commit.current || !_nativeCurrent()) _retired = true;
      } catch (_) {
        _retired = true;
      }
    }
    return !_retired;
  }
}

/// ONE existing pending review decision. No canon apply, approval, job close,
/// snapshot/body access, generation, provider work or reconstructed Undo.
final class SupportNativeRewriteRejectAdapter
    implements SupportAppActionAdapter {
  SupportNativeRewriteRejectAdapter({
    required this.support,
    required this.sources,
    required this.owners,
    required this.originContainer,
    required this.metadata,
    required this.captureMetadataGuard,
  });
  final SupportRepo support;
  final SupportNativeDomainSources sources;
  final RewriteNativeReviewOwnerRegistry owners;
  final ProviderContainer originContainer;
  final SupportAppMetadataPolicy metadata;
  final bool Function() Function() captureMetadataGuard;
  final _receipts = <String, _RetainedRewriteReject>{};
  int _reservedSlots = 0;
  bool _disposed = false;
  bool get _current =>
      !_disposed &&
      owners.current &&
      sources.isOriginalOwnerCurrent() &&
      sources.owners.isCurrent &&
      !sources.mutations.isDisposed;
  void dispose() {
    _disposed = true;
    _receipts.clear();
  }

  bool _room() {
    if (!_current) return false;
    _receipts.removeWhere((_, saved) => !saved.current());
    return _receipts.length + _reservedSlots < 64;
  }

  bool _reserve() {
    if (!_room()) return false;
    _reservedSlots++; // synchronous PRE-effect, including all in-flight slots
    return true;
  }

  static const _identifier = r'^[A-Za-z0-9][A-Za-z0-9_.:-]{0,127}$';
  @override
  List<SupportAppActionDefinition> get definitions =>
      !_current || owners.loaded(originContainer).isEmpty
      ? const []
      : [
          SupportAppActionDefinition(
            name: 'astoria_rewrite_reject',
            description:
                'Reject ONE existing reviewable PENDING decision in the '
                'already-loaded explicitly selected original manual Rewrite Review. '
                'Discover only native loaded metadata via astoria_rewrite_review_receipts '
                'operation=discover. Exact native confirmation binds job/version/operation/'
                'revision. No approval, close, edit, apply, canon, generation or provider work.',
            risk: SupportAppActionRisk.destructive,
            fields: {
              'jobId': const SupportAppActionField.text(
                128,
                pattern: _identifier,
              ),
              'operationId': const SupportAppActionField.text(
                128,
                pattern: _identifier,
              ),
            },
            requiredFields: {'jobId', 'operationId'},
          ),
          SupportAppActionDefinition(
            name: 'astoria_rewrite_review_receipts',
            description:
                'operation=discover returns metadata ONLY for an ALREADY '
                'loaded explicit original review selection, never fallback-first, model '
                'selection or a fabricated source ID. operation=receipts lists ONLY '
                'genuine retained local rejection receipts in this Astoria parent. '
                'Neither operation reads private snapshots, evidence or model text.',
            risk: SupportAppActionRisk.metadata,
            fields: {
              'operation': SupportAppActionField.choice([
                'discover',
                'receipts',
              ]),
              'jobId': const SupportAppActionField.text(
                128,
                pattern: _identifier,
              ),
              'operationId': const SupportAppActionField.text(
                128,
                pattern: _identifier,
              ),
              'offset': const SupportAppActionField.integer(0, 63),
            },
            requiredFields: {'operation'},
          ),
          SupportAppActionDefinition(
            name: 'astoria_rewrite_reject_undo',
            description:
                'Restore ONLY the exact prior pending decision and its prior '
                'decisionRevision from a genuine retained ORIGINAL rejection receipt, '
                'with fresh native confirmation and unchanged job/version/operation/'
                'revision/status/applied markers. Job version remains monotonic. '
                'No approval, edit/revalidation, journal JSON replay or latest-version adoption.',
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
    Map<String, Object?> args,
    SupportAppActionContext context,
  ) {
    if (!_current || !context.current) return null;
    final owner = action == 'astoria_rewrite_reject'
        ? owners.existing(args['jobId'] as String, originContainer)
        : action == 'astoria_rewrite_reject_undo'
        ? _receipts[args['receipt']]?.owner
        : null;
    final saved = action == 'astoria_rewrite_reject_undo'
        ? _receipts[args['receipt']]
        : null;
    if (owner == null ||
        !owner.current ||
        (saved != null &&
            (saved.parent != context.sessionId || !saved.current())))
      return null;
    return owner.readLoaded()?.job.chatSessionId;
  }

  bool _safe(Map<String, Object?> preview) {
    final text = jsonEncode(preview);
    return utf8.encode(text).length <= 256 &&
        metadata.exactText(text, maxLength: 256) == text &&
        ['job', 'operation'].every(
          (key) =>
              preview[key] is String &&
              metadata.exactText(preview[key] as String, maxLength: 128) ==
                  preview[key],
        );
  }

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> args,
    SupportAppActionContext context,
  ) async {
    final definition = definitions.where((d) => d.name == action).firstOrNull;
    if (definition == null ||
        !definition.accepts(args) ||
        !_current ||
        !context.current ||
        context.domainRoot == null)
      return null;
    if (action == 'astoria_rewrite_review_receipts')
      return _metadata(args, context);
    final undo = action == 'astoria_rewrite_reject_undo';
    if (!undo && !_room()) return null;
    final saved = undo ? _receipts[args['receipt']] : null;
    if (undo &&
        (saved == null ||
            saved.parent != context.sessionId ||
            !saved.current()))
      return null;
    final job = undo ? saved!.commit.receipt.jobId : args['jobId'] as String;
    final operationId = undo
        ? saved!.commit.receipt.operationId
        : args['operationId'] as String;
    final owner = owners.existing(job, originContainer);
    if (owner == null ||
        !owner.queue.idle ||
        owner.selected()?.operation.id != operationId ||
        (undo && !identical(saved!.owner, owner)))
      return null;
    final loaded = owner.readLoaded(), selected = owner.selected();
    final session = loaded?.job.chatSessionId;
    if (session == null || session == context.sessionId) return null;
    final chat = sources.owners.existing(session);
    if (chat == null || chat.characterId != owner.readLoaded()?.job.characterId)
      return null;
    final ownerRevision = owners.revision,
        chatRevision = sources.owners.revision;
    final queueRevision = owner.queue.revision;
    final selection = owner.captureNativeGuard(),
        policy = captureMetadataGuard();
    final checkpoint = sources.mutations.sessionCheckpoint(session);
    bool nativeCurrent() =>
        _current &&
        policy() &&
        selection() &&
        owners.revision == ownerRevision &&
        sources.owners.revision == chatRevision &&
        identical(owner.originContainer, originContainer) &&
        identical(owners.existing(job, originContainer), owner) &&
        sources.owners.retains(chat, session);
    bool readCurrent() =>
        nativeCurrent() &&
        context.current &&
        owner.queue.idle &&
        owner.queue.revision == queueRevision &&
        checkpoint != null &&
        identical(owner.readLoaded(), loaded) &&
        identical(owner.selected(), selected) &&
        !sources.mutations.isSessionPending(session) &&
        identical(sources.mutations.sessionCheckpoint(session), checkpoint) &&
        (!undo || saved!.current());
    if (!readCurrent()) return null;
    final rejected = undo
        ? null
        : await owner.observeReject(operationId, readCurrent);
    if (!readCurrent() || (!undo && rejected == null)) return null;
    final restored = undo
        ? await owner.observeUndo(saved!.commit, readCurrent)
        : null;
    if (!readCurrent() || (undo && restored == null)) return null;
    final version = undo
        ? saved!.commit.receipt.jobVersion
        : rejected!.jobVersion;
    final revision = undo ? saved!.commit.receipt.revision : rejected!.revision;
    final priorDecisionRevision = undo ? revision : rejected!.decisionRevision;
    final preview = <String, Object?>{
      'job': job,
      'operation': operationId,
      'version': version,
      'revision': revision,
      'decisionRevision': priorDecisionRevision,
      'from': undo ? 'rejected' : 'pending',
      'to': undo ? 'pending' : 'rejected',
      'nextDecisionRevision': undo
          ? saved!.commit.receipt.priorDecisionRevision
          : revision,
    };
    bool safe() => policy() && _safe(preview);
    if (!safe()) return null;
    final Object observed = undo ? restored! : rejected!;
    final target = undo ? args['receipt'] as String : operationId;
    return SupportAppPreparedAction(
      target: target,
      observation: observed,
      observationIsCurrent: () =>
          readCurrent() &&
          safe() &&
          (undo ? restored!.current : rejected!.current && _room()),
      preview: preview,
      execute: (admitted) async {
        final operation = undo
            ? SupportAppDomainOperation.rewriteRejectUndo
            : SupportAppDomainOperation.rewriteReject;
        final event = sources.mutations.sessionCheckpoint(session);
        final publication = context.domainPublication(session);
        bool current() =>
            admitted() &&
            nativeCurrent() &&
            safe() &&
            publication != null &&
            chat.queue.isCurrentPublication(publication) &&
            context.domainEffectForSession(session) &&
            context.domainEffectForOperation(operation) &&
            context.domainEffectMatches(target, observed) &&
            identical(sources.mutations.sessionCheckpoint(session), event);
        if (!current())
          return SupportAppActionOutcome(SupportAppActionCode.stale);
        final reserved = !undo && _reserve();
        if (!undo && !reserved)
          return SupportAppActionOutcome(SupportAppActionCode.unavailable);
        try {
          if (undo) {
            final result = await owner.undo(
              saved: saved!.commit,
              observed: restored!,
              queueRevision: queueRevision,
              support: support,
              parentSession: context.sessionId,
              sourceCurrent: current,
            );
            if (result == null)
              return SupportAppActionOutcome(SupportAppActionCode.conflict);
            _receipts.remove(args['receipt']);
            return SupportAppActionOutcome(
              SupportAppActionCode.completed,
              effect: SupportAppActionEffect.persisted,
              data: {
                'outcome': 'undone',
                'affectedRecords': 1,
                'jobVersion': result.commit.jobVersion,
                'refreshPending':
                    !current() ||
                    !result.current ||
                    owner.readLoaded()?.job != result.commit.nativeJob ||
                    owner.selected()?.operation !=
                        result.commit.nativeOperation,
              },
            );
          }
          final result = await owner.reject(
            observed: rejected!,
            queueRevision: queueRevision,
            support: support,
            parentSession: context.sessionId,
            journalId: supportRepairOpaqueId('rewrite-reject-op'),
            sourceCurrent: current,
          );
          if (result == null)
            return SupportAppActionOutcome(SupportAppActionCode.conflict);
          String? handle;
          final retained = _RetainedRewriteReject(
            context.sessionId,
            owner,
            result,
            () =>
                nativeCurrent() &&
                safe() &&
                publication != null &&
                chat.queue.isCurrentPublication(publication) &&
                identical(sources.mutations.sessionCheckpoint(session), event),
          );
          if (!_disposed && retained.current()) {
            handle = supportRepairOpaqueId('repair');
            _receipts[handle] = retained;
          }
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            effect: SupportAppActionEffect.persisted,
            data: {
              'outcome': 'applied',
              'affectedRecords': 1,
              'jobVersion': result.receipt.jobVersion,
              if (handle != null) 'receipt': handle,
              'refreshPending':
                  !current() ||
                  !result.current ||
                  owner.readLoaded()?.job != result.receipt.nativeJob ||
                  owner.selected()?.operation != result.receipt.nativeOperation,
            },
          );
        } on ManualRewriteNativeStorageException {
          return SupportAppActionOutcome(
            SupportAppActionCode.storageUncertain,
            effect: SupportAppActionEffect.uncertain,
          );
        } finally {
          if (reserved) _reservedSlots--;
        }
      },
    );
  }

  SupportAppPreparedAction? _metadata(
    Map<String, Object?> args,
    SupportAppActionContext context,
  ) {
    final receipts = args['operation'] == 'receipts';
    if (receipts &&
            (args.containsKey('jobId') || args.containsKey('operationId')) ||
        !receipts && args.containsKey('offset'))
      return null;
    final policy = captureMetadataGuard(), ownerRevision = owners.revision;
    final guards = <bool Function()>[];
    bool current() =>
        _current &&
        policy() &&
        context.current &&
        owners.revision == ownerRevision &&
        guards.every((guard) => guard());
    final records = <Map<String, Object?>>[];
    if (receipts) {
      for (final entry in _receipts.entries) {
        if (entry.value.parent == context.sessionId && entry.value.current()) {
          records.add({'receipt': entry.key, 'conditional': true});
          guards.add(entry.value.current);
        }
      }
    } else {
      for (final owner in owners.loaded(originContainer)) {
        final snap = owner.readLoaded(), selected = owner.selected();
        final native = owner.captureNativeGuard(),
            queueRevision = owner.queue.revision;
        if (!owner.queue.idle ||
            snap == null ||
            selected == null ||
            snap.job.status != 'pending' ||
            selected.operation.status != 'reviewable' ||
            selected.operation.appliedCharacterRevision != 0 ||
            (args['jobId'] != null && args['jobId'] != snap.job.id) ||
            (args['operationId'] != null &&
                args['operationId'] != selected.operation.id))
          continue;
        final preview = <String, Object?>{
          'job': snap.job.id,
          'operation': selected.operation.id,
          'version': snap.job.version,
          'revision': selected.operation.currentRevision,
          'decisionRevision': selected.operation.decisionRevision,
          'from': selected.operation.decision,
          'to': 'rejected',
        };
        if (!_safe(preview)) return null;
        records.add(preview);
        guards.add(
          () =>
              native() &&
              owner.queue.idle &&
              owner.queue.revision == queueRevision &&
              identical(owner.readLoaded(), snap) &&
              identical(owner.selected(), selected) &&
              _safe(preview),
        );
      }
    }
    if (!current() || records.length > 64) return null;
    final offset = args['offset'] as int? ?? 0;
    return SupportAppPreparedAction(
      target: 'native-rewrite-review-metadata',
      observation: Object(),
      observationIsCurrent: current,
      execute: (admitted) async => SupportAppActionOutcome(
        admitted() && current()
            ? SupportAppActionCode.completed
            : SupportAppActionCode.stale,
        data: admitted() && current()
            ? {
                'records': records.skip(offset).take(16).toList(),
                'count': records.length,
                'nextOffset': offset + 16 < records.length ? offset + 16 : null,
              }
            : const {},
      ),
    );
  }
}
