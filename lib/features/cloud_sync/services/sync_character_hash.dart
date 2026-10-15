import 'dart:io';

import '../../../core/models/gallery_entry.dart';
import '../sync_repo_interfaces.dart';
import 'sync_serialization.dart';

/// Portable card identity, with a legacy fingerprint for safe lazy upgrades.
class SyncCharacterHash {
  static int avatarSize(Map<String, dynamic> json, SyncImageStore? store) {
    try {
      final path = store?.absolutePath(json['avatarPath'] as String?);
      if (path == null || path.isEmpty) return 0;
      final file = File(path);
      return file.existsSync() ? file.lengthSync() : 0;
    } catch (_) {
      return 0;
    }
  }

  static String compute(
    Map<String, dynamic> json,
    int avatarSize, {
    bool legacy = false,
  }) {
    final out = Map<String, dynamic>.from(json)..remove('avatarPath');
    final gallery = out.remove('gallery') as List?;
    if (gallery != null && gallery.isNotEmpty) {
      final items = [
        for (final raw in gallery)
          if (raw is Map<String, dynamic>)
            raw
          else if (!legacy && raw is GalleryEntry)
            raw.toJson(),
      ];
      out['_gallery'] = [
        for (final raw in items)
          {
            'id': raw['id'],
            'label': raw['label'],
            'createdAt': raw['createdAt'],
          },
      ];
    }
    if (avatarSize > 0) out['_avatarFileSize'] = avatarSize;
    if (!legacy) {
      out.remove('currentSessionIndex');
      out.remove('tokenCount');
      out.remove('updatedAt');
    }
    return SyncSerialization.computeSyncHash(out);
  }

  static int timestampMillis(int value) =>
      value > 0 && value < 100000000000 ? value * 1000 : value;
}
