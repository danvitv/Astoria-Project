part of 'native_provider_transport.dart';

final class _NativeFrame {
  const _NativeFrame(this.event, this.payload);
  final String? event;
  final String payload;
}

/// Strict byte framing, private because these frames still contain provider
/// material. No public stream/parser callback ever receives a raw frame.
final class _NativeSseFrames {
  final _line = <int>[];
  final _data = <String>[];
  String? _event;
  int _wire = 0;
  int _frame = 0;
  int _count = 0;

  Iterable<_NativeFrame> add(Uint8List bytes) sync* {
    _wire += bytes.length;
    _nativeRequire(
      _wire <= NativeProviderTransportLimits.wireBytes,
      NativeProviderTransportReason.wireLimit,
    );
    for (final byte in bytes) {
      _nativeRequire(
        ++_frame <= NativeProviderTransportLimits.frameBytes,
        NativeProviderTransportReason.wireLimit,
      );
      if (byte != 10) {
        _line.add(byte);
      } else {
        final frame = _consumeLine();
        if (frame != null) yield frame;
      }
    }
  }

  Iterable<_NativeFrame> finish() sync* {
    if (_line.isNotEmpty) {
      final frame = _consumeLine();
      if (frame != null) yield frame;
    }
    if (_data.isNotEmpty) yield _takeFrame();
    _nativeRequire(_event == null, NativeProviderTransportReason.unexpectedEof);
  }

  _NativeFrame? _consumeLine() {
    if (_line.isNotEmpty && _line.last == 13) _line.removeLast();
    String line;
    try {
      line = utf8.decode(_line);
    } catch (_) {
      _nativeFail(NativeProviderTransportReason.malformed);
    }
    _line.clear();
    if (line.isEmpty) {
      _frame = 0;
      if (_data.isEmpty) {
        _nativeRequire(_event == null);
        return null;
      }
      return _takeFrame();
    }
    if (line.startsWith(':')) return null;
    final colon = line.indexOf(':');
    final field = colon < 0 ? line : line.substring(0, colon);
    var value = colon < 0 ? '' : line.substring(colon + 1);
    if (value.startsWith(' ')) value = value.substring(1);
    switch (field) {
      case 'data':
        _data.add(value);
      case 'event':
        _nativeRequire(_event == null);
        _event = value;
      case 'id':
      case 'retry':
        break; // No reconnection or retry implementation.
      default:
        _nativeFail(NativeProviderTransportReason.malformed);
    }
    return null;
  }

  _NativeFrame _takeFrame() {
    _nativeRequire(
      ++_count <= NativeProviderTransportLimits.frames,
      NativeProviderTransportReason.wireLimit,
    );
    final frame = _NativeFrame(_event, _data.join('\n'));
    _data.clear();
    _event = null;
    _nativeRequire(
      frame.event != 'error',
      NativeProviderTransportReason.providerError,
    );
    return frame;
  }
}
