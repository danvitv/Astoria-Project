class StreamAccumulator {
  final String? tagStart;
  final String? tagEnd;
  final bool hasInlineTags;
  final String? headerModel;
  final String? headerInline;

  StringBuffer _raw = StringBuffer();
  StringBuffer _text = StringBuffer();
  StringBuffer _externalReasoning = StringBuffer();
  StringBuffer _inlineReasoning = StringBuffer();
  StringBuffer _tagCandidate = StringBuffer();
  StringBuffer _variantCandidate = StringBuffer();
  bool _hasExternalReasoning = false;
  bool _splitDone = false;
  _ParsePhase _phase = _ParsePhase.beforeReasoning;
  List<bool> _variantOpenPossible = const [];
  List<bool> _variantClosePossible = const [];
  List<bool> _variantOpenTail = const [];
  List<bool> _variantCloseTail = const [];
  late final String? _configuredThinkVariant = _resolveThinkVariant(
    tagStart: tagStart,
    tagEnd: tagEnd,
    enabled: _parsesInline,
  );

  StreamAccumulator({
    this.tagStart,
    this.tagEnd,
    this.hasInlineTags = false,
    this.headerModel,
    this.headerInline,
  });

  bool get _parsesInline => hasInlineTags && tagStart != null && tagEnd != null;

  bool get _normalizesThinkVariants => _configuredThinkVariant != null;

  List<String> get _alternateOpen => switch (_configuredThinkVariant) {
    'think' => const ['<thinking', '<thought'],
    'thinking' => const ['<think', '<thought'],
    'thought' => const ['<think', '<thinking'],
    _ => const [],
  };
  List<String> get _alternateClose => switch (_configuredThinkVariant) {
    'think' => const ['</thinking', '</thought'],
    'thinking' => const ['</think', '</thought'],
    'thought' => const ['</think', '</thinking'],
    _ => const [],
  };

  void consumeDelta(String delta, {String? reasoningDelta}) {
    if (reasoningDelta != null && reasoningDelta.isNotEmpty) {
      _externalReasoning.write(reasoningDelta);
      _hasExternalReasoning = true;
    }

    if (!_parsesInline) {
      _text.write(delta);
      return;
    }

    _openEmptyTagIfNeeded();
    for (var i = 0; i < delta.length; i++) {
      _consumeVariantChar(delta[i]);
    }
  }

  void _openEmptyTagIfNeeded() {
    if (_phase != _ParsePhase.beforeReasoning || tagStart!.isNotEmpty) return;
    _phase = _ParsePhase.inReasoning;
    _trimTextLeft();
    if (tagEnd!.isEmpty) _closeReasoning();
  }

  void _consumeVariantChar(String char) {
    if (!_normalizesThinkVariants) {
      _emitNormalized(char);
      return;
    }

    if (_variantCandidate.isEmpty) {
      if (char != '<') {
        _emitNormalized(char);
        return;
      }
      _variantCandidate.write(char);
      _variantOpenPossible = List.filled(_alternateOpen.length, true);
      _variantClosePossible = List.filled(_alternateClose.length, true);
      _variantOpenTail = List.filled(_alternateOpen.length, false);
      _variantCloseTail = List.filled(_alternateClose.length, false);
      return;
    }

    _variantCandidate.write(char);
    final index = _variantCandidate.length - 1;
    final openComplete = _advanceVariants(
      char,
      index,
      _alternateOpen,
      possible: _variantOpenPossible,
      tails: _variantOpenTail,
    );
    final closeComplete = _advanceVariants(
      char,
      index,
      _alternateClose,
      possible: _variantClosePossible,
      tails: _variantCloseTail,
    );
    if (openComplete || closeComplete) {
      _clearVariantCandidate();
      _emitNormalized(openComplete ? tagStart! : tagEnd!);
    } else if (!_variantOpenPossible.any((value) => value) &&
        !_variantClosePossible.any((value) => value)) {
      _rejectVariantCandidate();
    }
  }

  bool _advanceVariants(
    String char,
    int index,
    List<String> literals, {
    required List<bool> possible,
    required List<bool> tails,
  }) {
    var complete = false;
    for (var variant = 0; variant < literals.length; variant++) {
      if (!possible[variant]) continue;
      final literal = literals[variant];
      if (index < literal.length) {
        possible[variant] = char.toLowerCase() == literal[index];
      } else if (!tails[variant]) {
        if (_isWordCharacter(char)) {
          possible[variant] = false;
        } else if (char == '>') {
          complete = true;
        } else {
          tails[variant] = true;
        }
      } else if (char == '>') {
        complete = true;
      }
    }
    return complete;
  }

  bool _isWordCharacter(String char) {
    final code = char.codeUnitAt(0);
    return (code >= 0x30 && code <= 0x39) ||
        (code >= 0x41 && code <= 0x5a) ||
        code == 0x5f ||
        (code >= 0x61 && code <= 0x7a);
  }

  void _rejectVariantCandidate() {
    final rejected = _variantCandidate.toString();
    final restart = rejected.lastIndexOf('<');
    _clearVariantCandidate();
    final committedEnd = restart > 0 ? restart : 1;
    _emitNormalized(rejected.substring(0, committedEnd));
    for (var i = committedEnd; i < rejected.length; i++) {
      _consumeVariantChar(rejected[i]);
    }
  }

  void _clearVariantCandidate() {
    _variantCandidate = StringBuffer();
    _variantOpenPossible = const [];
    _variantClosePossible = const [];
    _variantOpenTail = const [];
    _variantCloseTail = const [];
  }

  void _emitNormalized(String value) {
    _raw.write(value);
    if (_phase == _ParsePhase.afterReasoning) {
      _writeVisibleText(value);
      return;
    }

    for (var i = 0; i < value.length; i++) {
      _consumeTagChar(value[i]);
    }
  }

  void _consumeTagChar(String char) {
    final target = _phase == _ParsePhase.beforeReasoning ? tagStart! : tagEnd!;
    if (target.isEmpty) {
      if (_phase == _ParsePhase.inReasoning) _closeReasoning();
      _writeVisibleText(char);
      return;
    }

    final index = _tagCandidate.length;
    if (char == target[index]) {
      _tagCandidate.write(char);
      if (_tagCandidate.length == target.length) {
        _tagCandidate = StringBuffer();
        if (_phase == _ParsePhase.beforeReasoning) {
          _phase = _ParsePhase.inReasoning;
          _trimTextLeft();
          if (tagEnd!.isEmpty) _closeReasoning();
        } else {
          _closeReasoning();
        }
      }
      return;
    }

    final rejected = '${_tagCandidate.toString()}$char';
    _tagCandidate = StringBuffer();
    _writeCurrent(rejected[0]);
    for (var i = 1; i < rejected.length; i++) {
      _consumeTagChar(rejected[i]);
    }
  }

  void _closeReasoning() {
    _phase = _ParsePhase.afterReasoning;
    _splitDone = true;
  }

  void _writeCurrent(String value) {
    if (_phase == _ParsePhase.inReasoning) {
      _inlineReasoning.write(value);
    } else {
      _writeVisibleText(value);
    }
  }

  void _writeVisibleText(String value) {
    if (_phase == _ParsePhase.afterReasoning && _text.isEmpty) {
      value = value.trimLeft();
    }
    _text.write(value);
  }

  void _trimTextLeft() {
    final trimmed = _text.toString().trimLeft();
    _text = StringBuffer(trimmed);
  }

  void flush() {}

  String _combineReasoning() {
    final external = _externalReasoning.toString().trim();
    final inline = _inlineReasoningWithPending.trim();

    if (external.isNotEmpty && inline.isNotEmpty) {
      final hModel = headerModel ?? '';
      final hInline = headerInline ?? '';
      final prefix = hModel.isNotEmpty ? '$hModel\n' : '';
      final midfix = hInline.isNotEmpty ? '$hInline\n' : '';
      return '$prefix$external\n\n---\n\n$midfix$inline';
    }
    return inline.isNotEmpty ? inline : external;
  }

  String get _pending =>
      '${_tagCandidate.toString()}${_variantCandidate.toString()}';

  String get _inlineReasoningWithPending =>
      '${_inlineReasoning.toString()}${_phase == _ParsePhase.inReasoning ? _pending : ''}';

  String get text =>
      '${_text.toString()}${_phase == _ParsePhase.inReasoning ? '' : _pending}';
  String get reasoning => _combineReasoning();
  bool get hasExternalReasoning => _hasExternalReasoning;
  bool get splitDone => _splitDone;

  String get raw =>
      _parsesInline ? '${_raw.toString()}${_variantCandidate.toString()}' : '';

  void reset() {
    _raw = StringBuffer();
    _text = StringBuffer();
    _externalReasoning = StringBuffer();
    _inlineReasoning = StringBuffer();
    _tagCandidate = StringBuffer();
    _clearVariantCandidate();
    _hasExternalReasoning = false;
    _splitDone = false;
    _phase = _ParsePhase.beforeReasoning;
  }
}

enum _ParsePhase { beforeReasoning, inReasoning, afterReasoning }

String? _resolveThinkVariant({
  required String? tagStart,
  required String? tagEnd,
  required bool enabled,
}) {
  if (!enabled) return null;
  final startLower = tagStart!.toLowerCase();
  final endLower = tagEnd!.toLowerCase();
  for (final variant in const ['thinking', 'thought', 'think']) {
    if (startLower.startsWith('<$variant') &&
        endLower.startsWith('</$variant')) {
      return variant;
    }
  }
  return null;
}
