part of 'support_report_private_key_store.dart';

extension _WindowsDpapi on SupportReportPrivateKeyStore {
  Uint8List _protect(Uint8List privateKey, SupportReportRecipient recipient) {
    final input = calloc<CRYPT_INTEGER_BLOB>(),
        out = calloc<CRYPT_INTEGER_BLOB>();
    final bytes = calloc<Uint8>(32), entropy = calloc<CRYPT_INTEGER_BLOB>();
    final public = Uint8List.fromList(recipient.descriptorJson.codeUnits);
    final entropyBytes = calloc<Uint8>(public.length);
    try {
      bytes.asTypedList(32).setAll(0, privateKey);
      input.ref
        ..cbData = 32
        ..pbData = bytes;
      entropyBytes.asTypedList(public.length).setAll(0, public);
      entropy.ref
        ..cbData = public.length
        ..pbData = entropyBytes;
      // UI_FORBIDDEN only: NEVER CRYPTPROTECT_LOCAL_MACHINE.
      if (CryptProtectData(input, nullptr, entropy, nullptr, nullptr, 1, out) ==
              0 ||
          out.ref.cbData < 1 ||
          out.ref.cbData > SupportReportPrivateKeyStore._maxProtectedBytes) {
        _refuse();
      }
      return Uint8List.fromList(out.ref.pbData.asTypedList(out.ref.cbData));
    } finally {
      bytes.asTypedList(32).fillRange(0, 32, 0);
      _zeroFreeOutput(out);
      calloc.free(bytes);
      calloc.free(input);
      calloc.free(out);
      calloc.free(entropyBytes);
      calloc.free(entropy);
    }
  }

  SecureKey _unprotect(Uint8List ciphertext, SupportReportRecipient recipient) {
    final input = calloc<CRYPT_INTEGER_BLOB>(),
        out = calloc<CRYPT_INTEGER_BLOB>();
    final bytes = calloc<Uint8>(ciphertext.length),
        entropy = calloc<CRYPT_INTEGER_BLOB>();
    final public = Uint8List.fromList(recipient.descriptorJson.codeUnits);
    final entropyBytes = calloc<Uint8>(public.length);
    try {
      bytes.asTypedList(ciphertext.length).setAll(0, ciphertext);
      input.ref
        ..cbData = ciphertext.length
        ..pbData = bytes;
      entropyBytes.asTypedList(public.length).setAll(0, public);
      entropy.ref
        ..cbData = public.length
        ..pbData = entropyBytes;
      if (CryptUnprotectData(
                input,
                nullptr,
                entropy,
                nullptr,
                nullptr,
                1,
                out,
              ) ==
              0 ||
          out.ref.cbData != 32) {
        _refuse();
      }
      return sodium.secureCopy(out.ref.pbData.asTypedList(32));
    } finally {
      _zeroFreeOutput(out);
      calloc.free(bytes);
      calloc.free(input);
      calloc.free(out);
      calloc.free(entropyBytes);
      calloc.free(entropy);
    }
  }

  void _zeroFreeOutput(Pointer<CRYPT_INTEGER_BLOB> out) {
    if (out.ref.pbData != nullptr) {
      out.ref.pbData
          .asTypedList(out.ref.cbData)
          .fillRange(0, out.ref.cbData, 0);
      LocalFree(out.ref.pbData);
    }
  }
}
