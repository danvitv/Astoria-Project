import 'dart:convert';
import '../../../credentials/secret_redactor.dart';

/// Bounded strict JSON boundary. No tolerant defaults, duplicate-key
/// overwrite, arbitrary serialization, or executable values.
abstract final class SupportSourceJson {
  /// Source text may itself contain JSON or custom HTTP headers. Header values
  /// are never useful source evidence and arbitrary header names cannot be
  /// classified as non-secret. Remove whole header containers, including
  /// JSON-in-JSON, before normal known-secret/pattern redaction and slicing.
  static String redactText(String raw, SecretRedactor redactor) {
    if (raw.length > redactor.maxInputLength) return SecretRedactor.limited;
    var nodes = 0;
    Object? visit(Object? value, int depth) {
      if (++nodes > 8192 || depth > 24) throw const FormatException();
      if (value is Map<String, Object?>) {
        return {
          for (final e in value.entries)
            e.key:
                SecretRedactor.isSecretField(e.key) ||
                    e.key
                        .toLowerCase()
                        .replaceAll(RegExp('[^a-z]'), '')
                        .contains('header')
                ? SecretRedactor.removed
                : visit(e.value, depth + 1),
        };
      }
      if (value is List) return value.map((v) => visit(v, depth + 1)).toList();
      if (value is String) {
        final trimmed = value.trimLeft();
        if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
          return jsonEncode(
            visit(
              decode(value, maxBytes: redactor.maxInputLength * 4),
              depth + 1,
            ),
          );
        }
        return redactor.redactText(value);
      }
      return value;
    }

    final trimmed = raw.trimLeft();
    if (trimmed.startsWith('{') || trimmed.startsWith('[')) {
      try {
        return redactor.redactText(
          jsonEncode(
            visit(decode(raw, maxBytes: redactor.maxInputLength * 4), 0),
          ),
        );
      } catch (_) {
        // JSON-like malformed or over-budget source text is not a safe fallback.
        return SecretRedactor.limited;
      }
    }
    // Raw custom HTTP header blocks have arbitrary names too. When source text
    // explicitly declares such a block, fail closed instead of guessing values.
    if (RegExp(
      r'^\s*(?:custom|extra|request)?[-_ ]*headers\s*[:=]',
      caseSensitive: false,
      multiLine: true,
    ).hasMatch(raw)) {
      return SecretRedactor.removed;
    }
    return redactor.redactText(raw);
  }

  static Object? decode(String raw, {int maxBytes = 65536}) {
    if (maxBytes < 1 || utf8.encode(raw).length > maxBytes) {
      throw const FormatException();
    }
    final parser = _SourceJsonParser(raw);
    final value = parser.value(0);
    parser.space();
    if (parser.offset != raw.length) throw const FormatException();
    return value;
  }

  static bool identity(Object? value) {
    if (value is! String || value.isEmpty || value.length > 128) return false;
    for (final rune in value.runes) {
      if (rune <= 0x20 ||
          (rune >= 0x7f && rune <= 0x9f) ||
          rune == 0xa0 ||
          rune == 0x1680 ||
          (rune >= 0x2000 && rune <= 0x200f) ||
          (rune >= 0x2028 && rune <= 0x202f) ||
          (rune >= 0x205f && rune <= 0x206f) ||
          rune == 0x3000 ||
          rune == 0xfeff ||
          (rune >= 0xd800 && rune <= 0xdfff)) {
        return false;
      }
    }
    return true;
  }
}

final class _SourceJsonParser {
  _SourceJsonParser(this.raw);
  final String raw;
  int offset = 0, nodes = 0;
  Never bad() => throw const FormatException();
  void space() {
    while (offset < raw.length &&
        const [0x20, 9, 10, 13].contains(raw.codeUnitAt(offset))) {
      offset++;
    }
  }

  bool take(String token) {
    if (!raw.startsWith(token, offset)) return false;
    offset += token.length;
    return true;
  }

  Object? value(int depth) {
    if (++nodes > 8192 || depth > 24) bad();
    space();
    if (offset == raw.length) bad();
    if (take('{')) {
      final result = <String, Object?>{};
      space();
      if (take('}')) return result;
      do {
        space();
        final key = text();
        if (key.length > 128 ||
            result.length >= 512 ||
            result.containsKey(key)) {
          bad();
        }
        space();
        if (!take(':')) bad();
        result[key] = value(depth + 1);
        space();
        if (take('}')) return result;
        if (!take(',')) bad();
      } while (true);
    }
    if (take('[')) {
      final result = <Object?>[];
      space();
      if (take(']')) return result;
      do {
        if (result.length >= 512) bad();
        result.add(value(depth + 1));
        space();
        if (take(']')) return result;
        if (!take(',')) bad();
      } while (true);
    }
    if (raw[offset] == '"') return text();
    if (take('true')) return true;
    if (take('false')) return false;
    if (take('null')) return null;
    final start = offset;
    while (offset < raw.length && '-+0123456789.eE'.contains(raw[offset])) {
      offset++;
    }
    if (offset == start) bad();
    final number = jsonDecode(raw.substring(start, offset));
    if (number is! num || !number.isFinite) bad();
    return number;
  }

  String text() {
    final start = offset;
    if (!take('"')) bad();
    while (offset < raw.length) {
      final char = raw[offset++];
      if (char == r'\') {
        if (offset == raw.length) bad();
        offset++;
      } else if (char == '"') {
        final decoded = jsonDecode(raw.substring(start, offset)) as String;
        for (var i = 0; i < decoded.length; i++) {
          final unit = decoded.codeUnitAt(i);
          if (unit >= 0xd800 && unit <= 0xdbff) {
            if (++i == decoded.length ||
                decoded.codeUnitAt(i) < 0xdc00 ||
                decoded.codeUnitAt(i) > 0xdfff) {
              bad();
            }
          } else if (unit >= 0xdc00 && unit <= 0xdfff) {
            bad();
          }
        }
        return decoded;
      }
    }
    bad();
  }
}
