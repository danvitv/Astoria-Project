import 'dart:convert';

/// Lossless structural JSON observation. Never compile/evaluate regex or script
/// text, normalize legacy fields, generate IDs, or re-encode the saved document.
final class NativeGlobalRegexJson {
  NativeGlobalRegexJson._(this.raw, this.rows, this._spans);
  final String raw;
  final List<Map<String, dynamic>> rows;
  final List<_JsonSpan> _spans;

  static NativeGlobalRegexJson? read(String raw) {
    try {
      if (raw.length > 2 * 1024 * 1024) return null;
      final decoded = jsonDecode(raw);
      if (decoded is! List || decoded.any((e) => e is! Map<String, dynamic>)) {
        return null;
      }
      final parser = _JsonSpans(raw);
      final document = parser.value();
      parser.whitespace();
      if (parser.offset != raw.length || document.elements == null) return null;
      final rows = decoded.cast<Map<String, dynamic>>();
      final ids = <String>{};
      for (final row in rows) {
        final id = row['id'];
        if (id is! String ||
            id.isEmpty ||
            !ids.add(id) ||
            row['disabled'] is! bool)
          return null;
      }
      return NativeGlobalRegexJson._(raw, rows, document.elements!);
    } catch (_) {
      return null;
    }
  }

  String disabled(int index) {
    final span = _spans[index].fields!['disabled']!;
    return raw.replaceRange(span.start, span.end, 'true');
  }
}

final class _JsonSpan {
  const _JsonSpan(this.start, this.end, {this.fields, this.elements});
  final int start, end;
  final Map<String, _JsonSpan>? fields;
  final List<_JsonSpan>? elements;
}

/// The document is validated by jsonDecode first. This scanner only retains
/// token boundaries and refuses duplicate JSON members (including escaped keys).
final class _JsonSpans {
  _JsonSpans(this.raw);
  final String raw;
  int offset = 0;
  void whitespace() {
    while (offset < raw.length &&
        const [9, 10, 13, 32].contains(raw.codeUnitAt(offset))) {
      offset++;
    }
  }

  _JsonSpan value() {
    whitespace();
    final start = offset;
    final first = raw[offset++];
    if (first == '{') {
      final fields = <String, _JsonSpan>{};
      whitespace();
      while (raw[offset] != '}') {
        final keySpan = value();
        final key =
            jsonDecode(raw.substring(keySpan.start, keySpan.end)) as String;
        whitespace();
        if (raw[offset++] != ':' || fields.containsKey(key)) {
          throw const FormatException('Ambiguous JSON member');
        }
        fields[key] = value();
        whitespace();
        if (raw[offset] == '}') break;
        if (raw[offset++] != ',') throw const FormatException('JSON delimiter');
        whitespace();
      }
      offset++;
      return _JsonSpan(start, offset, fields: fields);
    }
    if (first == '[') {
      final elements = <_JsonSpan>[];
      whitespace();
      while (raw[offset] != ']') {
        elements.add(value());
        whitespace();
        if (raw[offset] == ']') break;
        if (raw[offset++] != ',') throw const FormatException('JSON delimiter');
        whitespace();
      }
      offset++;
      return _JsonSpan(start, offset, elements: elements);
    }
    if (first == '"') {
      while (raw[offset] != '"') {
        if (raw[offset++] == '\\') offset++;
      }
      offset++;
    } else {
      while (offset < raw.length &&
          !const [
            9,
            10,
            13,
            32,
            44,
            93,
            125,
          ].contains(raw.codeUnitAt(offset))) {
        offset++;
      }
    }
    return _JsonSpan(start, offset);
  }
}
