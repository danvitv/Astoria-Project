import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/services.dart';

import '../../../core/support_report/support_report_save_port.dart';

enum SupportReportSavePlatform { windows, android, unsupported }

typedef SupportReportWindowsSelector =
    Future<String?> Function(String fileName);
typedef SupportReportWindowsWriter =
    void Function(String privatePath, Uint8List ciphertext);

/// One original operation, one selector, one write attempt. Construct a fresh
/// adapter for a retry. Paths/URIs never leave private destination custody.
///
/// The trusted validator must check the actual report packet codec, not merely
/// a filename or prefix. Source/consent ROOT synchronization belongs to the
/// coordinator's final [isCurrent] callback; this adapter cannot fence SQLite.
final class SupportReportPlatformSave implements SupportReportSavePort {
  SupportReportPlatformSave({
    required bool Function(Uint8List) validateCiphertext,
    SupportReportSavePlatform? platform,
    SupportReportWindowsSelector? windowsSelector,
    SupportReportWindowsWriter? windowsWriter,
    MethodChannel? androidChannel,
  }) : _validate = validateCiphertext,
       _platform = platform ?? _hostPlatform(),
       _selectWindows = windowsSelector ?? _selectWindowsFile,
       _writeWindows = windowsWriter ?? _writeWindowsFile,
       _channel = androidChannel ?? const MethodChannel(channelName);

  static const channelName = 'app.astoria/support-report-save';
  static const neutralFileName = 'astoria-support-report.astreport';

  /// Transport ceiling, deliberately above the codec's stricter packet ceiling.
  /// Android repeats this 4 MiB limit before copying/streaming channel bytes.
  static const maxCiphertextBytes = 4 * 1024 * 1024;

  final bool Function(Uint8List) _validate;
  final SupportReportSavePlatform _platform;
  final SupportReportWindowsSelector _selectWindows;
  final SupportReportWindowsWriter _writeWindows;
  final MethodChannel _channel;
  final Object _issuer = Object();
  bool _canceled = false, _started = false;
  String? _request;
  _ReportDestination? _destination;
  Completer<SupportReportSaveDestination?>? _selection;

  static SupportReportSavePlatform _hostPlatform() => Platform.isWindows
      ? SupportReportSavePlatform.windows
      : Platform.isAndroid
      ? SupportReportSavePlatform.android
      : SupportReportSavePlatform.unsupported;

  static Future<String?> _selectWindowsFile(String name) => FilePicker.saveFile(
    dialogTitle: 'Save encrypted support report',
    fileName: name,
    type: FileType.custom,
    allowedExtensions: const ['astreport'],
    // Crucially no bytes. Android must never use this plugin write-before-return.
  );

  static void _writeWindowsFile(String path, Uint8List bytes) {
    // The native save dialog owns explicit selected-file overwrite consent.
    // No directory creation, fallback, temporary file, or broad deletion.
    File(path).writeAsBytesSync(bytes, flush: true);
  }

  bool _current(bool Function() guard) {
    if (_canceled) return false;
    try {
      if (guard() && !_canceled) return true;
    } catch (_) {
      // A refused/throwing native custody callback is terminal, not retryable.
    }
    _canceled = true;
    return false;
  }

  @override
  Future<SupportReportSaveDestination?> chooseDestination({
    required String fileName,
    required bool Function() isCurrent,
  }) {
    if (_started ||
        !_current(isCurrent) ||
        _platform == SupportReportSavePlatform.unsupported) {
      return Future.value(null);
    }
    _started = true;
    // Ignore caller names: metadata from a model must not name an OS artifact.
    final completion = Completer<SupportReportSaveDestination?>();
    _selection = completion;
    unawaited(_observeSelection(isCurrent, completion));
    return completion.future;
  }

  Future<void> _observeSelection(
    bool Function() original,
    Completer<SupportReportSaveDestination?> completion,
  ) async {
    try {
      String? location;
      if (_platform == SupportReportSavePlatform.windows) {
        location = await _selectWindows(neutralFileName);
      } else {
        final begun = await _channel.invokeMapMethod<String, Object?>(
          'beginRequest',
        );
        final issued = begun?['request'];
        if (begun?['status'] != 'ready' ||
            issued is! String ||
            issued.isEmpty) {
          return;
        }
        _request = issued;
        if (!_current(original)) return;
        final selected = await _channel.invokeMapMethod<String, Object?>(
          'choose',
          {'request': issued, 'neutralName': neutralFileName},
        );
        final token = selected?['token'];
        if (selected?['status'] == 'selected' &&
            token is String &&
            token.isNotEmpty) {
          location = token;
        }
      }
      if (!_current(original) || location == null || location.isEmpty) return;
      final destination = _ReportDestination(_issuer, original, location);
      _destination = destination;
      if (!completion.isCompleted) completion.complete(destination);
    } catch (_) {
      // No exception, URI, path, payload or key is logged or returned.
    } finally {
      if (!completion.isCompleted) completion.complete(null);
      _selection = null;
      if (_destination == null) {
        _canceled = true;
        await _cancelNative();
      }
    }
  }

