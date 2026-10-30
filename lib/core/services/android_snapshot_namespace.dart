import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path/path.dart' as p;

/// Android Context metadata only. This is not a file-picker or export grant.
final class AndroidSnapshotNamespace {
  AndroidSnapshotNamespace._(this.dataRoot);
  final String dataRoot;
  String get workerStageRoot =>
      p.posix.join(dataRoot, 'no_backup', 'astoria_snapshots');

  /// Explicit synthetic Windows metadata; never enables the Android FS backend.
  factory AndroidSnapshotNamespace.forTestingWindows(String root) {
    if (!Platform.isWindows ||
        !p.windows.isAbsolute(root) ||
        root.contains('\u0000')) {
      throw ArgumentError('Synthetic private namespace unavailable');
    }
    return AndroidSnapshotNamespace._(root);
  }

  static Future<AndroidSnapshotNamespace?> forSource(File source) async {
    final namespace = await forStartup();
    if (namespace == null ||
        !p.posix.isWithin(namespace.dataRoot, source.path) ||
        p.posix.basename(source.path) != 'astoria.db') {
      return null;
    }
    return namespace;
  }

  /// Existing Context metadata only. In particular, do not call path_provider's
  /// documents/cache accessors: those may create directories before admission.
  static Future<AndroidSnapshotNamespace?> forStartup() async {
    if (!Platform.isAndroid) return null;
    try {
      final root = await const MethodChannel(
        'app.astoria.flutter/snapshot_storage',
      ).invokeMethod<String>('privateNamespace');
      if (root == null ||
          !p.posix.isAbsolute(root) ||
          root.contains('\u0000') ||
          p.posix.normalize(root) != root) {
        return null;
      }
      return AndroidSnapshotNamespace._(root);
    } catch (_) {
      return null; // Old engines / unsupported namespace: normal DB still works.
    }
  }
}
