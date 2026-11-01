import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_native_view.dart';
import '../services/support_native_consent_controller.dart';
import 'support_surface_layout.dart';

/// Returns null on decline, false on stale/failed admission, true only after the
/// native permission store accepts this exact consent. No scope or API review.
Future<bool?> requestSupportApplicationDataConsent({
  required BuildContext context,
  required SupportNativeConsentController controller,
  required SupportNativeDisplayedIntent? displayedIntent,
  required bool Function() isCurrent,
}) async {
  if (!context.mounted ||
      !isCurrent() ||
      !controller.isDisplayedIntentCurrent(displayedIntent))
    return false;
  final runtime = controller.runtime;
  final session = runtime.sessionId, lifetime = runtime.lifetime;
  final review = await controller.prepareReview(
    displayedIntent: displayedIntent,
    resolveRecipient: false,
  );
  if (!context.mounted ||
      !isCurrent() ||
      review == null ||
      runtime.sessionId != session ||
      runtime.lifetime != lifetime)
    return false;
  final owner = runtime.writeOwner;
  final configuration = runtime.configurationRevision();
  bool current() =>
      context.mounted &&
      isCurrent() &&
      runtime.alive &&
      runtime.sessionId == session &&
      runtime.lifetime == lifetime &&
      runtime.writeOwner == owner &&
      runtime.pending == 0 &&
      runtime.settingsPending == 0 &&
      runtime.configurationStable() &&
      runtime.configurationRevision() == configuration;
  if (!current()) return false;
  final accepted = await showModalBottomSheet<bool>(
    context: context,
    useRootNavigator: true,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    builder: (_) => SupportApplicationDataConsentSheet(
      controller: controller,
      isCurrent: current,
    ),
  );
  if (!current()) return false;
  if (accepted != true) return null;
  return controller.setGrant(
    review,
    SupportPermission.readApplicationData,
    true,
  );
}

class SupportApplicationDataConsentSheet extends StatefulWidget {
  const SupportApplicationDataConsentSheet({
    super.key,
    required this.controller,
    required this.isCurrent,
  });
  final SupportNativeConsentController controller;
  final bool Function() isCurrent;

  @override
  State<SupportApplicationDataConsentSheet> createState() =>
      _ConsentSheetState();
}

class _ConsentSheetState extends State<SupportApplicationDataConsentSheet> {
  late final void Function() _stop;
  bool _closed = false;

  @override
  void initState() {
    super.initState();
    _stop = widget.controller.runtime.listen(() {
      if (mounted && !_closed) setState(() {});
    });
  }

  @override
  void deactivate() {
    _closed = true;
    super.deactivate();
  }

  @override
  void dispose() {
    _stop();
    super.dispose();
  }

  void _finish(bool accepted) {
    if (_closed ||
        !mounted ||
        ModalRoute.of(context)?.isCurrent != true ||
        (accepted && !widget.isCurrent()))
      return;
    _closed = true;
    Navigator.of(context).pop(accepted);
  }

  @override
  Widget build(BuildContext context) => SheetView(
    title: 'Доступ к данным приложения',
    showBack: false,
    titleWidget: SupportSheetTitle(
      title: 'Доступ к данным приложения',
      onBack: () => _finish(false),
    ),
    onBack: () => _finish(false),
    body: Builder(
      builder: (context) => SupportSheetDecisionBody(
        content: ListView(
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            MenuGroup(
              header: 'Разрешить Астории читать данные для твоих вопросов?',
              description:
                  'Одно согласие для всех чатов Астории, пока ты не отключишь доступ в настройках.',
              items: [
                const Padding(
                  padding: EdgeInsets.all(16),
                  child: Text(
                    'Ассистент самостоятельно находит и читает нужные данные: '
                    'историю, в том числе несколько сессий для сравнения, '
                    'карточки, пресеты и сохранённые Studio presets, память, '
                    'настройки и диагностику. Названия и нужные фрагменты '
                    'используются выбранной моделью, в том числе локальной, '
                    'без отдельных подтверждений каждого источника.\n\n'
                    'API-ключи, токены и другие учётные секреты исключены. '
                    'Чтение ограничено доступными источниками и объёмом контекста — '
                    'это не обещание прочитать всю историю.\n\n'
                    'Передача репорта разработчику — отдельно: сначала точный '
                    'просмотр включённых данных, затем твоё явное согласие. '
                    'Разработчику ничего автоматически не отправляется. Опасные изменения '
                    'по-прежнему требуют точного подтверждения.',
                  ),
                ),
                if (!widget.isCurrent())
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text(
                      'Настройки или сессия изменились. Открой согласие заново.',
                    ),
                  ),
              ],
            ),
          ],
        ),
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            GlazeActionButton(
              key: const ValueKey('support_application_data_consent_accept'),
              label: 'Разрешить чтение',
              maxLabelLines: null,
              icon: Icons.check_rounded,
              expand: true,
              onTap: widget.isCurrent() ? () => _finish(true) : null,
            ),
            const SizedBox(height: 8),
            GlazeActionButton(
              key: const ValueKey('support_application_data_consent_decline'),
              label: 'Продолжить без доступа',
              maxLabelLines: null,
              icon: Icons.close_rounded,
              expand: true,
              onTap: () => _finish(false),
            ),
          ],
        ),
      ),
    ),
  );
}
