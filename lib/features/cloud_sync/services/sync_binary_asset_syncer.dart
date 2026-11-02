import 'dart:io';
import 'dart:typed_data';

import '../../../core/models/gallery_entry.dart';
import '../../../core/services/preset_image_paths.dart';
import '../cloud_adapter.dart';
import '../sync_models.dart';
import '../sync_repo_interfaces.dart';

/// Handles push/pull of binary avatar and gallery image assets during cloud
/// sync. Extracted from [SyncEngine] to keep the engine focused on entity
/// manifest diffing.
class SyncBinaryAssetSyncer {
  final CloudAdapter _adapter;
  final SyncCharacterStore _characterRepo;
  final SyncPersonaStore _personaRepo;
  final SyncPresetStore _presetRepo;
  final SyncImageStore _imageStorage;
  final void Function()? _checkOriginal;
  final Future<void> Function(Future<void> Function())? _originalCommit;
  void _check() => _checkOriginal?.call();
  Future<T> _read<T>(Future<T> Function() action) async {
    _check();
    final result = await action();
    _check();
    return result;
  }
  Future<void> _commit(Future<void> Function() action) async {
    _check();
    final commit = _originalCommit;
    if (commit != null) { await commit(action); }
    else { await action(); }
    _check();
  }

  SyncBinaryAssetSyncer(
    this._adapter,
    this._characterRepo,
    this._personaRepo,
    this._presetRepo,
    this._imageStorage, [this._checkOriginal, this._originalCommit]
  );

  /// Extensions probed when pulling a binary whose stored extension is unknown
  /// on this device.
  static const _imageExtensions = ['png', 'jpg', 'webp', 'gif'];

  Future<void> pushCharacterAvatar(String charId) async {
    final c = await _read(() => _characterRepo.getById(charId));
    if (c?.avatarPath == null) return;
    final path = _imageStorage.absolutePath(c!.avatarPath);
    if (path == null) return;
    final file = File(path);
    if (!await _read(file.exists)) return;
    final bytes = await _read(file.readAsBytes);
    final ext = c.avatarPath!.split('.').last;
    await _adapter.uploadBinary(galleryCloudPath(charId, 'avatar', ext), bytes);
  }

  Future<bool> pullCharacterAvatar(String charId) async {
    final c = await _read(() => _characterRepo.getById(charId));
    if (c == null) return false;

    for (final ext in _imageExtensions) {
      final bytes = await _downloadIfAvailable(
        galleryCloudPath(charId, 'avatar', ext),
      );
      if (bytes == null || bytes.isEmpty) continue;
      late String localPath;
      await _commit(() async { localPath = await _imageStorage.saveBytes(bytes, 'avatars', charId, ext); });
      await _commit(() => _characterRepo.updateAvatarPath(charId, localPath));
      return true;
    }
    return false;
  }

  Future<void> pushPersonaAvatar(String personaId) async {
    final p = await _read(() => _personaRepo.getById(personaId));
    if (p?.avatarPath == null) return;
    final path = _imageStorage.absolutePath(p!.avatarPath);
    if (path == null) return;
    final file = File(path);
    if (!await _read(file.exists)) return;
    final bytes = await _read(file.readAsBytes);
    final ext = p.avatarPath!.split('.').last;
    await _adapter.ensureFolder('$cloudBase/persona_avatars/$personaId');
    await _adapter.uploadBinary(personaAvatarCloudPath(personaId, ext), bytes);
  }

  Future<bool> pullPersonaAvatar(String personaId) async {
    final p = await _read(() => _personaRepo.getById(personaId));
    if (p == null) return false;

    for (final ext in _imageExtensions) {
      final bytes = await _downloadIfAvailable(
        personaAvatarCloudPath(personaId, ext),
      );
      if (bytes == null || bytes.isEmpty) continue;
      late String relativePath;
      await _commit(() async { relativePath = await _imageStorage.saveBytes(bytes, 'avatars', personaId, ext); });
      await _commit(() => _personaRepo.updateAvatarPath(personaId, relativePath));
      return true;
    }
    return false;
  }

  /// Uploads every preset cover that lives on this device.
  ///
  /// Presets travel as one `theme_presets` singleton, so this runs once for the
  /// whole list instead of per entry. Covers pointing at a bundled `assets/...`
  /// path are skipped — they ship with the app on every device.
  Future<void> pushPresetImages() async {
    try {
      final presets = await _read(_presetRepo.getAll);
      var folderEnsured = false;
      for (final preset in presets) {
        final path = preset.imagePath;
        if (path == null || path.isEmpty || _isBundledAsset(path)) continue;
        final absPath = _imageStorage.absolutePath(path);
        if (absPath == null) continue;
        final file = File(absPath);
        if (!await _read(file.exists)) continue;
        final bytes = await _read(file.readAsBytes);
        if (!folderEnsured) {
          await _adapter.ensureFolder('$cloudBase/preset_images');
          folderEnsured = true;
        }
        await _adapter.ensureFolder('$cloudBase/preset_images/${preset.id}');
        await _adapter.uploadBinary(
          presetImageCloudPath(preset.id, _extensionOf(path)),
          bytes,
        );
      }
    } catch (_) { _check(); }
  }

