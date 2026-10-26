part of 'support_model_service.dart';

/// Private per-original-run adapter/custody. Handles are metadata references,
/// never source IDs, paths, repair handles, approvals or persisted rights.
final class _ModelSourceToolRun
    implements
        SupportAppActionAdapter,
        SupportAppSourceAccessPort,
        SupportAppSourceBodyResultPort {
  _ModelSourceToolRun(this.run, this.repo);
  final _ModelRun run;
  final SupportSourceTextRepo repo;
  final _handles = <String, SupportSourceCatalogEntry>{};
  final _approved = <_ModelApprovedSource>[];
  final _outcomes =
      Map<SupportAppActionOutcome, _ModelApprovedSource>.identity();
  SupportAppActionContext? _context;
  Uri? _destination;
  bool _closed = false;

  static const listAction = 'astoria_sources_list',
      readAction = 'astoria_source_read';
  static const maxHandles = 64;
  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: listAction,
      description:
          'List only source metadata: games newest activity first; Studio selected '
          'preset first, then newest activity. activeAtListing is selection metadata '
          'at discovery, not a historical prompt or permission. '
          'Use the returned opaque handle for an exact native source-read request.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'domain': SupportAppActionField.choice(const ['game', 'studioPreset']),
        'offset': const SupportAppActionField.integer(0, 4096),
      },
      requiredFields: const {'domain', 'offset'},
    ),
    SupportAppActionDefinition(
      name: readAction,
      description:
          'Request one exact native confirmation for local read AND disclosure '
          'to this model: at most 16 trailing ACTIVE game messages, or CURRENT SAVED '
          'Studio definition. Large Studio presets return one definitionChunk, not the '
          'whole preset; follow nextStudioPage with a fresh confirmation for each part. '
          'studioPage starts at 0 and must be 0 for games. '
          'No hidden variants, attachments or historical prompt.',
      risk: SupportAppActionRisk.bodyRead,
      fields: const {
        'opaqueHandle': SupportAppActionField.text(128),
        'activeMessageOffset': SupportAppActionField.integer(0, 2000),
        'studioPage': SupportAppActionField.integer(0, 255),
      },
      requiredFields: const {'opaqueHandle', 'activeMessageOffset'},
    ),
  ];

  void bindOriginalContext(SupportAppActionContext context, Uri destination) {
    if (_context != null ||
        !identical(context.sourceToolAccess, this) &&
            run.binding.toolUi?.confirmation != null) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    _context = context;
    _destination = destination;
  }

  bool get current => !_closed && run.current();
  bool original(SupportAppActionContext context) =>
      current &&
      identical(context, _context) &&
      identical(context.sourceToolAccess, this) &&
      context.current &&
      current;
  void check(SupportAppActionContext context) {
    run.operation.check();
    if (!original(context))
      throw const SupportAppActionRefused(SupportAppActionCode.stale);
  }

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    check(context);
    if (action == listAction) {
      return SupportAppPreparedAction(
        target: 'source-metadata',
        observation: this,
        observationIsCurrent: () => original(context),
        execute: (admitted) async {
          if (!admitted())
            throw const SupportAppActionRefused(SupportAppActionCode.stale);
          final domain = SupportSourceDomain.values.byName(
            arguments['domain'] as String,
          );
          run.toolActivity(
            SupportModelToolStage.executing,
            sourceLabel: domain == SupportSourceDomain.game
                ? 'Истории игр'
                : 'Сохранённые Studio-пресеты',
            detail:
                'Чтение только каталога; содержимое источников не передаётся',
          );
          check(context);
          final SupportSourceCatalogPage page;
          try {
            final activeReader = run.service._activeStudioPresetId;
            final active =
                domain == SupportSourceDomain.studioPreset &&
                    activeReader != null
                ? await activeReader()
                : null;
            check(context);
            if (!admitted())
              throw const SupportAppActionRefused(SupportAppActionCode.stale);
            page = await repo.catalog(
              domain: domain,
              offset: arguments['offset'] as int,
              activeStudioPresetId: active,
              isCurrent: () => original(context) && admitted(),
            );
          } on SupportSourceReadException catch (error) {
            run.refuseSourceTool(error);
            throw const SupportAppActionRefused(
              SupportAppActionCode.unavailable,
            );
          }
          check(context);
          if (_handles.length + page.entries.length > maxHandles) {
            throw const SupportAppActionRefused(
              SupportAppActionCode.unavailable,
            );
          }
          final entries = <Map<String, Object?>>[];
          for (final entry in page.entries) {
            final handle = run.service._newId();
            if (handle.length > 128 ||
                handle.isEmpty ||
                _handles.containsKey(handle) ||
                _ModelSourceMetadata(run).exactText(handle, maxLength: 128) !=
                    handle) {
              throw const SupportAppActionRefused(
                SupportAppActionCode.unsafeMetadata,
              );
            }
            _handles[handle] = entry;
            entries.add({
              'opaqueHandle': handle,
              'label': safeLabel(entry.label),
              'kind': domain.name,
              'updatedAt': entry.updatedAt,
              if (domain == SupportSourceDomain.studioPreset &&
                  page.activeStudioSourceId != null)
                'activeAtListing': entry.sourceId == page.activeStudioSourceId,
              if (entry.sessionIndex != null)
                'sessionIndex': entry.sessionIndex,
            });
          }
          return SupportAppActionOutcome(
            SupportAppActionCode.completed,
            data: {'entries': entries, 'nextOffset': page.nextOffset},
          );
        },
      );
    }
    if (action != readAction) return null;
    final handle = arguments['opaqueHandle'] as String;
    final entry = _handles[handle];
    if (entry == null)
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    run.toolActivity(
      SupportModelToolStage.preparing,
      sourceLabel:
          '${entry.domain == SupportSourceDomain.game ? 'История игры' : 'Studio-пресет'}: ${safeLabel(entry.label)}',
      detail:
          'Проверка выбранного источника и границ чтения; текст ещё не передаётся',
    );
    check(context);
    if (_approved.length >= SupportModelProvenanceLimits.maxToolDisclosures) {
      throw const SupportAppActionRefused(SupportAppActionCode.unavailable);
    }
    final SupportSourceObservation observation;
    try {
      observation = await repo.observe(
        entry: entry,
        activeMessageOffset: arguments['activeMessageOffset'] as int,
        studioPage: arguments['studioPage'] as int? ?? 0,
        isCurrent: () => original(context),
      );
    } on SupportSourceReadException catch (error) {
      run.refuseSourceTool(error);
      throw const SupportAppActionRefused(SupportAppActionCode.unavailable);
    }
    check(context);
    if (observation.studioIsPaged) {
      run.toolSourcePart = observation.studioPage + 1;
      run.toolActivity(
        SupportModelToolStage.preparing,
        sourceLabel: 'Studio-пресет: ${safeLabel(observation.label)}',
        detail:
            'Часть ${observation.studioPage + 1}; полный пресет проверяется '
            'локально, модели передаётся только эта часть',
      );
      check(context);
    }
    final recipient = run.binding.configuration.recipient;
    return SupportAppPreparedAction(
      target: handle,
      observation: observation,
      observationIsCurrent: () => original(context),
      preview: {
        'sourceLabel': safeLabel(observation.label),
        'kind': observation.domain.name,
        // Generic preview strings keep their original 256-character limit.
        // Full local-validation and part limits are rendered from bounded fields.
        'extent': observation.domain == SupportSourceDomain.game
            ? observation.extentDescription
            : observation.studioIsPaged
            ? 'CURRENT SAVED Studio: ONLY Part ${observation.studioPage + 1}; '
                  'studioPage ${observation.studioPage}. Deterministic Unicode scalar boundaries; '
                  'total parts known after local validation. One part is not the full preset.'
            : 'CURRENT SAVED Studio: complete saved definition (studioPage 0).',
        if (observation.domain == SupportSourceDomain.studioPreset) ...{
          'studioIsPaged': observation.studioIsPaged,
          'studioPage': observation.studioPage,
          'partCharacters': SupportSourceTextRepo.maxStudioPartCharacters,
          'partEscapedBytes':
              SupportSourceTextRepo.maxStudioPartDoubleJsonBytes,
        },
        'selectedCount': observation.orderedSourceIds.length,
        'activeMessageOffset': observation.activeMessageOffset,
        'orderedSourceIds': observation.orderedSourceIds,
        'storedTextBytes': observation.textBytes,
        'exclusions': observation.domain == SupportSourceDomain.game
            ? 'Hidden/failed/locked messages, inactive variants, attachments, prompts, cards, memory and trackers.'
            : 'Historical assembled prompts, old versions, runtime state; no proof of association with game answers.',
        'connection': safeLabel(recipient.connectionLabel),
        'protocol': safeLabel(recipient.protocolLabel),
        'routing': safeLabel(recipient.routingLabel),
        'origin': safeLabel(recipient.originLabel),
        'model': safeLabel(run.binding.configuration.settings.modelId!),
        'operation': switch (run.binding.configuration.api.protocol) {
          'gemini' => 'generateContent',
          'anthropic' => 'Messages',
          'openai_responses' => 'Responses',
          _ => 'Chat Completions',
        },
        'consent':
            'One local bounded read AND disclosure of the resulting text to this exact selected model for this request only.',
      },
      execute: (admitted) =>
          _read(context, observation, arguments, handle, admitted),
    );
  }

  String safeLabel(String value) => _safeText(
    run.service._redaction.redactor,
    value,
    256,
  ).replaceAll(RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\ufeff]'), ' ');

  Future<SupportAppActionOutcome> _read(
    SupportAppActionContext context,
    SupportSourceObservation observation,
    Map<String, Object?> arguments,
    String handle,
    bool Function() admitted,
  ) async {
    try {
      return await _readApproved(
        context,
        observation,
        arguments,
        handle,
        admitted,
      );
    } on SupportSourceReadException catch (error) {
      run.refuseSourceTool(error);
      throw const SupportAppActionRefused(SupportAppActionCode.unavailable);
    } on SupportTextContextException {
      throw const SupportAppActionRefused(SupportAppActionCode.stale);
    } on SupportModelProvenanceException {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    } on NativeToolException {
      // Exact FULL native result overflow happens before the provenance CAS.
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
  }

  Future<SupportAppActionOutcome> _readApproved(
    SupportAppActionContext context,
    SupportSourceObservation observation,
    Map<String, Object?> arguments,
    String handle,
    bool Function() admitted,
  ) async {
    check(context);
    final lease = context.sourceReadConfirmation(observation);
    if (lease == null ||
        lease.request.target != handle ||
        SupportModelToolPayloads.argumentsKey(lease.request.arguments) !=
            SupportModelToolPayloads.argumentsKey(arguments) ||
        !admitted()) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    final authority = _ModelSourceAuthority(
      this,
      observation,
      lease,
      _destination!,
    );
    run.toolActivity(
      SupportModelToolStage.executing,
      detail: observation.studioIsPaged
          ? 'Чтение одобренной части ${observation.studioPage + 1} Studio-пресета'
          : 'Чтение одобренного текста для этого запроса',
    );
    check(context);
    // This future is joined, never abandoned on cancellation. Body SQL/crypto and
    // native confirmation stay OUTSIDE the original model read-only ROOT.
    final snapshot = await repo.read(
      observation: observation,
      authority: authority,
    );
    check(context);
    final json = await repo.toolResult(
      snapshot: snapshot,
      authority: authority,
    );
    check(context);
    final outcome = SupportAppActionOutcome(
      SupportAppActionCode.completed,
      data: {'sourceText': json},
    );
    // Validate the FULL actual result before any provenance append. Body strings
    // stay a bounded encoded data payload, not generic relaxed metadata JSON.
    final native = NativeToolResult(
      callId: lease.request.callId,
      name: readAction,
      content: {
        'ok': true,
        'code': outcome.code.name,
        'effect': 'none',
        'data': outcome.data,
      },
    );
    final approved = _ModelApprovedSource(authority, snapshot, json, native);
    _approved.add(approved);
    if (!await run.admitOriginalRoot(
      capsuleCurrent: () => authority.isCurrent,
      dispatch: () {},
    )) {
      throw const SupportAppActionRefused(SupportAppActionCode.stale);
    }
    check(context);
    final old = run.context!.recipe;
    final disclosure = SupportModelToolDisclosure(
      domain: SupportModelToolDisclosureDomain.values.byName(
        snapshot.domain.name,
      ),
      sourceId: snapshot.sourceId,
      // Provenance v4 identifies a Studio source with exactly its preset ID.
      // Each part has its own private digest (full raw source + chosen extent),
      // never a persisted read grant or a claim that one part was the whole preset.
      orderedSourceIds: snapshot.domain == SupportSourceDomain.studioPreset
          ? [snapshot.sourceId]
          : snapshot.orderedSourceIds,
      snapshotDigest: snapshot.snapshotDigestForEncryptedProvenance,
    );
    final prior = old.toolDisclosures ?? const <SupportModelToolDisclosure>[];
    final same = prior.any(
      (d) =>
          d.domain == disclosure.domain &&
          d.sourceId == disclosure.sourceId &&
          d.snapshotDigest == disclosure.snapshotDigest,
    );
    if (same &&
        prior.any(
          (d) =>
              d.domain == disclosure.domain &&
              d.sourceId == disclosure.sourceId &&
              d.snapshotDigest == disclosure.snapshotDigest &&
              !_sameConversationIds(
                d.orderedSourceIds,
                disclosure.orderedSourceIds,
              ),
        )) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    if (!same) {
      final next = SupportModelProvenance(
        supportSessionId: old.supportSessionId,
        replyMessageId: old.replyMessageId,
        runId: old.runId,
        currentUserMessageId: old.currentUserMessageId,
        originalRanges: old.originalRanges,
        directReplies: old.directReplies,
        currentConversationMessageIds: old.currentConversationMessageIds,
        compactedThroughMessageId: old.compactedThroughMessageId,
        toolDisclosures: [...prior, disclosure],
      );
      _checkRecipeIdentifiers(run.service._redaction.redactor, next);
      final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(
        next,
      );
      final refreshed = await run.service._writes.enqueue(() async {
        check(context);
        if (!authority.isCurrent)
          throw const SupportAppActionRefused(SupportAppActionCode.stale);
        final pending = await run.service._writer.readReplyForSourceExtension(
          expected: run.expected!,
          originatingUser: run.durableUser!,
          isCurrent: () => original(context) && authority.isCurrent,
        );
        check(context);
        if (pending == null)
          throw const SupportAppActionRefused(SupportAppActionCode.conflict);
        final written = await run.service._writer.extendReplySources(
          expected: pending,
          provenanceJson: encoded,
          isCurrent: () => original(context) && authority.isCurrent,
        );
        if (written == null)
          throw const SupportAppActionRefused(SupportAppActionCode.conflict);
        // Settlement must retain OUR actual durable reservation even if Stop
        // retired publication during the transaction's release.
        run.expected = written;
        return written;
      });
      check(context);
      if (refreshed.provenance.protectedFactsJson != encoded) {
        throw const SupportAppActionRefused(SupportAppActionCode.conflict);
      }
      final originals = run.snapshots;
      final fresh = await run.history.refreshAfterOwnSourceExtension(
        snapshots: originals,
        checkpoint: () {
          check(context);
        },
      );
      check(context);
      run.snapshots = fresh;
      run.context = _ModelContextPlan(
        fresh.take(run.context!.snapshots.length),
        run.context!.custody,
        next,
      );
    }
    check(context);
    if (!authority.isCurrent)
      throw const SupportAppActionRefused(SupportAppActionCode.stale);
    _outcomes[outcome] = approved;
    return outcome;
  }

  @override
  bool acceptsSourceBodyOutcome(
    NativeToolCall call,
    SupportAppActionOutcome outcome,
  ) {
    final approved = _outcomes[outcome];
    return call.name == readAction &&
        current &&
        approved != null &&
        call.id == approved.native.callId &&
        SupportModelToolPayloads.argumentsKey(call.arguments) ==
            SupportModelToolPayloads.argumentsKey(
              approved.authority.lease.request.arguments,
            ) &&
        approved.authority.isCurrent &&
        outcome.code == SupportAppActionCode.completed &&
        outcome.effect == SupportAppActionEffect.none &&
        outcome.data.length == 1 &&
        outcome.data['sourceText'] == approved.json &&
        approved.native.content['data'] is Map;
  }

  Future<bool> revalidate(void Function() checkpoint) async {
    for (final approved in _approved) {
      checkpoint();
      if (!await repo.revalidate(
        snapshot: approved.snapshot,
        authority: approved.authority,
      ))
        return false;
      checkpoint();
    }
    return current;
  }

  @override
  Future<SupportAppSourceLease?> acquire({
    required String domain,
    required String sourceId,
    required Object observation,
    required SupportAppActionContext context,
  }) async => null;

  void close() {
    _closed = true;
    for (final item in _approved) {
      item.authority.release();
    }
    _handles.clear();
    _outcomes.clear();
    _approved.clear();
  }
}

