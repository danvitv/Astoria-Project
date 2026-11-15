import 'package:flutter/material.dart';

import '../../../shared/widgets/glass_surface.dart';
import '../../../shared/widgets/glaze_spinner.dart';

class ChatStatusCardShell extends StatelessWidget {
  const ChatStatusCardShell({
    super.key,
    required this.label,
    required this.icon,
    required this.accent,
    required this.showSpinner,
    this.action,
  });

  final String label;
  final IconData icon;
  final Color accent;
  final bool showSpinner;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: GlassSurface(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: accent.withValues(alpha: 0.25)),
        child: SizedBox(
          height: 48,
          width: double.infinity,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                if (showSpinner)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: GlazeSpinner(color: accent),
                  )
                else
                  Icon(icon, size: 18, color: accent),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: cs.onSurface,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                if (action != null)
                  TooltipVisibility(
                    visible: false,
                    child: SizedBox.square(
                      // IconButton themes and accessibility settings must not
                      // consume the row or make it taller than the viewport.
                      dimension: 32,
                      child: action,
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
