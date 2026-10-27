import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/widgets/sheet_view.dart';
import 'support_theme_controls.dart';
import 'support_surface_layout.dart';

/// Once native deletion decision. No widget pending check replaces J's guard.
class SupportThemeDeleteSheet extends StatefulWidget {
  const SupportThemeDeleteSheet({super.key, required this.isCurrent});
  final bool Function() isCurrent;

  @override
  State<SupportThemeDeleteSheet> createState() => _DeleteSheetState();
}

class _DeleteSheetState extends State<SupportThemeDeleteSheet> {
  ModalRoute<bool>? _route;
  NavigatorState? _navigator;
  bool _decided = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_route != null) return;
    final route = _route = ModalRoute.of<bool>(context)!;
    _navigator = Navigator.of(context);
    route.popped.then((_) => _decided = true);
  }

  void _decide(bool confirmed) {
    final route = _route, navigator = _navigator;
    if (_decided || !mounted || route?.isCurrent != true) return;
    _decided = true;
    navigator!.pop(confirmed && widget.isCurrent());
  }

  @override
  void deactivate() {
    _decided = true;
    super.deactivate();
  }

  @override
  Widget build(BuildContext context) => SheetView(
    title: 'support_theme_delete_title'.tr(),
    showBack: false,
    titleWidget: SupportSheetTitle(
      title: 'support_theme_delete_title'.tr(),
      onBack: () => _decide(false),
    ),
    onBack: () => _decide(false),
    body: Builder(
      builder: (bodyContext) => SupportSheetDecisionBody(
        footer: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SupportThemeButton(
              key: const ValueKey('support_theme_delete_cancel'),
              label: 'support_theme_delete_cancel'.tr(),
              onTap: () => _decide(false),
            ),
            SupportThemeButton(
              key: const ValueKey('support_theme_delete_confirm'),
              label: 'support_theme_delete_confirm'.tr(),
              destructive: true,
              onTap: widget.isCurrent() ? () => _decide(true) : null,
            ),
          ],
        ),
        content: ListView(
          key: const ValueKey('support_theme_delete_scroll'),
          padding: EdgeInsets.fromLTRB(
            16,
            12,
            16,
            MediaQuery.paddingOf(bodyContext).bottom + 24,
          ),
          children: [Text('support_theme_delete_notice'.tr())],
        ),
      ),
    ),
  );
}
