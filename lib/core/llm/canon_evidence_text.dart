import 'dart:convert';

/// A read-only evidence projection, never a rewrite of the saved transcript.
/// Only explicitly marked assistant OOC is excluded. User corrections and
/// instructions remain intact, including when they are written in OOC.
abstract final class CanonEvidenceText {
  static final _oocTag = RegExp(
    r'<(/?)([\w:-]*ooc[\w:-]*)\b[^>]*>',
    caseSensitive: false,
  );
  static final _bracketOoc = RegExp(r'\[\s*OOC\s*:', caseSensitive: false);
  static final _parenOoc = RegExp(r'\(\s*OOC\s*:', caseSensitive: false);
  static final _doubleParen = RegExp(r'\(\(');

  static String forMessage(String role, String content) =>
      role == 'assistant' ? assistantNarrative(content) : content;

  static String assistantNarrative(String text) {
    final out = StringBuffer();
    final stack = <String>[];
    var offset = 0;
    for (final match in _oocTag.allMatches(text)) {
      if (stack.isEmpty) out.write(text.substring(offset, match.start));
      final name = match.group(2)!.toLowerCase();
      if (match.group(1)!.isEmpty) {
        if (!match.group(0)!.endsWith('/>')) stack.add(name);
      } else if (stack.isNotEmpty && stack.last == name) {
        stack.removeLast();
      }
      if (stack.isEmpty) out.write('\n');
      offset = match.end;
    }
    // An unclosed/mismatched OOC wrapper remains excluded to EOF, rather than
    // laundering its unfinished forecast into scene evidence.
    if (stack.isEmpty) out.write(text.substring(offset));
    var result = out.toString();
    result = _withoutBalanced(result, _bracketOoc, '[', ']');
    result = _withoutBalanced(result, _doubleParen, '(', ')');
    return _withoutBalanced(result, _parenOoc, '(', ')');
  }

  static String _withoutBalanced(
    String text,
    RegExp opening,
    String left,
    String right,
  ) {
    final out = StringBuffer();
    var offset = 0;
    while (offset < text.length) {
      final match = opening.firstMatch(text.substring(offset));
      if (match == null) {
        out.write(text.substring(offset));
        break;
      }
      final start = offset + match.start;
      out.write(text.substring(offset, start));
      var depth = 0;
      var end = start;
      do {
        if (text[end] == left) depth++;
        if (text[end] == right) depth--;
        end++;
      } while (end < text.length && depth > 0);
      out.write('\n');
      offset = end;
    }
    return out.toString();
  }

  /// Preserve evidence IDs, roles, metadata and all non-history context. The
  /// stored immutable input/hash is unchanged; only model-facing text differs.
  static String projectContextJson(String input) {
    final decoded = jsonDecode(input);
    if (decoded is! Map || decoded['chatHistory'] is! List) return input;
    var changed = false;
    final history = <Object?>[];
    for (final message in decoded['chatHistory'] as List) {
      if (message is! Map || message['content'] is! String) {
        history.add(message);
        continue;
      }
      final content = message['content'] as String;
      final projected = forMessage(message['role'] as String? ?? '', content);
      changed |= projected != content;
      history.add({...message, 'content': projected});
    }
    return changed ? jsonEncode({...decoded, 'chatHistory': history}) : input;
  }
}
