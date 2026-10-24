part of 'support_model_service.dart';

/// Trusted-only configuration. Never exported in preview/run state or prompts.
final class _ModelConfiguration {
  const _ModelConfiguration(
    this.settings,
    this.api,
    this.key,
    this.policy,
    this.recipient,
    this.nativeSource,
    this.directConversation,
  );
  final SupportAssistantSettings settings;
  final ApiConfig api;
  final String key;
  final SupportPermissionPreferences policy;
  final SupportResolvedRecipient recipient;
  final NativePreparedSavedConnection? nativeSource;
  final bool directConversation;

  static Future<_ModelConfiguration> read(
    _ModelReadOperation operation,
    String id, {
    bool prime = false,
    void Function()? checkpoint,
    _ModelConfiguration? original,
    bool directConversation = false,
  }) async {
    final s = operation.service;
    directConversation = original?.directConversation ?? directConversation;
    // Capture BEFORE settings/API/prompt awaits. Admission retains the exact
    // original prepared source; it never mints a replacement authorization.
    final sources = s._nativeSources;
    final retained = original?.nativeSource;
    final stamp = sources != null && original == null
        ? sources.captureOriginalStamp()
        : null;
    bool sourceCurrent() =>
        operation.current() &&
        (stamp == null ||
            sources!.isOriginalCurrent(stamp, operation.current)) &&
        (retained == null || retained.isCurrent);
    if (!sourceCurrent()) _refuse(SupportModelRefusal.stale);
    final settings = await operation.settings(id, checkpoint);
    operation.check();
    if (!settings.hasConfiguredModel) _refuse(SupportModelRefusal.noModel);
    final row = await operation.checked(
      () => s._apiRepo.getById(settings.apiConfigId!),
      checkpoint,
    );
    if (row == null) _refuse(SupportModelRefusal.unavailable);
    ApiConfig api = row;
    if (!sourceCurrent()) _refuse(SupportModelRefusal.stale);
    final metadata = s._nativeMetadata;
    final facts = metadata == null
        ? null
        : await operation.checked(
            () => metadata.readConfiguration(
              connectionId: api.id,
              isCurrent: sourceCurrent,
            ),
            checkpoint,
          );
    if (!sourceCurrent()) _refuse(SupportModelRefusal.stale);
    NativePreparedSavedConnection? prepared;
    if (facts != null && facts.nativeManaged) {
      if (facts.metadata?.configured != true ||
          sources == null ||
          s._nativeDispatcher == null) {
        _refuse(SupportModelRefusal.unavailable);
      }
      final NativePreparedSavedConnection savedSource;
      if (original != null) {
        if (retained == null || !retained.isNative || !retained.isCurrent) {
          _refuse(SupportModelRefusal.stale);
        }
        // Latest durable row is compared below, but NEVER used to mint auth.
        savedSource = retained;
        api = sources.projectNativeConfiguration(api);
      } else {
        savedSource = await operation.checked(
          () => sources.prepare(
            originalStamp: stamp!,
            configuration: api,
            purpose: NativeProviderPurpose.astoria,
            isCurrent: operation.current,
          ),
          checkpoint,
        );
        if (!sourceCurrent() ||
            !savedSource.isNative ||
            !savedSource.isCurrent) {
          _refuse(SupportModelRefusal.stale);
        }
        api = savedSource.configuration;
      }
      prepared = savedSource;
      savedSource.requireModel(settings.modelId!);
      // Non-key request shape is checked before full-prompt approval. The
      // unchanged private plan validates the actual key only inside dispatch.
      if (!api.topP.isFinite ||
          !api.frequencyPenalty.isFinite ||
          !api.presencePenalty.isFinite ||
          settings.modelId!.length > 256) {
        _refuse(SupportModelRefusal.unsupported);
      }
    } else if (retained != null || (sources != null && metadata == null)) {
      // Incomplete native injection or changed protected presence is not legacy.
      _refuse(SupportModelRefusal.unavailable);
    }
    if (!api.stream ||
        api.mode != 'chat' ||
        api.extraRequestParameters.any((parameter) => parameter.enabled)) {
      _refuse(SupportModelRefusal.unsupported);
    }
    // Only explicit ABSENT native metadata permits the unchanged row-key path.
    // Native configurations remain keyless; no dummy preview/plan credential.
    final key = api.apiKey;
    if (prepared == null &&
        (key.isEmpty ||
            key.length > 8192 ||
            RegExp(r'[\x00-\x20\x7f]').hasMatch(key))) {
      _refuse(SupportModelRefusal.unavailable);
    }
    if (prime) {
      s._redaction.registerSecret(api.apiKey);
      s._redaction.registerSecret(api.embeddingApiKey);
      operation.check(); // A coordinator-driven provider rebuild DENIES.
    }
    final policy = await operation.policy(id, checkpoint);
    final latest = await operation.settings(id, checkpoint);
    if (!_sameSettings(settings, latest)) _refuse(SupportModelRefusal.stale);
    final runtime = s._runtime;
    final recipient = const SupportRecipientProjection().project(
      context: SupportRecipientContext(
        supportSessionId: id,
        epoch: runtime.writeOwner,
      ),
      config: api,
      modelId: settings.modelId!,
      revision: s._revisions.revision,
      redactor: s._redaction.redactor,
    );
    if (recipient == null ||
        Uri.parse(recipient.recipient.nativeRoute).scheme != 'https' ||
        (prepared != null &&
            prepared.savedConnectionAuth!.connection.endpoint !=
                recipient.recipient.nativeRoute)) {
      _refuse(SupportModelRefusal.unsupported);
    }
    if ((!directConversation &&
            (!runtime.recipientConfirmed ||
                runtime.recipient is! SupportResolvedRecipient ||
                !recipient.recipient.sameAs(policy.recipient) ||
                !recipient.recipient.sameAs(
                  (runtime.recipient as SupportResolvedRecipient).recipient,
                ) ||
                !recipient.context.sameAs(runtime.recipientContext))) ||
        !_samePolicy(policy, runtime.snapshot.preferences)) {
      _refuse(SupportModelRefusal.recipientRequired);
    }
    operation.check();
    if (!sourceCurrent()) _refuse(SupportModelRefusal.stale);
    checkpoint?.call();
    return _ModelConfiguration(
      settings,
      api,
      key,
      policy,
      recipient,
      prepared,
      directConversation,
    );
  }