  /// Downloads the cover of every preset that references a file this device
  /// does not have yet.
  ///
  /// The stored path is relative and carries its own version suffix, so it is
  /// valid on every device and never rewritten here — the pull only has to put
  /// the bytes where the path already points. A cover that fails to download is
  /// left alone: the next push from the device that owns the file must not be
  /// told the image is gone, and the UI simply shows no cover meanwhile.
  Future<void> pullPresetImages() async {
    try {
      final presets = await _read(_presetRepo.getAll);
      for (final preset in presets) {
        final path = preset.imagePath;
        if (path == null || path.isEmpty || _isBundledAsset(path)) continue;
        final storageId = presetImageStorageIdOf(path);
        if (storageId == null) continue;
        final absPath = _imageStorage.absolutePath(path);
        if (absPath != null && await _read(File(absPath).exists)) continue;

        for (final ext in _extensionsToProbe(path)) {
          try {
            final bytes = await _adapter.downloadBinary(
              presetImageCloudPath(preset.id, ext),
            );
            _check();
            if (bytes.isEmpty) continue;
            await _commit(() async { await _imageStorage.saveBytes(bytes, 'avatars', storageId, ext); });
            // The pushed and stored extensions agree in practice (covers are
            // always written as PNG), but honour a mismatch rather than leaving
            // the preset pointing at a file saved under another name.
            final relative = presetImageRelativePath(storageId, ext);
            if (relative != path) {
              await _commit(() => _presetRepo.put(preset.copyWith(imagePath: relative)));
            }
            break;
          } catch (_) { _check(); }
        }
      }
    } catch (_) { _check(); }
  }

  /// Bundled covers (a cloned featured preset) exist in every install's asset
  /// bundle, so they are neither uploaded nor downloaded.
  bool _isBundledAsset(String path) => isPresetAssetImage(path);

  String _extensionOf(String path) => path.split('.').last;

  /// The extension the path already claims, tried first, then the rest.
  List<String> _extensionsToProbe(String path) {
    final own = _extensionOf(path).toLowerCase();
    if (!_imageExtensions.contains(own)) return _imageExtensions;
    return [own, ..._imageExtensions.where((e) => e != own)];
  }

  Future<void> pushCharacterGallery(String charId) async {
    final c = await _read(() => _characterRepo.getById(charId));
    if (c == null || c.gallery.isEmpty) return;
    await _adapter.ensureFolder('$cloudBase/gallery/$charId');
    for (final entry in c.gallery) {
      final absPath = _imageStorage.absolutePath(entry.imagePath);
      if (absPath == null) continue;
      final file = File(absPath);
      if (!await _read(file.exists)) continue;
      final bytes = await _read(file.readAsBytes);
      final ext = entry.imagePath.split('.').last;
      await _adapter.uploadBinary(
        galleryCloudPath(charId, entry.id, ext),
        bytes,
      );
    }
  }

  Future<void> pullCharacterGallery(String charId) async {
    final c = await _read(() => _characterRepo.getById(charId));
    if (c == null) return;

    final updatedGallery = <GalleryEntry>[];
    for (final entry in c.gallery) {
      var pulled = false;
      for (final ext in _extensionsToProbe(entry.imagePath)) {
        final bytes = await _downloadIfAvailable(
          galleryCloudPath(charId, entry.id, ext),
        );
        if (bytes == null || bytes.isEmpty) continue;
        late String destPath;
        await _commit(() async { destPath = await _imageStorage.saveBytes(bytes, 'gallery/$charId', entry.id, ext); });
        updatedGallery.add(entry.copyWith(imagePath: destPath));
        pulled = true;
        break;
      }
      if (!pulled) {
        // Keep metadata if the binary is temporarily unavailable; retry later.
        updatedGallery.add(entry);
      }
    }
    if (!_galleriesEqual(updatedGallery, c.gallery)) {
      await _commit(() => _characterRepo.updateGallery(charId, updatedGallery));
    }
  }

  Future<Uint8List?> _downloadIfAvailable(String path) async {
    try {
      return await _read(() => _adapter.downloadBinary(path));
    } on CloudFileNotFoundException {
      return null;
    }
  }

  bool localFileExists(String? path) {
    _check();
    if (path == null || path.isEmpty) return false;
    final abs = _imageStorage.absolutePath(path);
    return abs != null && File(abs).existsSync();
  }

  bool _galleriesEqual(List<GalleryEntry> a, List<GalleryEntry> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].id != b[i].id || a[i].imagePath != b[i].imagePath) return false;
    }
    return true;
  }
}
