import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';

import 'private_text_event_decoder.dart';
import 'private_text_outcome.dart';
import 'private_text_request.dart';

/// Byte-framed SSE: each complete UTF-8 frame is validated, projected, then
/// delivered as one encoded chunk to legacy parsers. No raw event is forwarded.
final class PrivateTextStreamGuard {
  PrivateTextStreamGuard({
    required this.decoder,
    required this.cancelToken,
    required this.isCurrent,
    this.onActivity,
  });
  final PrivateTextEventDecoder decoder;
  final CancelToken cancelToken;
  final bool Function() isCurrent;
  final void Function()? onActivity;
  PrivateTextReason reason = PrivateTextReason.none;
  StreamSubscription<Uint8List>? _subscription;
  late StreamController<Uint8List> _output;
  final _line = <int>[];
  final _data = <String>[];
  String? _event;
  int _wireBytes = 0;
  int _frameBytes = 0;
  int _frames = 0;
  bool _closed = false;
  bool _active = false;

  Stream<Uint8List> bind(Stream<Uint8List> input) {
    _output = StreamController<Uint8List>(
      onListen: () {
        if (cancelToken.isCancelled) {
          unawaited(_stop());
          return;
        }
        _subscription = input.listen(
          _chunk,
          onError: (Object _, StackTrace _) =>
              _failure(PrivateTextReason.transport),
          onDone: _eof,
          cancelOnError: true,
        );
      },
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: () => _stop(),
    );
    unawaited(cancelToken.whenCancel.then((_) => _stop()));
    return _output.stream;
  }

  void _chunk(Uint8List bytes) {
    if (_closed) return;
    if (cancelToken.isCancelled || !isCurrent()) {
      if (!cancelToken.isCancelled) {
        reason = PrivateTextReason.notCurrent;
        cancelToken.cancel();
      }
      unawaited(_stop());
      return;
    }
    _wireBytes += bytes.length;
    if (_wireBytes > PrivateTextLimits.wireBytes) {
      _failure(PrivateTextReason.wireLimit);
      return;
    }
    try {
      for (final byte in bytes) {
        if (_closed) break;
        if (_line.isEmpty && (cancelToken.isCancelled || !isCurrent())) {
          if (!cancelToken.isCancelled) {
            reason = PrivateTextReason.notCurrent;
            cancelToken.cancel();
          }
          unawaited(_stop());
          break;
        }
        if (++_frameBytes > PrivateTextLimits.frameBytes) {
          throw const PrivateTextFailure(PrivateTextReason.wireLimit);
        }
        if (byte == 10) {
          _consumeLine();
        } else {
          _line.add(byte);
        }
      }
    } on PrivateTextFailure catch (failure) {
      _failure(failure.reason);
    } catch (_) {
      _failure(PrivateTextReason.malformed);
    }
  }

  void _consumeLine() {
    if (_line.isNotEmpty && _line.last == 13) _line.removeLast();
    final line = utf8.decode(_line); // strict; a code point cannot cross LF.
    _line.clear();
    if (line.isEmpty) {
      _frame();
      _frameBytes = 0;
      return;
    }
    if (line.startsWith(':')) return;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        _data.add(value);
      case 'event':
        if (_event != null) {
          throw const PrivateTextFailure(PrivateTextReason.malformed);
        }
        _event = value;
      case 'id':
      case 'retry':
        break; // SSE framing only; no reconnect is implemented.
      default:
        throw const PrivateTextFailure(PrivateTextReason.malformed);
    }
  }

  void _frame() {
    if (_data.isEmpty) {
      if (_event != null) {
        throw const PrivateTextFailure(PrivateTextReason.malformed);
      }
      return;
    }
    if (++_frames > 8192) {
      throw const PrivateTextFailure(PrivateTextReason.wireLimit);
    }
    final payload = _data.join('\n');
    _data.clear();
    final event = _event;
    _event = null;
    if (event == 'error') {
      throw const PrivateTextFailure(PrivateTextReason.providerError);
    }
    if (payload == '[DONE]') {
      if (!decoder.acceptsDone) {
        throw const PrivateTextFailure(PrivateTextReason.malformed);
      }
      decoder.done();
      _output.add(Uint8List.fromList(utf8.encode('data: [DONE]\n\n')));
    } else {
      final parsed = decoder.decode(payload);
      if (event != null && event != 'message' && parsed['type'] != event) {
        throw const PrivateTextFailure(PrivateTextReason.malformed);
      }
      final projected = decoder.consume(parsed);
      for (final item in projected) {
        _output.add(
          Uint8List.fromList(utf8.encode('data: ${jsonEncode(item)}\n\n')),
        );
      }
    }
    if (!_active) {
      _active = true;
      onActivity?.call(); // activity only, never text/reasoning/provider JSON.
    }
    if (decoder.terminal) unawaited(_stop());
  }

  void _eof() {
    if (_closed) return;
    try {
      // Compatibility: a fully valid terminal JSON line may omit final LF.
      // Partial JSON/UTF-8 and nonterminal data still fail, never complete.
      if (_line.isNotEmpty) _consumeLine();
      if (_data.isNotEmpty) _frame();
      if (_event != null || !decoder.canFinishAtEof) {
        throw const PrivateTextFailure(PrivateTextReason.unexpectedEof);
      }
      decoder.terminal = true;
      unawaited(_stop());
    } on PrivateTextFailure catch (failure) {
      _failure(failure.reason);
    } catch (_) {
      _failure(PrivateTextReason.malformed);
    }
  }

  void _failure(PrivateTextReason failure) {
    if (_closed) return;
    reason = failure;
    _output.addError(PrivateTextFailure(failure));
    unawaited(_stop());
  }

  Future<void> _stop() async {
    if (_closed) return;
    _closed = true;
    _line.clear();
    _data.clear();
    try {
      await _subscription?.cancel();
    } catch (_) {
      /* No arbitrary error object is retained or stringified. */
    }
    unawaited(_output.close());
  }
}
