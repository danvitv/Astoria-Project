part of 'support_model_service.dart';

/// Trusted-only configuration. Never exported in preview/run state or prompts.
final class _ModelConfiguration {
  const _ModelConfiguration(
    this.settings,
    this.api,
    this.key,
    this.policy,
    this.recipient,
  );
  final SupportAssistantSettings settings;
  final ApiConfig api;
  final String key;
  final SupportPermissionPreferences policy;
  final SupportResolvedRecipient recipient;

  static Future<_ModelConfiguration> read(
    _ModelReadOperation operation,
    String id, {
    bool prime = false,
    void Function()? checkpoint,
  }) async {
    final s = operation.service;
    final settings = await operation.settings(id, checkpoint);
    operation.check();
    if (!settings.hasConfiguredModel) _refuse(SupportModelRefusal.noModel);
    final api = await operation.checked(
      () => s._apiRepo.getById(settings.apiConfigId!),
      checkpoint,
    );
    if (api == null) _refuse(SupportModelRefusal.unavailable);
    if (!api.stream ||
        api.mode != 'chat' ||
        api.extraRequestParameters.any((parameter) => parameter.enabled)) {
      _refuse(SupportModelRefusal.unsupported);
    }
    // Current durable API row is authoritative, exactly as for native routing.
    // A same-ID vault slot is not evidence of this row's current credential.
    final key = api.apiKey;
    if (key.isEmpty ||
        key.length > 8192 ||
        RegExp(r'[\x00-\x20\x7f]').hasMatch(key)) {
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
        Uri.parse(recipient.recipient.nativeRoute).scheme != 'https') {
      _refuse(SupportModelRefusal.unsupported);
    }
    if (!runtime.recipientConfirmed ||
        runtime.recipient is! SupportResolvedRecipient ||
        !recipient.recipient.sameAs(policy.recipient) ||
        !recipient.recipient.sameAs(
          (runtime.recipient as SupportResolvedRecipient).recipient,
        ) ||
        !recipient.context.sameAs(runtime.recipientContext) ||
        !_samePolicy(policy, runtime.snapshot.preferences)) {
      _refuse(SupportModelRefusal.recipientRequired);
    }
    operation.check();
    checkpoint?.call();
    return _ModelConfiguration(settings, api, key, policy, recipient);
  }

  bool sameAs(_ModelConfiguration other) =>
      api == other.api &&
      key == other.key &&
      _sameSettings(settings, other.settings) &&
      _samePolicy(policy, other.policy) &&
      recipient.recipient.sameAs(other.recipient.recipient) &&
      recipient.context.sameAs(other.recipient.context);

  ChatTransportRequest request(List<SupportModelPreviewText> messages) =>
      ChatTransportRequest(
        endpoint: recipient.recipient.nativeRoute,
        apiKey: key,
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
        requestReasoning:
            settings.reasoningEffort != SupportReasoningEffort.off,
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
  ) : sessionId = service._runtime.sessionId,
      lifetime = service._runtime.lifetime,
      owner = service._runtime.writeOwner,
      epoch = service._runtime.epoch,
      revision = service._revisions.revision,
      redactor = service._redaction.redactor;
  final SupportModelService service;
  final _ModelConfiguration configuration;
  final Object controller, uiLifetime;
  final int draftRevision, lifetime, owner, epoch, revision;
  final String sessionId;
  final bool Function() isEmitterCurrent, isDraftCurrent;
  final SecretRedactor redactor;
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
          r.recipientConfirmed &&
          r.recipient is SupportResolvedRecipient &&
          configuration.recipient.recipient.sameAs(
            (r.recipient as SupportResolvedRecipient).recipient,
          ) &&
          _samePolicy(policy, r.snapshot.preferences) &&
          identical(redactor, service._redaction.redactor);
    } catch (_) {
      return false;
    }
  }
}
