part of 'support_model_service.dart';

final class _ModelRun {
  _ModelRun(
    this.service,
    this.binding,
    this.text,
    this.userId,
    this.replyId,
    this.runId, {
    this.isCompact = false,
    this.regeneration,
    this.regenerationUser,
    this.unanswered,
  }) {
    for (final id in [userId, replyId, runId, sessionId]) {
      requireSupportPermissionId(id);
      if (id.length > 128) _refuse(SupportModelRefusal.unsafe);
      if (_safeText(service._redaction.redactor, id, 128) != id) {
        _refuse(SupportModelRefusal.unsafe);
      }
    }
    if ({userId, replyId, runId}.length != 3) {
      _refuse(SupportModelRefusal.unsafe);
    }
    if (binding.policy.allows(SupportPermission.modelSupportHistory) &&
        binding.policy.scope?.supportHistory?.messageIds.any(
              (id) => id == userId || id == replyId,
            ) ==
            true) {
      _refuse(SupportModelRefusal.lineageUnavailable);
    }
    operation = _ModelReadOperation(service, current);
    authorization = SupportAuthorizationService(
      readPolicy: (id) async => SupportPermissionSnapshot(
        SupportPermissionAvailability.available,
        await operation.policy(id, admissionCheckpoint),
      ),
      currentNativeContext: () {
        service._runtime.checkConfiguration();
        final r = service._runtime, p = r.snapshot.preferences;
        return SupportNativePermissionContext(
          supportSessionId: r.sessionId,
          epoch: r.epoch,
          scope: p?.scope,
          recipient: p?.recipient,
        );
      },
      allowsUse: (_) => current(),
    );
  }
  final SupportModelService service;
  final _ModelBinding binding;
  final String text, userId, replyId, runId;
  final bool isCompact;
  final SupportReplyRegenerationObservation? regeneration;
  final SupportMessage? regenerationUser;
  final SupportUnansweredUserObservation? unanswered;
  bool get isRegeneration => regeneration != null;
  bool get isRetry => unanswered != null;
  bool get isReattempt => isRegeneration || isRetry;
  String get inputRunId => regenerationUser?.runId ?? runId;
  SupportCompactionCheckpoint? checkpoint;
  bool compactInstalled = false;
  PrivateTextOutcome? compactOutcome;
  SupportAppActionRegistry? originalActions;
  SupportDatabaseBackupAdapter? originalBackup;
  bool toolsResolved = false;
  _ModelSourceToolRun? originalSourceTools;
  int toolSequence = 0;
  int? toolSourcePart;
  String? toolAction, toolSourceLabel, toolFailureDetail;
  String get sessionId => binding.sessionId;
  late final _ModelReadOperation operation;
  SupportTextContextRepo get history => operation.history;
  late final SupportAuthorizationService authorization;
  final acceptance = Completer<bool>();
  final preparation = Completer<SupportModelPreparation>();
  final completion = Completer<SupportModelRunResult>();
  SupportMessage? durableUser;
  SupportReplyReservation? expected;
  SupportModelPreview? preview;
  _ModelContextPlan? context;
  List<SupportTextContextSnapshot> snapshots = const [];
  void Function()? admissionCheckpoint;
  bool accepted = false,
      preparing = true,
      running = false,
      approvalIssued = false;
  bool settlementValid = true, _settling = false;
  SupportModelRefusal reason = SupportModelRefusal.none;

  bool current() =>
      service._ownerCurrent &&
      identical(service._active, this) &&
      binding.current(draft: !accepted) &&
      !operation.token.isCancelled;

  bool get publicationCurrent =>
      service._ownerCurrent &&
      identical(service._active, this) &&
      binding.current();

  bool references(String id, String message) =>
      (id == sessionId && (message == userId || message == replyId)) ||
      (binding.configuration.directConversation && id == sessionId) ||
      sources.any(
        (s) =>
            (s.kind == SupportSourceKind.supportHistory
                    ? sessionId
                    : s.gameSessionId) ==
                id &&
            (s.historyExtent == SupportHistoryExtent.wholeSession ||
                s.selectedIds.contains(message)),
      );

  void phase(SupportModelPhase phase) {
    if (!publicationCurrent) return;
    try {
      service._onPhase?.call(phase);
    } catch (_) {
      /* Observer cannot own a run. */
    }
  }

  void publish(SupportMessage message) {
    if (!publicationCurrent) return;
    try {
      service._onMessage?.call(project(message));
    } catch (_) {
      /* Durable result stays accepted. */
    }
  }

  SupportModelMessage project(SupportMessage message) => SupportModelMessage(
    id: message.id,
    sessionId: message.sessionId,
    runId: message.runId!,
    role: message.role,
    status: message.status,
    createdAt: message.createdAt,
    text: _safeText(service._redaction.redactor, message.body, 65536),
  );

  void cancel(SupportModelRefusal why) {
    if (reason == SupportModelRefusal.none) reason = why;
    operation.cancel(why);
    if (!preparing && !running && !_settling) unawaited(finish());
  }

