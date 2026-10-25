import 'package:glaze_flutter/core/credentials/credential_storage.dart';

/// Synthetic single-value backend. No provider/plugin/installed vault is used.
final class StartupMemoryKeys implements CredentialStorage {
  StartupMemoryKeys(this.value, {this.failRead = false});
  final String? value;
  final bool failRead;
  int reads = 0, writes = 0, deletes = 0;

  @override
  Future<String?> read(String key) async {
    reads++;
    if (failRead) throw StateError('Synthetic read failure');
    return value;
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
  }
}
