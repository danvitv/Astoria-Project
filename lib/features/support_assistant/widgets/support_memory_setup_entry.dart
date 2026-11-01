import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/glaze_toast.dart';
import '../models/support_permission_preferences.dart';
import '../state/support_native_provider.dart';
import '../state/support_memory_setup_provider.dart';
import 'support_action_strip.dart';
import 'support_application_data_consent.dart';
import 'support_memory_setup_sheet.dart';

class SupportMemorySetupEntry extends ConsumerStatefulWidget {
  const SupportMemorySetupEntry({super.key, this.compact = false});
  final bool compact;
  @override
  SupportMemorySetupEntryState createState() => SupportMemorySetupEntryState();
}

class SupportMemorySetupEntryState
    extends ConsumerState<SupportMemorySetupEntry> {
  bool _open = false;
  Object _lifetime = Object();
  @override
  void deactivate() {
    _lifetime = Object();
    super.deactivate();
  }

  Future<void> open() async {
    if (_open || !mounted) return;
    final controller = ref.read(supportNativeConsentControllerProvider);
    final runtime = controller.runtime;
    final lifetime = _lifetime;
    final session = runtime.sessionId, nativeLifetime = runtime.lifetime;
    final anchor = controller.view.displayedIntent;
    // Subscription retains ORIGINAL controller identity, never reads replacement.
    var original = true;
    final subscription = ref.listenManual(
      supportNativeConsentControllerProvider,
      (before, after) {
        if (!identical(controller, after)) original = false;
      },
    );
    bool uiCurrent() =>
        mounted &&
        original &&
        identical(lifetime, _lifetime) &&
        runtime.alive &&
        runtime.sessionId == session &&
        runtime.lifetime == nativeLifetime;
    setState(() => _open = true);
    try {
      if (runtime.snapshot.preferences?.allows(
            SupportPermission.readApplicationData,
          ) !=
          true) {
        final granted = await requestSupportApplicationDataConsent(
          context: context,
          controller: controller,
          displayedIntent: anchor,
          isCurrent: uiCurrent,
        );
        if (mounted && uiCurrent() && granted == true)
          GlazeToast.show(
            context,
            'Чтение разрешено. Нажми «Память» ещё раз: изменения потребуют отдельного точного подтверждения.',
          );
        return;
      }
      final factory = ref.read(supportMemorySetupFactoryProvider);
      final service = factory(uiCurrent: uiCurrent);
      if (!service.start(anchor)) {
        service.retire();
        if (mounted)
          GlazeToast.show(
            context,
            'Мастер недоступен: исходный владелец или доступ изменились.',
          );
        return;
      }
      try {
        await showModalBottomSheet<void>(
          context: context,
          useRootNavigator: true,
          isScrollControlled: true,
          backgroundColor: Colors.transparent,
          builder: (_) => SupportMemorySetupSheet(service: service),
        );
      } finally {
        service.retire();
      }
    } finally {
      subscription.close();
      if (mounted) setState(() => _open = false);
    }
  }

  @override
  Widget build(BuildContext context) => widget.compact
      ? SupportActionTile(
          key: const ValueKey('support_memory_open'),
          icon: Icons.auto_stories_outlined,
          label: 'Память',
          tooltip: 'Мастер Memory Books',
          selected: _open,
          onTap: _open ? null : open,
        )
      : IconButton(
          key: const ValueKey('support_memory_open'),
          tooltip: 'Мастер Memory Books',
          icon: const Icon(Icons.auto_stories_outlined),
          isSelected: _open,
          onPressed: _open ? null : open,
        );
}