  Future<void> prepare() async {
    if (isCompact) {
      await prepareCompact();
      return;
    }
    try {
      operation.check();
      final user =
          regenerationUser ??
          await service._writes.enqueue(
            () => service._writer.appendCurrentUser(
              message: SupportMessage(
                id: userId,
                sessionId: sessionId,
                role: 'user',
                body: text,
                runId: runId,
                createdAt: service._now(),
              ),
              isCurrent: current,
            ),
          );
      if (user == null) _refuse(SupportModelRefusal.appendFailed);
      durableUser = user;
      if (!isReattempt) {
        accepted = true;
        acceptance.complete(true); // Durable append, not transport success.
        publish(user);
      }
      operation.check();
      var initial = isReattempt
          ? await loadContext()
          : await loadManagedContext();
      operation.check();
      if (!isReattempt &&
          binding.configuration.directConversation &&
          binding.configuration.settings.dcpCompressionEnabled &&
          _contextPressure(initial)) {
        await compactContext(initial);
        operation.check();
        initial = await loadContext();
        operation.check();
      }
      final provenance = SupportModelProvenanceCodec.encodeForEncryptedStorage(
        initial.recipe,
      );
      if (isRegeneration) _requireSameRegenerationSources(initial.recipe);
      expected = await service._writes.enqueue(
        () => isRegeneration
            ? service._writer.reserveRegeneratedReply(
                expected: regeneration!,
                originatingUser: user,
                attemptRunId: runId,
                provenanceJson: provenance,
                isCurrent: current,
              )
            : isRetry
            ? service._writer.reserveUnansweredReply(
                expected: unanswered!,
                message: SupportMessage(
                  id: replyId,
                  sessionId: sessionId,
                  role: 'assistant',
                  body: '',
                  runId: runId,
                  status: 'preparing',
                  createdAt: service._now(),
                ),
                provenanceJson: provenance,
                isCurrent: current,
              )
            : service._writer.reserveOrderedReply(
                message: SupportMessage(
                  id: replyId,
                  sessionId: sessionId,
                  role: 'assistant',
                  body: '',
                  runId: runId,
                  status: 'preparing',
                  createdAt: service._now(),
                ),
                originatingUser: user,
                provenanceJson: provenance,
                isCurrent: current,
              ),
      );
      if (expected == null) _refuse(SupportModelRefusal.reservationFailed);
      if (isReattempt) {
        accepted = true;
        acceptance.complete(
          true,
        ); // Only the atomic assistant claim is reattempt acceptance.
        publish(expected!.message);
      }
      operation.check();
      final pending = await service._writes.enqueue(
        () => service._writer.settleReply(
          expected: expected!,
          status: 'pending',
          isCurrent: current,
        ),
      );
      if (pending == null) _refuse(SupportModelRefusal.reservationFailed);
      expected = (message: pending, provenance: expected!.provenance);
      publish(pending);
      operation.check();
      // ALL own writes are now complete. Fresh snapshots, then immutable preview.
      preview = await finalPreview(provenance);
      operation.check();
      preparation.complete(
        SupportModelPreparation._(preview, SupportModelRefusal.none),
      );
      if (binding.configuration.directConversation) {
        // The original Send authorizes this exact saved destination, immutable
        // input and visible current conversation. Actual-wire admission remains.
        operation.check();
        preparing = false;
        running = true;
        unawaited(generate());
      } else {
        preparing = false;
        phase(SupportModelPhase.preview);
      }
    } on _ModelRefused catch (error) {
      reason = error.reason;
    } on SupportAuthorizationDenied {
      reason = SupportModelRefusal.historyDenied;
    } on SupportModelProvenanceException {
      reason = SupportModelRefusal.lineageUnavailable;
    } on SupportTextContextException catch (error) {
      reason = error.failure == SupportTextContextFailure.limited
          ? SupportModelRefusal.tooLarge
          : SupportModelRefusal.stale;
    } catch (_) {
      reason = accepted
          ? SupportModelRefusal.reservationFailed
          : SupportModelRefusal.appendFailed;
    }
    if (preparing) {
      preparing = false;
      if (operation.reason != SupportModelRefusal.none) {
        reason = operation.reason;
      }
      if (!acceptance.isCompleted) acceptance.complete(false);
      if (!preparation.isCompleted) {
        preparation.complete(SupportModelPreparation._(null, reason));
      }
      await finish();
    }
  }

