import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'sqlite_native_abi_probe.dart';

void main() {
  test(
    'SQLite restore ABI shipped module exposes required native controls',
    () {
      final status = probeSqliteNativeRestoreAbi(
        approvedTempRoot: Directory(
          r'C:\Users\Даниил\AppData\Local\Temp\opencode',
        ),
      );
      expect(status, SqliteNativeAbiStatus.supported);
    },
  );
}
