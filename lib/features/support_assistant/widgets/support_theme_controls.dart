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
  });
  final String label;
  final VoidCallback? onTap;
  final bool destructive;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Opacity(
      opacity: onTap == null ? 0.4 : 1,
      child: GlassSurface(
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: context.cs.outlineVariant),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Text(
            label,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: destructive ? context.cs.error : context.cs.primary,
              fontWeight: FontWeight.w600,
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
        Text('support_theme_mode'.tr(args: [value.mode])),
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
      brightness: value.mode == 'dark' ? Brightness.dark : Brightness.light,
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
