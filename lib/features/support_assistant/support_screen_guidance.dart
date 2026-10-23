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
    final view = controller.view;
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
            SupportGuidanceTarget.recipient => view.needsRecipientConfirmation,
            SupportGuidanceTarget.themeScope =>
              scope?.safeCategories.contains(SupportSafeCategory.theme) != true,
            SupportGuidanceTarget.connectionsScope =>
              scope?.safeCategories.contains(SupportSafeCategory.connections) !=
                  true,
            _ => true,
          };
        })
        .toList(growable: false);
    final needsModel =
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
      if (needsModel && emitter != null) ...[
        if (scope?.safeCategories.contains(SupportSafeCategory.connections) !=
            true)
          SupportGuidanceTarget.connectionsScope,
        if (policy?.allows(
              SupportGuidanceTarget.readSafeSettings.permission!,
            ) !=
            true)
          SupportGuidanceTarget.readSafeSettings,
      ],
      ...needed.where(
        (target) =>
            target == SupportGuidanceTarget.gameSession ||
            target == SupportGuidanceTarget.supportSession ||
            target == SupportGuidanceTarget.readGameData,
      ),
      if (needsModel && emitter != null && view.needsRecipientConfirmation)
        SupportGuidanceTarget.recipient,
      ...needed,
    }.take(4).toList(growable: false);
    if (ordered.isNotEmpty || emitter == null) {
      if (emitter == null) _modelUi.rejectNoModel();
      _publishGuidance(
        ordered.isNotEmpty
            ? ordered
            : const [
                SupportGuidanceTarget.connection,
                SupportGuidanceTarget.providerSetup,
              ],
        draft,
        session,
      );
      // Proposal is not acceptance: preserve the draft, never append twice,
      // silently resend, enable a permission, or call the model here.
      return Future.value(false);
    }
    return _modelUi.send(emitter, draft, context);
  }

  Iterable<Widget> _pendingGuidance(String session) sync* {
    if (_guidance.isEmpty ||
        _guidanceSession != session ||
        _guidanceDraft?.isCurrent() != true) {
      return;
    }
    yield const Text(
      'Для этого предлагаю нужные настройки ниже. Ничего не включено; '
      'твой текст сохранён в поле. После выбора отправь его снова.',
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
