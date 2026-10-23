part of 'support_provider_action_service.dart';

extension SupportProviderActionPreparation on SupportProviderActionService {
  Future<SupportProviderReview?> prepareCreate(
    SupportProviderUiIntent intent,
    SupportProviderSetupInput input,
  ) async {
    final b = intent._binding;
    if (!await _fresh(b, changes: true) || !_current(b, changes: true)) {
      return null;
    }
    try {
      final providerId = switch (input.protocol) {
        'openai' || 'openai_responses' => 'openai',
        'anthropic' => 'anthropic',
        'gemini' => 'gemini',
        'openrouter' => 'openrouter',
        'custom_chat_completion' => 'custom_chat_completion',
        _ => null,
      };
      if (providerId == null) return null;
      // Identity allocation precedes the immutable review. No supplied ID/key.
      final draft = KeylessApiConfigDraft(
        nativeId: NativeKeylessConnectionId.generate(),
        displayName: input.name,
        providerId: providerId,
        protocol: input.protocol,
        endpoint: input.endpoint,
        model: input.model,
        maxTokens: input.maxTokens,
        contextSize: input.contextSize,
        temperature: input.temperature,
      );
      final destination = _destination(draft.view);
      if (destination == null) return null;
      final review = SupportProviderReview._(
        b,
        SupportProviderActionKind.create,
        input.purpose,
        destination,
        null,
        draft.view,
        draft: draft,
      );
      return _current(b, changes: true) && projectReview(review) != null
          ? review
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<SupportProviderConnections?> observeConnections(
    SupportProviderUiIntent intent,
    SupportProviderPurpose purpose,
  ) async {
    final b = intent._binding;
    return _readLocal(b, () async {
      final ids = List<String>.unmodifiable(
        await readConnectionIds(() => _current(b)),
      );
      if (!_current(b) ||
          ids.length > 256 ||
          ids.toSet().length != ids.length) {
        throw SupportAuthorizationDenied();
      }
      final choices = <SupportProviderChoice>[];
      for (final id in ids) {
        if (!_current(b) ||
            id.length > 128 ||
            currentRedactor().redactText(id) != id) {
          throw SupportAuthorizationDenied();
        }
        // Cold restart: a protected key can equal an otherwise benign label.
        // The trusted root reads/registers it under this SAME local-read lease
        // before native inspection or minting a handle with variable fields.
        // Metadata is display safety ONLY, never ownership/model-egress proof.
        SupportProviderReadiness? metadata;
        try {
          metadata = await readReadiness(id, purpose, () => _current(b));
        } catch (_) {
          // No variable exception text or guessed absence. This row is skipped,
          // but the original scope is still checked before considering another.
        }
        if (!_current(b)) throw SupportAuthorizationDenied();
        if (!_usableProviderReadiness(metadata)) continue;
        final observation = await apiRepo.inspectKeyless(id);
        if (!_current(b)) throw SupportAuthorizationDenied();
        // Unsafe/unowned legacy rows do not become editable by listing them.
        // A NEW update can acquire native protected proof at final application.
        if (observation == null || _destination(observation.view) == null) {
          continue;
        }
        final choice = SupportProviderChoice._(b, observation, purpose);
        if (choice.value == null) continue;
        choices.add(choice);
      }
      if (!_current(b)) throw SupportAuthorizationDenied();
      return SupportProviderConnections._(choices);
    });
  }

  Future<SupportProviderReview?> prepareUpdate(
    SupportProviderChoice choice,
    SupportProviderSetupInput input,
  ) async {
    final b = choice._binding;
    if (!await _fresh(b, changes: true) || !_current(b, changes: true)) {
      return null;
    }
    final original = choice._view;
    if (input.purpose != choice.purpose ||
        input.protocol != original.protocol ||
        input.endpoint != original.endpoint) {
      return null;
    }
    final observed = await _readLocal(
      b,
      () => apiRepo.inspectKeyless(original.connectionId),
    );
    if (!_current(b, changes: true) || observed == null) return null;
    try {
      if (!apiRepo.sameKeylessObservation(choice._observation, observed)) {
        return null;
      }
      final patch = KeylessApiConfigPatch(
        displayName: input.name,
        model: input.model,
        maxTokens: input.maxTokens,
        contextSize: input.contextSize,
        temperature: input.temperature,
      );
      final after = patch.applyTo(original);
      final destination = _destination(after);
      if (destination == null || after == original) return null;
      final review = SupportProviderReview._(
        b,
        SupportProviderActionKind.update,
        input.purpose,
        destination,
        original,
        after,
        choice: choice,
        patch: patch,
      );
      return _current(b, changes: true) && projectReview(review) != null
          ? review
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<SupportProviderReview?> prepareUndo(
    SupportProviderUiIntent intent,
    SupportProviderApplied applied,
  ) async {
    final b = intent._binding;
    if (!identical(applied._binding.service, this) ||
        !identical(applied._binding, b) ||
        !canUndo(applied) ||
        !await _fresh(b, changes: true) ||
        !canUndo(applied)) {
      return null;
    }
    final observed = await _readLocal(
      b,
      () => apiRepo.inspectKeyless(applied._view.connectionId),
    );
    if (!_current(b, changes: true) || observed == null || !canUndo(applied)) {
      return null;
    }
    try {
      if (!apiRepo.sameKeylessObservation(
        applied._undoObservation!,
        observed,
      )) {
        return null;
      }
      final before = applied._receipt.after;
      final after = applied._receipt.before;
      if (before == null || after == null) return null;
      final destination = _destination(after);
      if (destination == null) return null;
      final review = SupportProviderReview._(
        b,
        SupportProviderActionKind.undo,
        applied.purpose,
        destination,
        before,
        after,
        undo: applied,
      );
      return projectReview(review) != null && _current(b, changes: true)
          ? review
          : null;
    } catch (_) {
      return null;
    }
  }

  Future<SupportProviderReadiness?> projectReadiness(
    SupportProviderConnectionHandle handle,
  ) async {
    final b = handle._binding;
    return _readLocal(b, () async {
      if (handle.value == null) throw SupportAuthorizationDenied();
      final observed = await apiRepo.inspectKeyless(handle._view.connectionId);
      if (!_current(b) ||
          observed == null ||
          observed.view != handle._view ||
          handle.value == null) {
        throw SupportAuthorizationDenied();
      }
      final metadata = await readReadiness(
        handle._view.connectionId,
        handle.purpose,
        () => _current(b) && handle.value != null,
      );
      if (!_current(b) ||
          handle.value == null ||
          metadata == null ||
          !_usableProviderReadiness(metadata)) {
        throw SupportAuthorizationDenied();
      }
      // This lane has NEVER contacted a provider. Callback cannot manufacture a
      // test result or turn keySaved/configPrepared into provider evidence.
      return SupportProviderReadiness(
        configurationSaved: true,
        credentialConfigured: metadata.credentialConfigured,
        characterCount: metadata.characterCount,
      );
    });
  }
}

bool _usableProviderReadiness(SupportProviderReadiness? metadata) =>
    metadata != null &&
    metadata.configurationSaved &&
    metadata.characterCount >= 0 &&
    metadata.characterCount <= 65536 &&
    (metadata.credentialConfigured
        ? metadata.characterCount > 0
        : metadata.characterCount == 0);
