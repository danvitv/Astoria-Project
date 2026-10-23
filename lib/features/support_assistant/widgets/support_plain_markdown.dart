import 'package:flutter/material.dart';

/// Passive, native-selectable support text. This is not a full Markdown engine.
///
/// Only paired `*italic*` and `**bold**` delimiters are removed. Different kinds
/// may nest once, including `***both***`; same-kind nesting and crossing
/// delimiters are not supported. A crossing delimiter is literal. Unmatched
/// delimiters remain literal, even when a nested pair is matched.
///
/// Runs longer than three stars are literal. Openers must precede non-whitespace
/// and closers must follow non-whitespace; interiors may contain newlines. An
/// odd run of backslashes immediately before stars makes that entire star run
/// literal. All backslashes, whitespace and Unicode code units are preserved.
/// Backtick-delimited text is literal through an equal-length closing backtick
/// run (or end of input for an unmatched opener); backticks are also preserved.
///
/// Links, images, HTML, URLs and tool-shaped prose have no special behavior:
/// their syntax stays text, with only the above emphasis rules applied outside
/// backticks. There are no resource loaders, recognizers or action callbacks.
/// Native selection gestures remain available; no context menu is installed.
/// This widget does not sanitize or authorize text: pass already-verified text.
class SupportPlainMarkdown extends StatelessWidget {
  /// Maximum admitted input length, measured in UTF-16 code units.
  static const int maxTextLength = 65536;

  final String text;
  final TextStyle? style;

  const SupportPlainMarkdown({super.key, required this.text, this.style});

  /// Builds an immutable, flat span tree without a context or side effects.
  ///
  /// Parsing is O(n) time and O(n) space, with at most two open delimiters,
  /// no recursion and no regular expressions. Oversize input throws a fixed
  /// [ArgumentError] before scanning; it is never silently truncated and the
  /// exception contains no input text. The caller owns the limited-outcome UI.
  TextSpan toTextSpan() {
    if (text.length > maxTextLength) {
      throw ArgumentError('Support text exceeds 65536 UTF-16 code units.');
    }
    return _EmphasisScanner(text).toTextSpan(style);
  }

  @override
  Widget build(BuildContext context) => SelectableText.rich(
    toTextSpan(),
    contextMenuBuilder: null,
    showCursor: false,
  );
}

class _EmphasisScanner {
  final String text;
  final _markers = <_EmphasisMarker>[];
  final _open = <_EmphasisMarker>[];

  _EmphasisScanner(this.text);

  TextSpan toTextSpan(TextStyle? style) {
    _scan();
    final spans = <TextSpan>[];
    var offset = 0;
    var emphasis = 0;
    for (final marker in _markers) {
      if (!marker.matched) continue;
      if (offset < marker.offset) {
        spans.add(
          TextSpan(
            text: text.substring(offset, marker.offset),
            style: _style(emphasis),
          ),
        );
      }
      emphasis ^= marker.width == 1 ? 1 : 2;
      offset = marker.offset + marker.width;
    }
    if (offset < text.length || spans.isEmpty) {
      spans.add(
        TextSpan(text: text.substring(offset), style: _style(emphasis)),
      );
    }
    return TextSpan(style: style, children: List<TextSpan>.unmodifiable(spans));
  }

  void _scan() {
    var offset = 0;
    var backslashes = 0;
    var backticks = 0;
    while (offset < text.length) {
      final code = text.codeUnitAt(offset);
      if (code == 0x60) {
        final start = offset;
        while (offset < text.length && text.codeUnitAt(offset) == 0x60) {
          offset++;
        }
        final width = offset - start;
        if (backticks == 0) {
          backticks = width;
        } else if (backticks == width) {
          backticks = 0;
        }
        backslashes = 0;
        continue;
      }
      if (code != 0x2a || backticks != 0) {
        backslashes = code == 0x5c ? backslashes + 1 : 0;
        offset++;
        continue;
      }
      final start = offset;
      while (offset < text.length && text.codeUnitAt(offset) == 0x2a) {
        offset++;
      }
      final width = offset - start;
      final escaped = backslashes.isOdd;
      backslashes = 0;
      if (escaped || width > 3) continue;
      final canOpen = offset < text.length && !_isWhitespace(offset);
      final canClose = start > 0 && !_isWhitespace(start - 1);
      if (width == 3) {
        if (_open.length == 2 && canClose) {
          final firstWidth = _open.last.width;
          _accept(start, firstWidth, canOpen: false, canClose: true);
          _accept(
            start + firstWidth,
            3 - firstWidth,
            canOpen: false,
            canClose: true,
          );
        } else if (_open.isEmpty && canOpen) {
          _accept(start, 2, canOpen: true, canClose: false);
          _accept(start + 2, 1, canOpen: true, canClose: false);
        }
        // With only one kind open, a triple run is deliberately literal.
      } else {
        _accept(start, width, canOpen: canOpen, canClose: canClose);
      }
    }
  }

  void _accept(
    int offset,
    int width, {
    required bool canOpen,
    required bool canClose,
  }) {
    if (_open.isNotEmpty && _open.last.width == width && canClose) {
      final opener = _open.last;
      if (offset <= opener.offset + opener.width) return;
      final closer = _EmphasisMarker(offset, width)..matched = true;
      opener.matched = true;
      _markers.add(closer);
      _open.removeLast();
    } else if (canOpen && !_open.any((marker) => marker.width == width)) {
      final opener = _EmphasisMarker(offset, width);
      _markers.add(opener);
      _open.add(opener);
    }
  }

  bool _isWhitespace(int offset) {
    final code = text.codeUnitAt(offset);
    return (code >= 0x09 && code <= 0x0d) ||
        code == 0x20 ||
        code == 0x85 ||
        code == 0xa0 ||
        code == 0x1680 ||
        (code >= 0x2000 && code <= 0x200a) ||
        code == 0x2028 ||
        code == 0x2029 ||
        code == 0x202f ||
        code == 0x205f ||
        code == 0x3000 ||
        code == 0xfeff;
  }

  static TextStyle? _style(int emphasis) => switch (emphasis) {
    1 => const TextStyle(fontStyle: FontStyle.italic),
    2 => const TextStyle(fontWeight: FontWeight.w700),
    3 => const TextStyle(
      fontWeight: FontWeight.w700,
      fontStyle: FontStyle.italic,
    ),
    _ => null,
  };
}

class _EmphasisMarker {
  final int offset;
  final int width;
  bool matched = false;

  _EmphasisMarker(this.offset, this.width);
}
