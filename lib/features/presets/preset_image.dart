import 'dart:io';

import 'package:flutter/widgets.dart';

import '../../core/models/preset.dart';
import '../../core/services/featured_presets.dart';
import '../../core/services/preset_image_paths.dart';
import '../../core/utils/platform_paths.dart';
import '../../shared/utils/avatar_image.dart';

export '../../core/services/preset_image_paths.dart'
    show
        isPresetAssetImage,
        presetImageRelativePath,
        presetImageStorageId,
        presetImageStorageIdOf;

/// Cover image of [preset], or null when it has none.
///
/// Resolution order:
///   1. a user-picked image stored on disk (thumbnail preferred),
///   2. an `assets/...` cover carried in `imagePath`,
///   3. the bundled featured-preset cover keyed by id.
ImageProvider? presetCoverImage(Preset preset) =>
    resolvePresetCoverImage(presetId: preset.id, imagePath: preset.imagePath);

/// [presetCoverImage] for editor state that has no persisted [Preset] yet.
ImageProvider? resolvePresetCoverImage({
  required String presetId,
  String? imagePath,
}) {
  if (imagePath != null && imagePath.isNotEmpty) {
    if (isPresetAssetImage(imagePath)) {
      return AssetImage(imagePath);
    }
    // A path can outlive its file — fall through to the bundled cover (if any)
    // instead of handing back a provider that would fail to decode.
    if (_coverFileExists(imagePath)) return glazeAvatarImage(imagePath);
  }
  final asset = featuredPresetImageAsset(presetId);
  return asset != null ? AssetImage(asset) : null;
}

bool _coverFileExists(String imagePath) {
  final resolved = resolveGlazeFilePath(imagePath);
  if (resolved == null || resolved.isEmpty) return false;
  return File(resolved).existsSync();
}
