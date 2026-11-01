import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'support_report_error.dart';

typedef _ConvertSdN =
    Int32 Function(
      Pointer<Utf16>,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Uint32>,
    );
typedef _ConvertSdD =
    int Function(Pointer<Utf16>, int, Pointer<Pointer<Void>>, Pointer<Uint32>);
typedef _GetSecurityN =
    Uint32 Function(
      IntPtr,
      Int32,
      Uint32,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<ACL>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
    );
typedef _GetSecurityD =
    int Function(
      int,
      int,
      int,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<ACL>>,
      Pointer<Pointer<Void>>,
      Pointer<Pointer<Void>>,
    );
typedef _ControlN =
    Int32 Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>);
typedef _ControlD =
    int Function(Pointer<Void>, Pointer<Uint16>, Pointer<Uint32>);
typedef _AceN = Int32 Function(Pointer<ACL>, Uint32, Pointer<Pointer<Void>>);
typedef _AceD = int Function(Pointer<ACL>, int, Pointer<Pointer<Void>>);
typedef _SidTextN = Int32 Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _SidTextD = int Function(Pointer<Void>, Pointer<Pointer<Utf16>>);
typedef _EqualSidN = Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _EqualSidD = int Function(Pointer<Void>, Pointer<Void>);

/// CurrentUser-only file DACL created AT file creation, then verified on the
/// SAME unshared handle before any key bytes are read or written. No icacls,
/// subprocess, filename re-open, inherited allow ACE, null DACL or SYSTEM ACE.
final class SupportReportWindowsAcl {
  SupportReportWindowsAcl();
  final _advapi = DynamicLibrary.open('advapi32.dll');
  Never _refuse() => throw const SupportReportException(
    SupportReportFailure.protectedKeyUnavailable,
  );

  T withCurrentSid<T>(T Function(Pointer<Void>, String) work) {
    final token = calloc<IntPtr>(), length = calloc<Uint32>();
    Pointer<Uint8> data = nullptr;
    final text = calloc<Pointer<Utf16>>();
    try {
      if (OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, token) == 0) {
        _refuse();
      }
      GetTokenInformation(token.value, 1, nullptr, 0, length);
      if (length.value < sizeOf<IntPtr>() || length.value > 65536) _refuse();
      data = calloc<Uint8>(length.value);
      if (GetTokenInformation(token.value, 1, data, length.value, length) ==
          0) {
        _refuse();
      }
      final sid = data.cast<Pointer<Void>>().value;
      final toText = _advapi.lookupFunction<_SidTextN, _SidTextD>(
        'ConvertSidToStringSidW',
      );
      if (toText(sid, text) == 0 || text.value == nullptr) _refuse();
      return work(sid, text.value.toDartString());
    } finally {
      if (text.value != nullptr) LocalFree(text.value);
      if (token.value != 0) CloseHandle(token.value);
      if (data != nullptr) calloc.free(data);
      calloc.free(token);
      calloc.free(length);
      calloc.free(text);
    }
  }

  T withSecurityAttributes<T>(
    String sid,
    T Function(Pointer<SECURITY_ATTRIBUTES>) work,
  ) {
    final descriptor = calloc<Pointer<Void>>(),
        attributes = calloc<SECURITY_ATTRIBUTES>();
    final text = 'O:${sid}D:P(A;;FA;;;$sid)'.toNativeUtf16();
    try {
      final convert = _advapi.lookupFunction<_ConvertSdN, _ConvertSdD>(
        'ConvertStringSecurityDescriptorToSecurityDescriptorW',
      );
      if (convert(text, 1, descriptor, nullptr) == 0 ||
          descriptor.value == nullptr) {
        _refuse();
      }
      attributes.ref
        ..nLength = sizeOf<SECURITY_ATTRIBUTES>()
        ..lpSecurityDescriptor = descriptor.value
        ..bInheritHandle = 0;
      return work(attributes);
    } finally {
      if (descriptor.value != nullptr) LocalFree(descriptor.value);
      calloc.free(descriptor);
      calloc.free(attributes);
      calloc.free(text);
    }
  }

  void verify(int handle, Pointer<Void> sid) {
    final owner = calloc<Pointer<Void>>(),
        dacl = calloc<Pointer<ACL>>(),
        sd = calloc<Pointer<Void>>();
    final control = calloc<Uint16>(),
        revision = calloc<Uint32>(),
        ace = calloc<Pointer<Void>>();
    try {
      final get = _advapi.lookupFunction<_GetSecurityN, _GetSecurityD>(
        'GetSecurityInfo',
      );
      final equalSid = _advapi.lookupFunction<_EqualSidN, _EqualSidD>(
        'EqualSid',
      );
      if (get(
                handle,
                1,
                OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION,
                owner,
                nullptr,
                dacl,
                nullptr,
                sd,
              ) !=
              0 ||
          sd.value == nullptr ||
          dacl.value == nullptr ||
          owner.value == nullptr ||
          equalSid(owner.value, sid) == 0) {
        _refuse();
      }
      final getControl = _advapi.lookupFunction<_ControlN, _ControlD>(
        'GetSecurityDescriptorControl',
      );
      if (getControl(sd.value, control, revision) == 0 ||
          (control.value & 0x1000) == 0 ||
          (control.value & 4) == 0 ||
          dacl.value.ref.AceCount != 1) {
        _refuse();
      }
      final getAce = _advapi.lookupFunction<_AceN, _AceD>('GetAce');
      if (getAce(dacl.value, 0, ace) == 0 || ace.value == nullptr) _refuse();
      // ACCESS_ALLOWED_ACE layout: header 4 bytes, mask 4, SID starts at 8.
      final bytes = ace.value.cast<Uint8>();
      if (bytes[0] != 0 ||
          bytes[1] != 0 ||
          (bytes + 4).cast<Uint32>().value != 0x1f01ff ||
          equalSid((bytes + 8).cast<Void>(), sid) == 0) {
        _refuse();
      }
    } finally {
      if (sd.value != nullptr) LocalFree(sd.value);
      calloc.free(owner);
      calloc.free(dacl);
      calloc.free(sd);
      calloc.free(control);
      calloc.free(revision);
      calloc.free(ace);
    }
  }
}
