part of 'native_provider_transport.dart';

final class _NativeOutputPiece {
  const _NativeOutputPiece(this.value, this.reasoning);
  final String value;
  final bool reasoning;
}

/// Hold the unresolved lexical token BEFORE any publication. Native keys and
/// their JSON/URI/base64 forms contain no whitespace, so a split key can never
/// cross two published tokens. Arrival-order holding also covers cross-lane
/// echoes. A contaminated cross-lane token becomes one marker in its first lane.
/// Long space-free prose is intentionally delayed until terminal (bounded).
final class _NativeOutputGate {
  _NativeOutputGate({
    required this._redactor,
    required this.check,
    required this.callback,
    required this.showReasoning,
    required this.structured,
    required this.hasCredential,
    required this.hasCrossLaneCredential,
  });
  final SecretRedactor Function() _redactor;
  final void Function() check;
  final ChatTransportOnUpdate? callback;
  final bool showReasoning;
  final bool structured;
  final bool Function(String) hasCredential;
  final bool Function(String, String) hasCrossLaneCredential;
  final _pending = <_NativeOutputPiece>[];
  final _text = StringBuffer();
  final _reasoning = StringBuffer();
  int _rawCharacters = 0;
  int _publishedCharacters = 0;
  int _pendingCharacters = 0;
  String get text => _text.toString();
  String get reasoning => _reasoning.toString();

  void add(String text, String reasoning) {
    check();
    _rawCharacters += text.length + reasoning.length;
    _nativeRequire(
      _rawCharacters <= NativeProviderTransportLimits.outputCharacters &&
          utf8.decode(utf8.encode(text)) == text &&
          utf8.decode(utf8.encode(reasoning)) == reasoning,
      NativeProviderTransportReason.outputLimit,
    );
    if (!structured &&
        (reasoning.isNotEmpty || _pending.any((piece) => piece.reasoning))) {
      final textLane =
          _pending
              .where((piece) => !piece.reasoning)
              .map((piece) => piece.value)
              .join() +
          text;
      final reasoningLane =
          _pending
              .where((piece) => piece.reasoning)
              .map((piece) => piece.value)
              .join() +
          reasoning;
      // Provider objects do not prescribe a channel concatenation order. Before
      // either lane flushes, detect both possible joined echoes as well as the
      // actual pending order. Never publish a complementary suffix first.
      final opposite = hasCrossLaneCredential(textLane, reasoningLane)
          ? '$textLane$reasoningLane'
          : hasCrossLaneCredential(reasoningLane, textLane)
          ? '$reasoningLane$textLane'
          : null;
      if (opposite != null) {
        final firstLane = _pending.isNotEmpty
            ? _pending.first.reasoning
            : text.isEmpty;
        _pending.clear();
        _pendingCharacters = 0;
        _emit(_safe(opposite), firstLane);
        return;
      }
    }
    _addLane(text, false);
    _addLane(reasoning, true);
  }

  void _addLane(String delta, bool reasoning) {
    check();
    if (delta.isEmpty) return;
    // Structured text is held whole and unwrapped only after terminal proof.
    if (structured && !reasoning) {
      _pending.add(_NativeOutputPiece(delta, false));
      _pendingCharacters += delta.length;
      return;
    }
    var start = 0;
    for (final match in RegExp(r'\s+').allMatches(delta)) {
      if (match.end > start) {
        _pending.add(
          _NativeOutputPiece(delta.substring(start, match.end), reasoning),
        );
        _pendingCharacters += match.end - start;
      }
      if (!structured) _flush();
      start = match.end;
    }
    if (start < delta.length) {
      _pending.add(_NativeOutputPiece(delta.substring(start), reasoning));
      _pendingCharacters += delta.length - start;
    }
    _nativeRequire(
      _pendingCharacters <= NativeProviderTransportLimits.outputCharacters,
      NativeProviderTransportReason.outputLimit,
    );
  }

  void finish() {
    check();
    if (structured) {
      // Do not publish complementary key fragments in separate schema/reasoning
      // results. Schema output is terminal-only, so dropping a contaminated
      // cross-lane payload is safer than inventing a repaired JSON document.
      final text = _pending
          .where((piece) => !piece.reasoning)
          .map((piece) => piece.value)
          .join();
      final reasoning = _pending
          .where((piece) => piece.reasoning)
          .map((piece) => piece.value)
          .join();
      if (hasCredential(_pending.map((piece) => piece.value).join()) ||
          hasCredential('$text$reasoning') ||
          hasCredential('$reasoning$text')) {
        _emit(SecretRedactor.removed, false, publish: false);
        _pending.clear();
        return;
      }
      // Bound/depth-check before the existing pure structured text unwrapping.
      _nativeJson(text);
      _emit(_safe(unwrapStructuredResponse(text)), false, publish: false);
      _emit(_safe(reasoning), true, publish: false);
      _pending.clear();
    } else {
      _flush();
    }
  }

  void _flush() {
    if (_pending.isEmpty) return;
    check();
    final original = _pending.map((piece) => piece.value).join();
    final safe = _safe(original);
    if (safe != original) {
      _emit(safe, _pending.first.reasoning);
    } else {
      for (final piece in _pending) {
        _emit(piece.value, piece.reasoning);
      }
    }
    _pending.clear();
    _pendingCharacters = 0;
  }

  String _safe(String input) {
    final safe = _redactor().redactText(input);
    _nativeRequire(
      safe != SecretRedactor.limited &&
          safe.length <= NativeProviderTransportLimits.outputCharacters,
      NativeProviderTransportReason.sanitationLimit,
    );
    return safe;
  }

  void _emit(String value, bool reasoning, {bool publish = true}) {
    if (value.isEmpty || (reasoning && !showReasoning)) return;
    check();
    _publishedCharacters += value.length;
    _nativeRequire(
      _publishedCharacters <= NativeProviderTransportLimits.outputCharacters,
      NativeProviderTransportReason.outputLimit,
    );
    (reasoning ? _reasoning : _text).write(value);
    if (publish && callback != null) {
      callback!(reasoning ? '' : value, reasoning ? value : null);
      check(); // A callback can synchronously revoke the original job.
    }
  }
}
