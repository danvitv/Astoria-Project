import 'package:flutter/material.dart';

import '../../../shared/theme/app_colors.dart';
import '../../chat/widgets/action_glyph.dart';
import '../../chat/widgets/drawer_panel_scaffold.dart';
import '../../chat/widgets/magic_drawer_widgets.dart';

/// One compact, horizontally scrollable placement for auxiliary actions.
/// Scrolling keeps the input and Stop independent of width, text scale and IME.
class SupportActionStrip extends StatelessWidget {
  const SupportActionStrip({super.key, required this.children});
  final List<Widget> children;

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
    key: const ValueKey('support_bottom_actions'),
    scrollDirection: Axis.horizontal,
    child: Row(
      children: [
        for (final child in children)
          Padding(padding: const EdgeInsets.only(right: 6), child: child),
      ],
    ),
  );
}

/// Reuses our chat drawer shell and equal-height card grid. Unlike the chat
/// drawer, this owns no pins, tool launcher, generation or permission behavior.
/// Offstage keeps keyed native entries mounted when the drawer is folded away.
class SupportActionDrawer extends StatelessWidget {
  const SupportActionDrawer({
    super.key,
    required this.open,
    required this.onClose,
    required this.children,
  });
  final bool open;
  final VoidCallback onClose;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final visibleHeight =
        MediaQuery.sizeOf(context).height -
        View.of(context).viewInsets.bottom / View.of(context).devicePixelRatio;
    // The real chat drawer is intentionally dark, including in a light theme.
    final theme = Theme.of(context);
    return Offstage(
      offstage: !open,
      child: SizedBox(
        key: const ValueKey('support_action_drawer'),
        height: (visibleHeight * .32).clamp(160.0, 240.0),
        child: Theme(
          data: theme.copyWith(
            colorScheme: ColorScheme.fromSeed(
              seedColor: theme.colorScheme.primary,
              brightness: Brightness.dark,
            ),
          ),
          child: DrawerPanelScaffold(
            disableEffects: true,
            onDismiss: onClose,
            header: Padding(
              padding: const EdgeInsets.fromLTRB(16, 20, 8, 0),
              child: Row(
                children: [
                  const Expanded(child: Text('Действия Астории')),
                  IconButton(
                    key: const ValueKey('support_drawer_close'),
                    constraints: const BoxConstraints(
                      minWidth: 48,
                      minHeight: 48,
                    ),
                    tooltip: 'Свернуть действия',
                    icon: const Icon(Icons.keyboard_arrow_down_rounded),
                    onPressed: onClose,
                  ),
                ],
              ),
            ),
            content: SingleChildScrollView(
              key: const ValueKey('support_bottom_actions'),
              padding: const EdgeInsets.fromLTRB(
                12,
                kDrawerContentTopInset + 8,
                12,
                16,
              ),
              child: MagicCardGrid(
                columns: 2,
                cells: [for (final child in children) Expanded(child: child)],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Presentation only: selection reflects an owned route, never permission.
class SupportActionTile extends StatelessWidget {
  const SupportActionTile({
    super.key,
    required this.icon,
    required this.label,
    required this.onTap,
    this.tooltip,
    this.selected = false,
    this.busy = false,
  });

  final IconData icon;
  final String label;
  final String? tooltip;
  final VoidCallback? onTap;
  final bool selected;
  final bool busy;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null && !busy;
    final foreground = selected ? context.cs.primary : context.cs.onSurface;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      label: label,
      child: Tooltip(
        message: tooltip ?? label,
        child: Opacity(
          opacity: enabled || selected ? 1 : 0.45,
          // MagicCard's compact icon/label presentation, adapted to Glaze
          // colour tokens, full labels and truthful disabled/selected states.
          // No separate backdrop pass for every drawer cell.
          child: Material(
            color: selected
                ? context.cs.primaryContainer
                : context.cs.onSurface.withValues(alpha: .04),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(14),
              side: BorderSide(
                color: selected
                    ? context.cs.primary
                    : context.cs.outlineVariant,
              ),
            ),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: enabled ? onTap : null,
              child: ConstrainedBox(
                constraints: const BoxConstraints(minWidth: 72, minHeight: 48),
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy)
                        const SizedBox.square(
                          dimension: 18,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        )
                      else
                        ActionGlyph(icon: icon, size: 18, color: foreground),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          label,
                          style: TextStyle(fontSize: 12, color: foreground),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
