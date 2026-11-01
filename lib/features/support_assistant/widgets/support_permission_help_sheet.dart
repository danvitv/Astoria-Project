import 'package:flutter/material.dart';

import '../../../shared/widgets/glaze_action_button.dart';
import '../../../shared/widgets/glaze_bottom_sheet.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_permission_scope.dart';
import '../services/support_native_runtime.dart';

/// Finite native destinations, never interpreted provider/model/user text.
enum SupportPermissionHelp {
  gameHistory,
  supportHistory,
  safeSettings,
  connections,
  recipient,
  diagnosticsUnavailable,
  gameDataUnavailable,
  snippetsUnavailable,
  attachmentsUnavailable,
  reportAttachmentsUnavailable,
  prerequisiteUnavailable;

  static SupportPermissionHelp forRight(
    SupportPermission right,
    SupportPermissionPreferences policy, {
    required bool needsRecipientConfirmation,
  }) {
    final scope = policy.scope;
    switch (right) {
      case SupportPermission.readApplicationData:
        break;
      case SupportPermission.readDiagnostics:
        return diagnosticsUnavailable;
      case SupportPermission.modelGameData:
        return gameDataUnavailable;
      case SupportPermission.modelPromptProviderSnippets:
        return snippetsUnavailable;
      case SupportPermission.modelAttachments:
        return attachmentsUnavailable;
      case SupportPermission.reportPersonalDataAttachments:
        return reportAttachmentsUnavailable;
      case SupportPermission.readGameData:
      case SupportPermission.modelGameHistory:
      case SupportPermission.reportGameHistory:
        if (scope?.hasGameHistory != true || scope?.gameSessionId == null) {
          return gameHistory;
        }
        if (right == SupportPermission.readGameData &&
            scope!.selectedData.isNotEmpty) {
          return gameDataUnavailable;
        }
      case SupportPermission.modelSupportHistory:
      case SupportPermission.reportSupportHistory:
        if (scope?.hasSupportHistory != true) return supportHistory;
      case SupportPermission.readSafeSettings:
        if (scope?.safeCategories.any(
              (category) =>
                  category == SupportSafeCategory.theme ||
                  category == SupportSafeCategory.connections,
            ) !=
            true) {
          return safeSettings;
        }
      case SupportPermission.modelSafeSettingsDiagnostics:
        if (scope?.safeCategories.contains(SupportSafeCategory.connections) !=
            true) {
          return connections;
        }
      case SupportPermission.confirmedSettingsChanges:
      case SupportPermission.confirmedConnectionTests:
        break;
    }
    if (needsRecipientConfirmation &&
        {
          SupportPermission.modelGameHistory,
          SupportPermission.modelSupportHistory,
          SupportPermission.modelSafeSettingsDiagnostics,
          SupportPermission.confirmedConnectionTests,
        }.contains(right)) {
      return recipient;
    }
    return prerequisiteUnavailable;
  }

  String get description => switch (this) {
    gameHistory => 'Сначала явно выбери область ролевой истории.',
    supportHistory =>
      'Сначала явно выбери область истории текущей сессии Астории.',
    safeSettings =>
      'Выбери одну безопасную категорию: оформление или подключения. '
          'Это только область доступа, без ключей и произвольных настроек.',
    connections =>
      'Для этого права доступна безопасная проекция подключений, '
          'без ключей. Оформление и сбор диагностики сюда не входят.',
    recipient =>
      'Область уже выбрана. Сначала проверь и подтверди текущего получателя.',
    diagnosticsUnavailable =>
      'Сбор структурированной диагностики пока не подключён. Разрешение не включено.',
    gameDataUnavailable =>
      'Загрузчики выбранных ролевых данных пока не подключены. Разрешение не включено.',
    snippetsUnavailable =>
      'Загрузчик фрагментов промпта и провайдера пока не подключён. Разрешение не включено.',
    attachmentsUnavailable =>
      'Загрузчик вложений для модели пока не подключён. Разрешение не включено.',
    reportAttachmentsUnavailable =>
      'Загрузчики личных данных и вложений для репорта пока не подключены. Разрешение не включено.',
    prerequisiteUnavailable =>
      'Предпосылки этого права сейчас недоступны. Разрешение не включено.',
  };
}

/// Scope-only review or fixed explanation. Returns one explicit category;
/// the original caller owns the native write. No grants, readers or resolvers.
class SupportPermissionHelpSheet extends StatefulWidget {
  const SupportPermissionHelpSheet({
    super.key,
    required this.help,
    required this.runtime,
    required this.isCurrent,
  });
  final SupportPermissionHelp help;
  final SupportNativeRuntime runtime;
  final bool Function() isCurrent;

  static Future<SupportSafeCategory?> show(
    BuildContext context, {
    required SupportPermissionHelp help,
    required SupportNativeRuntime runtime,
    required bool Function() isCurrent,
  }) => GlazeBottomSheet.show<SupportSafeCategory>(
    context,
    title: 'Предпосылки разрешения',
    child: SupportPermissionHelpSheet(
      help: help,
      runtime: runtime,
      isCurrent: isCurrent,
    ),
  );

  @override
  State<SupportPermissionHelpSheet> createState() => _PermissionHelpState();
}

class _PermissionHelpState extends State<SupportPermissionHelpSheet> {
  late final void Function() _stop;
  bool _closed = false;
  ModalRoute<dynamic>? _route;
  NavigatorState? _navigator;

  @override
  void initState() {
    super.initState();
    _stop = widget.runtime.listen(() {
      if (mounted && !_closed) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of(context);
    _navigator ??= Navigator.of(context);
  }

  void _finish([SupportSafeCategory? category]) {
    if (!mounted || _closed) return;
    final route = _route;
    if (!mounted ||
        _closed ||
        route?.isCurrent == false ||
        route?.animation?.status == AnimationStatus.reverse ||
        (category != null && !widget.isCurrent()) ||
        !mounted ||
        _closed ||
        route?.isCurrent == false ||
        route?.animation?.status == AnimationStatus.reverse) {
      return;
    }
    _closed = true;
    _navigator?.pop(category);
  }

  @override
  void deactivate() {
    _closed = true;
    super.deactivate();
  }

  @override
  void dispose() {
    _closed = true;
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.all(16),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(widget.help.description),
        if (widget.help == SupportPermissionHelp.safeSettings ||
            widget.help == SupportPermissionHelp.connections) ...[
          const SizedBox(height: 12),
          const Text(
            'Выбор области не включает право. После подтверждения '
            'включи нужное разрешение отдельным нажатием.',
          ),
          for (final category in [
            if (widget.help == SupportPermissionHelp.safeSettings)
              SupportSafeCategory.theme,
            SupportSafeCategory.connections,
          ])
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: GlazeActionButton(
                key: ValueKey('support_permission_help_${category.name}'),
                label: category == SupportSafeCategory.theme
                    ? 'Выбрать только оформление'
                    : 'Выбрать только подключения',
                icon: Icons.check_rounded,
                expand: true,
                onTap: !_closed && widget.isCurrent()
                    ? () => _finish(category)
                    : null,
              ),
            ),
        ],
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: GlazeActionButton(
            key: const ValueKey('support_permission_help_close'),
            label: 'Закрыть',
            icon: Icons.close,
            expand: true,
            onTap: () => _finish(),
          ),
        ),
      ],
    ),
  );
}
