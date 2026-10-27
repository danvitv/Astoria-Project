import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import 'support_theme_controls.dart';
import 'support_theme_screen_controller.dart';

/// Three bounded native choices, never a string dispatcher or stored action.
/// Each render reprojects the original observation under current permissions.
class SupportThemeModeChoices extends StatelessWidget {
  const SupportThemeModeChoices({super.key, required this.controller});
  final SupportThemeScreenController controller;

  @override
  Widget build(BuildContext context) {
    final c = controller, original = controller.intent;
    final observed = c.observation;
    final installed = c.current && original != null && observed != null
        ? original.installed(observed)
        : null;
    String? currentMode;
    if (installed != null) {
      for (final choice in installed.choices) {
        final value = choice.value;
        if (value?.active == true) currentMode = value!.mode;
      }
    }
    final choices = c.current && original != null && observed != null
        ? original.modeChoices(observed)
        : null;
    return Column(
      key: const ValueKey('support_theme_mode_choices'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text('support_theme_mode_title'.tr()),
        Text('support_theme_mode_preserves_fields'.tr()),
        if (choices == null)
          Text('support_theme_unavailable'.tr())
        else
          for (final choice in choices.choices)
            if (choice.value case final value?)
              SupportThemeButton(
                key: ValueKey('support_theme_mode_choice_${value.mode}'),
                label: 'support_theme_mode_${value.mode}'.tr(),
                selected: currentMode != null && value.mode == currentMode,
                onTap: c.busy ? null : () => c.prepare(choice),
              )
            else
              Text('support_theme_unavailable'.tr()),
      ],
    );
  }
}
