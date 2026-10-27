part of 'support_model_service.dart';

final class _ModelSourceApproval implements nav.ApprovalPort {
  _ModelSourceApproval(this.owner);
  final _ModelSourceToolRun owner;
  @override
  Future<nav.NativeGrant?> request(nav.ApprovalRequest request) async {
    final context = owner._context, call = owner._call;
    if (context == null ||
        call == null ||
        context.confirmation == null ||
        !identical(request.run, owner.navigationRun))
      return null;
    owner.check(context);
    final plan = await owner.scopeForApproval(request.source);
    owner.check(context);
    if (!request.source.lease.isCurrent()) return null;
    final remaining = nav.Limits.disclosureBytes - owner._wireSpent;
    final bytes = request.maximumDisclosureBytes < remaining
        ? request.maximumDisclosureBytes
        : remaining;
    final count =
        SupportModelProvenanceLimits.maxToolDisclosures -
        (owner.run.context!.recipe.toolDisclosures?.length ?? 0);
    if (bytes <= 0 || count <= 0) return null;
    final config = owner.run.binding.configuration;
    final redactor = owner.run.service._redaction.redactor;
    final label = _safeText(redactor, plan.label, 256);
    owner.run.toolActivity(
      SupportModelToolStage.preparing,
      sourceLabel: label,
      detail: 'Проверка исходного снимка и неизменяемой области чтения',
    );
    owner.check(context);
    final native = SupportAppConfirmationRequest(
      context: context,
      callId: call.id,
      action: call.name,
      target: 'original-source-scope',
      arguments: call.arguments,
      observation: request,
      observationIsCurrent: () =>
          owner.original(context) && request.source.lease.isCurrent(),
      preview: {
        'sourceNavigation': true,
        'sourceLabel': label,
        'kind': request.source.key.domain.name,
        'extent': _safeText(redactor, plan.extent, 256),
        'sections': plan.scope.sections.toList(),
        'exclusions': request.source.key.domain == nav.SourceDomain.game
            ? 'hidden/failed/locked/inactive variants, reasoning, attachments, cards, raw prompts'
            : 'credentials, private integrity hashes, live recalculation, historical prompt reconstruction',
        'disclosureBytes': bytes,
        'bodyResults': count,
        'connection': _safeText(
          redactor,
          config.recipient.recipient.connectionId,
          256,
        ),
        'model': _safeText(redactor, config.settings.modelId!, 256),
        'protocol': _safeText(redactor, config.api.protocol, 256),
        'routing': _safeText(
          redactor,
          config.recipient.recipient.protocol.name,
          256,
        ),
        'origin': _safeText(redactor, owner._destination!.origin, 256),
      },
    );
    final lease = await context.confirmation!.confirm(native);
    owner.check(context);
    owner.run.toolActivity(
      SupportModelToolStage.executing,
      detail:
          'Исходный запрос согласия вернулся; проверка точного нативного решения',
    );
    if (lease == null ||
        !lease.accept(native) ||
        !lease.current ||
        !native.current)
      return null;
    owner.run.toolActivity(
      SupportModelToolStage.executing,
      detail: 'Точное нативное согласие принято; область чтения заморожена',
    );
    return nav.NativeGrant(
      run: request.run,
      source: request.source.key,
      snapshot: request.source.snapshot,
      scope: plan.scope,
      disclosureBytes: bytes,
      lease: _ModelSourceScopeLease(owner, request, lease),
    );
  }
}

final class _ModelSourceScopeLease implements nav.ApprovalLease {
  _ModelSourceScopeLease(this.owner, this.approval, this.native);
  final _ModelSourceToolRun owner;
  final nav.ApprovalRequest approval;
  final SupportAppConfirmationLease native;
  bool _retired = false;
  @override
  bool isCurrent() {
    if (_retired) return false;
    if (!owner.current ||
        !identical(native.request.observation, approval) ||
        !identical(native.request.context, owner._context) ||
        !native.current ||
        !native.request.current ||
        !approval.source.lease.isCurrent() ||
        !owner.current)
      _retired = true;
    return !_retired;
  }
}