  bool sameAs(_ModelConfiguration other) =>
      api == other.api &&
      key == other.key &&
      identical(nativeSource, other.nativeSource) &&
      directConversation == other.directConversation &&
      _sameSettings(settings, other.settings) &&
      _samePolicy(policy, other.policy) &&
      recipient.recipient.sameAs(other.recipient.recipient) &&
      recipient.context.sameAs(other.recipient.context);

  ChatTransportRequest request(
    List<SupportModelPreviewText> messages, {
    required bool Function() isCurrent,
  }) => ChatTransportRequest(
    endpoint: recipient.recipient.nativeRoute,
    apiKey: key,
    savedConnectionAuth: nativeSource?.savedConnectionAuth,
    savedConnectionId: nativeSource?.savedConnectionId,
    nativeSourceIsCurrent: nativeSource?.bindNativeCurrent(
      isCurrent: isCurrent,
    ),
    model: settings.modelId!,
    messages: List.unmodifiable(
      messages.map(
        (m) => Map<String, dynamic>.unmodifiable({
          'role': m.role,
          'content': m.text,
        }),
      ),
    ),
    maxTokens: settings.maxTokens,
    temperature: settings.temperature,
    topP: api.topP,
    topK: api.topK,
    frequencyPenalty: api.frequencyPenalty,
    presencePenalty: api.presencePenalty,
    stream: true,
    requestReasoning: settings.reasoningEffort != SupportReasoningEffort.off,
    reasoningEffort: settings.reasoningEffort == SupportReasoningEffort.off
        ? null
        : settings.reasoningEffort.name,
    useResponsesApi: api.useResponsesApi,
    omitTemperature: api.omitTemperature,
    omitTopP: api.omitTopP,
    omitTopK: api.omitTopK,
    omitFrequencyPenalty: api.omitFrequencyPenalty,
    omitPresencePenalty: api.omitPresencePenalty,
    omitReasoning:
        api.omitReasoning ||
        settings.reasoningEffort == SupportReasoningEffort.off,
    omitReasoningEffort: api.omitReasoningEffort,
    showNativeReasoning: false,
    sessionIdMode: 'off',
    cacheControlTtl: 'off',
    promptPostProcessing: 'none',
    useSystemInstruction: api.useSystemInstruction,
  );
}

