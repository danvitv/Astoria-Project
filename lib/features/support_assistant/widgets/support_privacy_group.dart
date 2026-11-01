import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/support_consent_selection.dart';
import '../../../shared/widgets/menu_group.dart';
import '../models/support_permission_preferences.dart';
import '../models/support_native_view.dart';
import '../state/support_native_provider.dart';
import '../state/support_data_consent_admission.dart';
import 'support_application_data_consent.dart';
import 'support_privacy_review_sheet.dart';

/// One application-wide read control shared by desktop and mobile. Existing
/// contextual cards may navigate here, but cannot open a picker or grant data.
class SupportPrivacyGroup extends ConsumerStatefulWidget {
  const SupportPrivacyGroup({
    super.key,
    this.focusedPermission,
    this.initialSessionSource,
    this.initialRecipientReview = false,
  });
  final SupportPermission? focusedPermission;
  final SupportConsentSelectionSource? initialSessionSource;
  final bool initialRecipientReview;

  @override
  ConsumerState<SupportPrivacyGroup> createState() => _PrivacyGroupState();
}

class _PrivacyGroupState extends ConsumerState<SupportPrivacyGroup> {
  bool _busy = false;
  Object _lifetime = Object();
  Object? _controller;
  String? _session;
  String? _failure;

  @override
  void deactivate() {
    _lifetime = Object();
    _busy = false;
    super.deactivate();
  }

  Future<void> _change(
    SupportNativeView view,
    bool enabled, {
    bool recovery = false,
  }) async {
    if (_busy || !mounted) return;
    final controller = ref.read(supportNativeConsentControllerProvider);
    if ((enabled || recovery) &&
        !controller.isDisplayedIntentCurrent(view.displayedIntent)) {
      return;
    }
    final admission = ref.read(supportDataConsentAdmissionProvider.notifier);
    final token = _lifetime;
    final runtime = controller.runtime;
    final session = runtime.sessionId, lifetime = runtime.lifetime;
    bool current() =>
        mounted &&
        identical(token, _lifetime) &&
        identical(
          controller,
          ref.read(supportNativeConsentControllerProvider),
        ) &&
        runtime.alive &&
        runtime.sessionId == session &&
        runtime.lifetime == lifetime;
    setState(() {
      _busy = true;
      _failure = null;
    });
    try {
      bool? result;
      if (enabled && !recovery) {
        admission.markOffered();
        result = await requestSupportApplicationDataConsent(
          context: context,
          controller: controller,
          displayedIntent: view.displayedIntent,
          isCurrent: current,
        );
      } else if (!recovery) {
        // This native path retires active reads before its first await. A grant
        // review would wait for idleness and prevent the user from revoking.
        admission.markOffered();
        result = await controller.revokeApplicationDataFromDisplayedIntent(
          view.displayedIntent,
        );
      } else {
        admission.markOffered();
        final review = await controller.prepareReview(
          displayedIntent: view.displayedIntent,
          resolveRecipient: false,
        );
        if (!mounted || !current() || review == null) {
          return;
        }
        final accepted = await showModalBottomSheet<bool>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SupportPrivacyReviewSheet(
            controller: controller,
            review: review,
            isCurrent: current,
            recovery: true,
          ),
        );
        if (!current() || accepted != true) return;
        result = await controller.recoverToDeny(review, confirmed: true);
      }
      if (current() && result == false) {
        setState(
          () => _failure =
              runtime.error ??
              'Не удалось сохранить изменение доступа. Повтори действие.',
        );
      }
    } catch (_) {
      if (current()) {
        setState(
          () => _failure =
              runtime.error ??
              'Не удалось сохранить изменение доступа. Повтори действие.',
        );
      }
    } finally {
      if (mounted && identical(token, _lifetime)) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final view = ref.watch(supportNativeViewProvider);
    final controller = ref.watch(supportNativeConsentControllerProvider);
    if (!identical(controller, _controller) || view.sessionId != _session) {
      _controller = controller;
      _session = view.sessionId;
      _lifetime = Object();
      _busy = false;
      _failure = null;
    }
    final right = view.rights
        .where((r) => r.right == SupportPermission.readApplicationData)
        .firstOrNull;
    final available =
        view.availability == SupportPermissionAvailability.available;
    return MenuGroup(
      key: const ValueKey('support_privacy_group'),
      header: 'Данные и приватность',
      items: [
        IgnorePointer(
          ignoring:
              _busy || (right?.enabled != true && (!available || view.busy)),
          child: MenuSwitchItem(
            key: const ValueKey('support_application_data_switch'),
            label: 'Доступ к данным приложения',
            description: right?.enabled == true
                ? 'Астория самостоятельно читает нужные данные без ключей и токенов. Доступ общий для всех её чатов.'
                : 'Чтение данных отключено. Можно общаться без доступа или включить его одним согласием.',
            value: right?.enabled == true,
            onChanged: (enabled) => _change(view, enabled),
          ),
        ),
        if (!available)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              right?.enabled == true
                  ? 'Новое согласие временно недоступно. Чтение можно отключить.'
                  : 'Новое согласие сейчас недоступно. Чтение не разрешено.',
            ),
          ),
        if (controller.runtime.permissions.applicationDataRevocationUnsaved)
          IgnorePointer(
            ignoring: _busy,
            child: MenuItem(
              key: const ValueKey('support_application_data_revoke_retry'),
              label: 'Повторить сохранение отзыва',
              subtitle:
                  'Чтение заблокировано. Не удалось сохранить OFF для следующего запуска приложения.',
              icon: Icons.refresh,
              onTap: () => _change(view, false),
            ),
          ),
        if (view.availability == SupportPermissionAvailability.corrupt)
          IgnorePointer(
            ignoring: _busy || view.busy,
            child: MenuItem(
              label: 'Сбросить повреждённое согласие',
              icon: Icons.restart_alt,
              onTap: () => _change(view, false, recovery: true),
            ),
          ),
        if (_failure != null || view.error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_failure ?? view.error!),
          ),
      ],
    );
  }
}