final class _ModelSourceProjection implements nav.ProjectionPort {
  _ModelSourceProjection(this.owner);
  final _ModelSourceToolRun owner;
  SecretRedactor? _redactor;
  int _revision = 0;
  nav.ProjectionStamp _stamp() {
    owner.check(owner._context!);
    final current = owner.run.service._redaction.redactor;
    if (!identical(current, _redactor)) {
      _redactor = current;
      _revision++;
    }
    return nav.ProjectionStamp(owner.run.runId, _revision);
  }

  @override
  Future<nav.ProjectionStamp> currentStamp() async => _stamp();
  @override
  Future<nav.ProjectedRecord> project(nav.DataRecord record) async {
    final stamp = _stamp();
    Object? project(Object? value) {
      if (value is String)
        return _safeText(_redactor!, value, nav.Limits.rawBytes);
      if (value is List) return value.map(project).toList(growable: false);
      if (value is Map<String, Object?>) {
        if (!record.schemaKeysAttested)
          throw const SupportAppActionRefused(
            SupportAppActionCode.unsafeMetadata,
          );
        return {for (final e in value.entries) e.key: project(e.value)};
      }
      return value;
    }

    final payload = project(record.payload);
    owner.check(owner._context!);
    if (!stamp.same(_stamp()))
      throw const SupportAppActionRefused(SupportAppActionCode.stale);
    return nav.ProjectedRecord(payload, stamp);
  }

  @override
  Future<nav.ProjectedWire> wire(nav.WireCandidate candidate) async {
    final call = owner._call;
    final stamp = _stamp();
    if (call == null ||
        call.name != candidate.operation ||
        jsonEncode(call.arguments) != candidate.argumentsJson) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    if (call.name == SupportSourceToolNames.contents) {
      owner.run.toolActivity(
        SupportModelToolStage.executing,
        detail:
            'Оглавление разрешённой области построено; проверка полного результата',
      );
    }
    final content = <String, Object?>{
      'ok': true,
      'code': 'completed',
      'effect': 'none',
      'data': {'sourceText': candidate.encoded},
    };
    // Validate the real native result (including scalar/node/encoding limits)
    // before provenance. Also bound its additional protocol string escaping.
    final native = NativeToolResult(
      callId: call.id,
      name: call.name,
      content: content,
    );
    final encoded = jsonEncode(native.content);
    if (utf8.encode(jsonEncode(encoded)).length + 512 > nav.Limits.wireBytes) {
      throw const SupportAppActionRefused(SupportAppActionCode.unavailable);
    }
    owner.check(owner._context!);
    owner.run.toolActivity(
      SupportModelToolStage.executing,
      detail:
          'Полный нативный результат проверен; проверка вложенного конверта',
    );
    return nav.ProjectedWire(candidate, content, stamp);
  }
}

