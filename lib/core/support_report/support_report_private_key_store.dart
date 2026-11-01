import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:sodium/sodium.dart';
import 'package:win32/win32.dart';

import 'support_report_error.dart';
import 'support_report_recipient.dart';
import 'support_report_windows_acl.dart';

part 'support_report_windows_dpapi.dart';

/// Windows DPAPI CurrentUser + exact owner-only ACL protected private key file.
/// File stores DPAPI ciphertext, never private JSON. Private bytes never leave
/// secure/native buffers. User-selected absolute path is CLI-only, not model I/O.
final class SupportReportPrivateKeyStore {
  SupportReportPrivateKeyStore(this.sodium);
  final Sodium sodium;
  static const _maxProtectedBytes = 16384;
  static const _magic = [65, 83, 84, 75];

  /// Public-only descriptor, written once on the exact create-new handle.
  /// No create-then-reopen race can substitute a different recipient file.
  void createDescriptor(String path, SupportReportRecipient recipient) {
    _platform();
    _path(path);
    final acl = SupportReportWindowsAcl();
    acl.withCurrentSid(
      (sid, text) => acl.withSecurityAttributes(text, (attributes) {
        final nativePath = path.toNativeUtf16();
        final handle = CreateFile(
          nativePath,
          GENERIC_WRITE | READ_CONTROL | DELETE,
          0,
          attributes,
          CREATE_NEW,
          FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
          0,
        );
        calloc.free(nativePath);
        if (handle == INVALID_HANDLE_VALUE) _refuse();
        var complete = false;
        try {
          _regular(handle);
          acl.verify(handle, sid);
          _write(
            handle,
            Uint8List.fromList('${recipient.descriptorJson}\n'.codeUnits),
          );
          if (FlushFileBuffers(handle) == 0) _refuse();
          acl.verify(handle, sid);
          complete = true;
        } finally {
          if (!complete) _discardHandle(handle);
          CloseHandle(handle);
        }
      }),
    );
  }

  void create(
    String path,
    SupportReportRecipient recipient,
    SecureKey privateKey,
  ) {
    _platform();
    _path(path);
    if (privateKey.length != 32) _refuse();
    final acl = SupportReportWindowsAcl();
    acl.withCurrentSid(
      (sid, sidText) => acl.withSecurityAttributes(sidText, (attributes) {
        final nativePath = path.toNativeUtf16();
        final handle = CreateFile(
          nativePath,
          GENERIC_WRITE | READ_CONTROL | DELETE,
          0,
          attributes,
          CREATE_NEW,
          FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
          0,
        );
        calloc.free(nativePath);
        if (handle == INVALID_HANDLE_VALUE) _refuse();
        var complete = false;
        try {
          _regular(handle);
          acl.verify(handle, sid);
          final protected = privateKey.runUnlockedSync(
            (bytes) => _protect(bytes, recipient),
          );
          try {
            _write(handle, Uint8List.fromList([..._magic, ...protected]));
            if (FlushFileBuffers(handle) == 0) _refuse();
            acl.verify(handle, sid);
            _regular(handle);
            complete = true;
          } finally {
            protected.fillRange(0, protected.length, 0);
          }
        } finally {
          if (!complete) _discardHandle(handle);
          CloseHandle(handle);
        }
      }),
    );
  }

  SecureKey load(String path, SupportReportRecipient recipient) {
    _platform();
    _path(path);
    final acl = SupportReportWindowsAcl();
    return acl.withCurrentSid((sid, _) {
      final nativePath = path.toNativeUtf16();
      final handle = CreateFile(
        nativePath,
        GENERIC_READ | READ_CONTROL,
        0,
        nullptr,
        OPEN_EXISTING,
        FILE_ATTRIBUTE_NORMAL | FILE_FLAG_OPEN_REPARSE_POINT,
        0,
      );
      calloc.free(nativePath);
      if (handle == INVALID_HANDLE_VALUE) _refuse();
      try {
        acl.verify(handle, sid);
        _regular(handle);
        final bytes = _read(handle);
        if (bytes.length < 5 ||
            !_magic.asMap().entries.every((e) => bytes[e.key] == e.value)) {
          _refuse();
        }
        final key = _unprotect(Uint8List.sublistView(bytes, 4), recipient);
        try {
          acl.verify(handle, sid);
          _regular(handle);
          return key;
        } catch (_) {
          key.dispose();
          rethrow;
        }
      } finally {
        CloseHandle(handle);
      }
    });
  }

  void _regular(int handle) {
    final info = calloc<BY_HANDLE_FILE_INFORMATION>();
    try {
      if (GetFileInformationByHandle(handle, info) == 0 ||
          info.ref.nNumberOfLinks != 1 ||
          (info.ref.dwFileAttributes &
                  (FILE_ATTRIBUTE_DIRECTORY | FILE_ATTRIBUTE_REPARSE_POINT)) !=
              0) {
        _refuse();
      }
    } finally {
      calloc.free(info);
    }
  }

  Uint8List _read(int handle) {
    final size = calloc<Int64>(), read = calloc<Uint32>();
    Pointer<Uint8> buffer = nullptr;
    try {
      if (GetFileSizeEx(handle, size) == 0 ||
          size.value < 5 ||
          size.value > _maxProtectedBytes + 4) {
        _refuse();
      }
      buffer = calloc<Uint8>(size.value);
      if (ReadFile(handle, buffer, size.value, read, nullptr) == 0 ||
          read.value != size.value) {
        _refuse();
      }
      return Uint8List.fromList(buffer.asTypedList(size.value));
    } finally {
      if (buffer != nullptr) calloc.free(buffer);
      calloc.free(size);
      calloc.free(read);
    }
  }

  void _write(int handle, Uint8List bytes) {
    final buffer = calloc<Uint8>(bytes.length), written = calloc<Uint32>();
    try {
      buffer.asTypedList(bytes.length).setAll(0, bytes);
      if (WriteFile(handle, buffer, bytes.length, written, nullptr) == 0 ||
          written.value != bytes.length) {
        _refuse();
      }
    } finally {
      calloc.free(buffer);
      calloc.free(written);
    }
  }

  void _discardHandle(int handle) {
    final dispose = calloc<Int32>()..value = 1;
    try {
      SetFileInformationByHandle(handle, 4, dispose, sizeOf<Int32>());
    } finally {
      calloc.free(dispose);
    }
  }

  void _path(String path) {
    // Local drive only: exclude devices, UNC, alternate streams and aliases.
    if (!RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path) ||
        path.substring(2).contains(':') ||
        path.contains('\u0000') ||
        path.contains('..') ||
        path
            .split(RegExp(r'[\\/]'))
            .skip(1)
            .any((s) => s.isEmpty || s.endsWith('.') || s.endsWith(' '))) {
      _refuse();
    }
  }

  void _platform() {
    if (!Platform.isWindows) {
      throw const SupportReportException(
        SupportReportFailure.unsupportedPlatform,
      );
    }
  }

  Never _refuse() => throw const SupportReportException(
    SupportReportFailure.protectedKeyUnavailable,
  );
}
