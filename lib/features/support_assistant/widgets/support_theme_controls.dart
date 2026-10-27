import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../../shared/widgets/glass_surface.dart';
import '../models/support_theme_values.dart';

/// Glaze action tile with fully wrapping labels, including scaled narrow sheets.
class SupportThemeButton extends StatelessWidget {
  const SupportThemeButton({
    super.key,
    required this.label,
    required this.onTap,
    this.destructive = false,
    this.selected = false,
    this.busy = false,
  });
  final String label;
  final VoidCallback? onTap;
  final bool destructive;
  final bool selected, busy;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null && !busy,
      child: Opacity(
        opacity: onTap == null ? 0.4 : 1,
        child: GlassSurface(
          borderRadius: BorderRadius.circular(14),
          tint: selected ? context.cs.primaryContainer : null,
          border: Border.all(
            color: selected ? context.cs.primary : context.cs.outlineVariant,
          ),
          onTap: busy ? null : onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 48),
            padding: const EdgeInsets.all(14),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (busy)
                  const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                if (selected)
                  Icon(
                    Icons.check_rounded,
                    size: 20,
                    color: context.cs.onPrimaryContainer,
                  ),
                Text(
                  label,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    color: destructive
                        ? context.cs.error
                        : selected
                        ? context.cs.onPrimaryContainer
                        : context.cs.primary,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

/// Only four bounded safe fields. No preset/resource/font/catalog dependency.
class SupportThemeValueBlock extends StatelessWidget {
  const SupportThemeValueBlock({super.key, required this.value, this.heading});
  final SupportThemeValue value;
  final String? heading;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 8),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (heading != null) Text(heading!),
        Text('support_theme_name'.tr(args: [value.name])),
        Text('support_theme_id'.tr(args: [value.id])),
        Text(
          'support_theme_mode'.tr(
            args: ['support_theme_mode_${value.mode}'.tr()],
          ),
        ),
        Text('support_theme_accent'.tr(args: [value.accent])),
      ],
    ),
  );
}

/// Pure small sample, not a full theme preview or a current-active assertion.
class SupportThemeSample extends StatelessWidget {
  const SupportThemeSample({super.key, required this.value});
  final SupportThemeValue value;

  @override
  Widget build(BuildContext context) {
    final accent = Color(
      int.parse('ff${value.accent.substring(1)}', radix: 16),
    );
    final scheme = ColorScheme.fromSeed(
      seedColor: accent,
      brightness: switch (value.mode) {
        'dark' => Brightness.dark,
        'light' => Brightness.light,
        _ => MediaQuery.platformBrightnessOf(context),
      },
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.primary),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Text(
          'support_theme_sample'.tr(),
          style: TextStyle(color: scheme.primary, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}
