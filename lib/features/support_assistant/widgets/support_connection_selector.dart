import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/credentials/api_connection_metadata.dart';
import '../../../shared/widgets/menu_group.dart';
import '../../../shared/widgets/sheet_view.dart';
import '../state/support_provider_ui_binding.dart';
import '../state/support_workspace_provider.dart';
import 'support_privacy_group.dart';
import 'support_provider_entry.dart';
import 'support_settings_pickers.dart';
import 'support_surface_layout.dart';

/// The API row owns the same trusted provider entry as the native header.
class SupportConnectionSelector extends ConsumerStatefulWidget {
  const SupportConnectionSelector({
    super.key,
    required this.notifier,
    required this.connections,
    required this.currentValue,
    this.isOriginalUiCurrent,
  });

  final SupportWorkspaceNotifier notifier;
  final List<ApiConnectionMetadata> connections;
  final String currentValue;
  final bool Function()? isOriginalUiCurrent;

  @override
  ConsumerState<SupportConnectionSelector> createState() => _SelectorState();
}

class _SelectorState extends ConsumerState<SupportConnectionSelector> {
  final _entry = GlobalKey<SupportProviderEntryState>();
  Object _lifetime = Object();
  ModalRoute<void>? _route;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = _route = ModalRoute.of<void>(context);
    route?.popped.then((_) => _lifetime = Object());
  }

  void _open() {
    final lifetime = _lifetime = Object();
    final notifier = widget.notifier;
    final originalUi = widget.isOriginalUiCurrent;
    bool original() =>
        mounted &&
        identical(lifetime, _lifetime) &&
        (_route == null || _route!.isActive) &&
        identical(notifier, ref.read(supportWorkspaceProvider.notifier)) &&
        (originalUi?.call() ?? true);
    // Capture BEFORE opening the picker, never when its Add/Use completes.
    final intent = notifier.captureSettingsIntent(
      isOriginalUiCurrent: original,
    );
    if (intent == null || !intent.isCurrent) return;
    SupportSettingsPickers.connection(
      context,
      notifier,
      widget.connections,
      intent: intent,
      onAdd: () {
        if (!intent.isCurrent) return;
        _entry.currentState?.open(
          createForAstoria: true,
          isOriginalUiCurrent: () => intent.isCurrent,
          onUseConnection: (SupportProviderConnectionHandle bound) {
            if (!intent.isCurrent) return false;
            final value = bound.value; // Reproject the original opaque handle.
            if (value == null || !intent.isCurrent) return false;
            // Start the original settings job synchronously, before UI signals.
            notifier.selectConnection(
              value.connectionId,
              defaultModelId: value.model,
              intent: intent,
            );
            return true;
          },
        );
      },
    );
  }

  void _openPermissions() {
    if (!mounted ||
        _route?.isActive == false ||
        widget.isOriginalUiCurrent?.call() == false) {
      return;
    }
    showModalBottomSheet<void>(
      context: context,
      useRootNavigator: true,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (_) => SheetView(
        title: 'Доступ к настройке провайдера',
        showBack: false,
        titleWidget: SupportSheetTitle(
          title: 'Доступ к настройке провайдера',
          onBack: () => Navigator.of(context, rootNavigator: true).pop(),
        ),
        onBack: () => Navigator.of(context, rootNavigator: true).pop(),
        body: Builder(
          builder: (context) => SingleChildScrollView(
            padding: supportSurfacePadding(context),
            child: const SupportPrivacyGroup(),
          ),
        ),
      ),
    );
  }

  @override
  void deactivate() {
    _lifetime = Object();
    super.deactivate();
  }

  @override
  void dispose() {
    _lifetime = Object();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: [
      MenuSelectorItem(
        key: const ValueKey('support_connection_selector'),
        label: 'API',
        currentValue: widget.currentValue,
        onTap: _open,
      ),
      Offstage(
        child: SupportProviderEntry(
          key: _entry,
          onOpenPermissions: _openPermissions,
        ),
      ),
    ],
  );
}
