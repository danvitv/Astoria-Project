part of 'support_assistant_screen.dart';

extension _ScreenGuidance on _SupportAssistantScreenState {
  Future<void> _openGuidance(SupportGuidanceTarget target) async {
    if (!mounted || _sheetOpen) return;
    _sheetOpen = true;
    try {
      if (target == SupportGuidanceTarget.providerSetup) {
        await _providerEntry.currentState?.open();
      } else if (target == SupportGuidanceTarget.themeSetup) {
        await _themeEntry.currentState?.open();
      } else {
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SupportGuidanceSheet(target: target),
        );
      }
    } finally {
      _sheetOpen = false;
    }
  }

  Future<bool> _sendWithGuidance(
    SupportModelUiEmitter? emitter,
    SupportComposerDraft draft,
    String session,
  ) {
    if (!mounted ||
        !draft.isCurrent() ||
        (emitter != null && !emitter.isCurrent)) {
      return Future.value(false);
    }
    final controller = ref.read(supportNativeConsentControllerProvider);
    final runtime = controller.runtime;
    final policy = runtime.snapshot.preferences;
    final scope = policy?.scope;
    final recipientConfirmed = runtime.recipientConfirmed;
    final requested = const SupportGuidancePlanner().targetsFor(
      text: draft.text,
    );
    final needed = requested
        .where((target) {
          final permission = target.permission;
          if (permission != null) return policy?.allows(permission) != true;
          return switch (target) {
            SupportGuidanceTarget.gameSession =>
              scope?.gameHistoryExtent != SupportHistoryExtent.wholeSession,
            SupportGuidanceTarget.supportSession =>
              scope?.supportHistoryExtent != SupportHistoryExtent.wholeSession,
            SupportGuidanceTarget.recipient => !recipientConfirmed,
            SupportGuidanceTarget.themeScope =>
              scope?.safeCategories.contains(SupportSafeCategory.theme) != true,
            SupportGuidanceTarget.connectionsScope =>
              scope?.safeCategories.contains(SupportSafeCategory.connections) !=
                  true,
            _ => true,
          };
        })
        .toList(growable: false);
    final diagnostics = RegExp(
      r'диагност|diagnos|последн[а-я]* сесси|recent sessions',
      caseSensitive: false,
    ).hasMatch(draft.text);
    final needsModel =
        diagnostics ||
        requested.isEmpty ||
        requested.any(
          (target) => switch (target) {
            SupportGuidanceTarget.recipient ||
            SupportGuidanceTarget.modelGameHistory ||
            SupportGuidanceTarget.modelSupportHistory ||
            SupportGuidanceTarget.modelGameData ||
            SupportGuidanceTarget.modelSafeSettingsDiagnostics ||
            SupportGuidanceTarget.modelPromptProviderSnippets ||
            SupportGuidanceTarget.modelAttachments => true,
            _ => false,
          },
        );
    final ordered = <SupportGuidanceTarget>{
      ...needed.where(
        (target) =>
            target == SupportGuidanceTarget.gameSession ||
            target == SupportGuidanceTarget.supportSession ||
            target == SupportGuidanceTarget.readGameData,
      ),
      if (needsModel && emitter != null && !recipientConfirmed)
        SupportGuidanceTarget.recipient,
      ...needed,
    }.take(4).toList(growable: false);
    // A conversation does not grant access to game history or diagnostics.
    // Optional data proposals must not prevent an otherwise valid plain prompt.
    final blocked =
        emitter == null ||
        (needsModel && !recipientConfirmed) ||
        (!needsModel && ordered.isNotEmpty);
    final proposals = <SupportGuidanceTarget>{
      if (diagnostics) SupportGuidanceTarget.gameSession,
      ...ordered,
    }.take(4).toList(growable: false);
    if (blocked) {
      if (emitter == null) _modelUi.rejectNoModel();
      _publishGuidance(
        proposals.isNotEmpty
            ? proposals
            : const [
                SupportGuidanceTarget.connection,
                SupportGuidanceTarget.providerSetup,
              ],
        draft,
        session,
      );
      if (emitter != null && needsModel && !recipientConfirmed) {
        // Send itself opens the prerequisite, not another card/menu detour.
        return _reviewRecipientFromSend(session);
      }
      // A proposal is not acceptance: preserve the draft, do not grant or resend.
      return Future.value(false);
    }
    _publishGuidance(proposals, draft, session, blocking: false);
    final originalController = _guidanceController;
    final originalLifetime = _guidanceLifetime;
    final accepted = _modelUi.send(emitter, draft, context);
    accepted.then((value) {
      if (mounted &&
          value &&
          identical(originalController, _guidanceController) &&
          identical(
            originalController,
            ref.read(supportNativeConsentControllerProvider),
          ) &&
          originalLifetime == _guidanceLifetime &&
          controller.runtime.lifetime == originalLifetime &&
          controller.runtime.sessionId == session &&
          draft.isCurrent() &&
          _guidanceSession == session) {
        _retainGuidance();
      }
    }, onError: (_) {});
    return accepted;
  }

  Iterable<Widget> _pendingGuidance(String session) sync* {
    final controller = ref.read(supportNativeConsentControllerProvider);
    if (!_showSendSnapshot ||
        _guidanceSession != session ||
        !identical(_guidanceController, controller) ||
        _guidanceLifetime != controller.runtime.lifetime ||
        (!_guidancePersistent && _guidanceDraft?.isCurrent() != true)) {
      return;
    }
    final workspace = ref.watch(supportWorkspaceProvider);
    yield SupportSendSettingsSnapshot(
      settings: workspace.settings,
      permissions: controller.runtime.snapshot.preferences,
      recipientConfirmed: controller.runtime.recipientConfirmed,
      settingsAvailable: workspace.settingsAvailable,
      refusal: _modelUi.refusal,
    );
    if (_guidance.isEmpty) return;
    yield Text(
      _guidanceBlocking
          ? 'Для этого предлагаю нужные настройки ниже. Ничего не включено; '
                'твой текст сохранён в поле. После выбора отправь его снова.'
          : 'Можно начать диагностику без выбора игровой сессии. '
                'Вот список последних сессий — какую хочешь разобрать? '
                'Открой список ниже: это только метаданные. '
                'Содержимое требует отдельных разрешений.',
      key: ValueKey('support_contextual_guidance'),
    );
    for (final target in _guidance) {
      yield Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: SupportCardView(
          card: SupportGuidanceCard(target: target),
          onGuidance: _openGuidance,
        ),
      );
    }
  }
}