final class _ModelSourceProvenance implements nav.ProvenancePort {
  _ModelSourceProvenance(this.owner);
  final _ModelSourceToolRun owner;
  @override
  Future<nav.ProvenanceReceipt> append(nav.ProvenanceEntry entry) async {
    final run = owner.run, context = owner._context!, call = owner._call;
    owner.check(context);
    if (call == null ||
        !identical(entry.run, owner.navigationRun) ||
        entry.operation != call.name ||
        entry.argumentsJson != jsonEncode(call.arguments) ||
        !entry.grant.lease.isCurrent() ||
        !entry.source.lease.isCurrent()) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    // append is reached only after the engine validates the actual FULL nested
    // envelope and its original candidate custody, never a payload estimate.
    run.toolActivity(
      SupportModelToolStage.executing,
      detail: 'Полный вложенный конверт принят; проверка исходного ROOT',
    );
    final bytes = utf8.encode(jsonEncode(entry.exactEnvelopeJson)).length + 512;
    final old = run.context!.recipe;
    final prior = old.toolDisclosures ?? const <SupportModelToolDisclosure>[];
    if (prior.length >= SupportModelProvenanceLimits.maxToolDisclosures ||
        bytes > nav.Limits.wireBytes ||
        owner._wireSpent + bytes > nav.Limits.disclosureBytes ||
        (owner._scopeSpent[entry.grant] ?? 0) + bytes >
            entry.grant.disclosureBytes) {
      return nav.ProvenanceReceipt(
        entry,
        durableEncrypted: false,
        conflict: true,
      );
    }
    if (!await run.admitOriginalRoot(
      capsuleCurrent: () =>
          entry.grant.lease.isCurrent() && entry.source.lease.isCurrent(),
      additionalReadOnlyCheck: (checkpoint) =>
          owner.engine.revalidateForHost([entry.source], checkpoint),
      dispatch: () {},
    )) {
      throw const SupportAppActionRefused(SupportAppActionCode.stale);
    }
    owner.check(context);
    run.toolActivity(
      SupportModelToolStage.executing,
      detail:
          'Исходный ROOT проверен; проверка нативного захвата происхождения',
    );
    final ids = owner.repo.nativeIdsFor(entry),
        digest = owner.repo.privateDigestFor(entry);
    if (ids == null || digest == null || ids.isEmpty || ids.length > 16) {
      throw const SupportAppActionRefused(SupportAppActionCode.denied);
    }
    run.toolActivity(
      SupportModelToolStage.executing,
      detail:
          'Нативный захват происхождения проверен; подготовка зашифрованного расширения',
    );
    final selection =
        entry.source.key.domain == nav.SourceDomain.game &&
        entry.extents.any((e) => e.selection.range != null);
    final disclosure = SupportModelToolDisclosure(
      domain: SupportModelToolDisclosureDomain.values.byName(
        entry.source.key.domain.name,
      ),
      sourceId: entry.source.key.nativeId,
      orderedSourceIds: ids,
      snapshotDigest: digest,
      operation: SupportModelToolDisclosureOperation.values.byName(
        entry.operation.substring('astoria_source_'.length),
      ),
      extent: entry.operation == SupportSourceToolNames.contents
          ? SupportModelToolDisclosureExtent.scopeMetadata
          : selection
          ? SupportModelToolDisclosureExtent.selectedMessages
          : SupportModelToolDisclosureExtent.sourceIdentity,
    );
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
    final encoded = SupportModelProvenanceCodec.encodeForEncryptedStorage(next);
    owner._wireSpent += bytes;
    owner._scopeSpent.update(
      entry.grant,
      (n) => n + bytes,
      ifAbsent: () => bytes,
    );
    run.toolActivity(
      SupportModelToolStage.executing,
      detail: 'Запись зашифрованного расширения исходного ответа',
    );
    final written = await run.service._writes.enqueue(() async {
      owner.check(context);
      final pending = await run.service._writer.readReplyForSourceExtension(
        expected: run.expected!,
        originatingUser: run.durableUser!,
        isCurrent: () =>
            owner.original(context) && entry.grant.lease.isCurrent(),
      );
      owner.check(context);
      if (pending == null)
        throw const SupportAppActionRefused(SupportAppActionCode.conflict);
      final actual = await run.service._writer.extendReplySourcesAttested(
        expected: pending,
        provenanceJson: encoded,
        isCurrent: () =>
            owner.original(context) && entry.grant.lease.isCurrent(),
      );
      if (actual == null)
        throw const SupportAppActionRefused(SupportAppActionCode.conflict);
      // Preserve OUR durable reservation for Stop settlement before checking
      // publication lifetime; commit success must not be erased by cancellation.
      run.expected = actual.reservation;
      return actual;
    });
    owner.check(context);
    run.toolActivity(
      SupportModelToolStage.executing,
      detail:
          'Зашифрованное расширение сохранено; проверка собственного commit',
    );
    if (written.reservation.provenance.protectedFactsJson != encoded) {
      throw const SupportAppActionRefused(SupportAppActionCode.conflict);
    }
    await owner.acknowledgeOwnWrite(entry, written);
    owner.check(context);
    run.toolActivity(
      SupportModelToolStage.executing,
      detail: 'Собственный commit подтверждён; обновление исходного контекста',
    );
    final fresh = await run.history.refreshAfterOwnSourceExtension(
      snapshots: run.snapshots,
      checkpoint: () => owner.check(context),
    );
    owner.check(context);
    run.snapshots = fresh;
    run.context = _ModelContextPlan(
      fresh.take(run.context!.snapshots.length),
      run.context!.custody,
      next,
    );
    owner._admitted.add(entry);
    owner._wireBounds[entry] = bytes;
    run.toolActivity(
      SupportModelToolStage.executing,
      detail:
          'Зашифрованное происхождение и исходный контекст подтверждены до передачи',
    );
    return nav.ProvenanceReceipt(entry, durableEncrypted: true);
  }
}
