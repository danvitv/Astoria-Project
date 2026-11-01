import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/widgets/sheet_view.dart';
import '../models/support_guidance_target.dart';
import '../services/support_native_consent_controller.dart';
import '../state/support_native_provider.dart';
import 'support_settings_focus.dart';
import 'support_settings_panel.dart';
import 'support_surface_layout.dart';

/// Fresh current native UI, not an executable/restored card approval.
class SupportGuidanceSheet extends ConsumerStatefulWidget {
  const SupportGuidanceSheet({super.key, required this.target});
  final SupportGuidanceTarget target;

  @override
  ConsumerState<SupportGuidanceSheet> createState() => _GuidanceSheetState();
}

class _GuidanceSheetState extends ConsumerState<SupportGuidanceSheet> {
  late final SupportNativeConsentController _controller;
  late final String _session;
  late final int _lifetime;
  late final void Function() _stop;
  ModalRoute<void>? _route;
  bool _retired = false;

  @override
  void initState() {
    super.initState();
    _controller = ref.read(supportNativeConsentControllerProvider);
    _session = _controller.runtime.sessionId;
    _lifetime = _controller.runtime.lifetime;
    _stop = _controller.runtime.listen(() {
      if (mounted && !_retired) setState(() {});
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _route ??= ModalRoute.of<void>(context);
  }

  bool _current() =>
      mounted &&
      !_retired &&
      identical(
        _controller,
        ref.read(supportNativeConsentControllerProvider),
      ) &&
      _controller.runtime.alive &&
      _controller.runtime.sessionId == _session &&
      _controller.runtime.lifetime == _lifetime &&
      (_route?.isActive ?? true) &&
      !_retired;

  @override
  void deactivate() {
    _retired = true;
    super.deactivate();
  }

  @override
  void dispose() {
    _retired = true;
    _stop();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    ref.watch(supportNativeConsentControllerProvider);
    final current = _current();
    final target = widget.target;
    final focus = switch (target) {
      SupportGuidanceTarget.mode => SupportSettingsFocus.mode,
      SupportGuidanceTarget.connection => SupportSettingsFocus.connection,
      SupportGuidanceTarget.model => SupportSettingsFocus.model,
      SupportGuidanceTarget.temperature => SupportSettingsFocus.temperature,
      SupportGuidanceTarget.maxTokens => SupportSettingsFocus.maxTokens,
      SupportGuidanceTarget.reasoning => SupportSettingsFocus.reasoning,
      SupportGuidanceTarget.dcp => SupportSettingsFocus.dcp,
      _ => SupportSettingsFocus.privacy,
    };
    return SheetView(
      title: focus == SupportSettingsFocus.privacy
          ? 'Доступ к данным приложения'
          : target.title,
      showBack: false,
      titleWidget: SupportSheetTitle(
        title: focus == SupportSettingsFocus.privacy
            ? 'Доступ к данным приложения'
            : target.title,
        onBack: () => Navigator.of(context).pop(),
      ),
      onBack: () => Navigator.of(context).pop(),
      body: Builder(
        builder: (bodyContext) => !current
            ? const Center(
                child: Text('Сессия изменилась. Предложение устарело.'),
              )
            : SupportSettingsPanel(
                sheetHosted: true,
                focus: focus,
                focusedPermission: target.permission,
                isOriginalUiCurrent: _current,
              ),
      ),
    );
  }
}
