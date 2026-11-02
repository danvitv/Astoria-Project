part of 'support_plain_markdown.dart';

enum _SupportBlockKind { heading, listMarker, code }

class _SupportTextBlock {
  final int start;
  final int end;
  final _SupportBlockKind kind;
  final int level;

  const _SupportTextBlock(this.start, this.end, this.kind, [this.level = 0]);
}

/// Produces disjoint source-offset style ranges, never transformed text.
/// The caller admits bounded input first. Each line and delimiter run is visited
/// a constant number of times; a pending fence never searches ahead or recurses.
class _SupportBlockScanner {
  final String text;
  var _inlineTicks = 0;

  _SupportBlockScanner(this.text);

  List<_SupportTextBlock> scan() {
    final blocks = <_SupportTextBlock>[];
    var start = 0;
    var fenceStart = -1;
    var fenceCode = 0;
    var fenceWidth = 0;
    while (start < text.length) {
      var contentEnd = start;
      while (contentEnd < text.length &&
          text.codeUnitAt(contentEnd) != 0x0a &&
          text.codeUnitAt(contentEnd) != 0x0d) {
        contentEnd++;
      }
      var end = contentEnd;
      if (end < text.length) {
        if (text.codeUnitAt(end++) == 0x0d &&
            end < text.length &&
            text.codeUnitAt(end) == 0x0a) {
          end++;
        }
      }
      var prefix = start;
      while (prefix < contentEnd && text.codeUnitAt(prefix) == 0x20) {
        prefix++;
      }
      final fence = prefix - start <= 3 ? _fence(prefix, contentEnd) : null;
      if (fenceStart >= 0) {
        if (fence != null &&
            fence.code == fenceCode &&
            fence.width == fenceWidth &&
            fence.bare) {
          blocks.add(
            _SupportTextBlock(fenceStart, end, _SupportBlockKind.code),
          );
          fenceStart = -1;
        }
      } else if (_inlineTicks == 0 && fence != null && fence.canOpen) {
        fenceStart = start;
        fenceCode = fence.code;
        fenceWidth = fence.width;
      } else {
        if (_inlineTicks == 0) {
          final block = _lineStyle(start, prefix, contentEnd, end);
          if (block != null) blocks.add(block);
        }
        _scanInlineTicks(start, contentEnd);
      }
      start = end;
    }
    // An unresolved fence gets no block style and removes no source characters.
    return blocks;
  }

  ({int code, int width, bool bare, bool canOpen})? _fence(int start, int end) {
    if (start == end) return null;
    final code = text.codeUnitAt(start);
    if (code != 0x60 && code != 0x7e) return null;
    var offset = start;
    while (offset < end && text.codeUnitAt(offset) == code) {
      offset++;
    }
    final width = offset - start;
    if (width < 3) return null;
    var bare = true;
    var canOpen = true;
    while (offset < end) {
      final next = text.codeUnitAt(offset++);
      if (next != 0x20 && next != 0x09) bare = false;
      if (code == 0x60 && next == 0x60) canOpen = false;
    }
    return (code: code, width: width, bare: bare, canOpen: canOpen);
  }

  _SupportTextBlock? _lineStyle(int start, int prefix, int end, int lineEnd) {
    if (prefix == end) return null;
    if (prefix - start <= 3 && text.codeUnitAt(prefix) == 0x23) {
      var offset = prefix;
      while (offset < end && text.codeUnitAt(offset) == 0x23) {
        offset++;
      }
      final level = offset - prefix;
      if (level <= 6 && offset < end && _horizontalSpace(offset)) {
        return _SupportTextBlock(
          start,
          lineEnd,
          _SupportBlockKind.heading,
          level,
        );
      }
    }
    // List indentation remains exactly the original spaces/tabs, including
    // nested-looking items; there is no tree or list widget behind these spans.
    while (prefix < end && _horizontalSpace(prefix)) {
      prefix++;
    }
    if (prefix == end) return null;
    var offset = prefix;
    final code = text.codeUnitAt(offset);
    if (code == 0x2d || code == 0x2b || code == 0x2a) {
      offset++;
    } else {
      while (offset < end &&
          text.codeUnitAt(offset) >= 0x30 &&
          text.codeUnitAt(offset) <= 0x39) {
        offset++;
      }
      if (offset == prefix || offset - prefix > 9 || offset == end) return null;
      final delimiter = text.codeUnitAt(offset++);
      if (delimiter != 0x2e && delimiter != 0x29) return null;
    }
    if (offset == end || !_horizontalSpace(offset)) return null;
    while (offset < end && _horizontalSpace(offset)) {
      offset++;
    }
    return _SupportTextBlock(start, offset, _SupportBlockKind.listMarker);
  }

  void _scanInlineTicks(int start, int end) {
    var offset = start;
    while (offset < end) {
      if (text.codeUnitAt(offset) != 0x60) {
        offset++;
        continue;
      }
      final runStart = offset;
      while (offset < end && text.codeUnitAt(offset) == 0x60) {
        offset++;
      }
      final width = offset - runStart;
      if (_inlineTicks == 0) {
        _inlineTicks = width;
      } else if (_inlineTicks == width) {
        _inlineTicks = 0;
      }
    }
  }

  bool _horizontalSpace(int offset) {
    final code = text.codeUnitAt(offset);
    return code == 0x20 || code == 0x09;
  }
}

/// Overlays block styles on the unchanged emphasis scanner's source ranges.
/// One forward-only cursor keeps the emitted tree flat and linear-sized.
class _SupportBlockSpanBuilder {
  final String text;
  final TextStyle? rootStyle;
  final List<_SupportTextBlock> blocks;
  final spans = <TextSpan>[];
  var _blockIndex = 0;

  _SupportBlockSpanBuilder(this.text, this.rootStyle, this.blocks);

  void add(int start, int end, int emphasis) {
    if (start == end) {
      spans.add(TextSpan(text: '', style: _EmphasisScanner._style(emphasis)));
      return;
    }
    while (start < end) {
      while (_blockIndex < blocks.length && blocks[_blockIndex].end <= start) {
        _blockIndex++;
      }
      final block = _blockIndex < blocks.length ? blocks[_blockIndex] : null;
      final styled = block != null && block.start <= start;
      final boundary = block == null ? end : (styled ? block.end : block.start);
      final next = boundary < end ? boundary : end;
      spans.add(
        TextSpan(
          text: text.substring(start, next),
          style: block != null && styled
              ? _style(block, emphasis)
              : _EmphasisScanner._style(emphasis),
        ),
      );
      start = next;
    }
  }

  TextStyle _style(_SupportTextBlock block, int emphasis) {
    if (block.kind == _SupportBlockKind.code) {
      return const TextStyle(
        fontFamily: 'monospace',
        fontWeight: FontWeight.w400,
        fontStyle: FontStyle.normal,
        height: 1.5,
      );
    }
    double? size;
    if (block.kind == _SupportBlockKind.heading) {
      final requested = rootStyle?.fontSize;
      final base = requested != null && requested.isFinite && requested > 0
          ? requested.clamp(10.0, 24.0).toDouble()
          : 14.0;
      const factors = [1.5, 1.35, 1.25, 1.15, 1.1, 1.05];
      size = base * factors[block.level - 1];
    }
    return TextStyle(
      fontSize: size,
      fontWeight: (emphasis & 2) != 0 ? FontWeight.w700 : FontWeight.w600,
      fontStyle: (emphasis & 1) != 0 ? FontStyle.italic : null,
    );
  }
}
