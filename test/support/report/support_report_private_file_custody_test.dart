import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sodium/sodium.dart';
import 'package:win32/win32.dart';
import 'package:glaze_flutter/core/support_report/support_report_error.dart';
import 'package:glaze_flutter/core/support_report/support_report_private_key_store.dart';
import 'package:glaze_flutter/core/support_report/support_report_recipient.dart';

typedef _ConvertN =
    Int32 Function(
      Pointer<Utf16>,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Uint32>,
    );
typedef _ConvertD =
    int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _SetSecurityN = Int32 Function(Pointer<Utf16>, Uint32, Pointer<Void>);
typedef _SetSecurityD = int Function(Pointer<Utf16>, int, Pointer<Void>);
typedef _HardLinkN =
    Int32 Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);
typedef _HardLinkD =
    int Function(Pointer<Utf16>, Pointer<Utf16>, Pointer<Void>);

void main() {
  test(
    'synthetic protected file rejects hardlink aliases and a deliberately broadened DACL',
    () async {
      if (!Platform.isWindows) return;
      final sodium = await SodiumInit.init();
      final keys = sodium.crypto.box.keyPair();
      final recipient = SupportReportRecipient(
        keyId: 'synthetic-custody',
        publicKey: keys.publicKey,
      );
      final store = SupportReportPrivateKeyStore(sodium);
      final dir = await Directory.systemTemp.createTemp(
        'astoria-synthetic-key-custody-',
      );
      final path = '${dir.path}${Platform.pathSeparator}private.key';
      final alias = '${dir.path}${Platform.pathSeparator}alias.key';
      try {
        store.create(path, recipient, keys.secretKey);
        final source = path.toNativeUtf16(), dest = alias.toNativeUtf16();
        try {
          final link = DynamicLibrary.open(
            'kernel32.dll',
          ).lookupFunction<_HardLinkN, _HardLinkD>('CreateHardLinkW');
          expect(link(dest, source, nullptr), isNot(0));
        } finally {
          calloc.free(source);
          calloc.free(dest);
        }
        expect(
          () => store.load(path, recipient),
          throwsA(isA<SupportReportException>()),
        );
        await File(alias).delete();
        final loaded = store.load(path, recipient);
        loaded.dispose();
        final library = DynamicLibrary.open('advapi32.dll');
        final descriptor = calloc<Pointer<Void>>();
        final text = 'D:P(A;;FA;;;WD)'.toNativeUtf16(),
            nativePath = path.toNativeUtf16();
        try {
          final convert = library.lookupFunction<_ConvertN, _ConvertD>(
            'ConvertStringSecurityDescriptorToSecurityDescriptorW',
          );
          final set = library.lookupFunction<_SetSecurityN, _SetSecurityD>(
            'SetFileSecurityW',
          );
          expect(convert(text, 1, descriptor, nullptr), isNot(0));
          expect(
            set(nativePath, DACL_SECURITY_INFORMATION, descriptor.value),
            isNot(0),
          );
        } finally {
          if (descriptor.value != nullptr) LocalFree(descriptor.value);
          calloc.free(descriptor);
          calloc.free(text);
          calloc.free(nativePath);
        }
        expect(
          () => store.load(path, recipient),
          throwsA(isA<SupportReportException>()),
        );
      } finally {
        keys.secretKey.dispose();
        await dir.delete(recursive: true);
      }
    },
  );
}
