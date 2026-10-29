part of 'support_model_service.dart';

/// Trusted native plan, not a model selector or permission serialization.
final class _ModelSourceScopePlan {
  const _ModelSourceScopePlan(this.scope, this.label, this.extent);
  final nav.FrozenScope scope;
  final String label, extent;
}

/// Dirty-room integration of the independently implemented navigation engine.
/// The repository and callbacks retain this run's actual native DB. Only the
/// finite registry is model-visible; none of the native ports is a tool.
final class _ModelSourceToolRun
    implements
        SupportAppActionAdapter,
        SupportAppSourceAccessPort,
        SupportAppSourceBodyResultPort,
        SupportAppNativeSourceApprovalPort,
        nav.OwnerPort {
  _ModelSourceToolRun(
    this.run,
    this.repo, {
    required this.scopeForApproval,
    required this.acknowledgeOwnWrite,
    required this.releaseRepository,
  }) {
    projection = _ModelSourceProjection(this);
  }
  final _ModelRun run;
  final SupportSourceNavigationRepo repo;
  final Future<_ModelSourceScopePlan> Function(nav.SourceObservation)
  scopeForApproval;
  final Future<void> Function(nav.ProvenanceEntry, SupportReplySourceCommit)
  acknowledgeOwnWrite;
  final void Function() releaseRepository;
  late final nav.RunContext navigationRun;
  late final nav.SourceNavigationEngine engine;
  late final _ModelSourceProjection projection;
  final _outcomes =
      Map<SupportAppActionOutcome, _ModelNavigationOutcome>.identity();
  final _admitted = <nav.ProvenanceEntry>[];
  final _published = <nav.NavigationResult>[];
  final _discovered = <nav.SourceObservation>[];
  final _scopeSpent = Map<nav.NativeGrant, int>.identity();
  final _wireBounds = Map<nav.ProvenanceEntry, int>.identity();
  SupportAppActionContext? _context;
  NativeToolCall? _call;
  Uri? _destination;
  bool _closed = false;
  bool _bound = false;
  int _wireSpent = 0;

  @override
  List<SupportAppActionDefinition> get definitions => [
    SupportAppActionDefinition(
      name: SupportSourceToolNames.list,
      description:
          'Discover bounded source metadata. Names and text are not '
          'disclosed before native approval. Use returned run-local handles; '
          'ordinary and Studio presets are different namespaces.',
      risk: SupportAppActionRisk.metadata,
      fields: {
        'domain': SupportAppActionField.choice(
          nav.SourceDomain.values.map((d) => d.name).toList(),
        ),
        'parent': const SupportAppActionField.text(128),
        'cursor': const SupportAppActionField.text(128),
      },
      requiredFields: const {'domain'},
    ),
    SupportAppActionDefinition(
      name: SupportSourceToolNames.contents,
      description:
          'Obtain a bounded logical contents map within native-approved '
          'source scope. Follow issued section selectors and nextCursor. This '
          'does not mean the whole source was read.',
      risk: SupportAppActionRisk.bodyRead,
      fields: const {
        'source': SupportAppActionField.text(128),
        'section': SupportAppActionField.text(128),
        'cursor': SupportAppActionField.text(128),
      },
      requiredFields: const {'source'},
    ),
    SupportAppActionDefinition(
      name: SupportSourceToolNames.search,
      description:
          'Case-sensitive Unicode literal search in one approved scope. '
          'No regex, normalization or SQL syntax. Native literal limit is 256 '
          'UTF-16 units. Results are bounded excerpts with issued selectors; '
          'complete/partial/incompleteReason describe scan coverage, not all occurrences.',
      risk: SupportAppActionRisk.bodyRead,
      fields: const {
        'source': SupportAppActionField.text(128),
        'literal': SupportAppActionField.text(256),
        'section': SupportAppActionField.text(128),
        'cursor': SupportAppActionField.text(128),
      },
      requiredFields: const {'source', 'literal'},
    ),
    SupportAppActionDefinition(
      name: SupportSourceToolNames.read,
      description:
          'Read ONE issued logical record, native ACTIVE-message range '
          'or opaque text continuation. before/after add at most two ACTIVE '
          'neighbours inside the same frozen scope. Never load whole history or '
          'invent a raw ID, offset, path or JSON pointer. Partial text is not a full source.',
      risk: SupportAppActionRisk.bodyRead,
      fields: const {
        'source': SupportAppActionField.text(128),
        'selector': SupportAppActionField.text(128),
        'before': SupportAppActionField.integer(0, 2),
        'after': SupportAppActionField.integer(0, 2),
      },
      requiredFields: const {'source', 'selector'},
    ),
  ];

  void bindOriginalContext(SupportAppActionContext context, Uri destination) {
    if (_context != null ||
        !identical(
          context.sourceToolAccess,
          run.binding.toolUi?.confirmation == null ? null : this,
        )) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    _context = context;
    _destination = destination;
    final config = run.binding.configuration,
        recipient = config.recipient.recipient;
    navigationRun = nav.RunContext(
      run,
      run.runId,
      nav.Recipient(
        config.api.protocol,
        recipient.connectionId,
        config.api.protocol,
        config.settings.modelId ?? '',
        nativeRoute: destination.toString(),
        configurationRevision: recipient.configurationRevision,
      ),
    );
    engine = nav.SourceNavigationEngine(
      run: navigationRun,
      repository: repo,
      owner: this,
      approval: _ModelSourceApproval(this),
      projection: projection,
      provenance: _ModelSourceProvenance(this),
    );
    _bound = true;
  }

  bool get current => !_closed && run.current();
  // The exact immutable context owns this run even when native approval UI is
  // absent. Registry access and body approval remain separate, fail-closed gates.
  bool original(SupportAppActionContext context) =>
      current &&
      identical(context, _context) &&
      identical(context.cancelToken, run.operation.token) &&
      context.current &&
      current;
  void check(SupportAppActionContext context) {
    run.operation.check();
    if (!original(context))
      throw const SupportAppActionRefused(SupportAppActionCode.stale);
  }

  @override
  bool isOriginalOwnerCurrent(nav.RunContext originalRun) =>
      identical(originalRun, navigationRun) &&
      identical(originalRun.originalOwner, run) &&
      _context != null &&
      original(_context!);
  @override
  bool ownsOriginalSourceApproval(
    String action,
    SupportAppActionContext context,
  ) =>
      SupportSourceToolNames.body.contains(action) &&
      _call?.name == action &&
      identical(context.sourceToolAccess, this) &&
      context.confirmation != null &&
      original(context);

  @override
  Future<SupportAppPreparedAction?> prepare(
    String action,
    Map<String, Object?> arguments,
    SupportAppActionContext context,
  ) async {
    check(context);
    final call = run.toolCall;
    if (call == null ||
        call.name != action ||
        SupportModelToolPayloads.argumentsKey(call.arguments) !=
            SupportModelToolPayloads.argumentsKey(arguments)) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    _call = call;
    return SupportAppPreparedAction(
      target: 'original-source-navigation',
      observation: this,
      observationIsCurrent: () => original(context),
      execute: (admitted) async {
        check(context);
        if (!admitted())
          throw const SupportAppActionRefused(SupportAppActionCode.stale);
        try {
          run.toolActivity(
            SupportModelToolStage.executing,
            detail: action == SupportSourceToolNames.list
                ? 'Поиск метаданных источников; текст не передаётся'
                : 'Навигация только внутри нативно разрешённой области',
          );
          check(context);
          final result = await engine.invoke(
            action,
            arguments,
            retryOrRegeneration: context.readOnlySources,
          );
          check(context);
          if (result.wire['status'] != 'ok') {
            _refuseNavigation(result.wire['status']);
            return SupportAppActionOutcome(_failureCode(result.wire['status']));
          }
          final outcome = SupportAppActionOutcome(
            SupportAppActionCode.completed,
            data: result.bodyBearing
                ? {'sourceText': result.encoded}
                : await _selectNativeTarget(result, context, call),
          );
          if (result.bodyBearing) {
            final native = NativeToolResult(
              callId: call.id,
              name: call.name,
              content: {
                'ok': true,
                'code': 'completed',
                'effect': 'none',
                'data': outcome.data,
              },
            );
            if (jsonEncode(native.content) != result.postEncoded) {
              throw const SupportAppActionRefused(SupportAppActionCode.denied);
            }
            _outcomes[outcome] = _ModelNavigationOutcome(call, result, native);
          }
          return outcome;
        } finally {
          _call = null;
        }
      },
    );
  }

  Future<Map<String, Object?>> _selectNativeTarget(
    nav.NavigationResult result,
    SupportAppActionContext context,
    NativeToolCall call,
  ) async {
    check(context);
    final observations = repo.nativeDiscoveryCandidates;
    final pieces = result.wire['pieces'] as List;
    if (pieces.length != observations.length || pieces.length > 16) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    if (pieces.isEmpty) return result.wire;
    var index = 0;
    if (pieces.length > 1) {
      final port = run.binding.toolUi?.sourceTargetSelection;
      if (port == null) {
        throw const SupportAppActionRefused(SupportAppActionCode.unavailable);
      }
      final redactor = run.service._redaction.redactor;
      final candidates = [
        for (final observation in observations)
          SupportSourceTargetCandidate(
            observation: observation,
            label: _safeText(
              redactor,
              repo.nativeLabel(observation) ?? observation.key.domain.name,
              256,
            ),
            hint: _safeText(
              redactor,
              repo.nativeIdentityHint(observation),
              256,
            ),
          ),
      ];
      final request = SupportSourceTargetSelectionRequest(
        context: context,
        callId: call.id,
        candidates: candidates,
        isOriginalCurrent: () =>
            original(context) && observations.every((o) => o.lease.isCurrent()),
      );
      final selected = await port.selectSource(request);
      check(context);
      index = candidates.indexWhere((c) => identical(c, selected));
      if (index < 0 || !request.current) {
        repo.retire();
        throw const SupportAppActionRefused(SupportAppActionCode.denied);
      }
    }
    final observation = observations[index];
    if (!await engine.revalidateForHost([observation], () => check(context))) {
      throw const SupportAppActionRefused(SupportAppActionCode.conflict);
    }
    check(context);
    if (!_discovered.contains(observation)) _discovered.add(observation);
    // Return the engine's original pointer unchanged. Never retarget a body
    // handle, expose private labels, or mark an omitted catalog as complete.
    return {
      ...result.wire,
      'pieces': [pieces[index]],
      'count': 1,
      if (pieces.length > 1) ...{
        'complete': false,
        'incompleteReason': 'localTargetSelection',
      },
    };
  }

  void _refuseNavigation(Object? status) => run.refuseTool(switch (status) {
    'approvalRequired' ||
    'denied' => 'Нативное согласие на эту область не получено или отозвано',
    'staleSource' =>
      'Исходный снимок изменился; область не расширялась и не подменялась',
    'budgetExceeded' =>
      'Лимит навигации исчерпан; прочитанную часть нельзя считать всем источником',
    'invalidReference' || 'invalidArguments' =>
      'Модель передала невыданную ссылку или неподдерживаемые параметры',
    'stopped' =>
      'Исходное чтение остановлено; дальнейшая передача не разрешена',
    _ => 'Источник не прошёл безопасную проверку; содержимое не передано',
  });
  SupportAppActionCode _failureCode(Object? status) => switch (status) {
    'approvalRequired' ||
    'denied' ||
    'invalidReference' => SupportAppActionCode.denied,
    'invalidArguments' => SupportAppActionCode.invalidArguments,
    'staleSource' => SupportAppActionCode.conflict,
    'stopped' =>
      run.operation.token.isCancelled
          ? SupportAppActionCode.cancelled
          : SupportAppActionCode.stale,
    _ => SupportAppActionCode.unavailable,
  };

  @override
  bool acceptsSourceBodyOutcome(
    NativeToolCall call,
    SupportAppActionOutcome outcome,
  ) {
    final captured = _outcomes[outcome];
    if (!SupportSourceToolNames.body.contains(call.name) ||
        !current ||
        captured == null ||
        !identical(call, captured.call) ||
        outcome.code != SupportAppActionCode.completed ||
        outcome.effect != SupportAppActionEffect.none ||
        outcome.data.length != 1 ||
        outcome.data['sourceText'] != captured.result.encoded ||
        jsonEncode(captured.native.content) != captured.result.postEncoded)
      return false;
    if (!_published.contains(captured.result)) _published.add(captured.result);
    return true;
  }

  /// Actual ROOT validation is distinct from a POST: it must not charge a fake
  /// transmission or use withPost as a synthetic permission/check callback.
  Future<bool> revalidate(
    void Function() checkpoint, {
    nav.SourceObservation? additionalSource,
  }) async {
    if (!_bound)
      return additionalSource == null && _admitted.isEmpty && current;
    if (!await engine.revalidateForHost([
      ..._discovered,
      ..._admitted.map((e) => e.source),
      if (additionalSource != null) additionalSource,
    ], checkpoint))
      return false;
    for (final entry in _admitted) {
      checkpoint();
      if (!entry.grant.lease.isCurrent() ||
          !entry.source.lease.isCurrent() ||
          !entry.source.lease.isCurrent())
        return false;
      checkpoint();
      final stamp = await projection.currentStamp();
      checkpoint();
      if (!stamp.same(entry.projection) ||
          !entry.grant.lease.isCurrent() ||
          !entry.source.lease.isCurrent())
        return false;
    }
    return current;
  }

  Future<bool> withPost(Future<bool> Function() dispatch) async {
    if (!_bound) return false;
    var accepted = false;
    final ok = await engine.withPost(_published, (_) async {
      var bytes = 0;
      final scopeBytes = Map<nav.NativeGrant, int>.identity();
      for (final entry in _admitted) {
        final bound = _wireBounds[entry];
        if (bound == null) return;
        bytes += bound;
        scopeBytes.update(entry.grant, (n) => n + bound, ifAbsent: () => bound);
      }
      if (_wireSpent + bytes > nav.Limits.disclosureBytes ||
          scopeBytes.entries.any(
            (e) => (_scopeSpent[e.key] ?? 0) + e.value > e.key.disclosureBytes,
          ))
        return;
      _wireSpent += bytes;
      for (final e in scopeBytes.entries) {
        _scopeSpent.update(e.key, (n) => n + e.value, ifAbsent: () => e.value);
      }
      accepted = await dispatch();
    });
    return ok && accepted;
  }

  @override
  Future<SupportAppSourceLease?> acquire({
    required String domain,
    required String sourceId,
    required Object observation,
    required SupportAppActionContext context,
  }) async => null;
  void close() {
    if (_closed) return;
    _closed = true;
    if (_bound) engine.stop();
    _outcomes.clear();
    _published.clear();
    _discovered.clear();
    _admitted.clear();
    _wireBounds.clear();
    _scopeSpent.clear();
    releaseRepository();
  }
}

final class _ModelNavigationOutcome {
  const _ModelNavigationOutcome(this.call, this.result, this.native);
  final NativeToolCall call;
  final nav.NavigationResult result;
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
  Future<bool> sourceToolsRevalidate(
    void Function() checkpoint, {
    nav.SourceObservation? additionalSource,
  }) async =>
      originalSourceTools == null ||
      await originalSourceTools!.revalidate(
        checkpoint,
        additionalSource: additionalSource,
      );
}
