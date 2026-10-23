part of 'support_model_provenance_codec.dart';

/// Bounded grammar/Unicode/duplicate-key pass BEFORE jsonDecode can construct a
/// tree or overwrite escaped-equivalent keys. Builds only bounded object keys.
final class _ProvenanceJsonScanner {
  _ProvenanceJsonScanner(this.raw);

  final String raw;
  var offset = 0;
  var nodes = 0;

  void check() {
    if (raw.length > SupportModelProvenanceLimits.maxRawCharacters) {
      _reject(SupportModelProvenanceFailure.limitExceeded);
    }
    _value(0);
    _space();
    if (offset != raw.length) _invalid();
  }

  void _value(int depth) {
    if (++nodes > SupportModelProvenanceLimits.maxJsonNodes ||
        depth > SupportModelProvenanceLimits.maxJsonDepth) {
      _reject(SupportModelProvenanceFailure.limitExceeded);
    }
    _space();
    if (offset >= raw.length) _invalid();
    switch (raw.codeUnitAt(offset)) {
      case 0x7b:
        _objectValue(depth + 1);
      case 0x5b:
        _arrayValue(depth + 1);
      case 0x22:
        _text(false);
      case 0x74:
        _literal('true');
      case 0x66:
        _literal('false');
      case 0x6e:
        _literal('null');
      default:
        _number();
    }
  }

  void _objectValue(int depth) {
    _containerDepth(depth);
    offset++;
    _space();
    if (_take(0x7d)) return;
    final keys = <String>{};
    do {
      _space();
      if (keys.length >=
          SupportModelProvenanceLimits.maxDeclarationsAndReferences) {
        _reject(SupportModelProvenanceFailure.limitExceeded);
      }
      final key = _text(true)!;
      if (!keys.add(key)) _reject(SupportModelProvenanceFailure.duplicateKey);
      _space();
      if (!_take(0x3a)) _invalid();
      _value(depth);
      _space();
      if (_take(0x7d)) return;
      if (!_take(0x2c)) _invalid();
    } while (true);
  }

  void _arrayValue(int depth) {
    _containerDepth(depth);
    offset++;
    _space();
    if (_take(0x5d)) return;
    var count = 0;
    do {
      if (++count > SupportModelProvenanceLimits.maxIdsPerSource) {
        _reject(SupportModelProvenanceFailure.limitExceeded);
      }
      _value(depth);
      _space();
      if (_take(0x5d)) return;
      if (!_take(0x2c)) _invalid();
    } while (true);
  }

  String? _text(bool key) {
    if (!_take(0x22)) _invalid();
    final units = key ? <int>[] : null;
    var highSurrogate = false;
    while (offset < raw.length) {
      var unit = raw.codeUnitAt(offset++);
      if (unit == 0x22) {
        if (highSurrogate) _invalid();
        return units == null ? null : String.fromCharCodes(units);
      }
      if (unit < 0x20) _invalid();
      if (unit == 0x5c) {
        if (offset >= raw.length) _invalid();
        unit = switch (raw.codeUnitAt(offset++)) {
          0x22 => 0x22,
          0x5c => 0x5c,
          0x2f => 0x2f,
          0x62 => 0x08,
          0x66 => 0x0c,
          0x6e => 0x0a,
          0x72 => 0x0d,
          0x74 => 0x09,
          0x75 => _hexUnit(),
          _ => _invalid(),
        };
      }
      if (highSurrogate) {
        if (unit < 0xdc00 || unit > 0xdfff) _invalid();
        highSurrogate = false;
      } else if (unit >= 0xd800 && unit <= 0xdbff) {
        highSurrogate = true;
      } else if (unit >= 0xdc00 && unit <= 0xdfff) {
        _invalid();
      }
      if (units != null) {
        if (units.length >=
            SupportModelProvenanceLimits.maxIdentifierCharacters) {
          _reject(SupportModelProvenanceFailure.limitExceeded);
        }
        units.add(unit);
      }
    }
    _invalid();
  }

  int _hexUnit() {
    if (raw.length - offset < 4) _invalid();
    var value = 0;
    for (var i = 0; i < 4; i++) {
      final unit = raw.codeUnitAt(offset++);
      final digit = switch (unit) {
        >= 0x30 && <= 0x39 => unit - 0x30,
        >= 0x41 && <= 0x46 => unit - 0x41 + 10,
        >= 0x61 && <= 0x66 => unit - 0x61 + 10,
        _ => _invalid(),
      };
      value = value * 16 + digit;
    }
    return value;
  }

  void _number() {
    _take(0x2d);
    if (!_take(0x30)) {
      if (offset >= raw.length ||
          raw.codeUnitAt(offset) < 0x31 ||
          raw.codeUnitAt(offset) > 0x39) {
        _invalid();
      }
      _digits();
    }
    if (_take(0x2e)) {
      if (!_digits()) _invalid();
    }
    if (_take(0x65) || _take(0x45)) {
      if (!_take(0x2b)) _take(0x2d);
      if (!_digits()) _invalid();
    }
  }

  bool _digits() {
    final start = offset;
    while (offset < raw.length) {
      final unit = raw.codeUnitAt(offset);
      if (unit < 0x30 || unit > 0x39) break;
      offset++;
    }
    return offset != start;
  }

  void _literal(String literal) {
    if (!raw.startsWith(literal, offset)) _invalid();
    offset += literal.length;
  }

  void _space() {
    while (offset < raw.length) {
      final unit = raw.codeUnitAt(offset);
      if (unit != 0x20 && unit != 0x09 && unit != 0x0a && unit != 0x0d) break;
      offset++;
    }
  }

  bool _take(int unit) {
    if (offset >= raw.length || raw.codeUnitAt(offset) != unit) return false;
    offset++;
    return true;
  }

  void _containerDepth(int depth) {
    if (depth > SupportModelProvenanceLimits.maxJsonDepth) {
      _reject(SupportModelProvenanceFailure.limitExceeded);
    }
  }

  Never _invalid() => _reject(SupportModelProvenanceFailure.invalidEncoding);
}
