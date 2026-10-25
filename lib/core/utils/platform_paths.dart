import 'dart:io';
import 'package:path/path.dart' as p;
// Pinned via dependency_overrides to keep Windows builds green; see docs/BUILD_NOTES.md.
// ignore: depend_on_referenced_packages
import 'package:path_provider/path_provider.dart';

import '../constants/build_channel.dart';

/// Cached app data root, populated on the first [getAppDataDir] call (which
/// happens at startup via ImageStorageService.create / AppDatabase open).
/// Used by [resolveGlazeFilePath] so widgets can rebase stale absolute paths
/// without an async lookup.
String? _cachedAppDataDir;

String? get cachedAppDataDir => _cachedAppDataDir;

/// Pure spelling resolution for pre-migration Windows admission. The native
/// owner, not this resolver, proves that APPDATA exists and is canonical NTFS.
/// No cache, directory creation, plugin call or installation lookup occurs.
({Directory startupDirectory, File target}) resolveWindowsStartupPaths(
  Map<String, String> environment,
) {
  final appData = environment['APPDATA'];
  if (appData == null || appData.isEmpty) {
    throw UnsupportedError('Windows startup anchor unavailable');
  }
  return (
    startupDirectory: Directory(appData),
    target: File(p.windows.join(appData, astoriaDataFolderName, 'astoria.db')),
  );
}

Future<String> getAppDataDir() async {
  if (Platform.isAndroid || Platform.isIOS) {
    final dir = await getApplicationDocumentsDirectory();
    final base = p.join(dir.path, 'Astoria');
    _cachedAppDataDir = base;
    return base;
  }
  final base = _desktopDataDir();
  _cachedAppDataDir = base;
  return base;
}

/// Resolves a stored avatar/gallery/etc. path for display.
///
/// iOS changes the app sandbox container UUID on every reinstall/OS update, so
/// absolute paths persisted by an older build (e.g.
/// `.../Application/<OLD_UUID>/Documents/Glaze/avatars/x.png`) stop existing
/// even though the files survive under the *new* container. This rebases any
/// absolute path under an Astoria or legacy Glaze data root onto the current
/// [cachedAppDataDir]. Relative paths are joined onto the current base. When no
/// base is cached yet (very early startup) the input is returned unchanged.
String? resolveGlazeFilePath(String? path) {
  if (path == null || path.isEmpty) return path;
  // A stored path can also be a URL (`data:`, `https:`) — a catalog card whose
  // picture was never downloaded. It is not absolute, so without this it would
  // be joined onto the data root and come back as a path no file lives at.
  // [relativeGlazeFilePath], this function's inverse, has always left URLs
  // alone; this is the other half of that symmetry.
  if (_urlSchemeRegex.hasMatch(path)) return path;
  final base = _cachedAppDataDir;
  if (base == null) return path;

  if (!p.isAbsolute(path)) {
    return p.joinAll([base, ...path.split(RegExp(r'[/\\]'))]);
  }
  // Absolute: first prefer the matching file in this build channel's data
  // root. A copied/imported database can still contain paths from another
  // installed channel, whose source files may also continue to exist.
  final normalized = path.replaceAll('\\', '/');
  // Desktop channels use sibling roots. Match all of them so a copied DB can
  // move in either direction: stable <-> staging <-> nightly.
  final match = RegExp(
    r'/(?:Astoria(?:-dev|-staging|-nightly)?|Glaze(?:-staging|-nightly)?)/',
    caseSensitive: false,
  ).allMatches(normalized).lastOrNull;
  if (match != null) {
    final suffix = normalized.substring(match.end);
    if (suffix.isNotEmpty) {
      final rebased = p.join(base, suffix);
      if (File(rebased).existsSync()) return rebased;
    }
  }
  if (File(path).existsSync()) return path;
  return path;
}

/// [path] spelled relative to the app data root when it lives inside it.
///
/// The inverse of [resolveGlazeFilePath], and the spelling every image path is
/// stored in: a relative path survives the data root moving under it — a new
/// iOS container UUID, a database copied between the desktop build channels —
/// where an absolute one silently stops pointing at a file. Paths outside the
/// data root (and anything that is already relative, or a URL) come back
/// unchanged.
String relativeGlazeFilePath(String path) {
  if (path.isEmpty) return path;
  if (_urlSchemeRegex.hasMatch(path)) return path;
  final normalized = path.replaceAll('\\', '/');
  if (!p.isAbsolute(path)) return normalized;

  final base = _cachedAppDataDir;
  if (base != null) {
    final relative = p.relative(path, from: base);
    if (!p.isAbsolute(relative) && !relative.startsWith('..')) {
      return relative.replaceAll('\\', '/');
    }
  }
  // No base cached yet (very early startup), or the file belongs to another
  // installed build channel: the data-root name still tells us where it sat,
  // and [resolveGlazeFilePath] rebases that suffix onto the current root.
  final match = RegExp(
    r'/(?:Astoria(?:-dev|-staging|-nightly)?|Glaze(?:-staging|-nightly)?)/',
    caseSensitive: false,
  ).allMatches(normalized).lastOrNull;
  if (match != null) {
    final suffix = normalized.substring(match.end);
    if (suffix.isNotEmpty) return suffix;
  }
  return path;
}

/// A URL scheme, which a stored image path can also be (`data:`, `https:`).
/// Two characters minimum, so a Windows drive letter is not read as one.
final RegExp _urlSchemeRegex = RegExp(r'^[a-zA-Z][a-zA-Z0-9+.-]+:');

const kThumbnailExtensions = ['png', 'jpg'];

/// Returns the on-disk path to the PNG/JPEG thumbnail for a stored avatar
/// path when that thumbnail exists, otherwise the resolved full-resolution
/// avatar path (or `null` when there is no avatar).
///
/// Lists (character grid, folder cards, chat history) should prefer this over
/// [resolveGlazeFilePath] so that scrolling decodes scaled thumbnails instead
/// of the multi-megabyte source PNGs — the latter causes visible jank and
/// delayed "pop-in" the first time each card scrolls into view.
String? resolveGlazeThumbnailPath(String? avatarPath) {
  final resolved = resolveGlazeFilePath(avatarPath);
  if (resolved == null || resolved.isEmpty) return resolved;
  final name = p.basenameWithoutExtension(resolved);
  // Transparent thumbnails are PNG, opaque ones JPEG.
  final base = p.dirname(p.dirname(resolved));
  for (final extension in kThumbnailExtensions) {
    final thumb = p.join(base, 'thumbnails', '$name.$extension');
    if (File(thumb).existsSync()) return thumb;
  }
  return resolved;
}

String _desktopDataDir() {
  if (Platform.isWindows) {
    return p.windows.dirname(
      resolveWindowsStartupPaths(Platform.environment).target.path,
    );
  } else if (Platform.isLinux) {
    final xdg =
        Platform.environment['XDG_DATA_HOME'] ??
        p.join(Platform.environment['HOME']!, '.local', 'share');
    return p.join(xdg, astoriaDataFolderName);
  } else if (Platform.isMacOS) {
    return p.join(
      Platform.environment['HOME']!,
      'Library',
      'Application Support',
      astoriaDataFolderName,
    );
  }
  throw UnsupportedError('Platform not supported yet');
}