  Future<void> generate() async {
    PrivateTextOutcome? outcome;
    try {
      operation.check();
      phase(SupportModelPhase.waiting);
      final configuration = binding.configuration;
      if (hasNativeTools) {
        outcome = await generateTools();
        await finish(outcome);
        return;
      }
      // ONE original private admission owner. Native dispatch receives this
      // very instance, not a permissive generic transport or substitute capsule.
      final inner = PrivateTextTransport(
        adapterFactory: service._adapterFactory,
        currentRedactor: () => service._redaction.redactor,
        authorize: (_) async => false,
        admit: admit,
        scheduleDeadline: service._scheduleTimer,
      );
      final request = configuration.request(
        preview!.messages,
        isCurrent: current,
      );
      final recipient = Uri.parse(
        configuration.recipient.recipient.nativeRoute,
      );
      void activity() {
        if (current()) phase(SupportModelPhase.activity);
      }

      final auth = configuration.nativeSource?.savedConnectionAuth;
      if (auth != null) {
        final factory = service._nativeDispatcher;
        if (factory == null) _refuse(SupportModelRefusal.unavailable);
        final dispatcher = factory(inner);
        operation.check(); // Constructor callback cannot renew retired custody.
        outcome = await dispatcher.generate(
          savedConnectionAuth: auth,
          protocol: configuration.api.protocol,
          request: request,
          approvedRecipient: recipient,
          cancelToken: operation.token,
          isCurrent: current,
          deadline: service._deadline,
          onActivity: activity,
        );
      } else {
        outcome = await inner.generate(
          protocol: configuration.api.protocol,
          request: request,
          approvedRecipient: recipient,
          cancelToken: operation.token,
          isCurrent: current,
          deadline: service._deadline,
          onActivity: activity,
        );
      }
    } on _ModelRefused catch (error) {
      reason = error.reason;
    } catch (_) {
      reason = SupportModelRefusal.unavailable;
    }
    await finish(outcome);
  }
}

/// Original-row settlement is deliberately independent of network/UI custody.
extension _ModelSettlement on _ModelRun {
  Future<void> finish([PrivateTextOutcome? outcome]) async {
    if (_settling) return;
    _settling =
        true; // Separate exact ORIGINAL row owner, not H/native current.
    if (reason == SupportModelRefusal.none &&
        operation.reason != SupportModelRefusal.none) {
      reason = operation.reason;
    }
    operation.close();
    // generateTools has joined any admitted file effect before settlement.
    originalBackup?.dispose();
    originalSourceTools?.close();
    phase(SupportModelPhase.settling);
    SupportModelMessage? message;
    var saved = compactInstalled && isCompact;
    try {
      if (expected != null && settlementValid) {
        final durable = await service._writes.enqueue(() {
          // Capture at FIFO execution, not when cancellation queues this work:
          // synchronous key registration may replace the policy in that gap.
          final settlementRedactor = service._redaction.redactor;
          var body = outcome?.text ?? '';
          var status = switch (outcome?.status) {
            PrivateTextStatus.complete => 'complete',
            PrivateTextStatus.limited => 'limited',
            PrivateTextStatus.stopped => 'stopped',
            PrivateTextStatus.error || PrivateTextStatus.partial => 'error',
            _ => operation.token.isCancelled ? 'stopped' : 'error',
          };
          try {
            body = _safeText(
              settlementRedactor.withKnownSecrets([binding.configuration.key]),
              body,
              65536,
            );
          } catch (_) {
            body = '';
            status = 'limited';
          }
          return service._writer.settleReply(
            expected: expected!,
            status: status,
            body: body,
            isCurrent: () =>
                settlementValid &&
                identical(settlementRedactor, service._redaction.redactor),
          );
        });
        if (durable != null) {
          expected = (message: durable, provenance: expected!.provenance);
          saved = true;
          publish(durable);
          // A retired coordinator can forbid display; never expose unchecked text.
          try {
            message = project(durable);
          } catch (_) {
            message = null;
          }
        } else {
          reason = SupportModelRefusal.settlementFailed;
        }
      } else if (expected != null) {
        reason = SupportModelRefusal.settlementFailed;
      }
    } catch (_) {
      reason = SupportModelRefusal.settlementFailed;
    }
    if (!acceptance.isCompleted) acceptance.complete(accepted);
    if (!preparation.isCompleted) {
      preparation.complete(SupportModelPreparation._(null, reason));
    }
    if (outcome != null) {
      final actualDispatch = outcome.dispatch;
      final actualUsage = outcome.usage;
      // The coordinator can change DURING settlement awaits. Even a refused or
      // selected-away result must never return earlier unchecked text in a DTO.
      try {
        outcome = PrivateTextOutcome(
          status: outcome.status,
          text: _safeText(
            service._redaction.redactor.withKnownSecrets([
              binding.configuration.key,
            ]),
            outcome.text,
            65536,
          ),
          reason: outcome.reason,
          httpStatus: outcome.httpStatus,
          dispatch: outcome.dispatch,
          usage: actualUsage,
        );
      } catch (_) {
        outcome = PrivateTextOutcome(
          status: PrivateTextStatus.limited,
          text: '',
          reason: PrivateTextReason.sanitationLimit,
          dispatch: actualDispatch,
          usage: actualUsage,
        );
      }
    }
    phase(SupportModelPhase.settled);
    if (publicationCurrent && outcome != null) {
      service._lastUsage = outcome.usage;
      service._usageSession = sessionId;
      service._usageRevision = binding.revision;
    }
    if (identical(service._active, this)) service._active = null;
    completion.complete(
      SupportModelRunResult(
        accepted: accepted,
        saved: saved,
        reason: reason,
        message: message,
        outcome: outcome,
        compacted: compactInstalled,
      ),
    );
  }
}