final class _ModelSourceAuthority
    implements SupportSourceReadAuthority, SupportAppSourceLease {
  _ModelSourceAuthority(
    this.owner,
    this.observation,
    this.lease,
    this.destination,
  );
  final _ModelSourceToolRun owner;
  @override
  final SupportSourceObservation observation;
  final SupportAppConfirmationLease lease;
  final Uri destination;
  bool _retired = false;
  @override
  bool get isCurrent {
    if (_retired) return false;
    if (!owner.current ||
        !identical(lease.request.observation, observation) ||
        !identical(lease.request.context, owner._context) ||
        destination != owner._destination ||
        !lease.current ||
        !lease.request.current ||
        !owner.current) {
      _retired = true;
    }
    return !_retired;
  }

  @override
  void release() => _retired = true;
}

final class _ModelApprovedSource {
  const _ModelApprovedSource(
    this.authority,
    this.snapshot,
    this.json,
    this.native,
  );
  final _ModelSourceAuthority authority;
  final SupportSourceSnapshot snapshot;
  final String json;
  final NativeToolResult native;
}

final class _ModelSourceMetadata implements SupportAppMetadataPolicy {
  const _ModelSourceMetadata(this.run);
  final _ModelRun run;
  @override
  String? exactText(String value, {required int maxLength}) {
    try {
      if (!run.current() ||
          RegExp(r'[\x00-\x1f\x7f\u200b-\u200f\ufeff]').hasMatch(value))
        return null;
      return _safeText(run.service._redaction.redactor, value, maxLength);
    } catch (_) {
      return null;
    }
  }
}

extension _ModelSourceRootValidation on _ModelRun {
  Future<bool> sourceToolsRevalidate(void Function() checkpoint) async =>
      originalSourceTools == null ||
      await originalSourceTools!.revalidate(checkpoint);
}
