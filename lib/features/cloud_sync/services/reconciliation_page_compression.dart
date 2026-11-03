import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// Gzip's OS header is metadata, not page content. Native zlib writes different
/// values on Windows, Unix and Apple platforms; hashing those values prevented
/// otherwise identical reconciliation pages from being reused across devices.
abstract final class ReconciliationPageCompression {
  static const _operatingSystemOffset = 9;
  static const _portableOperatingSystem = 255;

  /// Mutates the locally compressed page so the returned SHA-256 always covers
  /// its exact bytes. New pages use the portable header. Published legacy pages
  /// retain their original header/hash, avoiding a forced history re-upload.
  static String preparePage(Uint8List compressed, Set<String> publishedNames) {
    // The native encoder emits the fixed gzip header without optional fields.
    // In particular, do not alter a header that carries its own checksum.
    if (compressed.length < 18 ||
        compressed[0] != 0x1f ||
        compressed[1] != 0x8b ||
        compressed[2] != 8 ||
        compressed[3] != 0) {
      throw const FormatException('Unsupported reconciliation gzip header');
    }
    final nativeOperatingSystem = compressed[_operatingSystemOffset];
    compressed[_operatingSystemOffset] = _portableOperatingSystem;
    final portableHash = sha256.convert(compressed).toString();
    if (publishedNames.isEmpty ||
        publishedNames.contains('$portableHash.b64')) {
      return portableHash;
    }

    // Bounded compatibility with zlib headers for supported native platforms.
    // No historical folder listing or page download is needed: a match requires
    // SHA-256 equality of the entire compressed page, not just its header.
    final legacyOperatingSystems = <int>{
      nativeOperatingSystem,
      3, // Unix / Android / Linux.
      10, // Windows NTFS.
      19, // Apple platforms.
      0, // Older Windows/FAT zlib builds.
      7, // Older Macintosh zlib builds.
    }..remove(_portableOperatingSystem);
    for (final operatingSystem in legacyOperatingSystems) {
      compressed[_operatingSystemOffset] = operatingSystem;
      final hash = sha256.convert(compressed).toString();
      if (publishedNames.contains('$hash.b64')) return hash;
    }
    compressed[_operatingSystemOffset] = _portableOperatingSystem;
    return portableHash;
  }
}
