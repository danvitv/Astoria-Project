part of 'support_assistant_screen.dart';

extension _ScreenGuidance on _SupportAssistantScreenState {
  Future<void> _openGuidance(SupportGuidanceTarget target) async {
    if (!mounted || _sheetOpen) return;
    _setSheetOpen(true);
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
      if (mounted) _setSheetOpen(false);
    }
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
          : 'Доступ к данным включается одним согласием. '
                'После этого Астория сама выбирает нужные источники.',
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