  @override
  Future<SupportReportSaveResult> commit({
    required SupportReportSaveDestination destination,
    required Uint8List ciphertext,
    required bool Function() isCurrent,
  }) async {
    if (destination is! _ReportDestination ||
        !identical(destination._issuer, _issuer) ||
        !identical(destination, _destination) ||
        destination._used) {
      return const SupportReportSaveResult(
        SupportReportSaveStatus.refused,
        reason: 'invalid_destination',
      );
    }
    destination._used =
        true; // One use even if validation or admission refuses.
    if (!_current(destination._original) || !_current(isCurrent)) {
      await _cancelNative();
      return const SupportReportSaveResult(
        SupportReportSaveStatus.canceled,
        reason: 'not_current',
      );
    }
    if (ciphertext.isEmpty || ciphertext.length > maxCiphertextBytes) {
      await cancel();
      return const SupportReportSaveResult(
        SupportReportSaveStatus.refused,
        reason: 'invalid_ciphertext',
      );
    }
    // Copy BEFORE validation and hand off an unmodifiable view. Caller/validator
    // mutations cannot replace validated ciphertext while an OS call is pending.
    final frozen = Uint8List.fromList(ciphertext).asUnmodifiableView();
    var valid = false;
    try {
      valid = _validate(frozen);
    } catch (_) {
      // A validator exception refuses the write, with no exception disclosure.
    }
    if (!valid) {
      await cancel();
      return const SupportReportSaveResult(
        SupportReportSaveStatus.refused,
        reason: 'invalid_ciphertext',
      );
    }
    // No await between final original/native/source admission and I/O handoff.
    if (!_current(destination._original) || !_current(isCurrent)) {
      await _cancelNative();
      return const SupportReportSaveResult(
        SupportReportSaveStatus.canceled,
        reason: 'not_current',
      );
    }
    if (_platform == SupportReportSavePlatform.windows) {
      try {
        // Synchronous bounded write+flush avoids a validate-await-open gap.
        // OS I/O may block. Dart cannot cancel an admitted synchronous write;
        // failure may leave ciphertext/partial ciphertext, never claim absence.
        _writeWindows(destination._location, frozen);
        return const SupportReportSaveResult(
          SupportReportSaveStatus.saved,
          fileName: neutralFileName,
        );
      } catch (_) {
        return const SupportReportSaveResult(
          SupportReportSaveStatus.failed,
          reason: 'write_incomplete',
        );
      }
    }
    try {
      final reply = await _channel.invokeMapMethod<String, Object?>('commit', {
        'request': _request,
        'token': destination._location,
        'neutralName': neutralFileName,
        'bytes': frozen,
      });
      // Do not reinterpret an admitted native saved result after Dart scope
      // changes. Native cancellation wins before open; later I/O is truthful.
      return switch (reply?['status']) {
        'saved' => const SupportReportSaveResult(
          SupportReportSaveStatus.saved,
          fileName: neutralFileName,
        ),
        'canceled' => const SupportReportSaveResult(
          SupportReportSaveStatus.canceled,
          reason: 'native_canceled',
        ),
        'refused' => const SupportReportSaveResult(
          SupportReportSaveStatus.refused,
          reason: 'native_refused',
        ),
        _ => const SupportReportSaveResult(
          SupportReportSaveStatus.failed,
          reason: 'write_incomplete',
        ),
      };
    } catch (_) {
      // A lost reply cannot prove that no file was written.
      return const SupportReportSaveResult(
        SupportReportSaveStatus.failed,
        reason: 'write_incomplete',
      );
    }
  }

  Future<void> _cancelNative() async {
    final request = _request;
    if (_platform != SupportReportSavePlatform.android || request == null) {
      return;
    }
    try {
      await _channel.invokeMethod<void>('cancel', {'request': request});
    } catch (_) {
      // Already closed/replaced native Activity, no sensitive diagnostics.
    }
  }

  @override
  Future<void> cancel() async {
    _canceled = true;
    final pending = _selection;
    if (pending != null && !pending.isCompleted) pending.complete(null);
    await _cancelNative();
  }
}

final class _ReportDestination implements SupportReportSaveDestination {
  _ReportDestination(this._issuer, this._original, this._location);
  final Object _issuer;
  final bool Function() _original;
  final String _location;
  bool _used = false;
}
