part of 'support_assistant_screen.dart';

extension _ScreenRecipientReview on _SupportAssistantScreenState {
  Future<bool> _reviewRecipientFromSend(String session) async {
    if (!mounted || _sheetOpen) return false;
    final controller = ref.read(supportNativeConsentControllerProvider);
    final runtime = controller.runtime;
    final view = controller.view;
    final lifetime = runtime.lifetime;
    final parentRoute = ModalRoute.of(context);
    bool originalUi() =>
        mounted &&
        runtime.alive &&
        runtime.sessionId == session &&
        runtime.lifetime == lifetime &&
        (parentRoute?.isActive ?? true) &&
        identical(
          controller,
          ref.read(supportNativeConsentControllerProvider),
        ) &&
        mounted &&
        runtime.alive &&
        runtime.sessionId == session &&
        runtime.lifetime == lifetime &&
        (parentRoute?.isActive ?? true);
    if (!originalUi() ||
        !controller.isDisplayedIntentCurrent(view.displayedIntent)) {
      return false;
    }
    _sheetOpen = true; // Synchronous latch, before refresh/metadata callbacks.
    int? reviewOwner;
    var confirming = false;
    try {
      final review = await controller.prepareReview(
        displayedIntent: view.displayedIntent,
      );
      if (!mounted || !originalUi()) return false;
      if (review == null) {
        GlazeToast.show(
          context,
          'Подтверждение получателя недоступно. Проверь подключение и модель.',
        );
        return false;
      }
      reviewOwner = runtime.writeOwner;
      bool reviewCurrent() =>
          originalUi() &&
          controller.isDisplayedIntentCurrent(review.view.displayedIntent) &&
          originalUi();
      if (!mounted || !reviewCurrent() || parentRoute?.isCurrent == false) {
        return false;
      }
      ModalRoute<bool>? recipientRoute;
      final decision = await showModalBottomSheet<bool>(
        context: context,
        useRootNavigator: true,
        isScrollControlled: true,
        backgroundColor: Colors.transparent,
        builder: (sheetContext) {
          recipientRoute ??= ModalRoute.of<bool>(sheetContext);
          return SupportPrivacyReviewSheet(
            controller: controller,
            review: review,
            isCurrent: () =>
                recipientRoute?.isCurrent == true && reviewCurrent(),
          );
        },
      );
      if (!reviewCurrent() ||
          parentRoute?.isCurrent == false ||
          decision != true) {
        return false;
      }
      confirming = true;
      final saved = await controller.confirmRecipient(review);
      if (!mounted || !originalUi() || parentRoute?.isCurrent == false) {
        return false;
      }
      GlazeToast.show(
        context,
        saved && runtime.recipientConfirmed
            ? 'Получатель подтверждён. Нажми «Отправить» ещё раз для проверки точного prompt.'
            : 'Получатель не подтверждён. Проверь подключение и модель.',
      );
      // Recipient selection is not prompt approval or user-message acceptance.
      // A second explicit Send uses a fresh emitter; the exact input remains.
      return false;
    } catch (_) {
      if (mounted && originalUi()) {
        GlazeToast.show(
          context,
          'Не удалось проверить получателя. Текст остался в поле ввода.',
        );
      }
      return false;
    } finally {
      if (!confirming && originalUi() && runtime.writeOwner == reviewOwner) {
        controller.cancelReview();
      }
      _sheetOpen = false;
    }
  }
}
