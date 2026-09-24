import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/theme/theme_provider.dart';
import '../../../shared/widgets/blurred_image.dart';

/// The chat's own background — base colour, optional image, blur and dim.
///
/// Painted in two places, which is what keeps the desktop layout even: behind
/// the WebView (which is transparent, so the background has to come from
/// Flutter), and across the full column behind [ChatColumnWidth]'s side
/// gutters. Without the second one the capped chat column carried the chat's
/// background while the gutters beside it showed the app's, so the chat read
/// as a lighter strip between two darker bands.
///
/// The two overlap over the column itself, but the upper copy is opaque, so
/// the result is the same as painting it once.
class ChatBackground extends ConsumerWidget {
  /// One of `color`, `avatar`, `custom` or `inherit`.
  final String mode;

  /// Base fill, used when [mode] is `color`. Falls back to the theme surface.
  final Color? color;

  /// Character avatar file, used when [mode] is `avatar`.
  final String? avatarPath;

  /// Decoded image for `custom` and `inherit`.
  final Uint8List? imageBytes;

  final double blur;
  final double dim;

  /// The full-width desktop gutter background stays plain; the logo is drawn
  /// once in the chat column's own background.
  final bool showStockLogo;

  const ChatBackground({
    super.key,
    required this.mode,
    required this.color,
    required this.avatarPath,
    required this.imageBytes,
    required this.blur,
    required this.dim,
    this.showStockLogo = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final preset = ref.watch(themeProvider).activePreset;
    final isStockChat =
        preset.id == 'default' &&
        preset.accentColor.toUpperCase() == '#F5C400' &&
        preset.bgColor == null &&
        preset.uiColor == null &&
        preset.bgImage == null &&
        preset.chatBgImage == null &&
        mode == 'inherit' &&
        imageBytes == null;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = mode == 'color' && color != null
        ? color!
        : isStockChat && isDark
        ? const Color(0xFF1B1B1B)
        : Theme.of(context).colorScheme.surface;

    ImageProvider? image;
    if (mode == 'avatar') {
      final path = avatarPath;
      if (path != null && path.isNotEmpty) {
        image = FileImage(File(path));
      }
    } else if (mode != 'color' && imageBytes != null) {
      image = MemoryImage(imageBytes!);
    }

    return Stack(
      fit: StackFit.expand,
      children: [
        ColoredBox(color: base),
        if (image != null) ...[
          // Baked once per (image, sigma, size) instead of being re-filtered
          // on every composite — see [BlurredImage].
          BlurredImage(image: image, sigma: blur),
          if (dim > 0) ColoredBox(color: Colors.black.withValues(alpha: dim)),
        ],
        if (isStockChat && showStockLogo)
          Positioned.fill(
            child: IgnorePointer(
              child: LayoutBuilder(
                builder: (context, constraints) => Center(
                  child: Opacity(
                    opacity: isDark ? 0.045 : 0.055,
                    child: Image.asset(
                      'assets/logos/astoria.png',
                      width: math.min(320, constraints.maxWidth * 0.48),
                      fit: BoxFit.contain,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}
