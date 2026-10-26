import 'dart:convert';

/// Streaming framing only. Each completed object is strictly decoded separately.
/// Memory is bounded by ONE complete 64 KiB message, never the history array.
final class HistoryJsonFramer {
  static const maxUnitBytes = 65536;
  int offset = 0, _depth = 0, _phase = 0;
  bool _string = false, _escape = false;
  final _unit = <int>[];
  bool get complete => _phase == 4;

  void add(List<int> bytes, void Function(String) onUnit) {
    for (final byte in bytes) {
      offset++;
      if (_depth != 0) {
        if (_unit.length == maxUnitBytes)
          throw const FormatException('Oversized unit');
        _unit.add(byte);
        if (_string) {
          if (_escape) {
            _escape = false;
          } else if (byte == 92) {
            _escape = true;
          } else if (byte == 34) {
            _string = false;
          }
        } else if (byte == 34) {
          _string = true;
        } else if (byte == 123 || byte == 91) {
          _depth++;
        } else if (byte == 125 || byte == 93) {
          if (--_depth == 0) {
            final raw = utf8.decode(_unit, allowMalformed: false);
            _unit.clear();
            _phase = 3;
            onUnit(raw);
          }
        }
        continue;
      }
      if (const [9, 10, 13, 32].contains(byte)) continue;
      if (_phase == 0 && byte == 91) {
        _phase = 1;
        continue;
      }
      if ((_phase == 1 || _phase == 2) && byte == 123) {
        _depth = 1;
        _unit.add(byte);
        continue;
      }
      if ((_phase == 1 || _phase == 3) && byte == 93) {
        _phase = 4;
        continue;
      }
      if (_phase == 3 && byte == 44) {
        _phase = 2;
        continue;
      }
      throw const FormatException('Invalid history framing');
    }
  }

  void finish() {
    if (!complete || _depth != 0 || _string)
      throw const FormatException('Incomplete history');
  }
}
