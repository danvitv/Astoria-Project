import 'package:flutter/material.dart';

import '../models/support_model_view.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_workspace_models.dart';

/// Current native display only. No keys, prompts, routes, IDs or data readers.
class SupportSendSettingsSnapshot extends StatelessWidget {
  const SupportSendSettingsSnapshot({
    super.key,
    required this.settings,
    required this.permissions,
    required this.recipientConfirmed,
    required this.settingsAvailable,
    required this.refusal,
  });

  final SupportAssistantSettings settings;
  final SupportPermissionPreferences? permissions;
  final bool recipientConfirmed, settingsAvailable;
  final SupportModelRefusal refusal;

  String get reason {
    if (!settingsAvailable) return 'Настройки Астории ещё недоступны.';
    if (!settings.hasConfiguredModel) return 'Не выбраны подключение и модель.';
    if (refusal != SupportModelRefusal.none) return refusal.label;
    return '«Отправить» сразу передаёт вопрос и видимый текущий диалог '
        'выбранной модели. Ключ проверяется внутри доверенного транспорта.';
  }

  static String _yes(bool value) => value ? 'да' : 'нет';

  @override
  Widget build(BuildContext context) {
    final scope = permissions?.scope;
    return Padding(
      key: const ValueKey('support_send_settings_snapshot'),
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Снимок настроек отправки — без ключей и содержимого чатов',
          ),
          Text(reason, key: const ValueKey('support_send_block_reason')),
          Text(
            'Профиль выбран: ${_yes(settings.apiConfigId?.isNotEmpty == true)}; '
            'модель выбрана: ${_yes(settings.modelId?.isNotEmpty == true)}; '
            'получатель для внешних источников подтверждён: ${_yes(recipientConfirmed)}.',
          ),
          Text(
            'Лимит ответа: ${settings.maxTokens == -1 ? "не передаётся (-1)" : settings.maxTokens}; '
            'температура: ${settings.temperature}; '
            'reasoning: ${settings.reasoningEffort.name}.',
          ),
          Text(
            'Ролевая сессия выбрана: ${_yes(scope?.gameSessionId != null)}; '
            'передача ролевой истории: ${_yes(permissions?.allows(SupportPermission.modelGameHistory) == true)}; '
            'видимый текущий диалог Астории передаётся с отправкой.',
          ),
          const Text(
            'Состояние ключа этим снимком не проверялось; '
            'ключ не читается в интерфейс и не показывается.',
          ),
          const Text(
            'Для обычного разговора и начала диагностики игровая сессия '
            'не нужна. Другие чаты и диагностические данные без отдельных '
            'разрешений не читаются и не отправляются.',
          ),
        ],
      ),
    );
  }
}