bool _sameSettings(SupportAssistantSettings a, SupportAssistantSettings b) =>
    a.mode == b.mode &&
    a.apiConfigId == b.apiConfigId &&
    a.modelId == b.modelId &&
    a.temperature == b.temperature &&
    a.maxTokens == b.maxTokens &&
    a.reasoningEffort == b.reasoningEffort &&
    a.dcpCompressionEnabled == b.dcpCompressionEnabled;

bool _samePolicy(
  SupportPermissionPreferences a,
  SupportPermissionPreferences? b,
) =>
    b != null &&
    a.supportSessionId == b.supportSessionId &&
    a.policyIdentity == b.policyIdentity &&
    a.revision == b.revision &&
    (a.scope == null ? b.scope == null : a.scope!.sameAs(b.scope)) &&
    (a.recipient == null
        ? b.recipient == null
        : a.recipient!.sameAs(b.recipient)) &&
    a.grants.length == b.grants.length &&
    a.grants.every(b.grants.contains);

final class _ModelBinding {
  _ModelBinding(
    this.service,
    this.configuration,
    this.controller,
    this.uiLifetime,
    this.draftRevision,
    this.isEmitterCurrent,
    this.isDraftCurrent,
    List<SupportModelConversationMessage>? visibleConversation,
  ) : sessionId = service._runtime.sessionId,
      lifetime = service._runtime.lifetime,
      owner = service._runtime.writeOwner,
      epoch = service._runtime.epoch,
      revision = service._revisions.revision,
      redactor = service._redaction.redactor,
      visibleConversation = visibleConversation == null
          ? null
          : List.unmodifiable(visibleConversation);
  final SupportModelService service;
  final _ModelConfiguration configuration;
  final Object controller, uiLifetime;
  final int draftRevision, lifetime, owner, epoch, revision;
  final String sessionId;
  final bool Function() isEmitterCurrent, isDraftCurrent;
  final SecretRedactor redactor;
  final List<SupportModelConversationMessage>? visibleConversation;
  SupportPermissionPreferences get policy => configuration.policy;
  SupportNativePermissionContext get nativeContext =>
      SupportNativePermissionContext(
        supportSessionId: sessionId,
        epoch: epoch,
        scope: policy.scope,
        recipient: policy.recipient,
      );

  bool current({bool draft = false}) {
    try {
      final r = service._runtime;
      r.checkConfiguration();
      return service._ownerCurrent &&
          isEmitterCurrent() &&
          (!draft || isDraftCurrent()) &&
          r.alive &&
          r.sessionId == sessionId &&
          r.lifetime == lifetime &&
          r.writeOwner == owner &&
          r.epoch == epoch &&
          r.pending == 0 &&
          r.settingsPending == 0 &&
          service._revisions.isStable &&
          service._revisions.revision == revision &&
          r.configurationStable() &&
          r.configurationRevision() == revision &&
          (configuration.directConversation ||
              (r.recipientConfirmed &&
                  r.recipient is SupportResolvedRecipient &&
                  configuration.recipient.recipient.sameAs(
                    (r.recipient as SupportResolvedRecipient).recipient,
                  ))) &&
          _samePolicy(policy, r.snapshot.preferences) &&
          (configuration.nativeSource?.isCurrent ?? true) &&
          identical(redactor, service._redaction.redactor);
    } catch (_) {
      return false;
    }
  }
}
