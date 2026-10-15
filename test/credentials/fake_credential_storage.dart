import 'dart:async';

import 'package:glaze_flutter/core/credentials/credential_storage.dart';

/// Only synthetic data. Hooks provide deterministic ordering/failure evidence.
final class FakeCredentialStorage implements CredentialStorage {
  final values = <String, String>{};
  final operations = <String>[];
  int reads = 0;
  Object? readError;
  Object? writeError;
  Object? deleteError;
  bool dropWrites = false;
  bool dropDeletes = false;
  Future<void> Function()? beforeRead;
  Future<void> Function()? beforeWrite;

  @override
  Future<String?> read(String key) async {
    reads++;
    operations.add('read');
    await beforeRead?.call();
    if (readError != null) throw readError!;
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    operations.add('write');
    await beforeWrite?.call();
    if (writeError != null) throw writeError!;
    if (!dropWrites) values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    operations.add('delete');
    if (deleteError != null) throw deleteError!;
    if (!dropDeletes) values.remove(key);
  }
}
