part of '../database_restore_repo.dart';

/// Platform-owned files, separate from SQLite's borrowed connection descriptor.
/// A file pin never substitutes for the native connection identity proof.
abstract interface class _RestoreFilePort {
  p.Context get paths;
  String? get androidDataRoot;
  Pointer<Void> allocate(int bytes);
  void free(Pointer<Void> memory);
  bool exists(String path);
  List<_RestorePin> pinAncestors(String parent);
  _RestorePin pin(
    String path, {
    bool directory = false,
    bool immutable = false,
    bool lock = false,
    bool create = false,
    bool write = false,
  });
  String createStage(String parent);
  void deleteOwnedFile(String path);
  void deleteOwnedDirectory(String path);
  void releaseOwnedProofs();
  Future<Digest> copyOrHash(
    _RestorePin input,
    void Function() check, {
    _RestorePin? output,
  });
  void writeMarker(_RestorePin marker, String stageBasename);
}

abstract interface class _RestorePin {
  Pointer<Void> get handle;
  String get path;
  (int, int, int) get identity;
  bool get directory;
  bool get closed;
  int get length;
  void check();
  void close();
}

abstract interface class _RestoreNativePort {
  bool get closed;
  void check();
  _RestoreRaw open(String path, OpenMode mode, {bool immutable = false});
  void idle(_RestoreRaw raw);
  void verify(_RestoreRaw raw, _RestorePin pin);
  void verifyReadFence(_RestoreRaw raw, _RestorePin pin);
  void acquireExclusive(_RestoreRaw raw, _RestorePin pin);
  void durableOriginal(_RestoreRaw raw);
  Future<void> copy(_RestoreRaw source, _RestoreRaw destination);
  void close();
}
