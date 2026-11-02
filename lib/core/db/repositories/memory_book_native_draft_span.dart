part of 'memory_book_repo.dart';

/// A span in an already validated, finite drafts array. Replacing one JSON string
/// token preserves every other byte, including unknown values and whitespace.
final class _NativeDraftTextSpan {
  const _NativeDraftTextSpan(
    this.start,
    this.end,
    this.objectStart,
    this.objectEnd,
  );
  final int start, end, objectStart, objectEnd;
  String replace(String raw, String content) =>
      raw.substring(0, start) + jsonEncode(content) + raw.substring(end);

  static _NativeDraftTextSpan? locate(String raw, int index) {
    int space(int at) {
      while (at < raw.length && ' \r\n\t'.contains(raw[at])) {
        at++;
      }
      return at;
    }

    int stringEnd(int at) {
      for (var i = at + 1; i < raw.length; i++) {
        if (raw[i] == '\\') {
          i++;
        } else if (raw[i] == '"') {
          return i + 1;
        }
      }
      throw const FormatException('Unterminated draft token');
    }

    int valueEnd(int at) {
      if (raw[at] == '"') return stringEnd(at);
      if (raw[at] == '{' || raw[at] == '[') {
        var depth = 0;
        for (var i = at; i < raw.length; i++) {
          if (raw[i] == '"') {
            i = stringEnd(i) - 1;
          } else if (raw[i] == '{' || raw[i] == '[') {
            depth++;
          } else if (raw[i] == '}' || raw[i] == ']') {
            if (--depth == 0) return i + 1;
          }
        }
        throw const FormatException('Unterminated draft object');
      }
      var end = at;
      while (end < raw.length && !',]} \r\n\t'.contains(raw[end])) {
        end++;
      }
      return end;
    }

    var at = space(0);
    if (raw[at++] != '[') return null;
    at = space(at);
    for (var n = 0; n < index; n++) {
      at = space(valueEnd(at));
      if (raw[at++] != ',') return null;
      at = space(at);
    }
    final objectStart = at, objectEnd = valueEnd(at);
    if (raw[at++] != '{') return null;
    at = space(at);
    while (raw[at] != '}') {
      if (raw[at] != '"') return null;
      final keyEnd = stringEnd(at);
      final key = jsonDecode(raw.substring(at, keyEnd));
      at = space(keyEnd);
      if (raw[at++] != ':') return null;
      at = space(at);
      final end = valueEnd(at);
      if (key == 'content') {
        return raw[at] == '"'
            ? _NativeDraftTextSpan(at, end, objectStart, objectEnd)
            : null;
      }
      at = space(end);
      if (raw[at] == '}') break;
      if (raw[at++] != ',') return null;
      at = space(at);
    }
    return null;
  }
}
